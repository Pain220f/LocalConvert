# LocalConvert

A native macOS file converter that runs **100% on-device**: it never sends anything over the network and it never lowers quality without telling you. You see exact **before/after file sizes** (in bytes and as a percentage) and can compare the original and converted file side by side.

- **Images** (ImageIO + CoreImage): PNG · TIFF · HEIC · JPEG · BMP · GIF. Can also read RAW and WebP.
- **Documents** (Quartz + PDFKit): images → PDF, PDF → single-page PDFs, PDF → its embedded images.
- **Audio & video** (AVFoundation + VideoToolbox): MOV ⇄ MP4 remux, M4A audio passthrough, ALAC, WAV, plus an optional HEVC hardware re-encode that is clearly marked as lossy.

Requires macOS 15.6 or later and builds with Xcode 26 or later in Swift 6 language mode (strict concurrency). It runs natively on Apple Silicon and Intel, and has **no third-party dependencies**.

## Two modes

Pick a file to see its controls in the inspector on the right.

- **Convert Format** changes the format or container while preserving quality. Defaults are always bit-exact or lossless.
- **Compress Size** makes the file smaller. You can keep the current format when it's compressible, or pick a size-efficient one: HEIC/JPEG for images, HEVC for video, AAC (M4A) for audio, or a compressed PDF. Turn on **Keep under** to set a strict maximum size, by typing it or with the one-click presets (50%, 25%, 100 KB, 250 KB, …). Presets larger than the original are hidden.

### How the size limit is guaranteed

| Output | Strategy | If it can't fit |
|---|---|---|
| JPEG / HEIC | In-memory binary search over quality, keeping the **highest** quality whose encoding fits. The exact winning bytes are written. | With *Allow downscaling*: binary search over scale, then quality. Without it: fails, reporting the smallest achievable size. |
| PNG | Encoded losslessly. It is never made lossy just to fit. | Downscales only if allowed. Otherwise it fails and suggests HEIC or JPEG. |
| HEVC video | Bitrate derived from `limit × 8 × 0.92 / duration − audio`. The result is measured, and one tightened second pass runs if needed. | Fails with an estimate of the smallest achievable size. |
| AAC audio | Bitrate derived from `limit × 8 × 0.94 / duration`, measured, and retried at a lower bitrate. | Fails at the encoder's minimum bitrate. |
| ALAC / WAV | Lossless. The size is checked afterwards. | Fails and suggests AAC. |
| PDF | PDFKit re-saves with JPEG image compression and keeps text and vectors. | With *Allow downscaling*: pages are rasterized to size-searched JPEG (text stops being selectable). Otherwise it fails. |

On top of these, the queue manager re-checks every result: an output larger than the limit is deleted and reported as a failure, so a limit is never exceeded silently.

---

## Privacy guarantees

| Guarantee | How it is enforced |
|---|---|
| No network access | `com.apple.security.app-sandbox = true`. `network.client` and `network.server` are set to `false`. The kernel refuses every socket `connect`/`bind`, including to loopback. |
| No telemetry, analytics or auto-update | No packages and no frameworks are bundled. `Network`/`CFNetwork` are not linked, and no `URLSession` or socket symbols are imported (see `Scripts/verify-privacy.sh`). |
| Access to your files is limited | Only `com.apple.security.files.user-selected.read-write`. The app can read and write only files you drop onto it or pick in an open or save panel. |
| Metadata stripping reaches embedded streams | With *Strip Metadata* on, EXIF, GPS and XMP are also removed from JPEGs embedded in or extracted from PDFs, without re-compressing them. Media container tags and location are dropped as well. |
| No leftover copies | Work files live in the sandbox container's `tmp/LocalConvert/<session>/<job>/`. They are deleted when you remove a job, at quit, and at the next launch. |
| Self-contained | Every engine is a system framework. Nothing is downloaded at runtime. |

### Verifying it yourself

