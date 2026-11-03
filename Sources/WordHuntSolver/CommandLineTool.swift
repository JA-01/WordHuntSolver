import AppKit
import Foundation
import WordHuntCore
import WordHuntMac

@MainActor
enum CommandLineTool {
    struct Solution: Codable {
        let board: Board
        let geometry: GridGeometry?
        let minimumConfidence: Float?
        let dictionaryWords: Int
        let estimatedScore: Int
        let words: [FoundWord]
    }

    static func run(_ arguments: [String]) -> Int32 {
        do {
            if arguments.contains("--help") || arguments.first == "help" { print(help); return 0 }
            let command = arguments.first ?? "help"
            switch command {
            case "solve":
                let size = try integer("--size", in: arguments, fallback: 4)
                guard let text = value("--board", in: arguments) else { throw WordHuntError.invalidBoard("Missing --board. See --help.") }
                let board = try Board(text: text, size: size)
                let solver = try dictionary(arguments)
                emit(board: board, solver: solver, arguments: arguments)
            case "image":
                _ = NSApplication.shared
                guard let path = value("--image", in: arguments), let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw WordHuntError.detection("Provide a readable screenshot with --image PATH.") }
                let size = try integer("--size", in: arguments, fallback: 4)
                let bounds = try parseBounds(value("--bounds", in: arguments))
                let detection = try BoardDetector().detect(image: image, size: size, bounds: bounds)
                guard let board = detection.board else {
                    throw WordHuntError.detection("Unreadable board: \(detection.cells.map(\.text).joined(separator: " ")). Use the app to correct letters or calibrate --bounds x,y,width,height.")
                }
                emit(board: board, solver: try dictionary(arguments), arguments: arguments, geometry: detection.geometry, confidence: detection.cells.map(\.confidence).min())
            case "sample", "--sample":
                _ = NSApplication.shared
                let url = URL(fileURLWithPath: value("--output", in: arguments) ?? "sample-board.png")
                try BoardArtwork.savePNG(BoardArtwork.image(), to: url)
                print(url.path)
            case "self-check", "--self-check":
                try selfCheck(arguments)
            case "practice-check":
                try practiceCheck(arguments)
            default: throw WordHuntError.invalidBoard("Unknown command: \(command). See --help.")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    private static func dictionary(_ arguments: [String]) throws -> WordSolver {
        if let path = value("--dictionary", in: arguments) {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let solver = WordSolver(words: text.split(whereSeparator: \.isNewline).map(String.init))
            guard solver.wordCount > 0 else { throw WordHuntError.dictionary("Dictionary contains no usable A–Z words.") }
            return solver
        }
        return try WordSolver.bundled()
    }

    private static func emit(board: Board, solver: WordSolver, arguments: [String], geometry: GridGeometry? = nil, confidence: Float? = nil) {
        let words = solver.solve(board)
        if arguments.contains("--json") {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let result = Solution(board: board, geometry: geometry, minimumConfidence: confidence, dictionaryWords: solver.wordCount, estimatedScore: words.reduce(0) { $0 + $1.score }, words: words)
            if let data = try? encoder.encode(result), let text = String(data: data, encoding: .utf8) { print(text) }
        } else {
            print(board.text)
            print("\n\(words.count) unique words; \(words.reduce(0) { $0 + $1.score }) estimated points. Game acceptance is not guaranteed.")
            for word in words { print("\(word.word)\t\(word.score)\t\(word.path.map(String.init).joined(separator: ","))") }
        }
    }

    private static func selfCheck(_ arguments: [String]) throws {
        _ = NSApplication.shared
        let solver = try WordSolver.bundled()
        let expected = BoardArtwork.sample
        let image = try BoardArtwork.image()
        let detection = try BoardDetector().detect(image: image)
        guard detection.board == expected else { throw WordHuntError.detection("Practice OCR mismatch. Expected \(expected.tiles); got \(detection.cells.map(\.text)).") }
        let solutions = solver.solve(expected)
        guard !solutions.isEmpty else { throw WordHuntError.dictionary("No sample words found.") }
        for word in solutions {
            guard Set(word.path).count == word.path.count,
                  word.path.map({ expected.tiles[$0] }).joined() == word.word else { throw WordHuntError.invalidBoard("Illegal solution path: \(word.word)") }
        }
        let timing = SwipeTiming()
        let plans = try SwipePlanner.plan(words: solutions, geometry: detection.geometry, imageSize: CGSize(width: image.width, height: image.height), windowFrame: CGRect(x: 100, y: 100, width: Double(image.width) / 2, height: Double(image.height) / 2), timing: timing)
        let schedule = WordSchedule.select(plans, seconds: 70)
        guard !schedule.isEmpty, schedule.reduce(0, { $0 + $1.estimatedDuration }) <= 70 else { throw WordHuntError.automation("Invalid gesture schedule.") }
        let practice = PracticeController(solver: solver)
        try practice.view.replayLocally(schedule.map(\.word))
        let expectedWords = Set(schedule.map { $0.word.word })
        let expectedScore = schedule.reduce(0) { $0 + $1.word.score }
        guard practice.view.accepted == expectedWords, practice.view.score == expectedScore else {
            throw WordHuntError.automation("Local event replay mismatch: accepted \(practice.view.accepted.count)/\(expectedWords.count) words, score \(practice.view.score)/\(expectedScore).")
        }
        // Duplicates must not increase the practice score.
        try practice.view.replayLocally([schedule[0].word])
        guard practice.view.score == expectedScore else { throw WordHuntError.automation("Duplicate gesture increased the practice score.") }
        try checkWorkbenchState(expected: expected, words: solutions)
        if let output = value("--output", in: arguments) {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try BoardArtwork.savePNG(image, to: directory.appendingPathComponent("sample-board.png"))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let result = Solution(board: expected, geometry: detection.geometry, minimumConfidence: detection.cells.map(\.confidence).min(), dictionaryWords: solver.wordCount, estimatedScore: solutions.reduce(0) { $0 + $1.score }, words: solutions)
            try encoder.encode(result).write(to: directory.appendingPathComponent("solution.json"))
        }
        print("PASS: detected \(expected.size)×\(expected.size) board; all \(expected.tiles.count) OCR tiles match.")
        print("PASS: \(solver.wordCount) dictionary words; \(solutions.count) unique legal solutions.")
        print("PASS: Retina-scale gesture planning; \(schedule.count) scheduled words within 70 seconds.")
        print("PASS: native local mouse handlers accepted \(practice.view.accepted.count) words for \(practice.view.score) points; duplicate rejected.")
        print("PASS: workbench correction, invalid-board rejection, and active-calibration safety.")
        print("LIMIT: local NSEvent replay is not system CGEvent injection or an iPhone test.")
        print("Permissions: Screen Recording=\(AutomationPermissions.screenRecordingGranted), Accessibility=\(AutomationPermissions.accessibilityGranted)")
    }

    /// Explicit opt-in system-input diagnostic, restricted to our local practice
    /// window. Unlike self-check, this exercises the complete production action.
    private static func practiceCheck(_ arguments: [String]) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.finishLaunching()
        guard AutomationPermissions.screenRecordingGranted, AutomationPermissions.accessibilityGranted else {
            throw WordHuntError.automation("practice-check requires Screen Recording and Accessibility. It captures and swipes the local practice window; it does not bypass privacy grants.")
        }
        let solver = try WordSolver.bundled()
        let practice = PracticeController(solver: solver)
        practice.show()
        NSRunningApplication(processIdentifier: getpid())?.activate(options: [.activateAllWindows])
        practice.window.makeKeyAndOrderFront(nil)
        // Let the Window Server settle before the production action verifies focus.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let model = AppModel()
        model.refreshWindows()
        guard let window = model.windowChoices.first(where: { $0.ownerPID == getpid() }) else {
            throw WordHuntError.automation("The local practice window is not available for capture.")
        }
        model.selectedWindowID = window.id
        model.timeLimit = 12
        model.solveAndPlay()
        let deadline = Date().addingTimeInterval(60)
        var lastStatus = ""
        while (model.busy || model.running) && Date() < deadline {
            if model.status != lastStatus {
                print(model.status)
                lastStatus = model.status
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            while let event = app.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                app.sendEvent(event)
            }
            app.updateWindows()
        }
        guard !model.busy && !model.running else {
            model.stop()
            throw WordHuntError.automation("The full capture-to-swipe practice run timed out.")
        }
        if let issue = model.issue { throw WordHuntError.automation(issue) }
        guard try Board(text: model.boardText, size: 4) == BoardArtwork.sample,
              model.attempted > 0, practice.view.accepted.count == model.attempted else {
            throw WordHuntError.automation("System input mismatch: \(model.attempted) attempted, \(practice.view.accepted.count) accepted. Board: \(model.boardText)")
        }
        let acceptedWords = model.words.filter { practice.view.accepted.contains($0.word) }
        let expectedScore = acceptedWords.reduce(0) { $0 + $1.score }
        guard practice.view.score == expectedScore else {
            throw WordHuntError.automation("Practice score mismatch: \(practice.view.score), expected \(expectedScore).")
        }
        if let output = value("--output", in: arguments) {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result: [String: Any] = [
                "attempted": model.attempted, "accepted": practice.view.accepted.sorted(),
                "score": practice.view.score, "board": model.boardText
            ]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("system-input.json"))
        }
        print("PASS: one action captured the live practice window, confirmed OCR, solved and posted system mouse drags.")
        print("PASS: \(model.attempted) attempted words accepted for \(practice.view.score) points.")
        print("LIMIT: local system-input proof, not proof of GamePigeon dictionary acceptance or iPhone touch delivery.")
        practice.window.close()
    }

