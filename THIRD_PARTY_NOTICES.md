# Third-party notices and reference data

## ENABLE dictionary (public domain)

`Sources/WordHuntCore/Resources/enable1.txt` is the full ENABLE word list
(Enhanced North American Benchmark LE xicon), credited to its originators,
M. Cooper and Alan Beale. It is distributed as public-domain word data, not
under the license of this application's source code. Redistribution of the
word-list portion must not be restricted by this application's license.

The file is bundled verbatim, including two-letter entries, from Dolph
Mathews's dictionary mirror:

- Repository: <https://github.com/dolph/dictionary>
- Pinned source: <https://raw.githubusercontent.com/dolph/dictionary/694bf9529e986f9175dcbf5fe5875d111941b708/enable1.txt>
- File revision: `694bf9529e986f9175dcbf5fe5875d111941b708` (2013-01-27)
- Retrieved: 2026-11-03
- Entries: 172,823 newline-separated words; 1,743,363 bytes
- SHA-256: `3f16130220645692ed49c7134e24a18504c2ca55b3c012f7290e3e77c63b1a89`

The solver normalizes words to uppercase in memory and returns only words of
at least three letters. The resource itself has not been filtered or altered.
It is read locally using SwiftPM resources; no dictionary downloads or other
network access occur at runtime. ENABLE is not claimed to be GamePigeon's
exact acceptance dictionary. A custom list may be supplied to `WordSolver`.

The original ENABLE public-domain dedication is reproduced in Debian's SCOWL
copyright file (SCOWL includes ENABLE among its source lists):
<https://tracker.debian.org/media/packages/s/scowl/copyright-2020.12.07-2>.
Only the ENABLE list is bundled here, not SCOWL's collective database or its
other source dictionaries. The ENABLE-specific dedication reads:

> The ENABLE master word list, WORD.LST, is herewith formally released
> into the Public Domain. Anyone is free to use it or distribute it in
> any manner they see fit. No fee or registration is required for its
> use nor are "contributions" solicited (if you feel you absolutely
> must contribute something for your own peace of mind, the authors of
> the ENABLE list ask that you make a donation on their behalf to your
> favorite charity). This word list is our gift to the Scrabble
> community, as an alternate to "official" word lists. Game designers
> may feel free to incorporate the WORD.LST into their games. Please
> mention the source and credit us as originators of the list. Note
> that if you, as a game designer, use the WORD.LST in your product,
> you may still copyright and protect your product, but you may *not*
> legally copyright or in any way restrict redistribution of the
> WORD.LST portion of your product. This *may* under law restrict your
> rights to restrict your users' rights, but that is only fair.

## GamePigeon glyph reference data (MIT)

The native recognition bank in
`Sources/WordHuntMac/Resources/GamePigeonGlyphs.bin` is derived from labeled
letter-capture images in:

- Project: [Ammaar-Alam/wordhunt-solver](https://github.com/Ammaar-Alam/wordhunt-solver)
- Pinned commit: `3af4c45003ca10006814932dbe434ce54f803fca`
- Source directory: `letter_dataset`
- Copyright: © 2024 WordHunt Solver Contributors
- License: MIT; complete text in
  `Sources/WordHuntMac/Resources/ReferenceGlyphs-LICENSE.txt`, included in the
  packaged recognition-resource bundle.

`GlyphProvenance.json` records normalization, prototype selection, source
filenames/hashes, bank checksum, and exclusions for visually confirmed
mislabeled source images. The bank contains normalized glyph shapes, not the
upstream PyTorch model; the app has no Python or PyTorch runtime dependency.
Native matching and capture/input repairs take architectural inspiration from
the upstream project. No upstream Python source or model weights are bundled.

Original held-out source glyphs are included under the same license in
`Tests/WordHuntMacTests/Fixtures`, enumerated in `ReferenceGlyphs.json`.
The upstream corpus includes duplicate/near-duplicate shapes across filenames;
its held-out filename results are not an independent general OCR-accuracy
estimate.

Local GamePigeon regression images were captured during user-authorized
testing and cropped to exclude avatar/status information. The 5×5 fixture is
assembled from those 4×4 capture tiles, not a separate photographed 5×5 board.
GamePigeon names and visual assets belong to their respective owners; no
affiliation or universal recognition accuracy is claimed.

## Word Hunt scoring references

The application's estimated scores use the published length-only schedule:

| Letters | Points |
| --- | --- |
| Fewer than 3 | 0 (not returned) |
| 3 | 100 |
| 4 | 400 |
| 5 | 800 |
| 6 | 1,400 |
| 7 | 1,800 |
| 8 or more | 2,200 |

References, consulted 2026-11-03:

- The Word Finder's [Word Hunt solver](https://www.thewordfinder.com/word-hunt-solver/),
  "Bonus points" section, explicitly gives the values for lengths 3 through 8.
- PuzzlePage's [Word Hunt solver](https://www.puzzlepage.app/word-hunt-solver),
  "Word Hunt Scoring, Explained" section, explicitly states that words of eight
  letters or more top out at 2,200 points.

These are independent secondary references, not a published GamePigeon rules
specification or validation on an iPhone. Scores and dictionary acceptance are
therefore estimates; actual GamePigeon behavior may differ. No unsupported
extra 400 points per letter beyond length eight are assumed. QU is an explicit
two-letter tile; a literal Q never supplies an implicit U. Scoring counts
letters in a spelling, not the number of tiles traversed.

No source code from the referenced solver websites is incorporated. Their
links document scoring research only. This project is not affiliated with
GamePigeon, its developers, or Apple.
