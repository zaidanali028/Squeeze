import Foundation

enum Preset: String, CaseIterable, Identifiable, Codable {
    case auto
    case quality
    case balanced
    case small
    case compatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Auto"
        case .quality: return "Quality"
        case .balanced: return "Balanced"
        case .small: return "Small"
        case .compatible: return "H.264"
        }
    }

    var detail: String {
        switch self {
        case .auto:
            return "Skip what is already efficient; otherwise pick the best modern codec."
        case .quality:
            return "Keep the most detail. Slowest, but the best-looking result."
        case .balanced:
            return "Great quality and a real size cut. The everyday default."
        case .small:
            return "Smallest files. Some fine detail is traded away."
        case .compatible:
            return "H.264 MP4 for the widest playback support."
        }
    }
}

enum PlanAction: String {
    case skip
    case remux
    case encode
}

struct MediaInfo {
    let url: URL
    let duration: Double
    let width: Int
    let height: Int
    let fps: Double
    let videoCodec: String
    let pixFmt: String
    let videoBitrate: Double
    let audioCodecs: [String]
    let audioChannels: Int
    let container: String
    let colorPrimaries: String?
    let colorTransfer: String?
    let colorSpace: String?
    let colorRange: String?
    let size: Int64

    var isMP4: Bool {
        container.contains("mp4") || container.contains("mov")
    }

    var isTenBit: Bool {
        pixFmt.contains("10") || pixFmt.contains("p010") || pixFmt.contains("p210")
    }

    var isHDR: Bool {
        guard let t = colorTransfer?.lowercased() else { return false }
        return t == "smpte2084" || t == "arib-std-b67"
    }

    var pixelRate: Double {
        Double(width) * Double(height) * max(fps, 1)
    }

    var bpp: Double {
        videoBitrate / max(pixelRate, 1)
    }

    var shortCodec: String {
        switch videoCodec.lowercased() {
        case "hevc", "h265": return "HEVC"
        case "h264", "avc": return "H.264"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "prores": return "ProRes"
        default: return videoCodec.uppercased()
        }
    }

    var resolution: String {
        "\(width)×\(height)"
    }

    var fpsLabel: String {
        if abs(fps.rounded() - fps) < 0.01 {
            return "\(Int(fps.rounded())) fps"
        }
        return String(format: "%.2f fps", fps)
    }
}

struct EncodeSpec {
    let codec: String
    let encoder: String
    let quality: Double
    let preset: String
    let hardware: Bool
    let note: String
}

struct Plan {
    let action: PlanAction
    let spec: EncodeSpec?
    let note: String

    static func skip(_ note: String) -> Plan { Plan(action: .skip, spec: nil, note: note) }
    static func remux(_ note: String) -> Plan { Plan(action: .remux, spec: nil, note: note) }
    static func encode(_ spec: EncodeSpec, _ note: String) -> Plan {
        Plan(action: .encode, spec: spec, note: note)
    }
}

struct JobOutcome {
    let input: URL
    let output: URL?
    let action: PlanAction
    let note: String
    let sourceSize: Int64
    let outputSize: Int64
    let codec: String?

    var savedBytes: Int64 { max(0, sourceSize - outputSize) }
    var savedFraction: Double {
        guard sourceSize > 0 else { return 0 }
        return Double(savedBytes) / Double(sourceSize)
    }
}

struct BatchResult {
    let outcomes: [JobOutcome]
    let archive: URL?
    let workFolder: URL?

    var outputs: [URL] { outcomes.compactMap(\.output) }
    var skipped: [URL] { outcomes.filter { $0.action == .skip }.map(\.input) }
    var failures: [(URL, String)] {
        outcomes.filter { $0.action == .encode && $0.output == nil }
            .map { ($0.input, $0.note) }
    }
    var totalSource: Int64 { outcomes.reduce(0) { $0 + $1.sourceSize } }
    var totalOutput: Int64 {
        outcomes.filter { $0.output != nil }.reduce(0) { $0 + $1.outputSize }
    }
    var totalSaved: Int64 {
        outcomes.reduce(0) { $0 + $1.savedBytes }
    }
}

enum SqueezeError: LocalizedError {
    case toolMissing(String)
    case probeFailed(String)
    case encodeFailed(String)
    case remuxFailed(String)
    case noGain(String)
    case cancelled
    case zipFailed(String)
    case badInput(String)

    var errorDescription: String? {
        switch self {
        case .toolMissing(let tool):
            return "\(tool) was not found. Install it with: brew install ffmpeg"
        case .probeFailed(let detail):
            return "Could not read the video: \(detail)"
        case .encodeFailed(let detail):
            return "Encoding failed: \(detail)"
        case .remuxFailed(let detail):
            return "Remux failed: \(detail)"
        case .noGain(let name):
            return "\(name) is already efficient; no smaller copy was produced."
        case .cancelled:
            return "Cancelled."
        case .zipFailed(let detail):
            return "Could not create the ZIP: \(detail)"
        case .badInput(let detail):
            return detail
        }
    }
}