    private static func checkWorkbenchState(expected: Board, words: [FoundWord]) throws {
        let model = AppModel()
        model.loadSample()
        // A late calibration callback must not replace an in-flight capture job.
        model.calibrate(CGRect(x: 0, y: 0, width: 1, height: 1))
        let timeout = Date().addingTimeInterval(45)
        while model.busy && Date() < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        guard model.issue == nil, model.words == words,
              try Board(text: model.boardText, size: 4) == expected else {
            throw WordHuntError.detection(model.issue ?? "Workbench recognition or calibration guard failed.")
        }
        let original = model.boardText
        model.boardText = "?"
        model.solveEdits()
        guard model.words.isEmpty, model.issue != nil else {
            throw WordHuntError.invalidBoard("The workbench accepted an unreadable board.")
        }
        model.boardText = original
        model.solveEdits()
        guard model.words == words, !model.canPlay else {
            throw WordHuntError.automation("Screenshot editing changed solutions or enabled system input.")
        }
        model.stop()
    }

    private static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
    private static func integer(_ flag: String, in arguments: [String], fallback: Int) throws -> Int {
        guard let raw = value(flag, in: arguments) else { return fallback }
        guard let number = Int(raw) else { throw WordHuntError.invalidBoard("\(flag) requires an integer.") }
        return number
    }
    private static func parseBounds(_ text: String?) throws -> CGRect? {
        guard let text else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4 else { throw WordHuntError.detection("Bounds must be x,y,width,height in image pixels.") }
        return CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }

    private static let help = """
    Word Hunt Solver — offline macOS solver

    Launch with no arguments for the native app.
    solve --board "S T A R E N O T L I N E C A R E" [--size 4|5] [--json]
    image --image screenshot.png [--size 4|5] [--bounds x,y,width,height] [--json]
    sample [--output sample-board.png]
    self-check [--output DIRECTORY]
    practice-check [--output DIRECTORY]  (system input to local practice only)

    solve/image accept --dictionary PATH (one word per line). QU is an explicit
    two-letter tile; bare Q is literal. Paths use zero-based row-major indices.
    solve/image/sample/self-check never send system mouse input.
    practice-check explicitly exercises capture and system drags on the local
    practice window. Use Solve & Auto Swipe in the app for iPhone Mirroring.
    """
}
