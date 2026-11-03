import AppKit
import ScreenCaptureKit
import WordHuntCore

public struct MirrorWindow {
    public let id: CGWindowID
    public let ownerPID: pid_t
    public let title: String
    /// Quartz global points, with the origin at the main display's top left.
    public let frame: CGRect

    public init(id: CGWindowID, ownerPID: pid_t, title: String, frame: CGRect) {
        self.id = id
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
    }
}

public struct WindowSnapshot {
    public let image: CGImage
    public let window: MirrorWindow

    public init(image: CGImage, window: MirrorWindow) {
        self.image = image
        self.window = window
    }
}

public enum AutomationPermissions {
    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    public static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    public static func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
    }
}

public enum MirroringCapture {
    // Verified against /System/Applications/iPhone Mirroring.app/Contents/Info.plist.
    private static let bundleIdentifier = "com.apple.ScreenContinuity"

    public static func windows() throws -> [MirrorWindow] {
        try candidateWindows(includeOffscreenFocused: true)
    }

    private static func candidateWindows(includeOffscreenFocused: Bool) throws -> [MirrorWindow] {
        guard AutomationPermissions.screenRecordingGranted else {
            throw WordHuntError.automation("Screen Recording permission is required to inspect and capture windows. Enable it in System Settings, then restart this app if requested.")
        }
        let options: CGWindowListOption = includeOffscreenFocused
            ? [.optionAll, .excludeDesktopElements] : [.optionOnScreenOnly, .excludeDesktopElements]
        guard let entries = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw WordHuntError.automation("The target window list is unavailable.")
        }
        return entries.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? NSNumber,
                  let pid = entry[kCGWindowOwnerPID as String] as? NSNumber,
                  let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width > 1, frame.height > 1,
                  let app = NSRunningApplication(processIdentifier: pid.int32Value) else { return nil }
            let title = entry[kCGWindowName as String] as? String ?? ""
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let isMirroring = app.bundleIdentifier == bundleIdentifier
                || (app.bundleIdentifier == nil
                    && app.bundleURL?.path == "/System/Applications/iPhone Mirroring.app"
                    && owner == app.localizedName)
            // The built-in practice window is an explicit safe, local automation target.
            let isPractice = pid.int32Value == getpid() && title == "Word Hunt Practice"
            guard isMirroring || isPractice else { return nil }
            let window = MirrorWindow(id: id.uint32Value, ownerPID: pid.int32Value, title: title, frame: frame)
            let onScreen = (entry[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            if !onScreen {
                // A different Space is eligible for explicit activation, not input.
                // Match the actual non-minimized AX focused window, never an
                // arbitrary offscreen Welcome window or Mirroring auxiliary.
                guard includeOffscreenFocused, !app.isHidden,
                      AutomationPermissions.accessibilityGranted,
                      isNonminimizedFocusedWindow(window) else { return nil }
            }
            return window
        }
    }

    public static func currentWindow(id: CGWindowID) throws -> MirrorWindow {
        guard let window = try candidateWindows(includeOffscreenFocused: false).first(where: { $0.id == id }) else {
            throw WordHuntError.automation("The target window is closed, hidden, minimized, or is not an iPhone Mirroring/practice window.")
        }
        return window
    }

