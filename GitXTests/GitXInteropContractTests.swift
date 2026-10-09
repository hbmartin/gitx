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
}
