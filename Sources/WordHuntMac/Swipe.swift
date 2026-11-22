import AppKit
import WordHuntCore

public struct SwipeTiming {
    public var stepDuration: Double
    public var wordPause: Double

    public init(stepDuration: Double = 0.035, wordPause: Double = 0.045) {
        self.stepDuration = stepDuration
        self.wordPause = wordPause
    }

    internal func validate() throws {
        guard stepDuration.isFinite, stepDuration >= 0.005, stepDuration <= 2,
              wordPause.isFinite, wordPause >= 0, wordPause <= 10 else {
            throw WordHuntError.automation("Use a step duration from 0.005 to 2 seconds and a word pause from 0 to 10 seconds.")
        }
    }
}

public struct SwipePlan {
    public let word: FoundWord
    public let points: [CGPoint]
    public let estimatedDuration: Double

    public init(word: FoundWord, points: [CGPoint], estimatedDuration: Double) {
        self.word = word
        self.points = points
        self.estimatedDuration = estimatedDuration
    }
}

public enum SwipePlanner {
    public static func plan(words: [FoundWord], geometry: GridGeometry, imageSize: CGSize,
                            windowFrame: CGRect, timing: SwipeTiming) throws -> [SwipePlan] {
        try timing.validate()
        guard (4...5).contains(geometry.size), valid(geometry.rect), valid(windowFrame),
              imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0,
              CGRect(origin: .zero, size: imageSize).contains(geometry.rect) else {
            throw WordHuntError.automation("Board geometry must be finite, positive, and entirely inside the captured image.")
        }
        return try words.map { word in
            try validatePath(word, size: geometry.size)
            let points = word.path.map { index -> CGPoint in
                let pixel = geometry.center(of: index)
                return CGPoint(x: windowFrame.minX + pixel.x * windowFrame.width / imageSize.width,
                               y: windowFrame.minY + pixel.y * windowFrame.height / imageSize.height)
            }
            return SwipePlan(word: word, points: points,
                             estimatedDuration: Double(points.count) * timing.stepDuration + timing.wordPause + 0.004)
        }
    }

    internal static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    internal static func validatePath(_ word: FoundWord, size: Int) throws {
        guard word.word.utf8.count >= 3, word.word.utf8.allSatisfy({ (65...90).contains($0) }),
              word.path.count >= 2, word.path.count <= size * size,
              word.word.utf8.count >= word.path.count, word.word.utf8.count <= word.path.count * 2 else {
            throw WordHuntError.automation("A swipe requires an uppercase word of at least three letters and a legal tile path.")
        }
        var seen: UInt32 = 0
        var previous: Int?
        for index in word.path {
            guard index >= 0, index < size * size else {
                throw WordHuntError.automation("A swipe path contains an out-of-range tile.")
            }
            let bit = UInt32(1) << UInt32(index)
            guard seen & bit == 0 else { throw WordHuntError.automation("A swipe path reuses a tile.") }
            seen |= bit
            if let previous {
                guard abs(index / size - previous / size) <= 1,
                      abs(index % size - previous % size) <= 1 else {
                    throw WordHuntError.automation("A swipe path contains nonadjacent tiles.")
                }
            }
            previous = index
        }
    }
}

/// Input is identified by its source tag, not by comparing the asynchronous
/// Window Server cursor against a point we just posted.
internal struct SwipeInputState {
    internal enum Interruption: Equatable { case mouse, escape, unavailable }
    let eventTag: Int64
    private(set) var interruption: Interruption?

    mutating func observe(_ event: CGEvent, type: CGEventType) {
        guard interruption == nil else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            interruption = .unavailable
            return
        }
        guard event.getIntegerValueField(.eventSourceUserData) != eventTag else { return }
        if type == .keyDown {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 { interruption = .escape }
        } else {
            // Only mouse/scroll events and key-down are subscribed to by the tap.
            // Even a physical click without displacement is a manual takeover.
            interruption = .mouse
        }
    }
}