```bash
# 1. Build Release (universal) and audit the signed binary: entitlements, linked frameworks, imported symbols, bundled code
Scripts/verify-privacy.sh

# 2. Run the tests inside the signed, sandboxed app. This includes a real connect() attempt that must fail with EPERM
xcodebuild -project LocalConvert.xcodeproj -scheme LocalConvert test

# 3. Inspect the entitlements by hand
codesign -d --entitlements - /path/to/LocalConvert.app
```

You can also watch the running app with a network monitor (Little Snitch, LuLu, `nettop -p LocalConvert`). It never opens a connection.

---

## How "zero quality loss" is achieved and reported

Every target has a **fidelity** class, shown as a badge before you convert:

| Badge | Meaning | Examples |
|---|---|---|
| **Bit-exact** | The original encoded data is copied byte for byte. Only the container or metadata changes. | JPEG→JPEG / HEIC→HEIC metadata strip (`CGImageDestinationCopyImageSource`), MOV⇄MP4 remux, M4A passthrough, JPEG→PDF (Quartz embeds the original DCT stream), PDF→images for JPEG/JPEG 2000 streams |
| **Lossless** | Re-encoded with a lossless codec. The decoded content is identical. | PNG (all row filters), TIFF (LZW), BMP, ALAC, WAV, PDF page split |
| **Max-quality lossy** | Lossy codec at quality 1.0 | PNG→JPEG, PNG→HEIC |
| **Lossy** | The target can't represent the source | non-GIF → GIF (256-color palette), HEVC re-encode |

Defaults always pick a **bit-exact or lossless** target. If metadata can't be stripped without re-encoding (for example, the HEIC encoder refuses), the conversion **fails rather than silently losing quality**.

After every image conversion, **`PixelVerifier`** decodes the source and the output and compares them sample by sample at 16 bits per channel. It compares **every frame** of animated images, and compares images **as displayed** (EXIF orientation applied), so a lost orientation flag counts as a difference. BMP and GIF can't store an orientation flag, so the rotation is applied to the pixels instead (an exact transform). The UI then shows *Pixel-identical* or the exact share of differing pixels and the maximum channel difference. Lossy results are reported, never hidden.

Sizes are measured with `URLResourceValues.fileSize`, the exact logical byte count. Folder outputs are summed recursively. Each job and the totals show the size before, the size after, the signed delta and the percentage change.

---

## Architecture

```text
LocalConvert/
├── LocalConvert.xcodeproj               # Hand-written, uses folder-synchronized groups (Xcode 16+)
├── LocalConvert/
│   ├── App/
│   │   ├── LocalConvertApp.swift        # Single-window scene, menu commands, temp purge on launch/quit
│   │   └── LocalConvert.entitlements    # Sandbox on, network.client/server = false, user-selected r/w
│   ├── Models/
│   │   ├── ConversionJob.swift          # @MainActor @Observable job: UTI, sizes, status, SizeDelta
│   │   └── SupportedFormat.swift        # Targets, Fidelity classes, UTType mappings
│   ├── Engines/
│   │   ├── ConversionEngineProtocol.swift  # Protocol, request/output types, EngineRegistry
│   │   ├── ImageConversionEngine.swift     # ImageIO: bitstream copy, lossless re-encode, metadata strip
│   │   ├── PDFConversionEngine.swift       # Quartz/PDFKit: compile, split, raw XObject extraction
│   │   ├── MediaConversionEngine.swift     # AVFoundation remux, PCM→ALAC/WAV, VideoToolbox HEVC
│   │   ├── ImageCompression.swift          # Target-size quality/scale search for JPEG, HEIC, PNG
│   │   ├── MediaCompression.swift          # Bitrate-targeted HEVC + AAC, interleaved reader/writer pump
│   │   ├── PDFCompression.swift            # PDFKit JPEG re-save, optional size-searched rasterization
│   │   └── BundledToolEngine.swift         # Future hook: signed CLI in Contents/MacOS (not registered)
│   ├── Services/
│   │   ├── ConversionQueueManager.swift # Bounded-concurrency TaskGroup, cancellation, export
│   │   ├── FileStorageService.swift     # Isolated temp dirs, exact byte counts, atomic export
│   │   ├── PixelVerifier.swift          # 16-bit-per-channel pixel comparison
│   │   ├── MetadataInspector.swift      # Flattened metadata diff + previews (Quick Look, CoreImage)
│   │   └── PanelService.swift           # NSOpenPanel / NSSavePanel
│   ├── Views/
│   │   ├── ContentView.swift            # Lean toolbar, empty state, card list + inspector, status bar
│   │   ├── JobRowView.swift             # File card: icon, name, type, size, result or inline error
│   │   ├── JobInspectorView.swift       # Mode switch, format picker, Keep-under limit, presets, result
│   │   └── ComparisonSheetView.swift    # Side-by-side / slider / difference views + metadata diff table
│   └── Resources/Assets.xcassets
├── LocalConvertTests/                   # Swift Testing, hosted in the sandboxed app (52 tests)
│   ├── ImageConversionTests.swift       # Lossless round trips, GPS stripping, PDF passthrough, byte counts
│   ├── FidelityRegressionTests.swift    # PDF metadata stripping, orientation, animated frames, safe defaults
│   ├── MediaConversionTests.swift       # WAV → ALAC → WAV sample-exact round trip
│   ├── VideoConversionTests.swift       # Synthetic H.264+AAC movies: remux, M4A, HEVC, metadata keep/strip
│   ├── CompressionTests.swift           # Strict size limits, monotonic quality, refusals, downscaling, job modes
│   ├── QueueAndStorageTests.swift       # Bounded concurrency, cancellation, folder import, combine, atomic export
│   └── SandboxEntitlementTests.swift    # SecTask entitlement checks + kernel socket denial
└── Scripts/verify-privacy.sh            # Static audit of the signed Release binary
```

