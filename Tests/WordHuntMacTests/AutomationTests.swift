import Testing
import AppKit
import WordHuntCore
@testable import WordHuntMac

struct AutomationTests {
    private let geometry = GridGeometry(size: 4, x: 80, y: 160, width: 640, height: 640)
    private let imageSize = CGSize(width: 800, height: 1000)
    private let window = CGRect(x: 100, y: 50, width: 400, height: 500)
    private let word = FoundWord(word: "CAT", path: [0, 1, 5], score: 100)

    private func plans(_ words: [FoundWord]? = nil, geometry: GridGeometry? = nil,
                       timing: SwipeTiming = SwipeTiming()) throws -> [SwipePlan] {
        try SwipePlanner.plan(words: words ?? [word], geometry: geometry ?? self.geometry,
                              imageSize: imageSize, windowFrame: window, timing: timing)
    }

    @Test func retinaPixelsMapToQuartzPoints() throws {
        let plan = try #require(plans().first)
        #expect(plan.points == [CGPoint(x: 180, y: 170), CGPoint(x: 260, y: 170), CGPoint(x: 260, y: 250)])
        #expect(abs(plan.estimatedDuration - (3 * 0.035 + 0.045 + 0.004)) < 0.000_001)
        #expect(plan.word == word)
    }

    @Test func secondaryDisplayMayHaveNegativeGlobalOrigin() throws {
        let plans = try SwipePlanner.plan(words: [word], geometry: geometry, imageSize: imageSize,
                                         windowFrame: CGRect(x: -1200, y: -300, width: 400, height: 500), timing: SwipeTiming())
        #expect(plans[0].points[0] == CGPoint(x: -1120, y: -180))
    }

    @Test func independentAxisScalingUsesActualScreenshotDimensions() throws {
        let plans = try SwipePlanner.plan(words: [word], geometry: geometry, imageSize: imageSize,
                                         windowFrame: CGRect(x: 0, y: 0, width: 800, height: 500), timing: SwipeTiming())
        #expect(plans[0].points[0] == CGPoint(x: 160, y: 120))
    }

    @Test func rejectsOutOfImageAndNonfiniteGeometry() {
        for bad in [GridGeometry(size: 4, x: -1, y: 0, width: 600, height: 600),
                    GridGeometry(size: 4, x: 0, y: 0, width: 801, height: 600),
                    GridGeometry(size: 4, x: .nan, y: 0, width: 600, height: 600),
                    GridGeometry(size: 4, x: 0, y: 0, width: 0, height: 600),
                    GridGeometry(size: 3, x: 0, y: 0, width: 600, height: 600)] {
            #expect(throws: (any Error).self) { try plans(geometry: bad) }
        }
    }

