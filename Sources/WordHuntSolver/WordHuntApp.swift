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
                    Button("Open practice board") { model.showPractice() }.keyboardShortcut("p")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Word Hunt").font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("See the board. Find every path.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Practice", systemImage: "gamecontroller") { model.showPractice() }
                Button("Import image", systemImage: "photo") { model.importImage() }.disabled(model.busy || model.running)
                Button("Capture only", systemImage: "viewfinder") { model.capture() }
                    .disabled(model.busy || model.running)
                Button("Solve & Auto Swipe", systemImage: "play.fill") { model.solveAndPlay() }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.running)
                    .help("Capture the live board, confirm its letters, solve and swipe automatically. Start the round on the phone first.")
            }.padding(24)
            Divider()
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(model.isLive ? "Live capture" : "Screenshot preview", systemImage: model.isLive ? "iphone" : "photo")
                            .font(.headline)
                        Spacer()
                        if let confidence = model.confidence { Text("OCR min \(Int(confidence * 100))%").font(.caption).foregroundStyle(.secondary) }
                    }
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .underPageBackgroundColor))
                        if model.image == nil {
                            VStack(spacing: 14) {
                                Image(systemName: "square.grid.4x4").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(.secondary)
                                Text("Your board appears here").font(.headline)
                                Text("No iPhone yet? Recognition and solving work offline.").foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Load sample screenshot") { model.loadSample() }
                            }.padding(30)
                        } else {
                            BoardPreview(image: model.image, geometry: model.geometry, path: model.selectedPath, calibrating: model.calibrating && !model.busy && !model.running, onBounds: model.calibrate)
                                .padding(10)
                        }
                    }.frame(minWidth: 330, maxWidth: .infinity, minHeight: 390, maxHeight: .infinity)
                    HStack {
                        Button(model.calibrating ? "Cancel calibration" : "Calibrate board", systemImage: "crop") { model.calibrating.toggle() }
                            .disabled(model.image == nil || model.busy || model.running)
                        Spacer()
                        Picker("Grid", selection: $model.size) {
                            Text("4 × 4").tag(4)
                            Text("5 × 5").tag(5)
                        }.frame(width: 140).disabled(model.busy || model.running)
                    }
                    Text(model.calibrating ? "Drag a rectangle around the whole grid, including half a gutter at its edges." : "Green dots must sit at tile centers. Select a word to preview its swipe.")
                        .font(.caption).foregroundStyle(.secondary).frame(height: 32, alignment: .topLeading)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)

                VStack(alignment: .leading, spacing: 13) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Board letters").font(.headline)
                                Spacer()
                                Button("Solve edits") { model.solveEdits() }.disabled(model.busy || model.running || model.boardText.isEmpty)
                            }
                            TextEditor(text: $model.boardText)
                                .font(.system(size: 20, weight: .medium, design: .monospaced))
                                .scrollContentBackground(.hidden)
                                .frame(height: model.size == 4 ? 106 : 128)
                                .disabled(model.busy || model.running)
                                .accessibilityLabel("Board letters, row by row. Separate each tile with a space.")
                            Text("One tile per space. Use QU only for a two-letter tile; Q means Q.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(6)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(model.words.count)").font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("words").foregroundStyle(.secondary)
                        Spacer()
                        Text(model.estimatedScore.formatted()).font(.system(size: 28, weight: .semibold, design: .rounded))
                        Text("estimated points").foregroundStyle(.secondary)
                    }
                    List(model.words, selection: $model.selectedWord) { word in
                        HStack {
                            Text(word.word).font(.system(.body, design: .monospaced).weight(.medium))
                            Spacer()
                            Text(word.score.formatted()).monospacedDigit().foregroundStyle(.secondary)
                        }.tag(word.word)
                    }.listStyle(.bordered(alternatesRowBackgrounds: true)).frame(minHeight: 120)
                    HStack {
                        Text(model.dictionaryName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Menu("Dictionary") {
                            Button("Import word list…") { model.importDictionary() }
                            Button("Use bundled ENABLE") { model.restoreDictionary() }
                        }.disabled(model.busy || model.running)
                        Button("Export") { model.exportWords() }.disabled(model.words.isEmpty)
                    }
                    DisclosureGroup("Timing and target") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Picker("Window", selection: $model.selectedWindowID) {
                                    Text("Select window").tag(CGWindowID(0))
                                    ForEach(model.windowChoices, id: \.id) { window in Text(window.title.isEmpty ? "iPhone Mirroring" : window.title).tag(window.id) }
                                }
                                Button(action: model.refreshWindows) { Image(systemName: "arrow.clockwise") }.help("Refresh visible windows")
                            }
                            HStack {
                                Text("Per tile")
                                Slider(value: $model.stepDuration, in: 0.02...0.10, step: 0.005)
                                Text("\(Int(model.stepDuration * 1000)) ms").monospacedDigit().frame(width: 48)
                            }
                            HStack {
                                Text("Word gap")
                                Slider(value: $model.wordPause, in: 0.03...0.25, step: 0.005)
                                Text("\(Int(model.wordPause * 1000)) ms").monospacedDigit().frame(width: 48)
                            }
                            HStack {
                                Text("Round budget")
                                Slider(value: $model.timeLimit, in: 10...75, step: 1)
                                Text("\(Int(model.timeLimit)) s").monospacedDigit().frame(width: 48)
                            }
                            Text("Budget starts at capture. Increase timing if the phone misses letters.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }.disabled(model.busy || model.running)
                    HStack {
                        Button("Play corrected board", systemImage: "hand.draw") { model.play() }
                            .disabled(!model.canPlay)
                        Text("Or use Solve & Auto Swipe above for a fresh board.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(width: 440)
            }.padding(24)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                if let issue = model.issue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                HStack(spacing: 14) {
                    if model.busy || model.running { ProgressView().controlSize(.small) }
                    Text(model.status).font(.callout).lineLimit(2)
                    Spacer()
                    if model.running { Text("\(model.attempted)/\(model.planned)").monospacedDigit() }
                    Button("Stop", systemImage: "stop.fill") { model.stop() }.tint(.red).disabled(!model.busy && !model.running)
                }
                HStack {
                    Label("Screen Recording", systemImage: model.screenRecording ? "checkmark.shield" : "lock")
                    Label("Accessibility", systemImage: model.accessibility ? "checkmark.shield" : "lock")
                    Spacer()
                    Button("Grant permissions") { model.requestPermissions() }
                    Button("Privacy settings") { model.openPrivacy() }
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .frame(minWidth: 960, minHeight: 780)
        .onChange(of: model.size) { model.sizeChanged() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refreshPermissions() } }
        .onDisappear { model.stop() }
    }
}
