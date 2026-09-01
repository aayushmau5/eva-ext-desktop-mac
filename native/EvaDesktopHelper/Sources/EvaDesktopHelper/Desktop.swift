import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct FrontmostApp: Codable {
    let name: String?
    let bundle_id: String?
    let pid: Int
}

struct RectInfo: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct DisplayInfo: Codable {
    let id: String
    let frame: RectInfo
    let pixel_width: Int
    let pixel_height: Int
    let scale: Double
    let is_main: Bool
}

struct AutomationState: Codable {
    let enabled: Bool
    let paused: Bool
    let expires_at: Int?
}

struct Permissions: Codable {
    let accessibility: Bool
    let screen_recording: Bool
}

struct Status: Codable {
    let helper_version: String
    let macos_version: String
    let automation: AutomationState
    let permissions: Permissions
    let frontmost_app: FrontmostApp?
    let displays: [DisplayInfo]
    let healthy: Bool
}

struct WindowInfo: Codable {
    let title: String?
    let frame: RectInfo?
}

struct ImageInfo: Codable {
    let width: Int
    let height: Int
    let mime_type: String
}

struct ElementInfo: Codable {
    let ref: String
    let role: String
    let subrole: String?
    let title: String?
    let element_description: String?
    let value: String?
    let enabled: Bool
    let focused: Bool
    let secure: Bool
    let frame: RectInfo?
    let actions: [String]

    enum CodingKeys: String, CodingKey {
        case ref, role, subrole, title, value, enabled, focused, secure, frame, actions
        case element_description = "description"
    }
}

struct ObservationResult: Codable {
    let observation_id: String
    let scope: String
    let image: ImageInfo
    let screenshot_base64: String
    let screen_frame_points: RectInfo
    let frontmost_app: FrontmostApp?
    let focused_window: WindowInfo?
    let elements: [ElementInfo]
    let tree_truncated: Bool
}

struct DesktopFailure: Error {
    let code: String
    let message: String

    static func invalid(_ message: String) -> DesktopFailure {
        DesktopFailure(code: "invalid_arguments", message: message)
    }
}

final class AutomationControl {
    static let shared = AutomationControl()

    private let lock = NSLock()
    private var enabledUntil: Date?

    func enable(for seconds: TimeInterval = 600) {
        lock.lock()
        enabledUntil = Date().addingTimeInterval(seconds)
        lock.unlock()
    }

    func pause() {
        lock.lock()
        enabledUntil = nil
        lock.unlock()
    }

    func state() -> AutomationState {
        lock.lock()
        defer { lock.unlock() }

        guard let deadline = enabledUntil, deadline > Date() else {
            enabledUntil = nil
            return AutomationState(enabled: false, paused: true, expires_at: nil)
        }

        return AutomationState(
            enabled: true,
            paused: false,
            expires_at: Int(deadline.timeIntervalSince1970)
        )
    }
}

private struct AccessibilitySnapshot {
    let window: AXUIElement?
    let windowInfo: WindowInfo?
    let elements: [ElementInfo]
    let refs: [String: AXUIElement]
    let truncated: Bool
}

private struct ObservationContext {
    let id: String
    let display: DisplayInfo
    let imageWidth: Int
    let imageHeight: Int
    let appPID: pid_t
    let appBundleID: String?
    let window: AXUIElement?
    let refs: [String: AXUIElement]
}

enum Desktop {
    static let helperVersion = "0.1.0"

    private static let maximumImageDimension = 1_280.0
    private static let maximumElements = 200
    private static let maximumLowPriorityElements = 50
    private static let maximumVisitedElements = 1_000
    private static let maximumTreeDepth = 12
    private static let maximumTextLength = 200
    private static var currentObservation: ObservationContext?
    private static var enhancedAccessibilityPIDs: Set<pid_t> = []

