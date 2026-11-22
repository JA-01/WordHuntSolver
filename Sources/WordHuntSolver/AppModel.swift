import AppKit
import SwiftUI
import WordHuntCore
import WordHuntMac

@MainActor
final class AppModel: ObservableObject {
    @Published var image: CGImage?
    @Published var geometry: GridGeometry?
    @Published var boardText = ""
    @Published var size = 4
    @Published var words: [FoundWord] = []
    @Published var selectedWord: String?
    @Published private(set) var activeWord: String?
    @Published var status = "Open Word Hunt in iPhone Mirroring, then choose Solve & Auto Swipe."
    @Published var issue: String?
    @Published var busy = false
    @Published var running = false
    @Published var watching = false
    @Published var confidence: Float?
    @Published var windowChoices: [MirrorWindow] = []
    @Published var selectedWindowID: CGWindowID = 0
    @Published var stepDuration = 0.035
    @Published var wordPause = 0.065
    @Published var timeLimit = 70.0
    @Published var attempted = 0
    @Published var planned = 0
    @Published var accessibility = AutomationPermissions.accessibilityGranted
    @Published var screenRecording = AutomationPermissions.screenRecordingGranted
    @Published var dictionaryName = "Bundled ENABLE"
    @Published var isLive = false

    private(set) var solver: WordSolver?
    private var board: Board?
    private var target: MirrorWindow?
    private var capturedAt = ProcessInfo.processInfo.systemUptime
    private var job: Task<Void, Never>?
    private var generation = 0
    private var executor: SwipeExecutor?

    var estimatedScore: Int { words.reduce(0) { $0 + $1.score } }
    var selectedPath: [Int] { words.first { $0.word == selectedWord }?.path ?? [] }
    var canPlay: Bool { !busy && !running && !words.isEmpty && target != nil && geometry != nil && isLive }

    init() {
        do { solver = try WordSolver.bundled() }
        catch { issue = error.localizedDescription }
        refreshWindows()
    }

    func refreshPermissions() {
        accessibility = AutomationPermissions.accessibilityGranted
        screenRecording = AutomationPermissions.screenRecordingGranted
    }

    func refreshWindows() {
        refreshPermissions()
        do {
            windowChoices = try MirroringCapture.windows()
            if !windowChoices.contains(where: { $0.id == selectedWindowID }) {
                selectedWindowID = windowChoices.first?.id ?? 0
            }
        } catch { windowChoices = [] }
    }

    func requestPermissions() {
        AutomationPermissions.requestAccessibility()
        AutomationPermissions.requestScreenRecording()
        refreshPermissions()
    }

