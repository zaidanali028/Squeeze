# Architecture

Squeeze is a thin, native macOS shell around a deterministic FFmpeg pipeline. The UI never talks to FFmpeg directly: it owns a queue, and the engine turns that queue into plans and outputs.

## Layers

```text
SqueezeApp (SwiftUI lifecycle + AppDelegate)
        │
        ├── ContentView ── JobModel ── Engine ── ffprobe / ffmpeg / ditto
        │                                  └── logs
        └── CLI ────────── Engine
```

| Layer | Responsibility |
| --- | --- |
| `SqueezeApp` | Window, Open With, Finder service, notifications permission, app lifecycle. |
| `ContentView` | Drop target, preset selector, queue rows, footer controls. |
| `JobModel` | Observable queue state, per-job progress, cancellation token, result application. |
| `Engine` | Probing, planning, encoding, remuxing, verification, size guard, ZIP creation, logging. |
| `CLI` | Argument parsing and human/JSON reporting over the same engine. |
| `Models` | Presets, `MediaInfo`, `Plan`, `EncodeSpec`, outcomes, errors. |

The app and CLI compile the same engine sources. There is no duplicated encoding logic.

## Processing pipeline

```text
input URLs
   │
   ├─ expand folders / filter extensions
   │
   ├─ ffprobe ──► MediaInfo
   │
   ├─ plan(preset, MediaInfo) ──► skip | remux | encode
   │
   ├─ execute
   │     ├─ skip   → source stays untouched
   │     ├─ remux  → stream copy into MP4, no quality loss
   │     └─ encode → FFmpeg → verify codec
   │
   ├─ size guard (only for encode)
   │     ├─ smaller → keep
   │     ├─ not smaller → retry stronger
   │     └─ still not smaller → delete output, mark Optimal
   │
   └─ batch
         ├─ one input  → output directly in chosen folder
         └─ many inputs → scratch folder → one ZIP
```

## Probing

`Engine.probe` runs `ffprobe` with JSON output and reads:

- container, duration, size
- first video stream: codec, dimensions, frame rate, pixel format, bitrate
- all audio streams: codec and maximum channel count
- color primaries, transfer function, matrix, range

`MediaInfo` derives:

- `isMP4`: container name contains `mp4` or `mov`
- `isTenBit`: pixel format contains `10`, `p010`, or `p210`
- `isHDR`: transfer is `smpte2084` or `arib-std-b67`
- `pixelRate`: width × height × fps
- `bpp`: video bitrate ÷ pixel rate

The bits-per-pixel value is the main “is this already efficient?” heuristic.

## Planning

`plan(for:preset:)` is pure: given metadata and a preset, it returns an action and an optional `EncodeSpec`.

### Auto

| Condition | Action |
| --- | --- |
| AV1 | Encode to HEVC for native playback |
| HEVC/AV1 in MP4 and bpp ≤ 0.10 | Skip as already efficient |
| HEVC outside MP4 with MP4-compatible audio | Remux to MP4 |
| H.264 MP4 and bpp ≤ 0.08 | Skip as already efficient |
| Everything else | Encode |

### Encode settings

| Preset | Large-frame path | Normal path |
| --- | --- | --- |
| Auto | HEVC VideoToolbox `q 58` | x265 `CRF 23`, preset `medium` |
| Quality | x265 `CRF 20` at 4K+, `19` at 1080p+, `18` below | x265 `slow`, `medium`, or `fast` depending on load |
| Balanced | HEVC VideoToolbox `q 55` | x265 `CRF 23`, preset `medium` |
| Small | HEVC VideoToolbox `q 50` | x265 `CRF 27`, preset `medium` |
| H.264 | > 2160p: x264 `veryfast`, `CRF 22` | software x264 `CRF 20`, `medium`; hardware `q 65` for heavy frames |

“Large” means `pixelRate > 300M`; “ultra” means `pixelRate > 900M` or height > 2160. Hardware HEVC is used for ultra sources to keep 8K practical.

## Encoding

The common FFmpeg command maps the first video stream, all audio streams, chapters, and global metadata:

```text
-map 0:v:0 -map 0:a? -map_chapters 0 -map_metadata 0
```

Video arguments depend on the encoder:

- `libx265`: `-crf`, `-preset`, 8-bit or 10-bit pixel format, `hvc1` tag, HDR parameters when applicable.
- `hevc_videotoolbox`: `-q:v`, `main` or `main10`, `nv12` or `p010le`, `hvc1`, `-allow_sw 1`.
- `libx264`: `-crf`, `-preset`, `yuv420p`, High profile.
- `h264_videotoolbox`: `-q:v`, `yuv420p`, High profile, `-allow_sw 1`.

Audio is copied when every audio codec is one of `aac`, `alac`, `ac3`, `eac3`, `mp3`. Otherwise it is encoded to AAC at 192 kbps for stereo or 384 kbps for more than two channels.

