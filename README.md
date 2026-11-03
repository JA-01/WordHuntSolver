# Word Hunt Solver

Native macOS solver for GamePigeon's Word Hunt in **iPhone Mirroring**. The main **Solve & Auto Swipe** button captures the window, detects the grid, reads its letters, confirms them in a second frame, finds words, and drags their paths automatically. Everything runs offline; no accounts, paid services, Python runtime, or model downloads.

## Build and open

Requires macOS 14+ and Swift 6 / Apple Command Line Tools. Live iPhone Mirroring requires macOS 15+, a supported Mac and iPhone running iOS 18+, and [Apple's pairing requirements](https://support.apple.com/en-us/120421).

```sh
make run
```

This builds and locally signs `dist/Word Hunt Solver.app`. `make app` builds without opening. Copy the **entire app** if moving it elsewhere. The app is not Apple-notarized; do not disable Gatekeeper system-wide.

Choose the final app location before granting permissions. Rebuilding an ad-hoc-signed app can invalidate its existing macOS privacy grants.

## One-button play

1. Connect or resume iPhone Mirroring. Open a Word Hunt game and start the round on the phone.
2. In the solver, click **Solve & Auto Swipe**. No separate capture, solve, or play click is needed.
3. Keep your hands off the mouse. **Escape** stops input globally; moving/clicking the mouse or scrolling also stops it.

The action handles **one round**, then disarms. If the board is not visible yet, it waits up to 90 seconds and shows the recognition problem in the status area. It does not press unknown start buttons, send new game invitations, or repeatedly launch rounds. A tutorial illustration is not a playable board.

**Timing and target** lets you select a particular Mirroring/practice window, choose 4×4 or 5×5, and adjust timing. Window selection refreshes when starting an automatic run. An exact, non-minimized focused window can be discovered on another Space, but input still requires it to become visible and focused.

The default **70-second round budget** starts when the board is first read. The app does not read the game's clock: start with a fresh round, or reduce the budget to the remaining time. Recognition and validation consume this budget. Default timing is 35 ms per tile and 65 ms between words; increase either if the mirrored phone misses letters.

### Permissions

Use **Grant permissions**, then enable the built app in System Settings → Privacy & Security:

- **Screen Recording / Screen & System Audio Recording** for window capture.
- **Accessibility** for focusing the selected window and posting mouse drags.
- If physical-input monitoring cannot start, also allow **Input Monitoring** as directed by the error.

Quit/reopen if macOS requests it. **Privacy settings** opens the Accessibility pane; Screen Recording and Input Monitoring have separate panes.

If an enabled grant is still reported as denied after rebuilding, quit the solver, remove its old entry with **−**, then add the current `dist/Word Hunt Solver.app` with **+**. An off/on toggle can leave the old code signature registered. Development executables may inherit their terminal/editor host's permissions instead; verify the packaged app separately.

### Manual inspection and correction

**Capture only** reads and solves without moving the mouse. Use it to inspect letters and the green tile-center markers before manual playback.

- If grid localization fails, select **Calibrate board** and drag around the whole grid in the preview. Include the normal half-gutters at its outer edges. Calibration is session-local and tied to that target and capture dimensions.
- Correct letters in the editor, then click **Solve edits** and **Play corrected board**.
- Separate tiles with spaces and rows with newlines. `Q` means literal Q; `QU` is only for a tile that actually contains both letters. Unknown letters remain `?` and cannot be played.
- Imported/generated screenshots can be recognized and solved but **never** enable system input: they have no live target.

Keyboard shortcuts: **⌘R** runs Solve & Auto Swipe; **⇧⌘R** captures only; **⌘O** imports a screenshot; **⌘P** opens practice.

## Recognition

GamePigeon letters use a bundled native glyph recognizer derived from real labeled captures in [Ammaar-Alam/wordhunt-solver](https://github.com/Ammaar-Alam/wordhunt-solver). It segments the dark glyph, normalizes its shape, and compares it with offline prototypes using Accelerate. A maximum shape-distance and a minimum distinct-letter margin reject unfamiliar or ambiguous matches. No dictionary guess substitutes for an unreadable letter.

Vision is a fallback for unfamiliar fonts and explicit multi-letter tiles, not the primary isolated-letter recognizer. The displayed minimum tile quality is a matching score, **not a calibrated probability of correctness**. Automatic playback requires a complete board, minimum quality of 80%, and identical letters in two frames.

Reference data contains mislabeled samples; visually confirmed label errors are excluded and documented in the bundled provenance. See [third-party notices](THIRD_PARTY_NOTICES.md) for the pinned source, license, and limits. New themes/fonts, overlays, clipped tiles, or genuinely ambiguous glyphs can still require calibration/correction.

## Input safety

The solver re-captures the live board before playback and compares its dark letter silhouettes with the original. A changed board, capture size, or window requires a new capture. Timer/score changes and color-only tile highlights do not invalidate it.

- A failed Accessibility `AXRaise` request alone is **not** a failure: actual frontmost application, focused-window geometry, and visibility determine whether activation succeeded. Mirroring can expose a focused window while its `AXWindows` list is empty.
- Capture includes the full window without shadows. ScreenCaptureKit's native scale and output pixels map to Quartz display points, including titlebar offsets and Retina scaling.
- Generated events carry an ownership tag, explicit button pressure, and a complete down → held tile-center drags → up sequence. A listen-only event tap distinguishes physical takeover from delayed self-generated events.
- Cancellation, Escape, pointer corners, physical input, and application focus are checked during waits. Window visibility/focus/geometry is checked at gesture boundaries and at least every 75 ms during a gesture.
- Mouse-up is always posted after an interrupted mouse-down. **Stop** cancels recognition/watching and latches input cancellation.

Completed gestures are **attempts**, not a claim that GamePigeon accepted every dictionary word.

## Dictionary and scheduling

The full **172,823-entry ENABLE** list is bundled. **Dictionary → Import word list** accepts a local UTF-8 list with one ASCII alphabetic word per line; **Use bundled ENABLE** restores it. Entries normalize to uppercase; duplicates, invalid entries, and words shorter than three letters do not produce solutions. ENABLE is not GamePigeon's published acceptance dictionary.

The engine finds every legal neighboring-tile path, deduplicates spellings, and retains a minimum-travel path per word. A 0/1 knapsack selects the highest estimated point total fitting the gesture budget, rounded conservatively to 10 ms; selected words run in descending estimated points per second.

Estimated scoring: 3 letters = 100; 4 = 400; 5 = 800; 6 = 1,400; 7 = 1,800; 8+ = 2,200. Dictionary differences, phone latency, and input delivery can reduce actual accepted scores. See [scoring references](THIRD_PARTY_NOTICES.md).

## Practice and command line

**Practice** opens an interactive local board. **Load sample screenshot** exercises offline recognition/solving without enabling input.

```sh
swift run WordHuntSolver solve --board 'S T A R E N O T L I N E C A R E'
swift run WordHuntSolver image --image screenshot.png --json
swift run WordHuntSolver image --image screenshot.png --bounds 32,150,456,456
swift run WordHuntSolver sample --output sample-board.png
```

`solve` and `image` accept `--dictionary PATH` and `--size 4|5`. Bounds are **image pixels with a top-left origin**, not display points. JSON includes letters, scores, and zero-based row-major tile paths. The packaged executable supports the same commands.

## Verification

```sh
make test        # Native Swift Testing behavior and recognition regressions
make smoke       # Offline screenshot → OCR → solve → schedule → local handlers
make live-smoke  # Requires permissions; actual capture/system drags on local practice
```

`live-smoke` explicitly opts into system input, restricted to the local practice window. It invokes the same one-button action as the UI and checks the real practice game's accepted words/score against completed attempts. Its JSON report is saved under `.build/system-smoke`. All other CLI commands are input-free.

Recognition regressions include a privacy-cropped actual GamePigeon capture, several capture scales, all reference letters, literal Q versus QU, tutorial rejection, blank/ambiguous tiles, manual bounds, and an **assembled** 5×5 layout made from real captured glyphs—not a claim of a photographed 5×5 device board. Core/input checks cover exhaustive search, path legality, budgets, geometry transforms, event state, delayed synthetic input, physical takeover, cancellation, and stale-board protection.

Real Mirroring activation/full-window capture and six system-posted local practice gestures have been exercised. The captured real board produced all 16 correct letters and 147 solutions. These observations do not establish universal font/theme support or accepted GamePigeon scores.

## Code map

- `Sources/WordHuntCore`: board types, immutable trie, exhaustive search, offline dictionary.
- `Sources/WordHuntMac`: grid detection, native glyph recognition/resources, capture/permissions, gesture planning/execution, score-budget optimization, stale-board comparison.
- `Sources/WordHuntSolver`: SwiftUI workbench, one-button orchestration, preview/calibration, practice game, CLI diagnostics.
- `Tests`: native behavioral and real/synthetic recognition fixtures.
- `scripts/build-app.sh`, `packaging/Info.plist`: standalone app packaging.