    func openPrivacy() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw WordHuntError.detection("Could not read this image.") }
            stop()
            target = nil; isLive = false
            startRecognition(image: image, target: nil)
        } catch { issue = error.localizedDescription }
    }

    func importDictionary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let entries = text.split(whereSeparator: \.isNewline).map(String.init)
            let replacement = WordSolver(words: entries)
            guard replacement.wordCount > 0 else { throw WordHuntError.dictionary("No valid words found. Use one A–Z word per line.") }
            solver = replacement
            dictionaryName = url.lastPathComponent
            solveEdits()
        } catch { issue = error.localizedDescription }
    }

    func restoreDictionary() {
        do { solver = try WordSolver.bundled(); dictionaryName = "Bundled ENABLE"; if !boardText.isEmpty { solveEdits() } }
        catch { issue = error.localizedDescription }
    }

    func loadSample() {
        do {
            stop()
            target = nil; isLive = false
            startRecognition(image: try BoardArtwork.image(), target: nil)
        } catch { issue = error.localizedDescription }
    }

    func capture() {
        guard !busy && !running else { return }
        issue = nil; busy = true
        generation += 1
        let token = generation
        job = Task {
            do {
                let window = try chosenWindow()
                // ScreenCaptureKit captures this specific window without raising it.
                // Accessibility and focus are only needed when sending input.
                let snapshot = try await MirroringCapture.capture(window)
                guard token == generation, !Task.isCancelled else { return }
                capturedAt = ProcessInfo.processInfo.systemUptime
                try await recognize(image: snapshot.image, target: snapshot.window)
            } catch { if token == generation { issue = error.localizedDescription } }
            if token == generation { busy = false }
        }
    }

    private func startRecognition(image: CGImage, target: MirrorWindow?) {
        job?.cancel()
        generation += 1
        let token = generation
        busy = true; issue = nil
        job = Task {
            do { try await recognize(image: image, target: target) }
            catch { if token == generation { issue = error.localizedDescription } }
            if token == generation { busy = false }
        }
    }

    private func recognize(image: CGImage, target: MirrorWindow?, solve: Bool = true) async throws {
        try Task.checkCancellation()
        let operation = generation
        self.image = image
        self.target = target
        isLive = target != nil
        geometry = nil; board = nil; words = []; confidence = nil; selectedWord = nil
        status = "Detecting tiles and reading letters…"
        let gridSize = size
        let result = try await Task.detached(priority: .userInitiated) { try BoardDetector().detect(image: image, size: gridSize) }.value
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
        self.geometry = result.geometry
        confidence = result.cells.map(\.confidence).min()
        boardText = (0..<gridSize).map { row in result.cells[(row * gridSize)..<((row + 1) * gridSize)].map(\.text).joined(separator: " ") }.joined(separator: "\n")
        if let board = result.board {
            self.board = board
            if solve {
                try await findWords(board)
                status = "Board ready. Select a word to preview its path; edit letters if needed."
            }
        } else {
            board = nil
            status = "Some tiles are unreadable. Correct the letters, then choose Solve edits."
        }
    }

    func solveEdits() {
        do {
            let edited = try Board(text: boardText, size: size)
            board = edited
            guard let solver else { throw WordHuntError.dictionary("Dictionary unavailable.") }
            words = solver.solve(edited)
            selectedWord = words.first?.word
            issue = nil
            status = "\(words.count) unique words. Scores are dictionary estimates, not confirmed game points."
        } catch { words = []; issue = error.localizedDescription }
    }

    private func findWords(_ board: Board) async throws {
        let operation = generation
        guard let solver else { throw WordHuntError.dictionary("Dictionary unavailable.") }
        let found = await Task.detached(priority: .userInitiated) { solver.solve(board) }.value
        try Task.checkCancellation()
        guard operation == generation else { throw CancellationError() }
        words = found
        selectedWord = found.first?.word
    }

    private func chosenWindow() throws -> MirrorWindow {
        let available = try MirroringCapture.windows()
        if let choice = available.first(where: { $0.id == selectedWindowID }) { return choice }
        guard available.count == 1, let only = available.first else {
            throw WordHuntError.automation("Open iPhone Mirroring with a visible Word Hunt board, then refresh and select its window.")
        }
        return only
    }

    /// One action owns capture, stable recognition, solving, validation and input.
    /// It may be armed before the round starts: it waits for a settled board and
    /// never presses buttons or starts a new game.
    func solveAndPlay() {
        guard !busy && !running else { return }
        refreshWindows()
        guard accessibility, screenRecording else {
            issue = "Enable Screen Recording and Accessibility with Grant permissions, then click Solve & Auto Swipe again."
            return
        }
        generation += 1
        let token = generation
        busy = true; watching = true; issue = nil
        attempted = 0; planned = 0
        status = "Armed. Start the round on the phone; swiping begins once its board is confirmed."
        job = Task {
            defer {
                if token == generation { busy = false; watching = false; running = false }
            }
            // The previous frame, while it showed confidently read letters.
            var lastFrame: (board: Board, image: CGImage)?
            // When the current letters first appeared; the round budget starts there.
            var seen: (board: Board, at: Double)?
            var lastProblem = "No readable board is visible."
            do {
                let initial = try chosenWindow()
                selectedWindowID = initial.id
                // Reading the board only needs ScreenCaptureKit, which captures the
                // target without raising it. Focus is required for input and is
                // requested and verified again in executePlay, where a failure is
                // actionable instead of blocking detection.
                try? MirroringCapture.activate(initial)
                let watchStart = ProcessInfo.processInfo.systemUptime
                while token == generation {
                    try Task.checkCancellation()
                    guard ProcessInfo.processInfo.systemUptime - watchStart < 90 else {
                        throw WordHuntError.automation("Automatic play stopped: \(lastProblem) Open a live round, or use Capture only to inspect and correct its letters.")
                    }
                    let frameTime = ProcessInfo.processInfo.systemUptime
                    let snapshot = try await MirroringCapture.capture(initial)
                    try Task.checkCancellation()
                    guard token == generation else { return }
                    do {
                        try await recognize(image: snapshot.image, target: snapshot.window, solve: false)
                        if let current = board, seen?.board != current { seen = (current, frameTime) }
                        if let current = board, let geometry, (confidence ?? 0) >= 0.80 {
                            // Identical letters are also read while the board is still
                            // animating in; the glyphs must also stay in place.
                            if let previous = lastFrame, previous.board == current,
                               try BoardAppearance.matches(previous.image, snapshot.image, geometry: geometry) {
                                capturedAt = seen?.at ?? frameTime
                                watching = false
                                status = "Board confirmed. Finding words…"
                                try await findWords(current)
                                do {
                                    try await executePlay()
                                    return
                                } catch is BoardChanged {
                                    // Still settling after Start: read it again instead of disarming.
                                    busy = true; watching = true
                                    status = "The board changed before swiping. Reading it again…"
                                }
                                lastFrame = nil
                            } else {
                                lastFrame = (current, snapshot.image)
                                status = "Board read. Confirming letters in a second frame…"
                            }
                        } else {
                            lastFrame = nil
                            lastProblem = board == nil
                                ? "Some letters could not be read."
                                : "Lowest tile confidence is \(Int((confidence ?? 0) * 100))%; automatic input requires 80%."
                            status = "\(lastProblem) Waiting for a clear board; Stop to correct it manually."
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch let error as WordHuntError {
                        // Only detection failures are transient. Never hide an input,
                        // permission, dictionary or stale-target failure in a retry loop.
                        guard case .detection = error else { throw error }
                        lastFrame = nil
                        lastProblem = error.localizedDescription
                        status = "Waiting for a live board: \(lastProblem)"
                    }
                    try await Task.sleep(nanoseconds: 250_000_000)
                }
            } catch {
                if token == generation && !Task.isCancelled {
                    issue = error.localizedDescription
                    status = "Automatic play stopped. Fix the reported problem, then try again."
                }
            }
        }
    }

    func play() {
        guard canPlay else { return }
        generation += 1
        busy = true; issue = nil
        let token = generation
        job = Task {
            do { try await executePlay() }
            catch { if token == generation { issue = error.localizedDescription; running = false; busy = false } }
        }
    }

    private func executePlay() async throws {
        let operation = generation
        busy = true
        defer {
            if generation == operation { busy = false; activeWord = nil }
        }
        guard let image, let geometry, let target, board != nil else { throw WordHuntError.automation("Capture a live board first. Imported screenshots cannot send mouse input.") }
        let edited = try Board(text: boardText, size: size)
        guard edited == board else { throw WordHuntError.automation("Letters changed. Choose Solve edits before playing.") }
        refreshPermissions()
        guard accessibility else { throw WordHuntError.automation("Accessibility permission is required to swipe.") }
        // Clicking the phone's Start button can land just before the board is
        // confirmed, and any physical pointer event during swiping stops input.
        // The round budget keeps running while waiting for the hand to leave.
        if !PointerActivity.isIdle(for: 0.3) {
            status = "Board ready. Take your hand off the mouse to start swiping."
            repeat {
                try await Task.sleep(nanoseconds: 50_000_000)
            } while !PointerActivity.isIdle(for: 0.3)
                && ProcessInfo.processInfo.systemUptime - capturedAt < timeLimit - 1.8
        }
        status = "Checking that the live board still matches this capture…"
        try MirroringCapture.activate(target)
        try await Task.sleep(nanoseconds: 200_000_000)
        let fresh = try await MirroringCapture.capture(target)
        try Task.checkCancellation()
        guard fresh.window.frame == target.frame,
              try BoardAppearance.matches(image, fresh.image, geometry: geometry) else { throw BoardChanged() }
        let elapsed = ProcessInfo.processInfo.systemUptime - capturedAt
        let remaining = timeLimit - elapsed - 0.8
        guard remaining > 1 else { throw WordHuntError.automation("This capture is too old for the selected round budget. Capture the current board again.") }
        let timing = SwipeTiming(stepDuration: stepDuration, wordPause: wordPause)
        let allPlans = try SwipePlanner.plan(words: words, geometry: geometry, imageSize: CGSize(width: image.width, height: image.height), windowFrame: target.frame, timing: timing)
        let schedule = WordSchedule.select(allPlans, seconds: remaining)
        guard !schedule.isEmpty else { throw WordHuntError.automation("No complete word fits the remaining gesture budget.") }
        running = true; watching = false; busy = false; attempted = 0; planned = schedule.count
        status = "Swiping \(schedule.count) words. Escape or moving the mouse stops input."
        let executor = SwipeExecutor()
        self.executor = executor
        let token = generation
        do {
            let count = try await Task.detached(priority: .userInitiated) {
                try executor.run(plans: schedule, window: target, timing: timing, timeLimit: remaining, willSwipe: { word in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.running else { return }
                        self.activeWord = word
                        self.selectedWord = word
                    }
                }) { count, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == token, self.running else { return }
                        self.attempted = count
                    }
                }
            }.value
            if generation == token {
                attempted = count
                running = false
                status = "Finished: \(count) words attempted. Check the game's accepted score. Automatic play is disarmed."
                self.executor = nil
            }
        } catch {
            if generation == token { running = false; self.executor = nil }
            throw error
        }
    }

    func stop() {
        generation += 1
        job?.cancel()
        executor?.cancel()
        job = nil; executor = nil
        busy = false; running = false; watching = false
        activeWord = nil
        status = "Stopped. No automatic play is armed."
    }

    func sizeChanged() {
        stop()
        geometry = nil; words = []; board = nil
        if let image { startRecognition(image: image, target: target) }
    }

    func exportWords() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "word-hunt-solution.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(words).write(to: url)
        } catch { issue = error.localizedDescription }
    }
}

/// The live board or window no longer matches the capture being played.
private struct BoardChanged: LocalizedError {
    var errorDescription: String? { "The board or window changed after capture. Capture and solve again before swiping." }
}
