import Foundation

private struct ProbePayload: Decodable {
    struct Stream: Decodable {
        let index: Int?
        let codec_name: String?
        let codec_type: String?
        let width: Int?
        let height: Int?
        let pix_fmt: String?
        let avg_frame_rate: String?
        let r_frame_rate: String?
        let bit_rate: String?
        let channels: Int?
        let duration: String?
        let color_primaries: String?
        let color_transfer: String?
        let color_space: String?
        let color_range: String?
    }

    struct Format: Decodable {
        let format_name: String?
        let duration: String?
        let size: String?
        let bit_rate: String?
    }

    let streams: [Stream]
    let format: Format
}

enum Engine {
    static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "avi", "webm", "mts", "m2ts", "ts",
        "3gp", "wmv", "flv", "mpg", "mpeg", "ogv", "vob", "asf", "divx"
    ]

    // MARK: - Tools

    static let ffmpegPath: String = findTool("ffmpeg")
    static let ffprobePath: String = findTool("ffprobe")

    private static func findTool(_ name: String) -> String {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return name
    }

    // MARK: - Logging

    private static let logQueue = DispatchQueue(label: "com.prom1.squeeze.log")
    static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Squeeze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("squeeze.log")
    }()

    static func log(_ message: String) {
        logQueue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: logURL.path),
               let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    // MARK: - Cancellation

    private static let cancelLock = NSLock()
    private static var currentProcess: Process?
    private static var didCancel = false

    static func beginRun() {
        cancelLock.lock()
        didCancel = false
        currentProcess = nil
        cancelLock.unlock()
    }

    static func cancel() {
        cancelLock.lock()
        didCancel = true
        let process = currentProcess
        cancelLock.unlock()
        process?.terminate()
    }

    static var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return didCancel
    }

    // MARK: - Probing

    static func probe(_ url: URL) throws -> MediaInfo {
        let args = [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            url.path
        ]
        let (status, output, error) = try runTool(ffprobePath, args)
        guard status == 0 else {
            let detail = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SqueezeError.probeFailed(detail.isEmpty ? "ffprobe exited \(status)" : detail)
        }

        let payload: ProbePayload
        do {
            payload = try JSONDecoder().decode(ProbePayload.self, from: output)
        } catch {
            throw SqueezeError.probeFailed("unreadable probe output")
        }

        guard let video = payload.streams.first(where: { $0.codec_type == "video" }) else {
            throw SqueezeError.probeFailed("no video track")
        }

        let audioStreams = payload.streams.filter { $0.codec_type == "audio" }
        let duration = double(payload.format.duration)
            ?? double(video.duration)
            ?? 0
        let size = Int64(payload.format.size ?? "")
            ?? fileSize(url)
        let streamBitrate = double(video.bit_rate) ?? 0
        let formatBitrate = double(payload.format.bit_rate) ?? 0

        return MediaInfo(
            url: url,
            duration: duration,
            width: video.width ?? 0,
            height: video.height ?? 0,
            fps: rate(video.avg_frame_rate) ?? rate(video.r_frame_rate) ?? 0,
            videoCodec: (video.codec_name ?? "unknown").lowercased(),
            pixFmt: (video.pix_fmt ?? "yuv420p").lowercased(),
            videoBitrate: streamBitrate > 0 ? streamBitrate : formatBitrate,
            audioCodecs: audioStreams.compactMap { $0.codec_name?.lowercased() },
            audioChannels: audioStreams.compactMap(\.channels).max() ?? 0,
            container: (payload.format.format_name ?? "").lowercased(),
            colorPrimaries: video.color_primaries,
            colorTransfer: video.color_transfer,
            colorSpace: video.color_space,
            colorRange: video.color_range,
            size: size
        )
    }

    // MARK: - Planning

    static func plan(for info: MediaInfo, preset: Preset) -> Plan {
        let modern = ["hevc", "h265", "av1"].contains(info.videoCodec)

        if preset == .auto {
            if info.videoCodec == "av1" {
                return .encode(
                    softwareHEVC(info, crf: 23, preset: "medium", note: "AV1 → HEVC"),
                    "Transcoding AV1 to HEVC for native macOS playback"
                )
            }
            if modern && info.isMP4 && info.bpp <= 0.10 {
                return .skip("Already efficient \(info.shortCodec)")
            }
            if info.videoCodec == "hevc" && !info.isMP4 && canRemux(info) {
                return .remux("Remux to MP4 — no quality loss")
            }
            if info.videoCodec == "h264" && info.isMP4 && info.bpp <= 0.08 {
                return .skip("Already efficient H.264")
            }
        }

        if preset == .compatible && info.videoCodec == "h264" && info.isMP4 && info.bpp <= 0.08 {
            return .skip("Already efficient H.264")
        }

        let spec = encodeSpec(for: info, preset: preset)
        let target = spec.codec == "hevc" ? "HEVC" : "H.264"
        return .encode(spec, "\(info.shortCodec) → \(target) · \(spec.note)")
    }

    private static func canRemux(_ info: MediaInfo) -> Bool {
        let supported = Set(["aac", "alac", "ac3", "eac3", "mp3"])
        return info.audioCodecs.allSatisfy { supported.contains($0) }
    }

    private static func encodeSpec(for info: MediaInfo, preset: Preset) -> EncodeSpec {
        let heavy = info.pixelRate > 300_000_000
        let ultra = info.pixelRate > 900_000_000 || info.height > 2160

        switch preset {
        case .auto:
            if ultra {
                return hardwareHEVC(info, q: 58, note: "hardware HEVC")
            }
            return softwareHEVC(info, crf: 23, preset: "medium", note: "software x265")

        case .balanced:
            if ultra {
                return hardwareHEVC(info, q: 55, note: "hardware HEVC")
            }
            return softwareHEVC(info, crf: 23, preset: "medium", note: "software x265")

        case .quality:
            let crf: Double = info.height >= 2160 ? 20 : (info.height >= 1080 ? 19 : 18)
            let x265Preset = ultra ? "fast" : (heavy ? "medium" : "slow")
            return softwareHEVC(info, crf: crf, preset: x265Preset, note: "software x265")

        case .small:
            if ultra {
                return hardwareHEVC(info, q: 50, note: "hardware HEVC")
            }
            return softwareHEVC(info, crf: 27, preset: "medium", note: "software x265")

        case .compatible:
            if info.height > 2160 {
                return softwareH264(info, crf: 22, preset: "veryfast", note: "software x264 (8K is slow)")
            }
            if heavy {
                return hardwareH264(info, q: 65, note: "hardware H.264")
            }
            return softwareH264(info, crf: 20, preset: "medium", note: "software x264")
        }
    }

    private static func softwareHEVC(_ info: MediaInfo, crf: Double, preset: String, note: String) -> EncodeSpec {
        EncodeSpec(codec: "hevc", encoder: "libx265", quality: crf, preset: preset, hardware: false, note: note)
    }

    private static func hardwareHEVC(_ info: MediaInfo, q: Double, note: String) -> EncodeSpec {
        EncodeSpec(codec: "hevc", encoder: "hevc_videotoolbox", quality: q, preset: "hardware", hardware: true, note: note)
    }

    private static func softwareH264(_ info: MediaInfo, crf: Double, preset: String, note: String) -> EncodeSpec {
        EncodeSpec(codec: "h264", encoder: "libx264", quality: crf, preset: preset, hardware: false, note: note)
    }

    private static func hardwareH264(_ info: MediaInfo, q: Double, note: String) -> EncodeSpec {
        EncodeSpec(codec: "h264", encoder: "h264_videotoolbox", quality: q, preset: "hardware", hardware: true, note: note)
    }

    // MARK: - Batch

    static func process(
        inputs: [URL],
        preset: Preset,
        outputDir: URL,
        keepFolder: Bool = false,
        progress: @escaping (Int, Double) -> Void,
        status: @escaping (String) -> Void
    ) throws -> BatchResult {
        guard !inputs.isEmpty else { throw SqueezeError.badInput("No videos selected.") }
        beginRun()
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let multiple = inputs.count > 1
        let workDir: URL
        if multiple {
            let cache = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/Squeeze", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            workDir = cache.appendingPathComponent("run-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        } else {
            workDir = outputDir
        }

        var outcomes: [JobOutcome] = []

        for (index, input) in inputs.enumerated() {
            if isCancelled { cleanup(workDir, multiple: multiple); throw SqueezeError.cancelled }
            status("Reading \(input.lastPathComponent)…")
            do {
                let outcome = try processOne(
                    input: input,
                    preset: preset,
                    outputDir: workDir,
                    index: index,
                    total: inputs.count,
                    progress: progress,
                    status: status
                )
                outcomes.append(outcome)
            } catch SqueezeError.cancelled {
                cleanup(workDir, multiple: multiple)
                throw SqueezeError.cancelled
            } catch {
                if isCancelled {
                    cleanup(workDir, multiple: multiple)
                    throw SqueezeError.cancelled
                }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("FAILED \(input.path): \(message)")
                outcomes.append(JobOutcome(
                    input: input,
                    output: nil,
                    action: .encode,
                    note: message,
                    sourceSize: fileSize(input),
                    outputSize: 0,
                    codec: nil
                ))
            }
        }

        var archive: URL?
        var keptFolder: URL?

        if multiple {
            let outputs = outcomes.compactMap(\.output)
            if !outputs.isEmpty {
                let stamp = timestamp()
                var zip = outputDir.appendingPathComponent("Squeeze-\(stamp).zip")
                zip = uniqueURL(zip)
                status("Creating ZIP…")
                try zipDirectory(workDir, to: zip)
                archive = zip
                if keepFolder {
                    let folder = outputDir.appendingPathComponent("Squeeze-\(stamp)")
                    let uniqueFolder = uniqueDirectory(folder)
                    try FileManager.default.moveItem(at: workDir, to: uniqueFolder)
                    keptFolder = uniqueFolder
                } else {
                    try? FileManager.default.removeItem(at: workDir)
                }
            } else {
                cleanup(workDir, multiple: true)
            }
        }

        return BatchResult(outcomes: outcomes, archive: archive, workFolder: keptFolder)
    }

    private static func processOne(
        input: URL,
        preset: Preset,
        outputDir: URL,
        index: Int,
        total: Int,
        progress: @escaping (Int, Double) -> Void,
        status: @escaping (String) -> Void
    ) throws -> JobOutcome {
        let info = try probe(input)
        let plan = plan(for: info, preset: preset)

        if plan.action == .skip {
            status("\(input.lastPathComponent): \(plan.note)")
            progress(index, 1)
            return JobOutcome(input: input, output: nil, action: .skip, note: plan.note,
                              sourceSize: info.size, outputSize: info.size, codec: info.videoCodec)
        }

        if plan.action == .remux {
            let output = uniqueOutputURL(dir: outputDir, stem: cleanStem(input), suffix: "-hevc")
            status("\(input.lastPathComponent): \(plan.note)")
            try remux(info, output: output, index: index, total: total, progress: progress)
            let outInfo = try verify(output: output, expectedCodec: "hevc", source: info)
            return JobOutcome(input: input, output: output, action: .remux, note: plan.note,
                              sourceSize: info.size, outputSize: fileSize(output), codec: outInfo.videoCodec)
        }

        guard let spec = plan.spec else {
            throw SqueezeError.encodeFailed("missing encode settings")
        }

        var currentSpec = spec
        let output = uniqueOutputURL(dir: outputDir, stem: cleanStem(input), suffix: spec.codec == "hevc" ? "-hevc" : "-h264")
        status("\(input.lastPathComponent): \(plan.note)")

        try encode(info, spec: currentSpec, output: output, index: index, total: total, progress: progress)
        var outInfo = try verify(output: output, expectedCodec: currentSpec.codec, source: info)

        if fileSize(output) >= info.size {
            log("NO GAIN \(input.lastPathComponent): \(fileSize(output)) >= \(info.size); retrying stronger")
            try? FileManager.default.removeItem(at: output)

            var stronger = currentSpec
            if stronger.hardware {
                stronger = EncodeSpec(codec: stronger.codec, encoder: stronger.encoder,
                                      quality: max(1, stronger.quality - 8),
                                      preset: stronger.preset, hardware: true,
                                      note: stronger.note + " (size guard)")
            } else {
                stronger = EncodeSpec(codec: stronger.codec, encoder: stronger.encoder,
                                      quality: stronger.quality + 4,
                                      preset: stronger.preset, hardware: false,
                                      note: stronger.note + " (size guard)")
            }
            currentSpec = stronger
            status("\(input.lastPathComponent): retrying to avoid a larger file…")
            try encode(info, spec: currentSpec, output: output, index: index, total: total, progress: progress)
            outInfo = try verify(output: output, expectedCodec: currentSpec.codec, source: info)

            if fileSize(output) >= info.size {
                try? FileManager.default.removeItem(at: output)
                status("\(input.lastPathComponent): already efficient — skipped")
                return JobOutcome(input: input, output: nil, action: .skip,
                                  note: "Already efficient; re-encoding would be larger.",
                                  sourceSize: info.size, outputSize: info.size, codec: info.videoCodec)
            }
        }

        return JobOutcome(input: input, output: output, action: .encode, note: plan.note,
                          sourceSize: info.size, outputSize: fileSize(output), codec: outInfo.videoCodec)
    }

    // MARK: - Encode

    private static func encode(
        _ info: MediaInfo,
        spec: EncodeSpec,
        output: URL,
        index: Int,
        total: Int,
        progress: @escaping (Int, Double) -> Void
    ) throws {
        var args: [String] = [
            "-hide_banner", "-nostdin", "-y",
            "-i", info.url.path,
            "-map", "0:v:0", "-map", "0:a?", "-map_chapters", "0", "-map_metadata", "0"
        ]
        args += videoArgs(info, spec: spec)
        args += audioArgs(info)
        args += colorArgs(info)
        args += [
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            "-loglevel", "error",
            output.path
        ]
        log("ENCODE \(info.url.path) -> \(output.path)")
        log("  \(ffmpegPath) \(args.joined(separator: " "))")
        try runFFmpeg(args, duration: info.duration, output: output, logName: output.deletingPathExtension().lastPathComponent) { fraction in
            progress(index, fraction)
        }
    }

    private static func remux(
        _ info: MediaInfo,
        output: URL,
        index: Int,
        total: Int,
        progress: @escaping (Int, Double) -> Void
    ) throws {
        let tag = info.videoCodec == "av1" ? "av01" : "hvc1"
        let args: [String] = [
            "-hide_banner", "-nostdin", "-y",
            "-i", info.url.path,
            "-map", "0:v:0", "-map", "0:a?", "-map_chapters", "0", "-map_metadata", "0",
            "-c", "copy", "-tag:v", tag,
            "-movflags", "+faststart",
            "-progress", "pipe:1", "-nostats",
            "-loglevel", "error",
            output.path
        ]
        log("REMUX \(info.url.path) -> \(output.path)")
        try runFFmpeg(args, duration: info.duration, output: output, logName: output.deletingPathExtension().lastPathComponent) { fraction in
            progress(index, fraction)
        }
    }

    private static func videoArgs(_ info: MediaInfo, spec: EncodeSpec) -> [String] {
        let quality = number(spec.quality)

        switch spec.encoder {
        case "libx265":
            var params = "log-level=error"
            if info.isHDR {
                params += ":hdr-opt=1:repeat-headers=1"
                if let value = info.colorPrimaries, value != "unknown" { params += ":colorprim=\(value)" }
                if let value = info.colorTransfer, value != "unknown" { params += ":transfer=\(value)" }
                if let value = info.colorSpace, value != "unknown" { params += ":colormatrix=\(value)" }
            }
            return [
                "-c:v", "libx265",
                "-preset", spec.preset,
                "-crf", quality,
                "-pix_fmt", info.isTenBit ? "yuv420p10le" : "yuv420p",
                "-tag:v", "hvc1",
                "-x265-params", params
            ]

        case "hevc_videotoolbox":
            return [
                "-c:v", "hevc_videotoolbox",
                "-q:v", quality,
                "-profile:v", info.isTenBit ? "main10" : "main",
                "-pix_fmt", info.isTenBit ? "p010le" : "nv12",
                "-tag:v", "hvc1",
                "-allow_sw", "1"
            ]

        case "libx264":
            return [
                "-c:v", "libx264",
                "-preset", spec.preset,
                "-crf", quality,
                "-pix_fmt", "yuv420p",
                "-profile:v", "high"
            ]

        case "h264_videotoolbox":
            return [
                "-c:v", "h264_videotoolbox",
                "-q:v", quality,
                "-profile:v", "high",
                "-pix_fmt", "yuv420p",
                "-allow_sw", "1"
            ]

        default:
            return ["-c:v", spec.encoder]
        }
    }

    private static func audioArgs(_ info: MediaInfo) -> [String] {
        guard !info.audioCodecs.isEmpty else { return [] }
        let supported = Set(["aac", "alac", "ac3", "eac3", "mp3"])
        if info.audioCodecs.allSatisfy({ supported.contains($0) }) {
            return ["-c:a", "copy"]
        }
        let bitrate = info.audioChannels > 2 ? "384k" : "192k"
        return ["-c:a", "aac", "-b:a", bitrate]
    }

    private static func colorArgs(_ info: MediaInfo) -> [String] {
        var args: [String] = []
        if let value = info.colorPrimaries, value != "unknown" {
            args += ["-color_primaries", value]
        }
        if let value = info.colorTransfer, value != "unknown" {
            args += ["-color_trc", value]
        }
        if let value = info.colorSpace, value != "unknown" {
            args += ["-colorspace", value]
        }
        if let value = info.colorRange, value != "unknown" {
            args += ["-color_range", value]
        }
        return args
    }

    // MARK: - Process execution

    private static func runFFmpeg(
        _ args: [String],
        duration: Double,
        output: URL,
        logName: String,
        onProgress: @escaping (Double) -> Void
    ) throws {
        if isCancelled { throw SqueezeError.cancelled }

        try? FileManager.default.removeItem(at: output)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Squeeze", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        let errLog = logDir.appendingPathComponent("encode-\(logName)-\(timestamp()).log")
        FileManager.default.createFile(atPath: errLog.path, contents: nil)
        guard let errHandle = try? FileHandle(forWritingTo: errLog) else {
            throw SqueezeError.encodeFailed("could not open log file")
        }
        process.standardError = errHandle

        do {
            try process.run()
        } catch {
            try? errHandle.close()
            throw SqueezeError.encodeFailed(error.localizedDescription)
        }

        cancelLock.lock()
        currentProcess = process
        cancelLock.unlock()

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let handle = outPipe.fileHandleForReading
            var buffer = Data()
            var lastFraction = 0.0
            func emit(_ value: Double) {
                let fraction = min(1, max(0, value))
                guard fraction > lastFraction + 0.0005 else { return }
                lastFraction = fraction
                onProgress(fraction)
            }
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.prefix(upTo: newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    guard let equals = line.firstIndex(of: "=") else { continue }
                    let key = String(line[..<equals])
                    let value = String(line[line.index(after: equals)...])
                    if key == "out_time_us" {
                        if let micros = Double(value), duration > 0 {
                            emit(micros / 1_000_000 / duration)
                        }
                    } else if key == "progress" && value == "end" {
                        emit(1)
                    }
                }
            }
            group.leave()
        }

        process.waitUntilExit()
        group.wait()
        try? errHandle.close()

        cancelLock.lock()
        if currentProcess === process { currentProcess = nil }
        let cancelled = didCancel
        cancelLock.unlock()

        if cancelled {
            try? FileManager.default.removeItem(at: output)
            throw SqueezeError.cancelled
        }

        guard process.terminationStatus == 0 else {
            let detail = tail(of: errLog, lines: 12)
            try? FileManager.default.removeItem(at: output)
            throw SqueezeError.encodeFailed(detail.isEmpty ? "ffmpeg exited \(process.terminationStatus)" : detail)
        }

        guard FileManager.default.fileExists(atPath: output.path), fileSize(output) > 0 else {
            throw SqueezeError.encodeFailed("ffmpeg produced no output")
        }

        onProgress(1)
    }

    private static func runTool(_ tool: String, _ args: [String]) throws -> (Int32, Data, Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
        } catch {
            throw SqueezeError.toolMissing((tool as NSString).lastPathComponent)
        }
        process.waitUntilExit()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, outData, errData)
    }

    // MARK: - Verification

    private static func verify(output: URL, expectedCodec: String, source: MediaInfo) throws -> MediaInfo {
        let info = try probe(output)
        let tolerance = max(1.0, source.duration * 0.02)
        if abs(info.duration - source.duration) > tolerance {
            try? FileManager.default.removeItem(at: output)
            throw SqueezeError.encodeFailed("duration mismatch (\(info.duration)s vs \(source.duration)s)")
        }
        if info.videoCodec != expectedCodec {
            try? FileManager.default.removeItem(at: output)
            throw SqueezeError.encodeFailed("unexpected codec \(info.videoCodec)")
        }
        if !source.audioCodecs.isEmpty && info.audioCodecs.isEmpty {
            try? FileManager.default.removeItem(at: output)
            throw SqueezeError.encodeFailed("audio track missing")
        }
        return info
    }

    // MARK: - ZIP & paths

    private static func zipDirectory(_ directory: URL, to zip: URL) throws {
        try? FileManager.default.removeItem(at: zip)
        let (status, _, error) = try runTool("/usr/bin/ditto", [
            "-c", "-k", "--sequesterRsrc", directory.path, zip.path
        ])
        guard status == 0 else {
            let detail = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SqueezeError.zipFailed(detail)
        }
    }

    static func uniqueOutputURL(dir: URL, stem: String, suffix: String) -> URL {
        var candidate = dir.appendingPathComponent("\(stem)\(suffix).mp4")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(stem)\(suffix)-\(counter).mp4")
            counter += 1
        }
        return candidate
    }

    private static func uniqueURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var counter = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    private static func uniqueDirectory(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        var counter = 2
        var candidate = url
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent)-\(counter)")
            counter += 1
        }
        return candidate
    }

    private static func cleanStem(_ url: URL) -> String {
        var stem = url.deletingPathExtension().lastPathComponent
        for suffix in ["-optimized", "-compressed", "-h264", "-hevc"] where stem.hasSuffix(suffix) {
            stem.removeLast(suffix.count)
            break
        }
        return stem.isEmpty ? "video" : stem
    }

    private static func cleanup(_ workDir: URL, multiple: Bool) {
        guard multiple else { return }
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: - Helpers

    static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        let fm = FileManager.default

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(url)
        }

        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let child = enumerator?.nextObject() as? URL {
                    if videoExtensions.contains(child.pathExtension.lowercased()) {
                        add(child)
                    }
                }
            } else if videoExtensions.contains(url.pathExtension.lowercased()) {
                add(url)
            }
        }
        return result
    }

    static func humanBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    private static func number(_ value: Double) -> String {
        if abs(value.rounded() - value) < 0.001 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }

    private static func double(_ value: String?) -> Double? {
        guard let value, value != "N/A" else { return nil }
        return Double(value)
    }

    private static func rate(_ value: String?) -> Double? {
        guard let value, value != "0/0" else { return nil }
        let parts = value.split(separator: "/")
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    private static func tail(of url: URL, lines: Int) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}