    static func status() -> Status {
        Status(
            helper_version: helperVersion,
            macos_version: ProcessInfo.processInfo.operatingSystemVersionString,
            automation: AutomationControl.shared.state(),
            permissions: Permissions(
                accessibility: AXIsProcessTrusted(),
                screen_recording: CGPreflightScreenCaptureAccess()
            ),
            frontmost_app: frontmostApp(),
            displays: displays(),
            healthy: true
        )
    }

    static func enableAutomation() { AutomationControl.shared.enable() }
    static func pauseAutomation() { AutomationControl.shared.pause() }

    static func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func requestScreenRecordingPermission() { _ = CGRequestScreenCaptureAccess() }

    static func screenPoint(
        x: Double,
        y: Double,
        imageWidth: Int,
        imageHeight: Int,
        frame: RectInfo
    ) -> CGPoint? {
        guard x.isFinite, y.isFinite, imageWidth > 0, imageHeight > 0,
              x >= 0, y >= 0, x < Double(imageWidth), y < Double(imageHeight) else {
            return nil
        }
        return CGPoint(
            x: frame.x + x / Double(imageWidth) * frame.width,
            y: frame.y + y / Double(imageHeight) * frame.height
        )
    }

    static func imageRect(
        _ rect: RectInfo,
        imageWidth: Int,
        imageHeight: Int,
        frame: RectInfo
    ) -> RectInfo? {
        guard imageWidth > 0, imageHeight > 0, frame.width > 0, frame.height > 0 else {
            return nil
        }
        return RectInfo(
            x: (rect.x - frame.x) / frame.width * Double(imageWidth),
            y: (rect.y - frame.y) / frame.height * Double(imageHeight),
            width: rect.width / frame.width * Double(imageWidth),
            height: rect.height / frame.height * Double(imageHeight)
        )
    }

