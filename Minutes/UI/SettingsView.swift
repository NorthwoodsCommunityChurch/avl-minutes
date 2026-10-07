import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showTraining = false

    var body: some View {
        Form {
            Section("Voice") {
                LabeledContent("Voiceprint") {
                    Text(model.hasVoicePrint ? "Trained" : "Not trained")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button(model.hasVoicePrint ? "Retrain…" : "Train…") { showTraining = true }
                    if model.hasVoicePrint {
                        Button("Delete Voiceprint", role: .destructive) { model.deleteVoicePrint() }
                    }
                }
            }

            Section("Transcripts") {
                TextField("Notes folder", text: $model.transcriptFolder)
                Toggle("Remind me to tell attendees", isOn: $model.remindOnStart)
            }

            Section {
                LabeledContent("Claude Code") {
                    switch model.claudeStatus {
                    case .connected: Text("Connected").foregroundStyle(.secondary)
                    case .notConnected: Button("Connect") { Task { await model.connectClaude() } }
                    case .claudeNotFound: Text("Not installed").foregroundStyle(.secondary)
                    case nil: ProgressView().controlSize(.small)
                    }
                }
                if let error = model.claudeError { ProblemRow(message: error) }
                if let indexer = model.indexer {
                    LabeledContent("Notes indexed", value: "\(indexer.noteCount)")
                    LabeledContent("Last refresh") {
                        Text(indexer.lastRefresh.map { $0.formatted(.relative(presentation: .named)) } ?? "Never")
                            .foregroundStyle(.secondary)
                    }
                    if let error = indexer.lastError { ProblemRow(message: error) }
                    Button(indexer.isRefreshing ? "Refreshing…" : "Refresh Now") {
                        Task { await indexer.refreshNow() }
                    }
                    .disabled(indexer.isRefreshing)
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Claude can read all of your notes and transcripts, but can't change them.")
            }

            Section("General") {
                Toggle("Open Minutes at login", isOn: Binding(
                    get: { _ = model.loginSettingVersion; return model.openAtLogin },
                    set: { model.openAtLogin = $0 }
                ))
            }

            Section("Speech Models") {
                LabeledContent("Status") { ModelStatusText(state: model.models.state) }
                if case .failed = model.models.state {
                    Button("Try Again") { Task { await model.models.prepare() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $showTraining) { VoiceTrainingView(model: model) }
        .task { await model.refreshClaudeStatus() }
    }
}

struct ModelStatusText: View {
    let state: ModelStore.State

    var body: some View {
        switch state {
        case .idle: Text("Not downloaded").foregroundStyle(.secondary)
        case .preparing(let step): Text(step).foregroundStyle(.secondary)
        case .ready: Text("Ready").foregroundStyle(.secondary)
        case .failed: Text("Couldn't download").foregroundStyle(.red)
        }
    }
}