/// Physical pointer activity outside an executor run. Any pointer event during
/// swiping is a takeover, so automatic play first waits for the hand to leave
/// the mouse, for example after clicking the game's Start button.
public enum PointerActivity {
    static let events: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                        .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                        .otherMouseDown, .otherMouseUp, .scrollWheel]

    /// No button is held and no hardware pointer event arrived for `seconds`.
    public static func isIdle(for seconds: Double) -> Bool {
        let buttons: [CGMouseButton] = [.left, .right, .center]
        guard !buttons.contains(where: { CGEventSource.buttonState(.combinedSessionState, button: $0) }) else { return false }
        return events.allSatisfy { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) >= seconds }
    }
}

private final class SwipeInputMonitor {
    let eventTag: Int64
    private var state: SwipeInputState
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let runLoop = CFRunLoopGetCurrent()

    init() throws {
        let tag = Int64.random(in: 1...Int64.max)
        eventTag = tag
        state = SwipeInputState(eventTag: tag)
        let types = PointerActivity.events + [.keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                         options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
            if let context {
                Unmanaged<SwipeInputMonitor>.fromOpaque(context).takeUnretainedValue().state.observe(event, type: type)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            throw WordHuntError.automation("Cannot monitor physical input safely. Allow Accessibility and Input Monitoring for this app before swiping.")
        }
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    deinit {
        if let source { CFRunLoopRemoveSource(runLoop, source, .defaultMode) }
        if let tap { CFMachPortInvalidate(tap) }
    }

    func service(for duration: Double = 0) {
        CFRunLoopRunInMode(.defaultMode, duration, false)
    }

    func check() throws {
        service()
        switch state.interruption {
        case .mouse: throw WordHuntError.automation("Swiping stopped because the mouse was moved or used.")
        case .escape: throw WordHuntError.automation("Swiping stopped by Escape.")
        case .unavailable: throw WordHuntError.automation("Physical input monitoring stopped. Swiping stopped for safety.")
        case nil: break
        }
        guard let tap, CGEvent.tapIsEnabled(tap: tap) else {
            throw WordHuntError.automation("Physical input monitoring stopped. Swiping stopped for safety.")
        }
    }
}

internal enum SwipeMouseEvent {
    static func prepare(_ event: CGEvent, type: CGEventType, at point: CGPoint,
                        previous: CGPoint, tag: Int64, gesture: Int64) {
        event.type = type
        event.location = point
        event.flags = []
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.setIntegerValueField(.eventSourceUserData, value: tag)
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.left.rawValue))
        event.setIntegerValueField(.mouseEventNumber, value: gesture)
        event.setIntegerValueField(.mouseEventClickState, value: type == .mouseMoved ? 0 : 1)
        event.setDoubleValueField(.mouseEventPressure, value: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0)
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64((point.x - previous.x).rounded()))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64((point.y - previous.y).rounded()))
    }
}

