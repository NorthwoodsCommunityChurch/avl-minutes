import MinutesKit
import SwiftUI

/// The menu bar popover: ready, listening, or saved.
struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.session.phase {
            case .idle, .starting:
                ReadyView(model: model)
            case .listening, .stopping:
                ListeningView(model: model)
            case .finished:
                SavedView(model: model)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .animation(.default, value: model.session.phase)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let indexer = model.indexer {
                Text(indexStatus(indexer))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Minutes")
            .disabled(model.session.isActive)
        }
    }

    private func indexStatus(_ indexer: NotesIndexer) -> String {
        guard let refreshed = indexer.lastRefresh else { return indexer.isRefreshing ? "Indexing notes…" : "Notes not indexed yet" }
        let count = indexer.noteCount == 1 ? "1 note" : "\(indexer.noteCount) notes"
        return "\(count) indexed · \(refreshed.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Ready

private struct ReadyView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Minutes")
                .font(.title3.weight(.semibold))
            Text("Transcribes meetings into Notes. Audio is never recorded.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        TextField("Meeting name (optional)", text: $model.meetingTitle)
            .textFieldStyle(.roundedBorder)
            .onSubmit { start() }

        VStack(spacing: 8) {
            SourceToggle(title: "Room microphone", symbol: "mic", isOn: $model.useRoom)
            SourceToggle(title: "Call audio", symbol: "phone.connection", isOn: $model.useCall)
        }

        if let problem = model.setupProblem ?? model.session.startError {
            ProblemRow(message: problem, action: {
                openWindow(id: "welcome")
                NSApplication.shared.activate()
            }, actionTitle: "Set Up Minutes…")
        }

        Button(action: start) {
            Text(model.session.phase == .starting ? "Starting…" : "Start Listening")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(!model.canStart || model.session.phase == .starting)
        .keyboardShortcut(.defaultAction)

        if model.remindOnStart {
            HStack(alignment: .firstTextBaseline) {
                Text("Let everyone know you're transcribing.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Don't Remind Me") { model.remindOnStart = false }
                    .buttonStyle(.link)
            }
            .font(.footnote)
        }

        if !model.hasVoicePrint, model.setupProblem == nil {
            Button("Train your voice so your lines say “Me”…") {
                openWindow(id: "welcome")
                NSApplication.shared.activate()
            }
            .buttonStyle(.link)
            .font(.footnote)
        }
    }

    private func start() {
        guard model.canStart else { return }
        Task { await model.startMeeting() }
    }
}

// MARK: - Listening

private struct ListeningView: View {
    @Bindable var model: AppModel

    private var session: MeetingSession { model.session }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Listening", systemImage: "record.circle.fill")
                .font(.headline)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.red, .primary)
            Spacer()
            if let start = session.startedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(ElapsedFormat.string(from: start, to: context.date))
                        .font(.title2.monospacedDigit().weight(.medium))
                        .contentTransition(.numericText())
                }
            }
        }
        Text("Audio is not being recorded.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack(spacing: 14) {
            ForEach(Source.allCases.filter { session.document?.sources.contains($0) == true }, id: \.self) { source in
                LevelGauge(title: source == .room ? "Room" : "Call", level: session.levels[source] ?? 0)
            }
        }

        if session.liveLines.isEmpty && session.volatileText.values.allSatisfy(\.isEmpty) {
            Text("Words will appear here as people talk.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(session.liveLines.suffix(4).enumerated()), id: \.offset) { _, line in
                    LineRow(speaker: line.speaker.displayName, text: line.text, inProgress: false)
                        .transition(.opacity)
                }
                ForEach(Source.allCases, id: \.self) { source in
                    if let text = session.volatileText[source], !text.isEmpty {
                        LineRow(speaker: source == .room ? "Room" : "Call", text: text, inProgress: true)
                    }
                }
            }
        }

        ForEach(Array(session.captureErrors.values), id: \.self) { message in
            ProblemRow(message: message)
        }
        if let error = session.saveError {
            ProblemRow(message: error)
        } else if let saved = session.lastSaved {
            Text("Saved to Notes \(saved.formatted(.relative(presentation: .named)))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        Button {
            Task { await model.stopMeeting() }
        } label: {
            Text(session.phase == .stopping ? "Saving…" : "Stop")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(session.phase == .stopping)
    }
}

// MARK: - Saved

private struct SavedView: View {
    @Bindable var model: AppModel

    var body: some View {
        let session = model.session
        Label(session.saveError == nil ? "Saved to Notes" : "Couldn't save to Notes",
              systemImage: session.saveError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.headline)
            .symbolRenderingMode(.palette)
            .foregroundStyle(session.saveError == nil ? .green : .yellow, .primary)

        if let document = session.document {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.title).font(.callout.weight(.medium))
                Text(summary(document))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        if let error = session.saveError {
            ProblemRow(message: error)
        }
        if let error = model.openError {
            ProblemRow(message: error)
        }

        HStack {
            if session.saveError != nil {
                Button("Copy Transcript") {
                    if let text = session.plainTextForCopy() {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
                .buttonStyle(.glass)
            } else {
                Button("Open in Notes") { Task { await model.openSavedNote() } }
                    .buttonStyle(.glass)
            }
            Spacer()
            Button("New Meeting") { session.reset() }
                .buttonStyle(.glassProminent)
        }
        .controlSize(.large)
    }

    private func summary(_ document: TranscriptDocument) -> String {
        var parts: [String] = []
        if let end = document.endedAt {
            parts.append("\(max(1, Int((end.timeIntervalSince(document.startedAt) / 60).rounded(.up)))) min")
        }
        parts.append("\(document.lines.count) \(document.lines.count == 1 ? "line" : "lines")")
        parts.append(model.transcriptFolder)
        return parts.joined(separator: " · ")
    }
}

// MARK: - Pieces

private struct SourceToggle: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).frame(width: 18)
            }
            Spacer()
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct LineRow: View {
    let speaker: String
    let text: String
    let inProgress: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(speaker)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(text)
                .font(.callout)
                .italic(inProgress)
                .foregroundStyle(inProgress ? .tertiary : .primary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LevelGauge: View {
    let title: String
    let level: Float

    var body: some View {
        Gauge(value: Double(Self.meterPosition(level))) {
            Text(title)
        }
        .gaugeStyle(.accessoryLinearCapacity)
        .tint(.green)
        .font(.caption)
        .accessibilityValue(level > 0.01 ? "Hearing sound" : "Quiet")
    }

    /// RMS to 0...1 on a -60…0 dBFS scale.
    static func meterPosition(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db + 60) / 60))
    }
}

struct ProblemRow: View {
    let message: String
    var action: (() -> Void)?
    var actionTitle: String = ""

    init(message: String) {
        self.message = message
    }

    init(message: String, action: @escaping () -> Void, actionTitle: String) {
        self.message = message
        self.action = action
        self.actionTitle = actionTitle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
            .font(.callout)
            if let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.glass)
            }
        }
    }
}

enum ElapsedFormat {
    static func string(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    /// Short form for the menu bar: 4:05 or 1:04:05.
    static func short(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
