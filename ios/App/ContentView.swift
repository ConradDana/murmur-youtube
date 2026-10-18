import SwiftUI
import UIKit

struct ContentView: View {
    @Bindable var controller: SessionController
    @Binding var openedFromKeyboard: Bool

    var body: some View {
        NavigationStack {
            Form {
                if openedFromKeyboard, controller.isRunning {
                    Section {
                        Label {
                            Text("Session started. Tap **◀** in the top-left corner of the screen to go back, then tap the mic on the Murmur keyboard.")
                        } icon: {
                            Image(systemName: "arrow.uturn.backward.circle.fill")
                        }
                    }
                }

                sessionSection
                tryItSection
                settingsSection

                Section("Dictionary") {
                    NavigationLink("Edit words and corrections") { DictionaryEditor() }
                }

                if !controller.history.isEmpty {
                    Section("Recent") {
                        ForEach(controller.history) { item in
                            HistoryRow(item: item)
                        }
                    }
                }

                setupSection
            }
            .navigationTitle("Murmur")
        }
    }

    // MARK: - Sections

    private var sessionSection: some View {
        Section {
            HStack(spacing: 14) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle).font(.headline)
                    Text(statusDetail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.isRunning ? "Stop" : "Start session") {
                    if controller.isRunning {
                        controller.stopSession()
                        openedFromKeyboard = false
                    } else {
                        Task { await controller.startSession() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRunning ? Color.gray : Color.accentColor)
            }
            .padding(.vertical, 4)

            if let message = controller.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("A session keeps the microphone ready in the background so the Murmur keyboard can dictate into any app, including Jump Desktop. The orange dot at the top of the screen means the mic is open. Murmur only listens while you're holding or have tapped the mic.")
        }
    }

    private var tryItSection: some View {
        Section("Try it here") {
            HoldToTalkButton(controller: controller)

            if controller.phase == .listening, !controller.liveText.isEmpty {
                Text(controller.liveText).foregroundStyle(.secondary)
            }

            if !controller.lastInAppResult.isEmpty {
                HStack(alignment: .top) {
                    Text(controller.lastInAppResult).textSelection(.enabled)
                    Spacer()
                    Button {
                        UIPasteboard.general.string = controller.lastInAppResult
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy")
                }
            }
        }
    }

    private var settingsSection: some View {
        Section("Cleanup") {
            Toggle("Clean up text", isOn: $controller.cleanupEnabled)
            Toggle("Use Apple Intelligence", isOn: $controller.smartCleanup)
                .disabled(!controller.cleanupEnabled)
            if controller.cleanupEnabled, controller.smartCleanup,
               let reason = FoundationModelFormatter.unavailableReason {
                Text("\(reason) Basic cleanup is used instead.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Picker("End session when idle", selection: $controller.idleMinutes) {
                Text("5 minutes").tag(5)
                Text("15 minutes").tag(15)
                Text("30 minutes").tag(30)
                Text("1 hour").tag(60)
                Text("Never").tag(0)
            }
        }
    }

    private var setupSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("1. Open **Settings ▸ General ▸ Keyboard ▸ Keyboards ▸ Add New Keyboard** and choose **Murmur**.")
                Text("2. Tap **Murmur** in that list and turn on **Allow Full Access**. The keyboard needs it to talk to this app. Your audio never leaves the iPad.")
                Text("3. In any app, hold 🌐 on the keyboard and pick Murmur. Tap the mic once: it opens this app to start a session. Come back with **◀**, then tap or hold the mic to talk.")
            }
            .font(.callout)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } header: {
            Text("Set up the keyboard")
        }
    }

    // MARK: - Status

    private var statusColor: Color {
        switch controller.phase {
        case .off: .gray
        case .ready: .green
        // Red means recording, and only recording.
        case .listening: .red
        case .processing: .orange
        }
    }

    private var statusTitle: String {
        switch controller.phase {
        case .off: "No session"
        case .ready: "Ready"
        case .listening: "Listening…"
        case .processing: "Working…"
        }
    }

    private var statusDetail: String {
        switch controller.phase {
        case .off: "Start a session to use the keyboard."
        case .ready: "The keyboard can dictate now."
        case .listening: "Talk now."
        case .processing: "Cleaning up your text."
        }
    }
}

/// Hold to talk, release to finish — the same gesture as the Mac's push-to-talk key.
private struct HoldToTalkButton: View {
    let controller: SessionController
    @State private var isHeld = false

    var body: some View {
        Label(isHeld ? "Release to finish" : "Hold to talk", systemImage: "mic.fill")
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(isHeld ? Color.red : Color.accentColor, in: .rect(cornerRadius: 12))
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isHeld else { return }
                        isHeld = true
                        Task {
                            if !controller.isRunning { await controller.startSession() }
                            // Let go during start-up: don't begin a dictation nobody's holding.
                            if isHeld { controller.beginUtterance(requestID: nil) }
                        }
                    }
                    .onEnded { _ in
                        isHeld = false
                        controller.endUtterance()
                    }
            )
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .accessibilityAddTraits(.isButton)
    }
}

private struct HistoryRow: View {
    let item: SessionController.HistoryItem

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text).textSelection(.enabled)
                Text(item.date, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = item.text
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Copy")
        }
    }
}

/// The dictionary is a plain text file, so it's edited as one. Same format as on the Mac.
private struct DictionaryEditor: View {
    @State private var text = DictionaryFile.read()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(.horizontal)
            .navigationTitle("Dictionary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        DictionaryFile.write(text)
                        dismiss()
                    }
                }
            }
    }
}