### Concurrency model

- `ConversionQueueManager` and `ConversionJob` are `@MainActor` and hold only UI state.
- Engines are `Sendable` value types. Their `nonisolated async` `convert` methods run on the cooperative pool inside a `TaskGroup`, with at most `min(4, cores/2)` jobs at a time.
- Progress reaches the main actor through a `@Sendable` callback. Cancellation reaches the engines through structured `Task` cancellation: ImageIO and PDF loops call `checkCancellation()`, the reader/writer pipeline is torn down, and `AVAssetExportSession` cancels itself.

### Adding an engine (e.g. bundled `oxipng` / `ffmpeg`)

1. Add a statically linked, code-signed binary to the app with a **Copy Files → Executables** build phase. It will inherit the sandbox, so it can't reach the network either.
2. Register it, with no UI or queue changes:

```swift
static let standard = EngineRegistry(engines: [
    BundledToolEngine(
        identifier: "oxipng", displayName: "oxipng", executableName: "oxipng",
        sourceTypes: [.png], targets: [.png], fidelity: .lossless,
        arguments: { input, output, _, _ in ["-o", "max", "--out", output.path, input.path] }),
    ImageConversionEngine(), PDFConversionEngine(), MediaConversionEngine(),
])
```

Any type that conforms to `ConversionEngineProtocol` works the same way.

---

## Building

```bash
open LocalConvert.xcodeproj        # ⌘R to run, ⌘U to test
```

Signing uses **Sign to Run Locally** (ad-hoc, `CODE_SIGN_IDENTITY = "-"`). To distribute the app, set your team under *Signing & Capabilities*, then archive and notarize. The entitlements stay the same.

## Known limitations

- HEIC/JPEG "lossless" re-encode isn't possible with system codecs. Those targets are labeled *Max-quality lossy*.
- PDF image extraction stores raw images without their soft masks and decode arrays. Indexed and 1-bit images are skipped and counted in the job notes.
- Pixel verification is skipped for images over 60 MP and capped at 500 frames, to keep memory and time bounded.
- WAV cannot carry metadata tags, so the job notes say so when they are dropped (ALAC keeps them). ALAC output always contains the encoder's own `iTunSMPB` gapless-timing tag.
- Video is never transcoded losslessly: remuxing is bit-exact and HEVC is lossy. Lossless video codecs can be added through the engine hook.

## License

MIT. See [LICENSE](LICENSE).
