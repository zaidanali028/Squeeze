# Changelog

## 1.0.0 — 2026-11-13

### Added

- Native SwiftUI macOS app with drag-and-drop, Open With, Dock drops, and a Finder service.
- Single-video direct output and multi-video ZIP batches.
- Per-video queue status with individual progress bars, percentages, and final size/savings.
- Presets: Auto, Quality, Balanced, Small, and H.264.
- HEVC encoding through software x265 and hardware VideoToolbox, including 10-bit and HDR pipelines.
- H.264 output through software x264 and hardware VideoToolbox.
- Automatic skip and remux paths for already-efficient or already-HEVC sources.
- Size guard that retries stronger and never keeps a larger output.
- Audio stream copy when MP4-compatible; AAC fallback at 192/384 kbps.
- CLI with human and JSON output, custom output folder, reveal, and keep-folder options.
- Local logs and temporary cache management.
- App icon, packaging scripts, architecture notes, testing notes, and UI snapshots.

### Fixed

- Open With now feeds files into the existing queue through the modern `application(_:open:)` delegate path.
- Opening multiple documents no longer creates multiple windows.
- Output-folder changes are reflected in the queue guidance text.
- Offscreen UI snapshots now render `ScrollView` content correctly through `NSHostingView`.