    @Test func rejectsInvalidImageAndWindowDimensions() {
        #expect(throws: (any Error).self) {
            try SwipePlanner.plan(words: [word], geometry: geometry,
                imageSize: CGSize(width: 0, height: 1000), windowFrame: window, timing: SwipeTiming())
        }
        #expect(throws: (any Error).self) {
            try SwipePlanner.plan(words: [word], geometry: geometry,
                imageSize: imageSize, windowFrame: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 500), timing: SwipeTiming())
        }
    }

    @Test func rejectsIllegalPathsAndWords() {
        for candidate in [FoundWord(word: "CAT", path: [0, 1, 0], score: 100),
                          FoundWord(word: "CAT", path: [0, 3, 7], score: 100),
                          FoundWord(word: "CAT", path: [0, 1, 16], score: 100),
                          FoundWord(word: "CAT", path: [-1, 0, 1], score: 100),
                          FoundWord(word: "CAT", path: [], score: 100),
                          FoundWord(word: "cat", path: [0, 1, 5], score: 100),
                          FoundWord(word: "AT", path: [0, 1], score: 0)] {
            #expect(throws: (any Error).self) { try plans([candidate]) }
        }
    }

    @Test func fiveByFiveAndMultiLetterTilePaths() throws {
        let geometry = GridGeometry(size: 5, x: 0, y: 0, width: 500, height: 500)
        let words = [FoundWord(word: "QUA", path: [0, 6], score: 100),
                     FoundWord(word: "CAT", path: [18, 19, 24], score: 100)]
        let result = try SwipePlanner.plan(words: words, geometry: geometry, imageSize: CGSize(width: 500, height: 500),
                                          windowFrame: CGRect(x: 0, y: 0, width: 500, height: 500), timing: SwipeTiming())
        #expect(result[0].points == [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 150)])
        #expect(result[1].points.last == CGPoint(x: 450, y: 450))
    }

    @Test func rejectsInvalidTimingEvenWithNoWords() {
        for timing in [SwipeTiming(stepDuration: 0), SwipeTiming(stepDuration: .nan),
                       SwipeTiming(stepDuration: .infinity), SwipeTiming(wordPause: -1), SwipeTiming(wordPause: .nan)] {
            #expect(throws: (any Error).self) { try plans([], timing: timing) }
        }
    }

    @Test func emptyScheduleHasNoAttempts() throws {
        #expect(try plans([]).isEmpty)
    }

    @Test func cancellationBeforeWorkerStartsRemainsLatched() async {
        let message = await Task.detached { () -> String? in
            let executor = SwipeExecutor()
            executor.cancel()
            let window = MirrorWindow(id: 0, ownerPID: 0, title: "Unused",
                                      frame: CGRect(x: 0, y: 0, width: 400, height: 500))
            do {
                _ = try executor.run(plans: [], window: window, timing: SwipeTiming(),
                                     timeLimit: 1, willSwipe: { _ in }, progress: { _, _ in })
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value
        // Cancellation is checked before permission/window inspection or event creation.
        #expect(message == "Swiping cancelled.")
    }

    @Test func emergencyCornersOnEveryDisplayWithoutReadingMouseOrPostingEvents() {
        let displays = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                        CGRect(x: -1280, y: -200, width: 1280, height: 1024)]
        #expect(SwipeExecutor.isEmergencyCorner(CGPoint(x: 1, y: 1), displays: displays))
        #expect(SwipeExecutor.isEmergencyCorner(CGPoint(x: -1279, y: -199), displays: displays))
        #expect(SwipeExecutor.isEmergencyCorner(CGPoint(x: -1, y: 823), displays: displays))
        #expect(!SwipeExecutor.isEmergencyCorner(CGPoint(x: 500, y: 500), displays: displays))
        #expect(!SwipeExecutor.isEmergencyCorner(CGPoint(x: -1000, y: 0), displays: displays))
    }

    @Test func nativeMouseDragCarriesPressedStateAndReleasesPressure() throws {
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: .zero, mouseButton: .left))
        let start = CGPoint(x: 180, y: 170)
        let end = CGPoint(x: 260, y: 250)
        var previous = start
        for (type, point, pressure) in [(CGEventType.mouseMoved, start, 0.0),
                                       (.leftMouseDown, start, 1.0),
                                       (.leftMouseDragged, end, 1.0),
                                       (.leftMouseUp, end, 0.0)] {
            event.flags = [.maskShift, .maskCommand]
            event.timestamp = 1
            SwipeMouseEvent.prepare(event, type: type, at: point, previous: previous, tag: 1234, gesture: 7)
            #expect(event.type == type)
            #expect(event.location == point)
            #expect(event.getDoubleValueField(.mouseEventPressure) == pressure)
            #expect(event.getIntegerValueField(.mouseEventButtonNumber) == 0)
            #expect(event.getIntegerValueField(.mouseEventNumber) == 7)
            #expect(event.getIntegerValueField(.mouseEventClickState) == (type == .mouseMoved ? 0 : 1))
            #expect(event.getIntegerValueField(.eventSourceUserData) == 1234)
            #expect(event.flags.isEmpty)
            #expect(event.timestamp > 1)
            if type == .leftMouseDragged {
                #expect(event.getIntegerValueField(.mouseEventDeltaX) == 80)
                #expect(event.getIntegerValueField(.mouseEventDeltaY) == 80)
            }
            previous = point
        }
    }

    @Test func arbitrarilyDelayedOwnMouseEventsDoNotTriggerTakeover() throws {
        var input = SwipeInputState(eventTag: 1234)
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: .zero, mouseButton: .left))
        // The pointer may lag multiple posted points for much longer than 12ms.
        // Ownership must not depend on the current cursor or event-delivery age.
        for (type, point) in [(CGEventType.mouseMoved, CGPoint(x: 180, y: 170)),
                              (.leftMouseDown, CGPoint(x: 180, y: 170)),
                              (.leftMouseDragged, CGPoint(x: 260, y: 170)),
                              (.leftMouseDragged, CGPoint(x: 260, y: 250)),
                              (.leftMouseUp, CGPoint(x: 260, y: 250))] {
            SwipeMouseEvent.prepare(event, type: type, at: point, previous: .zero, tag: 1234, gesture: 1)
            event.timestamp = 1
            input.observe(event, type: type)
            #expect(input.interruption == nil)
        }
    }

    @Test func physicalMouseTakeoverCannotBeClearedByLaterSyntheticEvents() throws {
        var input = SwipeInputState(eventTag: 1234)
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                        mouseCursorPosition: CGPoint(x: 300, y: 300), mouseButton: .left))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        input.observe(event, type: .mouseMoved)
        #expect(input.interruption == .mouse)
        SwipeMouseEvent.prepare(event, type: .leftMouseDragged, at: CGPoint(x: 260, y: 250),
                                previous: CGPoint(x: 260, y: 170), tag: 1234, gesture: 1)
        input.observe(event, type: .leftMouseDragged)
        #expect(input.interruption == .mouse)
    }

    @Test func physicalClickWithoutPointerDisplacementStopsSwiping() throws {
        var input = SwipeInputState(eventTag: 1234)
        let event = try #require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                                        mouseCursorPosition: CGPoint(x: 180, y: 170), mouseButton: .right))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        input.observe(event, type: .rightMouseDown)
        #expect(input.interruption == .mouse)
    }

    @Test func escapePressRemainsLatchedAfterKeyIsReleased() throws {
        var input = SwipeInputState(eventTag: 1234)
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: 0)
        input.observe(event, type: .keyDown)
        #expect(input.interruption == .escape)
        event.type = .keyUp
        input.observe(event, type: .keyUp)
        #expect(input.interruption == .escape)
    }

    @Test func lossOfPhysicalInputMonitorStopsEvenTaggedEvents() throws {
        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            var input = SwipeInputState(eventTag: 1234)
            let event = try #require(CGEvent(source: nil))
            event.setIntegerValueField(.eventSourceUserData, value: 1234)
            input.observe(event, type: type)
            #expect(input.interruption == .unavailable)
        }
    }

    @Test func fullWindowCaptureMapsTitlebarAndRetinaScaleWithoutShadowOffsets() throws {
        let frame = CGRect(x: 1289, y: 167, width: 322, height: 718)
        let configuration = try MirroringCapture.captureConfiguration(windowFrame: frame, contentRect: frame,
                                                                      pointPixelScale: 2)
        #expect(configuration.width == 644)
        #expect(configuration.height == 1436)
        #expect(configuration.ignoreShadowsSingleWindow)
        #expect(configuration.ignoreGlobalClipSingleWindow)
        #expect(!configuration.preservesAspectRatio)
        let board = GridGeometry(size: 4, x: 44, y: 300, width: 560, height: 560)
        let plans = try SwipePlanner.plan(words: [word], geometry: board,
                                         imageSize: CGSize(width: configuration.width, height: configuration.height),
                                         windowFrame: frame, timing: SwipeTiming())
        #expect(plans[0].points[0] == CGPoint(x: 1346, y: 352))
    }

    @Test func captureRejectsContentOnlyOrShadowExpandedBounds() {
        let frame = CGRect(x: 1289, y: 167, width: 322, height: 718)
        for mismatched in [CGRect(x: 1289, y: 195, width: 322, height: 690),
                           CGRect(x: 1255, y: 133, width: 390, height: 786)] {
            #expect(throws: (any Error).self) {
                try MirroringCapture.captureConfiguration(windowFrame: frame, contentRect: mismatched,
                                                          pointPixelScale: 2)
            }
        }
    }
}
