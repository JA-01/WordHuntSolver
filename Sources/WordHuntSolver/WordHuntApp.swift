import AppKit
import SwiftUI
import WordHuntCore

@main
struct WordHuntApplication: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.count > 1 { exit(CommandLineTool.run(Array(CommandLine.arguments.dropFirst()))) }
    }

    var body: some Scene {
        WindowGroup("Word Hunt Solver") { SolverWorkbench(model: model) }
            .defaultSize(width: 1120, height: 810)
            .windowResizability(.contentMinSize)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Solve & Auto Swipe") { model.solveAndPlay() }.keyboardShortcut("r")
                        .disabled(model.busy || model.running)
                    Button("Capture only") { model.capture() }.keyboardShortcut("r", modifiers: [.command, .shift])
                        .disabled(model.busy || model.running)
                    Button("Import screenshot…") { model.importImage() }.keyboardShortcut("o")
                        .disabled(model.busy || model.running)
                }
                CommandGroup(after: .appSettings) {
                    Button("Stop automation") { model.stop() }.keyboardShortcut(.escape, modifiers: [])
                }
            }
    }
}

private struct SolverWorkbench: View {
    @ObservedObject var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    private var isWorking: Bool { model.busy || model.running }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 20) {
                preview
                VStack(spacing: 12) {
                    ScrollViewReader { inspector in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                humanModeControls
                                boardEditor
                                results.id("word-results")
                                timing
                            }
                            .padding(.trailing, 4)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .onChange(of: model.activeWord) { previous, word in
                            if previous == nil, word != nil {
                                DispatchQueue.main.async {
                                    guard model.activeWord != nil else { return }
                                    inspector.scrollTo("word-results", anchor: .center)
                                }
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Button("Play corrected board", systemImage: "hand.draw") { model.play() }
                            .disabled(!model.canPlay)
                            .help("Swipe the corrected letters from the current live capture.")
                        Spacer()
                        if !model.isLive {
                            Text("Live captures only").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(width: 420)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            Divider()
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 900, minHeight: 600)
        .onChange(of: model.size) { model.sizeChanged() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshPermissions() } }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Word Hunt").font(.system(size: 26, weight: .bold, design: .rounded))
            Spacer()
            Button("Import image", systemImage: "photo") { model.importImage() }
                .disabled(isWorking)
            Button("Capture only", systemImage: "viewfinder") { model.capture() }
                .disabled(isWorking)
            Button("Solve & Auto Swipe", systemImage: "play.fill") { model.solveAndPlay() }
                .buttonStyle(.borderedProminent)
                .disabled(isWorking)
                .help("Capture the live board, confirm its letters, solve and swipe automatically. Start the round on the phone first.")
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(model.isLive ? "Live capture" : "Board preview", systemImage: model.isLive ? "iphone" : "photo")
                    .font(.headline)
                Spacer()
                Picker("Grid size", selection: $model.size) {
                    Text("4 × 4").tag(4)
                    Text("5 × 5").tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
                .disabled(isWorking)
            }
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .underPageBackgroundColor))
                if model.image == nil {
                    VStack(spacing: 12) {
                        Image(systemName: "square.grid.3x3")
                            .font(.system(size: 48, weight: .ultraLight))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("Your board appears here").font(.headline)
                        Text("Open Word Hunt in iPhone Mirroring,\nthen choose Solve & Auto Swipe.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button("Load sample screenshot") { model.loadSample() }
                            .padding(.top, 4)
                            .disabled(isWorking)
                    }
                    .padding(24)
                } else {
                    BoardPreview(image: model.image, geometry: model.geometry, path: model.selectedPath)
                        .padding(12)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let confidence = model.confidence {
                Label("Minimum tile quality \(Int(confidence * 100))%", systemImage: "text.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Lowest glyph-matching score across the board; not a probability of correctness.")
            }
        }
        .frame(minWidth: 330, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var boardEditor: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Board letters").font(.headline)
                    Spacer()
                    Button("Solve edits") { model.solveEdits() }
                        .disabled(isWorking || model.boardText.isEmpty)
                }
                TextEditor(text: $model.boardText)
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(height: model.size == 4 ? 106 : 128)
                    .disabled(isWorking)
                    .accessibilityLabel("Board letters, row by row. Separate each tile with a space.")
                Text("Space-separated tiles. Q is one letter; QU is a two-letter tile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    private var results: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.words.count.formatted())
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("Words found").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(model.estimatedScore.formatted())
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("Estimated points").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ScrollViewReader { scroll in
                    List(model.words, selection: $model.selectedWord) { word in
                        HStack {
                            Text(word.word).font(.system(.body, design: .monospaced).weight(.medium))
                            Spacer()
                            Text(word.score.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .tag(word.word)
                        .listRowBackground(word.word == model.activeWord ? Color.accentColor.opacity(0.3) : nil)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(height: 190)
                    .overlay {
                        if model.words.isEmpty {
                            Text("Solve a board to see its words.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: model.activeWord) { _, word in
                        guard let word else { return }
                        // Let AppKit finish applying the selection before scrolling its table.
                        DispatchQueue.main.async {
                            guard model.activeWord == word else { return }
                            scroll.scrollTo(word, anchor: .center)
                        }
                    }
                }
                HStack(spacing: 10) {
                    Menu("Dictionary") {
                        Button("Import word list…") { model.importDictionary() }
                        Button("Use bundled ENABLE") { model.restoreDictionary() }
                    }
                    .fixedSize()
                    .disabled(isWorking)
                    Text(model.dictionaryName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(model.dictionaryName)
                    Spacer(minLength: 0)
                    Button("Export", systemImage: "square.and.arrow.up") { model.exportWords() }
                        .disabled(model.words.isEmpty)
                }
            }
            .padding(8)
        }
    }

    private var humanModeControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Human mode", isOn: $model.humanMode)
                    .toggleStyle(.switch)
                    .help("Play fewer words and pause to think between swipes.")
                DisclosureGroup("Human mode settings") {
                    VStack(alignment: .leading, spacing: 10) {
                        Stepper(value: $model.humanMaxWords, in: 1...100) {
                            Text("Max words: \(model.humanMaxWords)")
                        }
                        Stepper(value: $model.humanMaxWordLength, in: 3...12) {
                            Text("Max word length: \(model.humanMaxWordLength) letters")
                        }
                        HStack {
                            Text("Max score").frame(width: 100, alignment: .leading)
                            Slider(value: $model.humanMaxScore, in: 100...50_000, step: 100)
                                .accessibilityLabel("Maximum estimated score")
                            Text(Int(model.humanMaxScore).formatted()).monospacedDigit()
                                .frame(width: 55, alignment: .trailing)
                        }
                        HStack {
                            Text("Thinking pause").frame(width: 100, alignment: .leading)
                            Slider(value: $model.humanThinkingPause, in: 0.5...4, step: 0.1)
                                .accessibilityLabel("Thinking pause")
                            Text("\(model.humanThinkingPause, format: .number.precision(.fractionLength(1))) s")
                                .monospacedDigit()
                                .frame(width: 55, alignment: .trailing)
                        }
                        Text("Longer words get a longer pause. The score limit uses estimated points, not the game's live score.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                }
            }
            .padding(8)
        }
        .disabled(isWorking)
    }

    private var timing: some View {
        GroupBox {
            DisclosureGroup("Timing and target") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Picker("Window", selection: $model.selectedWindowID) {
                            Text("Select window").tag(CGWindowID(0))
                            ForEach(model.windowChoices, id: \.id) { window in
                                Text(window.title.isEmpty ? "iPhone Mirroring" : window.title).tag(window.id)
                            }
                        }
                        Button(action: model.refreshWindows) { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh windows")
                            .help("Refresh available windows")
                    }
                    HStack {
                        Text("Per tile").frame(width: 100, alignment: .leading)
                        Slider(value: $model.stepDuration, in: 0.02...0.10, step: 0.005)
                            .accessibilityLabel("Per tile duration")
                        Text("\(Int(model.stepDuration * 1000)) ms").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Word gap").frame(width: 100, alignment: .leading)
                        Slider(value: $model.wordPause, in: 0.03...0.25, step: 0.005)
                            .accessibilityLabel("Pause between words")
                        Text("\(Int(model.wordPause * 1000)) ms").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Round budget").frame(width: 100, alignment: .leading)
                        Slider(value: $model.timeLimit, in: 10...75, step: 1)
                            .accessibilityLabel("Round time budget")
                        Text("\(Int(model.timeLimit)) s").monospacedDigit().frame(width: 48, alignment: .trailing)
                    }
                    Text("Budget starts at capture. Increase timing if the phone misses letters.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 12)
            }
            .padding(8)
        }
        .disabled(isWorking)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let issue = model.issue {
                ScrollView {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 48)
                .scrollBounceBehavior(.basedOnSize)
            }
            HStack(spacing: 12) {
                if isWorking { ProgressView().controlSize(.small) }
                Text(model.status).font(.callout).lineLimit(2).help(model.status)
                Spacer()
                if model.running { Text("\(model.attempted)/\(model.planned)").monospacedDigit() }
                Button("Stop", systemImage: "stop.fill") { model.stop() }
                    .tint(.red)
                    .disabled(!isWorking)
                    .help("Stop recognition or swiping. Escape also stops automation.")
            }
            if !model.screenRecording || !model.accessibility {
                permissionWarning
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var permissionWarning: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("Live play won't work until you grant both permissions.")
                        .font(.callout.weight(.semibold))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text("Turn on Word Hunt Solver in both settings panes. If it isn't listed, click + and add the app. Quit and reopen it if macOS asks. You can still solve imported screenshots without these permissions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                permissionRow("Screen Recording", purpose: "Reads the board in iPhone Mirroring.",
                              granted: model.screenRecording, pane: "Privacy_ScreenCapture")
                permissionRow("Accessibility", purpose: "Lets the app swipe words.",
                              granted: model.accessibility, pane: "Privacy_Accessibility")
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func permissionRow(_ name: String, purpose: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: 12) {
            Label("\(name) \(granted ? "granted" : "required")",
                  systemImage: granted ? "checkmark.circle.fill" : "lock")
            Text(purpose)
                .foregroundStyle(.secondary)
            Spacer()
            if !granted {
                Button("Open \(name) Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        }
    }
}
