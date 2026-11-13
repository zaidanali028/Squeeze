# Testing

Squeeze was validated on synthetic and real 8K media before the first release. Test files are not committed to the repository; the results below document what the engine actually produced.

## Environment

| Item | Value |
| --- | --- |
| macOS | 27.2 |
| Machine | Apple M1 Pro, 16 GB |
| Swift | 6.3.3 |
| FFmpeg | 9.0.1 (Homebrew) |
| Encoders | `libx264`, `libx265`, `libsvtav1`, `hevc_videotoolbox`, `h264_videotoolbox` |
| Build | `./build.sh` (ad-hoc signed, no Xcode project) |

## CLI matrix

All paths below are outputs from the shared `Engine.process` pipeline.

| Source | Preset | Result | Notes |
| --- | --- | --- | --- |
| 1080p30 H.264, 10.3 MB | Auto | 9.4 MB HEVC | Software x265; audio copied |
| 4K30 H.264, 20.6 MB | Auto | 17.2 MB HEVC | Software x265 |
| 8K120 HEVC MP4, 19.2 MB | Auto | Skipped | Already efficient HEVC |
| 8K120 HEVC MKV, 19.2 MB | Auto | 19.2 MB MP4 | Remux, no re-encode |
| 8K120 H.264, 19.2 MB | Balanced | 11.9 MB HEVC | 38% smaller with hardware HEVC |
| 8K120 H.264, 19.2 MB | H.264 | 21.2 MB → retry → 10.5 MB | First pass larger; size guard retried stronger |
| 4K30 H.264, 20.6 MB | H.264 | 17.1 MB H.264 | Software x264 |
| 8K 10-bit HDR, 114.5 MB | Balanced | 79.3 MB HEVC Main 10 | 10-bit pipeline preserved |
| 1080p HDR10, 2.2 MB | Quality | Skipped | Re-encode would have been larger |
| Two mixed videos | Auto | 25 MB ZIP | ZIP contains both encoded files |
| HEVC remux | Auto | Same bytes | `-c copy`; no quality loss |

## Per-video status test

A two-file batch was run in the installed app and captured at three points:

1. `clip-1080p.mp4` at 47%, `clip-4k.mp4` **Queued**
2. `clip-1080p.mp4` at 95%, `clip-4k.mp4` **Queued**
3. `clip-1080p.mp4` at 100%, `clip-4k.mp4` at 73%
4. Finished: `10.3 MB → 9.4 MB · 9% smaller · HEVC` and `20.6 MB → 17.2 MB · 16% smaller · HEVC`
5. Footer: `2 videos · 4.3 MB saved · Squeeze-...zip`

This confirms that progress is per row, not just an overall bar. The screenshots are in `docs/images/`.

## Open With test

- `open -a /Applications/Squeeze.app file1.mp4 file2.mp4` adds both files to the existing queue.
- The app uses one `Window` scene, so opening two files does not create two windows.
- The `application(_:open:)` URL delegate path is the one exercised by modern `open -a`; `openFiles` remains as a fallback.

## Batch and ZIP test

- Multiple inputs are encoded into `~/Library/Caches/Squeeze/run-<UUID>`.
- The folder is compressed with `ditto -c -k`.
- The ZIP is written to the output folder and the scratch folder is removed.
- Verified with `unzip -l`: both encoded files are at the ZIP root.

## Size-guard test

- An 8K H.264 source produced a larger first pass.
- Squeeze deleted the output, retried with a stronger setting, and produced a smaller file.
- When a stronger retry still could not beat the source, the row became **Optimal** and no output was kept.

## Build and smoke test

```sh
./build.sh
./install.sh
squeeze --help
squeeze --version
squeeze /tmp/squeeze-tests/clip-1080p.mp4 --json
```

Expected:

- `build/Squeeze.app` is produced and ad-hoc signed.
- `~/Applications/Squeeze.app` exists.
- `~/.local/bin/squeeze` points into the app bundle.
- `--json` returns `version`, `preset`, `items`, `total_source`, and `total_output`.
- The CLI exits non-zero when any item fails.

## UI snapshot test

`Tools/render_ui.swift` builds an `NSHostingView`, renders it offscreen with `cacheDisplay`, and writes PNGs to `/tmp`. It is intentionally AppKit-based rather than `ImageRenderer`, because `ImageRenderer` does not render `ScrollView` content correctly on this macOS version.

## Not yet covered

- Finder service invocation from a clean login session.
- Notarization and distribution outside the local machine.
- Subtitle/data-track preservation; these are intentionally dropped today.
- Automatic VMAF-based quality targeting.
- 10-bit H.264 output; the H.264 path is 8-bit by design.
