import ObjectiveC
import XCTest

final class GitXInteropContractTests: XCTestCase {
    func testRequiredObjectiveCRuntimeSelectorsRemainAvailable() {
        XCTAssertNotNil(class_getClassMethod(PBTask.self, NSSelectorFromString("taskWithLaunchPath:arguments:inDirectory:")))
        XCTAssertNotNil(class_getClassMethod(PBTask.self, NSSelectorFromString("launchTask:arguments:inDirectory:completionHandler:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTask.self, NSSelectorFromString("launchTask:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTask.self, NSSelectorFromString("performTaskWithTerminationHandler:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTask.self, NSSelectorFromString("performTaskWithCompletionHandler:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTask.self, NSSelectorFromString("terminateAfterGracePeriod:forceKillAfter:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTaskDiagnosticCapture.self, NSSelectorFromString("seal")))
    }

    func testNativeCaptureBootstrapIsDebugOnly() {
        let bootstrap = NSClassFromString("PBGitXTestProcessDiagnostics")
        #if DEBUG
            XCTAssertNotNil(bootstrap)
            if let bootstrap {
                XCTAssertNotNil(class_getClassMethod(bootstrap, NSSelectorFromString("installAtApplicationStartup")))
            }
        #else
            XCTAssertNil(bootstrap)
        #endif
    }

    func testConfigurationDependentRuntimeSurface() {
        #if DEBUG
            XCTAssertNotNil(NSClassFromString("PBTaskDiagnosticCaptureLifetimeProbe"))
        #else
            XCTAssertNil(NSClassFromString("PBTaskDiagnosticCaptureLifetimeProbe"))
        #endif
        // Compile an actual Swift consumer of the Objective-C import in both
        // configurations; selector checks alone cannot prove import visibility.
        let task = PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil)
        XCTAssertEqual(task.timeout, 30)
    }

    @MainActor
    func testMainQueueTaskConveniencesImportMainActorCallbacks() async {
        let probe = PBTaskMainQueueImportProbe()
        let dataCompleted = expectation(description: "main-queue data convenience")
        let terminationCompleted = expectation(description: "main-queue termination convenience")
        let classCompleted = expectation(description: "main-queue class launch convenience")
        let tasks = startMainQueueImportProbes(probe, dataCompleted: dataCompleted,
                                               terminationCompleted: terminationCompleted, classCompleted: classCompleted)
        defer { tasks.forEach { $0.terminate() } }
        await fulfillment(of: [dataCompleted, terminationCompleted, classCompleted], timeout: 10)
        XCTAssertEqual(probe.callbacks.count, 3)
        XCTAssertEqual(Set(probe.callbacks), Set(["data", "termination", "class"]))
    }

    /// Explicitly nonisolated so the imported block parameter, rather than the
    /// caller's actor, must make these callbacks safe to access the probe.
    private nonisolated func startMainQueueImportProbes(_ probe: PBTaskMainQueueImportProbe,
                                                        dataCompleted: XCTestExpectation,
                                                        terminationCompleted: XCTestExpectation,
                                                        classCompleted: XCTestExpectation) -> [PBTask]
    {
        let dataTask = PBTask(launchPath: "/bin/echo", arguments: ["main-data"], inDirectory: nil)
        dataTask.perform { data, error in
            let importedActor: MainActor = #isolation
            XCTAssertTrue(importedActor === MainActor.shared)
            probe.record("data", data: data, expected: Data("main-data\n".utf8), error: error, completed: dataCompleted)
        }
        let terminationTask = PBTask(launchPath: "/usr/bin/true", arguments: [], inDirectory: nil)
        terminationTask.perform { error in
            let importedActor: MainActor = #isolation
            XCTAssertTrue(importedActor === MainActor.shared)
            probe.record("termination", data: nil, expected: nil, error: error, completed: terminationCompleted)
        }
        PBTask.launch("/bin/echo", arguments: ["class-main"], inDirectory: nil) { data, error in
            let importedActor: MainActor = #isolation
            XCTAssertTrue(importedActor === MainActor.shared)
            probe.record("class", data: data, expected: Data("class-main\n".utf8), error: error, completed: classCompleted)
        }
        return [dataTask, terminationTask]
    }

    func testWorktreeFixtureProbesAreAvailableOnlyInDebug() {
        let selectors = ["repairPreparationCount", "ownershipCaptureCount", "discoveryEvidenceObserver",
                         "repairValidationObserver", "repairValidationResultObserver", "repairPreparationResultObserver",
                         "preferenceFingerprintObserver", "preferenceFingerprintResultObserver", "acceptedDiscoveryObserver", "lifecycleEventObserver",
                         "drainForTestingWithCompletion:", "initWithRepository:taskFactory:repairPreparationObserver:",
                         "refreshRepairPreviewForTesting:ownerIsCurrent:completion:"]
        for name in selectors {
            #if DEBUG
                XCTAssertNotNil(class_getInstanceMethod(PBRepositoryWorktreeService.self, NSSelectorFromString(name)), name)
            #else
                XCTAssertNil(class_getInstanceMethod(PBRepositoryWorktreeService.self, NSSelectorFromString(name)), name)
            #endif
        }
    }

    func testDirectRepairSelectorsAreAbsentInEveryConfiguration() {
        for name in ["repairWorktree:movedTo:completion:", "repairLinksWithRelativePaths:completion:",
                     "beginRepairForTestingWithWorktree:movedTo:relativePaths:ownerIsCurrent:completion:"]
        {
            XCTAssertNil(class_getInstanceMethod(PBRepositoryWorktreeService.self, NSSelectorFromString(name)), name)
        }
    }

    func testWorktreeCompatibilityAndExplicitHistorySelectorsRemainAvailable() {
        let serviceSelectors = [
            "addWorktreeAtPath:branch:createBranch:completion:",
            "removeWorktreeAtPath:force:completion:",
            "lockWorktreeAtPath:reason:completion:",
            "unlockWorktreeAtPath:completion:",
            "pruneWorktreesReportOnly:completion:",
            "preparePrunePreviewWithCompletion:",
            "pruneWithConfirmedPreview:completion:",
            "refreshPrunePreview:ownerIsCurrent:completion:",
            "confirmPrune:ownerIsCurrent:completion:",
            "isSnapshotStale",
            "hasPublishedSnapshot",
            "inventoryStatus",
            "discardPrunePreview:",
            "prepareRepairLinksWithRelativePaths:completion:",
            "prepareRepairWorktree:movedTo:completion:",
            "repairWithConfirmedPreview:completion:",
            "discardRepairPreview:",
        ]
        for name in serviceSelectors {
            XCTAssertNotNil(class_getInstanceMethod(PBRepositoryWorktreeService.self, NSSelectorFromString(name)), name)
        }
        XCTAssertNil(class_getInstanceMethod(PBRepositoryWorktreeService.self, NSSelectorFromString("setInventoryStatus:")), "Inventory status is read-only in every configuration")
        for name in ["showHistoryView:", "returnToHistory:"] {
            XCTAssertNotNil(class_getInstanceMethod(PBGitWindowController.self, NSSelectorFromString(name)), name)
        }
    }
}

@MainActor
private final class PBTaskMainQueueImportProbe {
    private(set) var callbacks: [String] = []

    func record(_ name: String, data: Data?, expected: Data?, error: Error?, completed: XCTestExpectation) {
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertNil(error)
        XCTAssertEqual(data, expected)
        callbacks.append(name)
        completed.fulfill()
    }
}