    public static func activate(_ window: MirrorWindow) throws {
        guard let current = try windows().first(where: { $0.id == window.id }) else {
            throw WordHuntError.automation("The target window is closed, hidden, minimized, or cannot be safely identified.")
        }
        guard current.ownerPID == window.ownerPID,
              let app = NSRunningApplication(processIdentifier: current.ownerPID) else {
            throw WordHuntError.automation("Unable to find the target application.")
        }
        guard AutomationPermissions.accessibilityGranted else {
            throw WordHuntError.automation("Accessibility permission is required to focus the target window.")
        }
        let application = AXUIElementCreateApplication(current.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        _ = app.activate(options: [.activateAllWindows])
        _ = AXUIElementSetAttributeValue(application, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let candidate = accessibilityWindow(current, application: application) {
            // Mirroring can reject AXRaise even when activation succeeds. These are
            // requests, not evidence of focus; verify the actual focused window below.
            _ = AXUIElementSetAttributeValue(candidate, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementSetAttributeValue(candidate, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            _ = AXUIElementPerformAction(candidate, kAXRaiseAction as CFString)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        var focusedSince: Double?
        repeat {
            let now = ProcessInfo.processInfo.systemUptime
            if isUnchangedVisibleTarget(current) {
                if let focusedSince, now - focusedSince >= 0.12 { return }
                if focusedSince == nil { focusedSince = now }
            } else {
                focusedSince = nil
            }
            // Activation and same-process practice-window focus must be allowed to
            // complete even when the caller is on the application's main thread.
            if Thread.isMainThread {
                _ = RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
            } else {
                Thread.sleep(forTimeInterval: 0.02)
            }
        } while ProcessInfo.processInfo.systemUptime < deadline
        throw WordHuntError.automation("The target window did not become focused. Bring the iPhone Mirroring/practice window to the front and try again.")
    }

    private static func accessibilityFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func matchesFrame(_ frame: CGRect, _ expected: CGRect) -> Bool {
        abs(frame.minX - expected.minX) < 1 && abs(frame.minY - expected.minY) < 1
            && abs(frame.width - expected.width) < 1 && abs(frame.height - expected.height) < 1
    }

    private static func accessibilityWindow(_ window: MirrorWindow, application: AXUIElement) -> AXUIElement? {
        // Mirroring exposes a valid AXFocusedWindow while AXWindows can be empty.
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
           let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() {
            let focused = focusedValue as! AXUIElement
            if let frame = accessibilityFrame(focused), matchesFrame(frame, window.frame) { return focused }
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }
        return windows.first { candidate in
            guard let frame = accessibilityFrame(candidate) else { return false }
            return matchesFrame(frame, window.frame)
        }
    }

    internal static func isFocused(_ window: MirrorWindow) -> Bool {
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID(),
              let frame = accessibilityFrame(focusedValue as! AXUIElement) else { return false }
        return matchesFrame(frame, window.frame)
    }

    private static func isNonminimizedFocusedWindow(_ window: MirrorWindow) -> Bool {
        let application = AXUIElementCreateApplication(window.ownerPID)
        AXUIElementSetMessagingTimeout(application, 0.25)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
              let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { return false }
        let focused = focusedValue as! AXUIElement
        guard let frame = accessibilityFrame(focused), matchesFrame(frame, window.frame) else { return false }
        var minimized: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused, kAXMinimizedAttribute as CFString, &minimized) == .success,
              let minimized = minimized as? NSNumber else { return false }
        return !minimized.boolValue
    }

    /// Fast revalidation of an already identity-checked target. Restrict the Window
    /// Server query to this window ID; do not rescan applications during a drag.
    internal static func isUnchangedVisibleTarget(_ window: MirrorWindow) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID,
              let entries = CGWindowListCopyWindowInfo(.optionIncludingWindow, window.id) as? [[String: Any]],
              let entry = entries.first,
              let id = entry[kCGWindowNumber as String] as? NSNumber, id.uint32Value == window.id,
              let pid = entry[kCGWindowOwnerPID as String] as? NSNumber, pid.int32Value == window.ownerPID,
              let onScreen = entry[kCGWindowIsOnscreen as String] as? NSNumber, onScreen.boolValue,
              let layer = entry[kCGWindowLayer as String] as? NSNumber, layer.intValue == 0,
              let alpha = entry[kCGWindowAlpha as String] as? NSNumber, alpha.doubleValue > 0,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              frame == window.frame else { return false }
        return isFocused(window)
    }

    public static func capture(_ window: MirrorWindow) async throws -> WindowSnapshot {
        let current = try currentWindow(id: window.id)
        guard current.ownerPID == window.ownerPID else {
            throw WordHuntError.automation("The capture target changed ownership.")
        }
        // Window-server visibility/focus is checked separately. ScreenCaptureKit's
        // on-screen filter can temporarily omit Mirroring during a Space transition.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == current.id && $0.owningApplication?.processID == current.ownerPID }) else {
            throw WordHuntError.automation("ScreenCaptureKit cannot find the target window.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = try captureConfiguration(windowFrame: current.frame, contentRect: filter.contentRect,
                                                     pointPixelScale: CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let after = try currentWindow(id: current.id)
        guard after.ownerPID == current.ownerPID, after.frame == current.frame else {
            throw WordHuntError.automation("The target moved or resized during capture. Capture it again.")
        }
        return WindowSnapshot(image: image, window: after)
    }

    internal static func captureConfiguration(windowFrame: CGRect, contentRect: CGRect,
                                              pointPixelScale: CGFloat) throws -> SCStreamConfiguration {
        guard SwipePlanner.valid(windowFrame), SwipePlanner.valid(contentRect),
              pointPixelScale.isFinite, pointPixelScale > 0,
              abs(contentRect.width - windowFrame.width) < 1,
              abs(contentRect.height - windowFrame.height) < 1 else {
            throw WordHuntError.automation("ScreenCaptureKit's full-window bounds do not match the target. Capture it again.")
        }
        let configuration = SCStreamConfiguration()
        // A desktop-independent filter captures the whole window, titlebar included.
        // Its native scale is authoritative, including when a window straddles displays.
        configuration.width = max(1, Int((contentRect.width * pointPixelScale).rounded()))
        configuration.height = max(1, Int((contentRect.height * pointPixelScale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.ignoreGlobalClipSingleWindow = true
        configuration.scalesToFit = true
        // Fill exactly the requested full-window raster. No padding/letterboxing may
        // enter the pixel-to-Quartz transform used by SwipePlanner.
        configuration.preservesAspectRatio = false
        return configuration
    }
}