/// Synchronous worker-thread executor. Its return value counts completed input attempts,
/// not words accepted by the game. Call cancel() from any thread; cancellation is
/// permanently latched, including when called before run(). Create a new executor to restart.
public final class SwipeExecutor {
    private let lock = NSLock()
    private var cancelled = false
    private var running = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func begin() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { throw WordHuntError.automation("This executor is already running.") }
        guard !cancelled else { throw WordHuntError.automation("Swiping cancelled.") }
        running = true
    }

    private func finish() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private enum Stop: Error { case deadline }

    /// Announces each word before input begins; progress counts only completed gestures.
    public func run(plans: [SwipePlan], window: MirrorWindow, timing: SwipeTiming,
                    timeLimit: Double, willSwipe: @escaping (String) -> Void,
                    progress: @escaping (Int, String) -> Void) throws -> Int {
        guard !Thread.isMainThread else { throw WordHuntError.automation("Run swipes on a background thread, never the main thread.") }
        try timing.validate()
        guard timeLimit.isFinite, timeLimit > 0, SwipePlanner.valid(window.frame) else {
            throw WordHuntError.automation("The time limit and target window geometry must be finite and positive.")
        }
        // Validate all plans before acquiring permission or emitting even a mouse move.
        for plan in plans {
            let duration = Double(plan.points.count) * timing.stepDuration + timing.wordPause + 0.004
            guard plan.points.count == plan.word.path.count, plan.points.count >= 2,
                  plan.estimatedDuration.isFinite, abs(plan.estimatedDuration - duration) < 0.000_001,
                  plan.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && window.frame.contains($0) }) else {
                throw WordHuntError.automation("Invalid swipe points or duration. Re-plan using the current timing and window.")
            }
            // Plan has no board size; accept a legal 4x4 or 5x5 path, as appropriate.
            let legal4 = (try? SwipePlanner.validatePath(plan.word, size: 4)) != nil
            let legal5 = (try? SwipePlanner.validatePath(plan.word, size: 5)) != nil
            guard legal4 || legal5 else { throw WordHuntError.automation("Invalid tile path in swipe plan.") }
        }
        try begin()
        defer { finish() }
        guard AutomationPermissions.accessibilityGranted else {
            throw WordHuntError.automation("Grant Accessibility permission before sending input.")
        }
        let current = try MirroringCapture.currentWindow(id: window.id)
        guard current.ownerPID == window.ownerPID, current.frame == window.frame else {
            throw WordHuntError.automation("The target window changed. Capture and plan again.")
        }
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              !CGEventSource.buttonState(.combinedSessionState, button: .center) else {
            throw WordHuntError.automation("Release the mouse buttons before starting automatic swipes.")
        }
        let input = try SwipeInputMonitor()
        guard let source = CGEventSource(stateID: .hidSystemState), let initial = CGEvent(source: nil)?.location else {
            throw WordHuntError.automation("Cannot create the mouse event source.")
        }
        source.userData = input.eventTag
        source.localEventsSuppressionInterval = 0
        let physicalEvents: CGEventFilterMask = [.permitLocalMouseEvents, .permitLocalKeyboardEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(physicalEvents, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(physicalEvents, state: .eventSuppressionStateRemoteMouseDrag)
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: initial, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: initial, mouseButton: .left),
              let drag = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged, mouseCursorPosition: initial, mouseButton: .left),
              let release = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: initial, mouseButton: .left) else {
            throw WordHuntError.automation("Cannot allocate mouse events.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeLimit
        let displays = Self.displayBounds()
        guard !displays.isEmpty else { throw WordHuntError.automation("No active displays are available.") }
        var expected = initial
        var lastWindowCheck = -Double.infinity
        var gesture: Int64 = 0
        var buttonDown = false
        var attempted = 0
        // This is deliberately independent of cancellation/deadline checks: release must
        // always happen even when the window disappears or a safety check throws.
        defer {
            if buttonDown {
                SwipeMouseEvent.prepare(release, type: .leftMouseUp, at: expected, previous: expected,
                                        tag: input.eventTag, gesture: gesture)
                release.post(tap: .cghidEventTap)
            }
        }

        func check(forceWindow: Bool = false) throws {
            try input.check()
            if isCancelled { throw WordHuntError.automation("Swiping cancelled.") }
            if CGEventSource.keyState(.combinedSessionState, key: 53) {
                throw WordHuntError.automation("Swiping stopped by Escape.")
            }
            guard let location = CGEvent(source: nil)?.location else {
                throw WordHuntError.automation("The pointer position is unavailable.")
            }
            if Self.isEmergencyCorner(location, displays: displays) {
                throw WordHuntError.automation("Swiping stopped at a display corner.")
            }
            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline { throw Stop.deadline }
            // App focus is cheap to inspect on every tick. Window Server + AX are
            // checked at each gesture boundary and at most every 75ms within a drag.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == window.ownerPID else {
                throw WordHuntError.automation("The target application lost focus. Swiping stopped.")
            }
            if forceWindow || now - lastWindowCheck >= 0.075 {
                guard MirroringCapture.isUnchangedVisibleTarget(window) else {
                    throw WordHuntError.automation("The target window moved, resized, closed, became hidden, or lost focus. Swiping stopped.")
                }
                lastWindowCheck = ProcessInfo.processInfo.systemUptime
                // Drain physical input that may have arrived during an AX query.
                try input.check()
                if isCancelled { throw WordHuntError.automation("Swiping cancelled.") }
                if ProcessInfo.processInfo.systemUptime >= deadline { throw Stop.deadline }
            }
        }

        func post(_ type: CGEventType, at point: CGPoint) throws {
            try check(forceWindow: type == .leftMouseDown || type == .leftMouseUp)
            guard window.frame.contains(point), displays.contains(where: { $0.contains(point) }),
                  !Self.isEmergencyCorner(point, displays: displays) else {
                throw WordHuntError.automation("A swipe point is outside the target or inside an emergency display corner.")
            }
            let event: CGEvent
            switch type {
            case .mouseMoved: event = move
            case .leftMouseDown: event = down
            case .leftMouseDragged: event = drag
            case .leftMouseUp: event = release
            default: throw WordHuntError.automation("Unsupported mouse event.")
            }
            SwipeMouseEvent.prepare(event, type: type, at: point, previous: expected,
                                    tag: input.eventTag, gesture: gesture)
            if type == .leftMouseDown { buttonDown = true }
            event.post(tap: .cghidEventTap)
            expected = point
            if type == .leftMouseUp { buttonDown = false }
        }

        func waitUntil(_ target: Double) throws {
            while ProcessInfo.processInfo.systemUptime < target {
                try check()
                input.service(for: min(0.004, max(0, target - ProcessInfo.processInfo.systemUptime)))
            }
            try check()
        }

        do {
            for plan in plans {
                try check(forceWindow: true)
                guard plan.points.allSatisfy({ point in displays.contains { $0.contains(point) } }) else {
                    throw WordHuntError.automation("A swipe point is outside the connected displays.")
                }
                // Reserve the entire word including pause; never deliberately start a
                // partial word at the deadline. Unexpected scheduling delays still release.
                guard ProcessInfo.processInfo.systemUptime + plan.estimatedDuration < deadline else { break }
                willSwipe(plan.word.word)
                gesture += 1
                let first = plan.points[0]
                try post(.mouseMoved, at: first)
                try waitUntil(ProcessInfo.processInfo.systemUptime + 0.004)
                try post(.leftMouseDown, at: first)
                try waitUntil(ProcessInfo.processInfo.systemUptime + timing.stepDuration)
                for index in 1..<plan.points.count {
                    // Hold each tile center for a complete input interval. A stream
                    // of interpolated 4ms positions can be coalesced by Mirroring,
                    // skipping the center before the iPhone consumes that sample.
                    try post(.leftMouseDragged, at: plan.points[index])
                    try waitUntil(ProcessInfo.processInfo.systemUptime + timing.stepDuration)
                }
                try post(.leftMouseUp, at: plan.points[plan.points.count - 1])
                attempted += 1
                progress(attempted, plan.word.word)
                try waitUntil(ProcessInfo.processInfo.systemUptime + timing.wordPause)
            }
        } catch Stop.deadline {
            return attempted
        }
        return attempted
    }

    internal static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return displays.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    internal static func isEmergencyCorner(_ point: CGPoint, displays: [CGRect]) -> Bool {
        displays.contains { rect in
            let nearX = abs(point.x - rect.minX) <= 5 || abs(point.x - rect.maxX) <= 5
            let nearY = abs(point.y - rect.minY) <= 5 || abs(point.y - rect.maxY) <= 5
            return nearX && nearY
        }
    }
}
