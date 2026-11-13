import Foundation
import AppKit
import Combine
import UserNotifications

@MainActor
final class JobModel: ObservableObject {
    static let shared = JobModel()

    enum JobState: String, Equatable {
        case queued
        case running
        case done
        case skipped
        case failed
    }

    struct Job: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        var state: JobState = .queued
        var progress: Double = 0
        var message: String = ""
        var output: URL?
        var sourceSize: Int64
        var outputSize: Int64 = 0
        var codec: String?

        var savedFraction: Double {
            guard sourceSize > 0, outputSize > 0 else { return 0 }
            return max(0, Double(sourceSize - outputSize) / Double(sourceSize))
        }
    }

    @Published var jobs: [Job] = []
    @Published var preset: Preset = .auto
    @Published var outputDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents", isDirectory: true)
    @Published var isRunning = false
    @Published var statusText = ""
    @Published var overallProgress: Double = 0
    @Published var archive: URL?
    @Published var errorMessage: String?
    @Published var revealWhenDone = true

    private var runToken = UUID()

    var outputs: [URL] {
        jobs.compactMap(\.output)
    }

    var hasResults: Bool {
        archive != nil || !outputs.isEmpty
    }

    var doneCount: Int {
        jobs.filter { $0.state == .done }.count
    }

    var skippedCount: Int {
        jobs.filter { $0.state == .skipped }.count
    }

    var failedCount: Int {
        jobs.filter { $0.state == .failed }.count
    }

    func add(_ urls: [URL]) {
        guard !isRunning else { return }
        let expanded = Engine.expand(urls)
        guard !expanded.isEmpty else {
            errorMessage = "No supported video files found."
            return
        }

        var existing = Set(jobs.map { $0.url.standardizedFileURL.path })
        for url in expanded {
            let key = url.standardizedFileURL.path
            guard !existing.contains(key) else { continue }
            existing.insert(key)
            jobs.append(Job(url: url, sourceSize: Engine.fileSize(url)))
        }

        errorMessage = nil
        archive = nil
        overallProgress = 0
        statusText = jobs.count == 1
            ? "Ready. One video will be saved directly to \(outputDir.lastPathComponent)."
            : "Ready. \(jobs.count) videos will become one ZIP."
        for index in jobs.indices where jobs[index].state != .queued {
            jobs[index].state = .queued
            jobs[index].progress = 0
            jobs[index].message = ""
            jobs[index].output = nil
            jobs[index].outputSize = 0
        }
    }

    func remove(_ job: Job) {
        guard !isRunning else { return }
        jobs.removeAll { $0.id == job.id }
        if jobs.isEmpty {
            statusText = ""
            archive = nil
            overallProgress = 0
        } else {
            statusText = jobs.count == 1
                ? "Ready. One video will be saved directly to \(outputDir.lastPathComponent)."
                : "Ready. \(jobs.count) videos will become one ZIP."
        }
    }

    func reset() {
        guard !isRunning else { return }
        jobs.removeAll()
        archive = nil
        errorMessage = nil
        statusText = ""
        overallProgress = 0
    }

    func start() {
        guard !isRunning, !jobs.isEmpty else { return }
        let inputs = jobs.map(\.url)
        let preset = self.preset
        let outputDir = self.outputDir
        let token = UUID()
        runToken = token

        isRunning = true
        errorMessage = nil
        archive = nil
        overallProgress = 0
        statusText = "Preparing…"
        for index in jobs.indices {
            jobs[index].state = .queued
            jobs[index].progress = 0
            jobs[index].message = ""
            jobs[index].output = nil
            jobs[index].outputSize = 0
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Engine.process(
                    inputs: inputs,
                    preset: preset,
                    outputDir: outputDir,
                    keepFolder: false,
                    progress: { fileIndex, fraction in
                        DispatchQueue.main.async {
                            guard self.runToken == token else { return }
                            if fileIndex < self.jobs.count {
                                self.jobs[fileIndex].state = .running
                                self.jobs[fileIndex].progress = fraction
                            }
                            self.overallProgress = (Double(fileIndex) + fraction) / Double(inputs.count)
                        }
                    },
                    status: { message in
                        DispatchQueue.main.async {
                            guard self.runToken == token else { return }
                            self.statusText = message
                        }
                    }
                )

                DispatchQueue.main.async {
                    guard self.runToken == token else { return }
                    self.apply(result)
                    self.isRunning = false
                    self.overallProgress = 1
                    if self.revealWhenDone && self.hasResults {
                        self.reveal()
                    }
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async {
                    guard self.runToken == token else { return }
                    self.isRunning = false
                    self.statusText = "Stopped"
                    self.errorMessage = message
                    for index in self.jobs.indices where self.jobs[index].state == .running {
                        self.jobs[index].state = .failed
                        self.jobs[index].message = message
                    }
                }
            }
        }
    }

    func cancel() {
        Engine.cancel()
        statusText = "Cancelling…"
    }

    func reveal() {
        let urls: [URL]
        if let archive {
            urls = [archive]
        } else {
            urls = outputs
        }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func apply(_ result: BatchResult) {
        archive = result.archive

        for outcome in result.outcomes {
            guard let index = jobs.firstIndex(where: {
                $0.url.standardizedFileURL.path == outcome.input.standardizedFileURL.path
            }) else { continue }

            jobs[index].sourceSize = outcome.sourceSize
            jobs[index].message = outcome.note

            if let output = outcome.output {
                jobs[index].state = .done
                jobs[index].output = output
                jobs[index].outputSize = outcome.outputSize
                jobs[index].codec = outcome.codec
                jobs[index].progress = 1
            } else if outcome.action == .skip {
                jobs[index].state = .skipped
                jobs[index].outputSize = outcome.sourceSize
                jobs[index].progress = 1
            } else {
                jobs[index].state = .failed
            }
        }

        if result.outcomes.contains(where: { $0.action == .skip }) && result.outputs.isEmpty {
            statusText = "Nothing to do — these files are already efficient."
        } else if let archive = result.archive {
            let saved = result.totalSaved
            statusText = "\(result.outputs.count) video\(result.outputs.count == 1 ? "" : "s") · \(Engine.humanBytes(saved)) saved · \(archive.lastPathComponent)"
        } else if result.outputs.count == 1 {
            statusText = "Saved to \(outputDir.lastPathComponent)."
        } else if result.outputs.isEmpty {
            statusText = "No output was needed."
        } else {
            statusText = "\(result.outputs.count) videos saved."
        }

        if result.failures.isEmpty {
            errorMessage = nil
        } else {
            errorMessage = result.failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n")
        }

        if !result.outputs.isEmpty || !result.skipped.isEmpty {
            let count = result.outputs.count
            let saved = Engine.humanBytes(result.totalSaved)
            let body: String
            if count > 0 {
                body = "\(count) video\(count == 1 ? "" : "s") · \(saved) saved"
            } else {
                body = "Already efficient — nothing to re-encode"
            }
            notify(title: "Squeeze finished", body: body)
        }
    }

    private func notify(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        NSSound(named: "Glass")?.play()
    }
}
