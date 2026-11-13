import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let squeezeAccent = Color(red: 0.12, green: 0.55, blue: 0.72)

struct ContentView: View {
    @EnvironmentObject private var model: JobModel
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 780, idealWidth: 840, minHeight: 620, idealHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(squeezeAccent)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Squeeze")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text("Drop videos. Get smaller files.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 24)

            VStack(alignment: .trailing, spacing: 7) {
                presetSelector

                Text(model.preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 350, alignment: .trailing)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 16) {
                dropZone

                if !model.jobs.isEmpty {
                    queue
                }

                if let error = model.errorMessage {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.orange.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.orange.opacity(0.18))
                    )
                }
            }
            .padding(22)
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    var url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else if let itemURL = item as? URL {
                        url = itemURL
                    }
                    guard let url else { return }
                    DispatchQueue.main.async {
                        model.add([url])
                    }
                }
            }
            return true
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(squeezeAccent.opacity(isTargeted ? 0.10 : 0.035))
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isTargeted ? squeezeAccent : Color.secondary.opacity(0.32),
                    style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                )

            VStack(spacing: 8) {
                Image(systemName: model.jobs.isEmpty ? "arrow.down.circle" : "plus.circle")
                    .font(.system(size: model.jobs.isEmpty ? 36 : 22, weight: .light))
                    .foregroundStyle(isTargeted ? squeezeAccent : Color.secondary)
                Text(model.jobs.isEmpty ? "Drop videos here" : "Add more videos")
                    .font(.system(size: model.jobs.isEmpty ? 19 : 14, weight: .semibold))
                Text("or click to choose files")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.jobs.isEmpty {
                    Text("One video goes straight to \(model.outputDir.lastPathComponent)  ·  many become one ZIP")
                        .font(.caption2)
                        .foregroundStyle(Color.secondary.opacity(0.75))
                        .padding(.top, 3)
                }
            }
        }
        .frame(height: model.jobs.isEmpty ? 235 : 112)
        .contentShape(Rectangle())
        .onTapGesture {
            chooseFiles()
        }
    }

    private var queue: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Queue")
                    .font(.headline)
                Text("\(model.jobs.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.secondary.opacity(0.12)))
                Spacer()
                if !model.isRunning {
                    Button("Clear") {
                        model.reset()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(squeezeAccent)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            LazyVStack(spacing: 0) {
                ForEach(Array(model.jobs.enumerated()), id: \.element.id) { index, job in
                    JobRow(job: job, canRemove: !model.isRunning) {
                        model.remove(job)
                    }
                    if index < model.jobs.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.12))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                Text("Save to")
                    .foregroundStyle(.secondary)
                Text(model.outputDir.path)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Change…") {
                    chooseFolder()
                }
                .buttonStyle(.plain)
                .foregroundStyle(squeezeAccent)
                .disabled(model.isRunning)
                Spacer()
                Toggle("Reveal when finished", isOn: $model.revealWhenDone)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                if model.isRunning {
                    ProgressView(value: model.overallProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 150)
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("Cancel") {
                        model.cancel()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if model.hasResults {
                        Button("Reveal in Finder") {
                            model.reveal()
                        }
                    }
                    Button("Start Squeeze") {
                        model.start()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.jobs.isEmpty)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var presetSelector: some View {
        HStack(spacing: 3) {
            ForEach(Preset.allCases) { preset in
                Button {
                    model.preset = preset
                } label: {
                    Text(preset.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(model.preset == preset ? Color.white : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(model.preset == preset ? squeezeAccent : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning)
            }
        }
        .padding(3)
        .frame(width: 350)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(0.10))
        )
    }

    private func chooseFiles() {
        guard !model.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose videos"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        if panel.runModal() == .OK {
            model.add(panel.urls)
        }
    }

    private func chooseFolder() {
        guard !model.isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Save squeezed videos to"
        panel.prompt = "Use Folder"
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = model.outputDir
        if panel.runModal() == .OK, let url = panel.url {
            model.outputDir = url
        }
    }
}

private struct JobRow: View {
    let job: JobModel.Job
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(job.url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if job.state == .running {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 250)
                }
            }

            Spacer(minLength: 10)
            badge

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary.opacity(0.55))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detail: String {
        switch job.state {
        case .queued:
            return "\(Engine.humanBytes(job.sourceSize)) · ready"
        case .running:
            return "\(Engine.humanBytes(job.sourceSize)) · \(job.message.isEmpty ? "encoding" : job.message)"
        case .done:
            let percent = Int((job.savedFraction * 100).rounded())
            let codec = job.codec?.uppercased() ?? ""
            return "\(Engine.humanBytes(job.sourceSize)) → \(Engine.humanBytes(job.outputSize)) · \(percent)% smaller · \(codec)"
        case .skipped:
            return "\(Engine.humanBytes(job.sourceSize)) · \(job.message)"
        case .failed:
            return job.message
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch job.state {
        case .queued:
            Text("Queued")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        case .running:
            Text("\(Int((job.progress * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(squeezeAccent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(squeezeAccent.opacity(0.10)))
        case .done:
            Text("−\(Int((job.savedFraction * 100).rounded()))%")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.10)))
        case .skipped:
            Text("Optimal")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.10)))
        case .failed:
            Text("Failed")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.red.opacity(0.10)))
        }
    }
}
