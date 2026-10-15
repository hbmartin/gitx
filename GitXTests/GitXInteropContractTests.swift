import ObjectiveC
import XCTest

final class GitXInteropContractTests: XCTestCase {
    func testRequiredObjectiveCRuntimeSelectorsRemainAvailable() {
        XCTAssertNotNil(class_getClassMethod(PBTask.self, NSSelectorFromString("taskWithLaunchPath:arguments:inDirectory:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTask.self, NSSelectorFromString("launchTask:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTask.self, NSSelectorFromString("terminateAfterGracePeriod:forceKillAfter:")))
        XCTAssertNotNil(class_getInstanceMethod(PBTaskDiagnosticCapture.self, NSSelectorFromString("seal")))
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

    func testWorktreeCompatibilityAndExplicitHistorySelectorsRemainAvailable() {
        let serviceSelectors = [
            "addWorktreeAtPath:branch:createBranch:completion:",
            "removeWorktreeAtPath:force:completion:",
            "lockWorktreeAtPath:reason:completion:",
            "unlockWorktreeAtPath:completion:",
            "pruneWorktreesReportOnly:completion:",
            "preparePrunePreviewWithCompletion:",
            "pruneWithConfirmedPreview:completion:",
            "discardPrunePreview:",
            "repairLinksWithRelativePaths:completion:",
            "repairWorktree:movedTo:completion:",
            "prepareRepairLinksWithRelativePaths:completion:",
            "prepareRepairWorktree:movedTo:completion:",
            "repairWithConfirmedPreview:completion:",
            "discardRepairPreview:",
        ]
        for name in serviceSelectors {
            XCTAssertNotNil(class_getInstanceMethod(PBRepositoryWorktreeService.self, NSSelectorFromString(name)), name)
        }
        for name in ["showHistoryView:", "returnToHistory:"] {
            XCTAssertNotNil(class_getInstanceMethod(PBGitWindowController.self, NSSelectorFromString(name)), name)
        }
    }
}
