import Foundation
import AppKit
import Darwin

@main
struct SqueezeCLI {
    static func main() {
        signal(SIGINT) { _ in
            Engine.cancel()
            _exit(130)
        }

        var preset: Preset = .auto
        var outputDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
        var keepFolder = false
        var json = false
        var reveal = false
        var inputs: [URL] = []

        let args = CommandLine.arguments
        var index = 1
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--preset", "-p":
                index += 1
                guard index < args.count, let value = Preset(rawValue: args[index]) else {
                    fail("--preset needs one of: auto, quality, balanced, small, compatible")
                }
                preset = value
            case "--out", "-o":
                index += 1
                guard index < args.count else { fail("--out needs a directory") }
                outputDir = URL(fileURLWithPath: (args[index] as NSString).expandingTildeInPath)
            case "--keep-folder":
                keepFolder = true
            case "--json":
                json = true
            case "--reveal":
                reveal = true
            case "--help", "-h":
                printHelp()
                exit(0)
            case "--version", "-v":
                print("Squeeze 1.0.0")
                exit(0)
            default:
                if arg.hasPrefix("-") {
                    fail("unknown option \(arg)")
                }
                inputs.append(URL(fileURLWithPath: (arg as NSString).expandingTildeInPath))
            }
            index += 1
        }

        let videos = Engine.expand(inputs)
        guard !videos.isEmpty else {
            fail("No videos found. Pass files or folders. See --help.")
        }

        let total = videos.count
        var lastPercent = -1
        let status: (String) -> Void = { message in
            if !json {
                lastPercent = -1
                writeStderr("\r\u{001B}[K\(message)\n")
            }
        }

        do {
            let result = try Engine.process(
                inputs: videos,
                preset: preset,
                outputDir: outputDir,
                keepFolder: keepFolder,
                progress: { fileIndex, fraction in
                    guard !json else { return }
                    let overall = (Double(fileIndex) + fraction) / Double(total)
                    let percent = Int((overall * 100).rounded())
                    guard percent != lastPercent else { return }
                    lastPercent = percent
                    writeStderr("\r\u{001B}[K  \(percent)%  \(videos[fileIndex].lastPathComponent)")
                },
                status: status
            )

            if json {
                printJSON(result: result, preset: preset, outputDir: outputDir)
            } else {
                printHuman(result: result, preset: preset, outputDir: outputDir)
            }

            if reveal {
                let revealURLs = result.archive.map { [$0] } ?? result.outputs
                if !revealURLs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(revealURLs)
                }
            }

            exit(result.failures.isEmpty ? 0 : 1)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if json {
                print("{\"error\":\(jsonString(message))}")
            } else {
                writeStderr("\r\u{001B}[Kerror: \(message)\n")
            }
            exit(1)
        }
    }

    private static func printHuman(result: BatchResult, preset: Preset, outputDir: URL) {
        print("")
        print("Squeeze 1.0.0")
        print("Preset: \(preset.rawValue)")
        print("Output: \(outputDir.path)")
        print("")
        for outcome in result.outcomes {
            let name = outcome.input.lastPathComponent
            switch outcome.action {
            case .skip:
                print("  – \(name): skipped — \(outcome.note)")
            case .encode, .remux:
                guard let output = outcome.output else {
                    print("  ! \(name): \(outcome.note)")
                    continue
                }
                let percent = Int((outcome.savedFraction * 100).rounded())
                let action = outcome.action == .remux ? "remuxed" : "encoded"
                print("  ✓ \(name) → \(output.lastPathComponent)  \(Engine.humanBytes(outcome.sourceSize)) → \(Engine.humanBytes(outcome.outputSize))  (\(percent)% smaller, \(action) \(outcome.codec ?? ""))")
            }
        }
        if let archive = result.archive {
            print("")
            print("ZIP: \(archive.path)")
        }
        if let folder = result.workFolder {
            print("Folder: \(folder.path)")
        }
        let saved = result.totalSaved
        if result.totalOutput > 0 {
            print("")
            print("Saved \(Engine.humanBytes(saved)) total.")
        }
    }

    private static func printJSON(result: BatchResult, preset: Preset, outputDir: URL) {
        var items: [[String: Any]] = []
        for outcome in result.outcomes {
            var item: [String: Any] = [
                "input": outcome.input.path,
                "action": outcome.action.rawValue,
                "note": outcome.note,
                "source_size": outcome.sourceSize,
                "output_size": outcome.outputSize,
                "saved_bytes": outcome.savedBytes
            ]
            if let output = outcome.output { item["output"] = output.path }
            if let codec = outcome.codec { item["codec"] = codec }
            items.append(item)
        }
        var payload: [String: Any] = [
            "version": "1.0.0",
            "preset": preset.rawValue,
            "output_dir": outputDir.path,
            "items": items,
            "total_source": result.totalSource,
            "total_output": result.totalOutput
        ]
        if let archive = result.archive { payload["archive"] = archive.path }
        if let folder = result.workFolder { payload["folder"] = folder.path }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }

    private static func jsonString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value], options: [])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    private static func writeStderr(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }

    private static func fail(_ message: String) -> Never {
        writeStderr("error: \(message)\n")
        exit(2)
    }

    private static func printHelp() {
        print("""
        Squeeze 1.0.0 — native macOS video compressor

        Usage:
          squeeze [options] <file-or-folder> [more…]

        Options:
          -p, --preset <auto|quality|balanced|small|compatible>
                                  Compression preset (default: auto)
          -o, --out <dir>         Output folder (default: ~/Documents)
              --keep-folder       For batches, also keep the folder next to the ZIP
              --reveal            Show the result in Finder
              --json              Machine-readable output
          -h, --help              Show this help
          -v, --version           Show version

        Behaviour:
          One video  → written directly to ~/Documents
          Many videos → one ZIP in ~/Documents

        Examples:
          squeeze ~/Movies/clip.mov
          squeeze -p balanced ~/Movies/*.mp4 --reveal
          squeeze -p compatible ~/Desktop/footage
        """)
    }
}
