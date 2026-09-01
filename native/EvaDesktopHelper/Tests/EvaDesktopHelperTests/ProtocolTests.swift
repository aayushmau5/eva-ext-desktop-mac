import XCTest
@testable import EvaDesktopHelper

final class ProtocolTests: XCTestCase {
    func testDecodeRequest() throws {
        let data = #"{"id":12,"method":"status","params":{}}"#.data(using: .utf8)!
        let request = try Request.decode(from: data)
        XCTAssertEqual(request.id, 12)
        XCTAssertEqual(request.method, "status")
    }

    func testDecodeRequestWithParams() throws {
        let data = #"{"id":7,"method":"action","params":{"kind":"click"}}"#.data(using: .utf8)!
        let request = try Request.decode(from: data)
        XCTAssertEqual(request.id, 7)
        if case .object(let params) = request.params,
           case .string(let kind)? = params["kind"] {
            XCTAssertEqual(kind, "click")
        } else {
            XCTFail("params did not decode as expected: \(request.params)")
        }
    }

    func testEncodeSuccessResponse() {
        let response = Response.ok(id: 12, result: .object(["healthy": .bool(true)]))
        let obj = try! JSONSerialization.jsonObject(with: response.encode()) as! [String: Any]
        XCTAssertEqual(obj["id"] as? Int, 12)
        XCTAssertEqual(obj["ok"] as? Bool, true)
    }

    func testEncodeErrorResponse() {
        let response = Response.failure(id: 12, code: "automation_paused", message: "Automation is paused.")
        let obj = try! JSONSerialization.jsonObject(with: response.encode()) as! [String: Any]
        XCTAssertEqual(obj["ok"] as? Bool, false)
        let error = obj["error"] as! [String: Any]
        XCTAssertEqual(error["code"] as? String, "automation_paused")
        XCTAssertEqual(error["message"] as? String, "Automation is paused.")
    }

    func testJSONValueEncodeHelper() {
        struct Foo: Codable { let n: Int; let s: String; let b: Bool }
        let value = JSONValue.encode(Foo(n: 3, s: "x", b: true))
        let obj = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(value)
        ) as! [String: Any]
        XCTAssertEqual(obj["n"] as? Int, 3)
        XCTAssertEqual(obj["s"] as? String, "x")
        XCTAssertEqual(obj["b"] as? Bool, true)
    }

    func testStatusShapeEncodes() {
        let status = Status(
            helper_version: "0.1.0",
            macos_version: "test",
            automation: AutomationState(enabled: false, paused: true, expires_at: nil),
            permissions: Permissions(accessibility: false, screen_recording: false),
            frontmost_app: FrontmostApp(name: "App", bundle_id: "com.app", pid: 1),
            displays: [DisplayInfo(
                id: "1",
                frame: RectInfo(x: 0, y: 0, width: 100, height: 50),
                pixel_width: 200,
                pixel_height: 100,
                scale: 2,
                is_main: true
            )],
            healthy: true
        )
        let obj = try! JSONSerialization.jsonObject(
            with: JSONEncoder().encode(status)
        ) as! [String: Any]
        XCTAssertEqual(obj["helper_version"] as? String, "0.1.0")
        let automation = obj["automation"] as! [String: Any]
        XCTAssertEqual(automation["paused"] as? Bool, true)
        XCTAssertEqual((obj["displays"] as! [[String: Any]]).count, 1)
    }

    func testAutomationCanBeEnabledAndPaused() {
        let control = AutomationControl()
        XCTAssertTrue(control.state().paused)

        control.enable(for: 60)
        XCTAssertTrue(control.state().enabled)
        XCTAssertNotNil(control.state().expires_at)

        control.pause()
        XCTAssertTrue(control.state().paused)
    }

    func testActionIsRejectedWhileAutomationIsPaused() {
        Desktop.pauseAutomation()
        let response = process(#"{"id":7,"method":"action","params":{"kind":"wait","observation_id":"missing"}}"#)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "automation_paused")
    }

    func testCoordinateMappingIncludesDisplayOriginAndScaling() {
        let frame = RectInfo(x: -1920, y: 120, width: 1920, height: 1080)
        let point = Desktop.screenPoint(
            x: 800, y: 450, imageWidth: 1600, imageHeight: 900, frame: frame
        )

        XCTAssertEqual(point?.x, -960)
        XCTAssertEqual(point?.y, 660)
    }

    func testCoordinateMappingRejectsScreenshotBounds() {
        let frame = RectInfo(x: 0, y: 0, width: 100, height: 50)
        XCTAssertNil(Desktop.screenPoint(x: -1, y: 0, imageWidth: 200, imageHeight: 100, frame: frame))
        XCTAssertNil(Desktop.screenPoint(x: 200, y: 0, imageWidth: 200, imageHeight: 100, frame: frame))
        XCTAssertNil(Desktop.screenPoint(x: 0, y: 100, imageWidth: 200, imageHeight: 100, frame: frame))
    }

    func testAccessibilityFramesUseScreenshotCoordinates() {
        let display = RectInfo(x: -1920, y: 120, width: 1920, height: 1080)
        let element = RectInfo(x: -960, y: 390, width: 480, height: 270)
        let rect = Desktop.imageRect(element, imageWidth: 1600, imageHeight: 900, frame: display)

        XCTAssertEqual(rect?.x, 800)
        XCTAssertEqual(rect?.y, 225)
        XCTAssertEqual(rect?.width, 400)
        XCTAssertEqual(rect?.height, 225)
    }

    func testOnlyCoordinateBoundsFailuresPreserveObservation() {
        XCTAssertTrue(Desktop.preservesObservation(
            after: DesktopFailure(code: "coordinate_out_of_bounds", message: "outside")
        ))
        XCTAssertFalse(Desktop.preservesObservation(
            after: DesktopFailure(code: "input_failed", message: "failed")
        ))
    }

    func testSecureTextFieldClassification() {
        XCTAssertTrue(Desktop.isSecure(role: "AXSecureTextField", subrole: nil))
        XCTAssertTrue(Desktop.isSecure(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertFalse(Desktop.isSecure(role: "AXTextField", subrole: nil))
    }

    func testAccessibilitySnapshotReservesSpaceForControls() {
        XCTAssertTrue(Desktop.shouldIncludeElement(
            role: "AXButton", lowPriorityCount: 50, totalCount: 50
        ))
        XCTAssertFalse(Desktop.shouldIncludeElement(
            role: "AXStaticText", lowPriorityCount: 50, totalCount: 50
        ))
        XCTAssertFalse(Desktop.shouldIncludeElement(
            role: "AXButton", lowPriorityCount: 0, totalCount: 200
        ))
    }

    func testUnknownMethodReturnsInvalidRequest() {
        let response = process(#"{"id":9,"method":"launch_missiles","params":{}}"#)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_request")
    }

    func testObserveRejectsInvalidParamsBeforeCheckingPermissions() {
        let response = process(#"{"id":10,"method":"observe","params":{"scope":"window"}}"#)
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_arguments")
    }
}