    static func isSecure(role: String, subrole: String?) -> Bool {
        role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    static func frontmostApp() -> FrontmostApp? {
        onMain {
            guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
            return FrontmostApp(
                name: app.localizedName,
                bundle_id: app.bundleIdentifier,
                pid: Int(app.processIdentifier)
            )
        }
    }

    static func displays() -> [DisplayInfo] {
        onMain {
            NSScreen.screens.compactMap { screen in
                guard let number = screen.deviceDescription[
                    NSDeviceDescriptionKey("NSScreenNumber")
                ] as? NSNumber else { return nil }

                let id = number.uint32Value
                let bounds = CGDisplayBounds(id)
                let mode = CGDisplayCopyDisplayMode(id)
                let pixelWidth = mode?.pixelWidth ?? CGDisplayPixelsWide(id)
                let pixelHeight = mode?.pixelHeight ?? CGDisplayPixelsHigh(id)
                return DisplayInfo(
                    id: String(id),
                    frame: RectInfo(bounds),
                    pixel_width: pixelWidth,
                    pixel_height: pixelHeight,
                    scale: bounds.width == 0 ? 1 : Double(pixelWidth) / bounds.width,
                    is_main: CGDisplayIsMain(id) != 0
                )
            }
        }
    }

    static func observe(_ params: JSONValue) -> Result<ObservationResult, DesktopFailure> {
        guard let object = params.objectValue else {
            return .failure(DesktopFailure.invalid("params must be an object"))
        }
        if let scope = object["scope"], scope.stringValue != "display" {
            return .failure(DesktopFailure.invalid("scope must be display"))
        }
        if let displayID = object["display_id"], displayID.stringValue == nil {
            return .failure(DesktopFailure.invalid("display_id must be a string"))
        }
        guard CGPreflightScreenCaptureAccess() else {
            return .failure(DesktopFailure(
                code: "screen_recording_permission_missing",
                message: "Grant Screen Recording permission from the Eva Desktop menu."
            ))
        }
        guard AXIsProcessTrusted() else {
            return .failure(DesktopFailure(
                code: "accessibility_permission_missing",
                message: "Grant Accessibility permission from the Eva Desktop menu."
            ))
        }

        let displayID = object["display_id"]?.stringValue
        guard let display = selectedDisplay(displayID) else {
            return .failure(DesktopFailure.invalid("unknown display_id"))
        }

        let capture: (Data, Int, Int)
        do {
            capture = try captureDisplay(display)
        } catch let failure as DesktopFailure {
            return .failure(failure)
        } catch {
            return .failure(DesktopFailure(code: "capture_failed", message: error.localizedDescription))
        }

        let app = frontmostApp()
        let snapshot = app.map {
            accessibilitySnapshot(
                pid_t($0.pid),
                display: display,
                imageWidth: capture.1,
                imageHeight: capture.2
            )
        }
        let observationID = newObservationID()
        currentObservation = ObservationContext(
            id: observationID,
            display: display,
            imageWidth: capture.1,
            imageHeight: capture.2,
            appPID: pid_t(app?.pid ?? 0),
            appBundleID: app?.bundle_id,
            window: snapshot?.window,
            refs: snapshot?.refs ?? [:]
        )

        return .success(ObservationResult(
            observation_id: observationID,
            scope: "display",
            image: ImageInfo(width: capture.1, height: capture.2, mime_type: "image/jpeg"),
            screenshot_base64: capture.0.base64EncodedString(),
            screen_frame_points: display.frame,
            frontmost_app: app,
            focused_window: snapshot?.windowInfo,
            elements: snapshot?.elements ?? [],
            tree_truncated: snapshot?.truncated ?? false
        ))
    }

    static func action(_ params: JSONValue) -> Result<ObservationResult, DesktopFailure> {
        guard AutomationControl.shared.state().enabled else {
            return .failure(DesktopFailure(
                code: "automation_paused",
                message: "Enable automation for ten minutes from the Eva Desktop menu."
            ))
        }
        guard let object = params.objectValue else {
            return .failure(DesktopFailure.invalid("params must be an object"))
        }
        guard let kind = object["kind"]?.stringValue else {
            return .failure(DesktopFailure.invalid("kind is required"))
        }
        guard let observationID = object["observation_id"]?.stringValue,
              let observation = currentObservation,
              observation.id == observationID else {
            return .failure(DesktopFailure(
                code: "stale_observation",
                message: "Observe the desktop again before acting."
            ))
        }
        let app = frontmostApp()
        guard !restricted(app),
              app?.pid == Int(observation.appPID),
              app?.bundle_id == observation.appBundleID,
              focusedWindowMatches(observation) else {
            return .failure(DesktopFailure(
                code: "target_changed",
                message: "The frontmost application or focused window changed; observe again."
            ))
        }

        currentObservation = nil
        do {
            try perform(kind, object, observation)
            if kind != "wait" { Thread.sleep(forTimeInterval: 0.2) }
            switch observe(.object(["display_id": .string(observation.display.id)])) {
            case .success(let result):
                return .success(result)
            case .failure(let failure):
                return .failure(DesktopFailure(
                    code: failure.code,
                    message: "The action was sent, but verification failed: \(failure.message) Observe before retrying."
                ))
            }
        } catch let failure as DesktopFailure {
            if preservesObservation(after: failure) { currentObservation = observation }
            return .failure(failure)
        } catch {
            return .failure(DesktopFailure(code: "input_failed", message: error.localizedDescription))
        }
    }

    // MARK: Capture

    private static func selectedDisplay(_ requestedID: String?) -> DisplayInfo? {
        let all = displays()
        if let requestedID { return all.first { $0.id == requestedID } }
        return all.first { $0.is_main } ?? all.first
    }

    private static func captureDisplay(_ display: DisplayInfo) throws -> (Data, Int, Int) {
        let contentSemaphore = DispatchSemaphore(value: 0)
        var contentResult: Result<SCShareableContent, Error>?
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) {
            content, error in
            if let content {
                contentResult = .success(content)
            } else {
                contentResult = .failure(error ?? DesktopFailure(
                    code: "capture_failed", message: "No shareable content"
                ))
            }
            contentSemaphore.signal()
        }
        guard contentSemaphore.wait(timeout: .now() + 15) == .success,
              let contentResult else {
            throw DesktopFailure(code: "capture_failed", message: "Timed out listing displays")
        }

        let content = try contentResult.get()
        guard let sourceDisplay = content.displays.first(where: {
            String($0.displayID) == display.id
        }) else {
            throw DesktopFailure(code: "capture_failed", message: "Display is not shareable")
        }

        let excluded = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(
            display: sourceDisplay,
            excludingApplications: excluded,
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        let sourceWidth = Double(sourceDisplay.width) * display.scale
        let sourceHeight = Double(sourceDisplay.height) * display.scale
        let outputScale = min(1, maximumImageDimension / max(sourceWidth, sourceHeight))
        configuration.width = max(1, Int(sourceWidth * outputScale))
        configuration.height = max(1, Int(sourceHeight * outputScale))
        configuration.showsCursor = false
        configuration.capturesAudio = false

        let imageSemaphore = DispatchSemaphore(value: 0)
        var imageResult: Result<CGImage, Error>?
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) {
            image, error in
            if let image {
                imageResult = .success(image)
            } else {
                imageResult = .failure(error ?? DesktopFailure(
                    code: "capture_failed", message: "No screenshot returned"
                ))
            }
            imageSemaphore.signal()
        }
        guard imageSemaphore.wait(timeout: .now() + 15) == .success,
              let imageResult else {
            throw DesktopFailure(code: "capture_failed", message: "Timed out taking screenshot")
        }

        let image = try imageResult.get()
        return (try jpegData(image), image.width, image.height)
    }