Color tags are copied when present and known. HDR encodes also pass `hdr-opt`, `repeat-headers`, and color parameters into x265.

After encoding, `verify` probes the output and rejects a missing, empty, or unexpected-codec file.

## Size guard

A successful encode is not automatically a win. The engine compares output and source sizes:

```text
output >= source
  ├─ hardware: retry with q − 8
  ├─ software: retry with CRF + 4
  └─ still >= source: delete output and return Optimal
```

This is why Squeeze can promise that a batch will not leave you with larger files.

## Batch lifecycle

- **One input:** `workDir` is the chosen output folder; the file is written there directly.
- **Multiple inputs:** `workDir` is `~/Library/Caches/Squeeze/run-<UUID>`; after all files are processed the folder is compressed with `ditto -c -k --sequesterRsrc` into `<output>/Squeeze-<timestamp>.zip`, then removed.

If `--keep-folder` is used, the scratch folder is moved next to the ZIP instead of deleted.

Output names are `<clean-stem>-hevc.mp4` or `<clean-stem>-h264.mp4`. A collision gets `-2`, `-3`, and so on. If a batch has no successful outputs, the scratch folder is cleaned up and no empty ZIP is created.

## Progress and cancellation

`Engine.process` reports:

- `progress(fileIndex, fraction)` from FFmpeg's `-progress pipe:1` output
- `status(message)` before probing, before each file, while zipping

`JobModel` maps `fileIndex` to the matching queue row, updates that row's progress, and computes overall progress as `(fileIndex + fraction) / inputCount`. Rows only transition to `running` when their first progress event arrives, so the active file is unambiguous.

Cancellation sets a flag and terminates the current `Process`. The engine checks the flag between files, deletes the scratch folder for batches, and throws `SqueezeError.cancelled`. Already-completed single outputs are left in place.

## Failure handling

Each input is processed in its own `do/catch`. A failure becomes a `JobOutcome` with `output == nil` and a readable note; the loop continues. The batch still returns successes, and the CLI exits non-zero if any outcome failed.

## UI model

`JobModel` is `@MainActor` and `ObservableObject`. Published state includes the job array, preset, output folder, running flag, overall progress, status text, archive URL, and error message.

Each `Job` carries its own state, progress, message, output URL, sizes, and codec. `ContentView` renders one `JobRow` per job:

- queued: size + ready
- running: inline `ProgressView` + percent badge
- done: source → output + percent saved + codec
- skipped: size + explanation + Optimal badge
- failed: error + Failed badge

The footer adds overall progress and the current filename. This separation is what makes per-video status possible.

## macOS integration

- `CFBundleDocumentTypes` registers common movie containers for Open With.
- `NSApplicationDelegate.application(_:open:)` and `application(_:openFiles:)` both feed URLs into the shared model. The `open:` URL path is the one used by modern `open -a`.
- `NSServices` registers the **Squeeze Video** Finder service. The app must have been launched once for the service to appear.
- A single `Window` scene prevents one window per opened document.
- Notifications are requested at launch and posted when a batch finishes.
- `NSWorkspace.activateFileViewerSelecting` implements Reveal in Finder.

## Packaging

`build.sh` uses `swiftc` directly, not an Xcode project:

1. compile app sources into `Squeeze.app/Contents/MacOS/Squeeze`
2. compile CLI sources into `Squeeze.app/Contents/MacOS/squeeze-cli`
3. copy `Info.plist` and `AppIcon.icns`
4. ad-hoc sign with `codesign --force --deep --sign -`

`install.sh` copies the bundle to `~/Applications`, clears quarantine attributes, links `~/.local/bin/squeeze`, and re-registers the bundle with Launch Services.

## Logging

- `~/Library/Logs/Squeeze/squeeze.log`: high-level events, FFmpeg commands, failures, size-guard retries.
- `~/Library/Logs/Squeeze/encode-<name>-<timestamp>.log`: FFmpeg stderr for one encode.

Logs are local and are not uploaded.

## Design decisions

1. **FFmpeg instead of AVFoundation.** It gives consistent codec, metadata, and container behavior across MP4, MKV, MOV, AVI, WebM, and 8K sources.
2. **HEVC by default.** It is the best native macOS trade-off for size and hardware support. H.264 remains one click away.
3. **No in-place edits.** Outputs always get a new name; the source is never touched.
4. **Conservative skipping.** Re-encoding an already-efficient file wastes time and can reduce quality.
5. **Hard size guard.** A compressor should not make files bigger, even if the requested preset would.
6. **Per-file outcomes, not just a batch result.** The queue is useful only if every row tells the truth.

## Extension points

- Add a preset in `Models.swift`, then map it in `Engine.encodeSpec`.
- Add a codec by extending `videoArgs`, `audioArgs`, and the verification expectations.
- Add a reporting format by extending `CLI.printJSON`.
- Replace the heuristic in `plan` with a VMAF sample pass if quality-targeted encoding is needed.