    private static func jpegData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else {
            throw DesktopFailure(code: "capture_failed", message: "Could not create JPEG encoder")
        }
        let options = [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw DesktopFailure(code: "capture_failed", message: "Could not encode screenshot")
        }
        return data as Data
    }

    // MARK: Accessibility

    private static let includedRoles: Set<String> = [
        "AXWindow", "AXButton", "AXTextField", "AXTextArea", "AXSecureTextField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXStaticText",
        "AXLink", "AXTab", "AXRow", "AXCell", "AXSlider"
    ]
    private static let lowPriorityRoles: Set<String> = ["AXStaticText", "AXRow", "AXCell"]

    static func shouldIncludeElement(
        role: String,
        lowPriorityCount: Int,
        totalCount: Int
    ) -> Bool {
        includedRoles.contains(role) &&
            totalCount < maximumElements &&
            (!lowPriorityRoles.contains(role) || lowPriorityCount < maximumLowPriorityElements)
    }

    private static func accessibilitySnapshot(
        _ pid: pid_t,
        display: DisplayInfo,
        imageWidth: Int,
        imageHeight: Int
    ) -> AccessibilitySnapshot {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 2)
        enableEnhancedAccessibility(application, pid: pid)
        let window = elementAttribute(application, kAXFocusedWindowAttribute)
        let windowInfo = window.map {
            WindowInfo(
                title: stringAttribute($0, kAXTitleAttribute),
                frame: elementFrame($0).flatMap {
                    imageRect($0, imageWidth: imageWidth, imageHeight: imageHeight, frame: display.frame)
                }
            )
        }
        var elements: [ElementInfo] = []
        var refs: [String: AXUIElement] = [:]
        var visited = 0
        var lowPriorityCount = 0
        var omittedLowPriority = false
        var truncated = false
        let deadline = Date().addingTimeInterval(3)

        func visit(_ element: AXUIElement, depth: Int) {
            guard depth <= maximumTreeDepth,
                  visited < maximumVisitedElements,
                  elements.count < maximumElements,
                  Date() < deadline else {
                truncated = true
                return
            }
            visited += 1
            let role = stringAttribute(element, kAXRoleAttribute) ?? ""
            let subrole = stringAttribute(element, kAXSubroleAttribute)
            let includedRole = includedRoles.contains(role) ? role : subrole ?? role
            if lowPriorityRoles.contains(includedRole),
               lowPriorityCount >= maximumLowPriorityElements {
                omittedLowPriority = true
            }
            if shouldIncludeElement(
                role: includedRole,
                lowPriorityCount: lowPriorityCount,
                totalCount: elements.count
            ) {
                let ref = "e\(elements.count + 1)"
                let secure = isSecure(role: role, subrole: subrole)
                if lowPriorityRoles.contains(includedRole) { lowPriorityCount += 1 }
                refs[ref] = element
                elements.append(ElementInfo(
                    ref: ref,
                    role: role,
                    subrole: subrole,
                    title: limited(stringAttribute(element, kAXTitleAttribute)),
                    element_description: limited(stringAttribute(element, kAXDescriptionAttribute)),
                    value: secure ? nil : limited(displayValue(element)),
                    enabled: boolAttribute(element, kAXEnabledAttribute) ?? true,
                    focused: boolAttribute(element, kAXFocusedAttribute) ?? false,
                    secure: secure,
                    frame: elementFrame(element).flatMap {
                        imageRect($0, imageWidth: imageWidth, imageHeight: imageHeight, frame: display.frame)
                    },
                    actions: actionNames(element)
                ))
            }
            for child in children(element) {
                visit(child, depth: depth + 1)
                if visited >= maximumVisitedElements ||
                    elements.count >= maximumElements || Date() >= deadline { break }
            }
        }

        if let window { visit(window, depth: 0) }
        return AccessibilitySnapshot(
            window: window,
            windowInfo: windowInfo,
            elements: elements,
            refs: refs,
            truncated: truncated || omittedLowPriority
        )
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 2)
        return elementAttribute(application, kAXFocusedWindowAttribute)
    }

    private static func enableEnhancedAccessibility(_ application: AXUIElement, pid: pid_t) {
        guard !enhancedAccessibilityPIDs.contains(pid) else { return }
        let result = AXUIElementSetAttributeValue(
            application,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        guard result == .success else { return }
        enhancedAccessibilityPIDs.insert(pid)
        Thread.sleep(forTimeInterval: 2.1)
    }

    static func preservesObservation(after failure: DesktopFailure) -> Bool {
        failure.code == "coordinate_out_of_bounds"
    }

    private static func focusedWindowMatches(_ observation: ObservationContext) -> Bool {
        let current = focusedWindow(observation.appPID)
        switch (observation.window, current) {
        case (nil, nil): return true
        case let (expected?, current?): return CFEqual(expected, current)
        default: return false
        }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var result = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        let contents = attribute(element, kAXContentsAttribute) as? [AXUIElement] ?? []
        for content in contents where !result.contains(where: { CFEqual($0, content) }) {
            result.append(content)
        }
        return result
    }

    private static func actionNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    private static func displayValue(_ element: AXUIElement) -> String? {
        guard let value = attribute(element, kAXValueAttribute) else { return nil }
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func elementFrame(_ element: AXUIElement) -> RectInfo? {
        guard let positionValue = attribute(element, kAXPositionAttribute),
              let sizeValue = attribute(element, kAXSizeAttribute),
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return RectInfo(x: point.x, y: point.y, width: size.width, height: size.height)
    }

    private static func limited(_ text: String?) -> String? {
        guard let text else { return nil }
        return text.count <= maximumTextLength ? text : String(text.prefix(maximumTextLength))
    }

    // MARK: Input

    private static func perform(
        _ kind: String,
        _ params: [String: JSONValue],
        _ observation: ObservationContext
    ) throws {
        switch kind {
        case "click": try click(params, observation, count: 1)
        case "double_click": try click(params, observation, count: 2)
        case "type": try typeText(params, observation)
        case "key", "press":
            guard let values = params["keys"]?.arrayValue,
                  !values.isEmpty, values.count <= 8,
                  values.allSatisfy({ $0.stringValue != nil }) else {
                throw DesktopFailure.invalid("keys must contain between 1 and 8 entries")
            }
            let keys = values.compactMap(\.stringValue)
            try pressKeys(keys)
        case "scroll": try scroll(params)
        case "wait":
            let milliseconds = params["milliseconds"]?.numberValue ?? 500
            guard milliseconds >= 0, milliseconds <= 10_000 else {
                throw DesktopFailure.invalid("milliseconds must be between 0 and 10000")
            }
            Thread.sleep(forTimeInterval: milliseconds / 1_000)
        case "drag": try drag(params, observation)
        default:
            throw DesktopFailure(code: "unsupported_action", message: "Unsupported action: \(kind)")
        }
    }

    private static func click(
        _ params: [String: JSONValue],
        _ observation: ObservationContext,
        count: Int
    ) throws {
        if let target = params["target"]?.stringValue {
            guard let element = observation.refs[target] else {
                throw DesktopFailure(
                    code: "stale_element",
                    message: "The element reference is no longer valid; observe again."
                )
            }
            guard stringAttribute(element, kAXRoleAttribute) != nil else {
                throw DesktopFailure(code: "stale_element", message: "Observe again before clicking.")
            }
            if count == 1, actionNames(element).contains(kAXPressAction as String) {
                let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
                if result == .invalidUIElement {
                    throw DesktopFailure(code: "stale_element", message: "Observe again before clicking.")
                }
                guard result == .success else {
                    throw DesktopFailure(code: "input_failed", message: "AXPress failed")
                }
                return
            }
            guard let frame = elementFrame(element) else {
                throw DesktopFailure.invalid("target has no clickable frame")
            }
            try postClick(
                CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2),
                button: params["button"]?.stringValue ?? "left",
                count: count
            )
            return
        }
        try postClick(
            imagePoint(params, observation),
            button: params["button"]?.stringValue ?? "left",
            count: count
        )
    }

    private static func postClick(_ point: CGPoint, button: String, count: Int) throws {
        let mouseButton: CGMouseButton
        let downType: CGEventType
        let upType: CGEventType
        switch button {
        case "left":
            mouseButton = .left; downType = .leftMouseDown; upType = .leftMouseUp
        case "right":
            mouseButton = .right; downType = .rightMouseDown; upType = .rightMouseUp
        default: throw DesktopFailure.invalid("button must be left or right")
        }

        for index in 1...count {
            guard let down = CGEvent(
                mouseEventSource: nil, mouseType: downType,
                mouseCursorPosition: point, mouseButton: mouseButton
            ), let up = CGEvent(
                mouseEventSource: nil, mouseType: upType,
                mouseCursorPosition: point, mouseButton: mouseButton
            ) else {
                throw DesktopFailure(code: "input_failed", message: "Could not create mouse event")
            }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            if count > 1 { Thread.sleep(forTimeInterval: 0.08) }
        }
    }

    private static func typeText(
        _ params: [String: JSONValue],
        _ observation: ObservationContext
    ) throws {
        guard let text = params["text"]?.stringValue else {
            throw DesktopFailure.invalid("text is required")
        }
        guard text.utf16.count <= 10_000 else { throw DesktopFailure.invalid("text is too long") }

        if let target = params["target"]?.stringValue {
            guard let element = observation.refs[target] else {
                throw DesktopFailure(code: "stale_element", message: "Observe again before typing.")
            }
            guard stringAttribute(element, kAXRoleAttribute) != nil else {
                throw DesktopFailure(code: "stale_element", message: "Observe again before typing.")
            }
            let result = AXUIElementSetAttributeValue(
                element, kAXFocusedAttribute as CFString, kCFBooleanTrue
            )
            if result == .invalidUIElement {
                throw DesktopFailure(code: "stale_element", message: "Observe again before typing.")
            }
            guard result == .success else {
                throw DesktopFailure(code: "input_failed", message: "Could not focus target")
            }
        }
        if params["replace"]?.boolValue == true { try pressKeys(["CMD", "A"]) }

        var characters = Array(text.utf16)
        guard !characters.isEmpty else { return }
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
            throw DesktopFailure(code: "input_failed", message: "Could not create keyboard event")
        }
        down.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
        up.keyboardSetUnicodeString(stringLength: characters.count, unicodeString: &characters)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
        "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "O": 31, "U": 32,
        "I": 34, "P": 35, "ENTER": 36, "RETURN": 36, "L": 37, "J": 38, "K": 40, "N": 45,
        "M": 46, "TAB": 48, "SPACE": 49, "BACKSPACE": 51, "DELETE": 51,
        "ESCAPE": 53, "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126
    ]

    private static func pressKeys(_ rawKeys: [String]) throws {
        let keys = rawKeys.map { $0.uppercased() }
        var flags: CGEventFlags = []
        var ordinary: [CGKeyCode] = []
        for key in keys {
            switch key {
            case "CMD", "COMMAND": flags.insert(.maskCommand)
            case "SHIFT": flags.insert(.maskShift)
            case "OPTION", "ALT": flags.insert(.maskAlternate)
            case "CTRL", "CONTROL": flags.insert(.maskControl)
            default:
                guard let code = keyCodes[key] else {
                    throw DesktopFailure.invalid("unsupported key: \(key)")
                }
                ordinary.append(code)
            }
        }
        guard !ordinary.isEmpty else {
            throw DesktopFailure.invalid("keys must include a non-modifier key")
        }
        for code in ordinary {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
                throw DesktopFailure(code: "input_failed", message: "Could not create key event")
            }
            down.flags = flags; up.flags = flags
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }

    static func newObservationID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }

    private static func scroll(_ params: [String: JSONValue]) throws {
        let dx = params["delta_x"]?.numberValue ?? 0
        let dy = params["delta_y"]?.numberValue ?? 0
        guard dx.isFinite, dy.isFinite, abs(dx) <= 10_000, abs(dy) <= 10_000 else {
            throw DesktopFailure.invalid("scroll delta is too large")
        }
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0
        ) else {
            throw DesktopFailure(code: "input_failed", message: "Could not create scroll event")
        }
        event.post(tap: .cghidEventTap)
    }

    private static func drag(
        _ params: [String: JSONValue],
        _ observation: ObservationContext
    ) throws {
        guard let rawPath = params["path"]?.arrayValue,
              rawPath.count >= 2, rawPath.count <= 100 else {
            throw DesktopFailure.invalid("path must contain between 2 and 100 points")
        }
        let points = try rawPath.map { value -> CGPoint in
            guard let point = value.objectValue else {
                throw DesktopFailure.invalid("each path point must be an object")
            }
            return try imagePoint(point, observation)
        }
        let finalPoint = points.last!
        guard let down = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDown,
            mouseCursorPosition: points[0], mouseButton: .left
        ), let up = CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseUp,
            mouseCursorPosition: finalPoint, mouseButton: .left
        ) else {
            throw DesktopFailure(code: "input_failed", message: "Could not create drag events")
        }
        down.post(tap: .cghidEventTap)
        defer { up.post(tap: .cghidEventTap) }
        for point in points.dropFirst() {
            guard let event = CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDragged,
                mouseCursorPosition: point, mouseButton: .left
            ) else {
                throw DesktopFailure(code: "input_failed", message: "Could not create drag event")
            }
            event.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private static func imagePoint(
        _ params: [String: JSONValue],
        _ observation: ObservationContext
    ) throws -> CGPoint {
        guard let x = params["x"]?.numberValue, let y = params["y"]?.numberValue else {
            throw DesktopFailure.invalid("x and y are required")
        }
        guard let point = screenPoint(
            x: x,
            y: y,
            imageWidth: observation.imageWidth,
            imageHeight: observation.imageHeight,
            frame: observation.display.frame
        ) else {
            throw DesktopFailure(
                code: "coordinate_out_of_bounds",
                message: "Coordinates are outside the screenshot; correct them and reuse this observation."
            )
        }
        return point
    }

    private static func onMain<T>(_ body: () -> T) -> T {
        Thread.isMainThread ? body() : DispatchQueue.main.sync(execute: body)
    }

    private static func restricted(_ app: FrontmostApp?) -> Bool {
        guard let app else { return true }
        return ["com.apple.loginwindow", "com.apple.ScreenSaver.Engine"].contains(app.bundle_id)
    }
}

private extension RectInfo {
    init(_ rect: CGRect) {
        self.init(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }
}
