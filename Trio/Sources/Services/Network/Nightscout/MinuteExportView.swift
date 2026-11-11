import SwiftUI

/// Settings > Nightscout > 1-Minute Export (fork feature, DIAforMary/Trio).
struct MinuteExportView: View {
    @ObservedObject private var exporter = MinuteGlucoseExporter.shared

    @State private var enabled = false
    @State private var target: MinuteExportTarget = .secondServer
    @State private var urlString = ""
    @State private var secret = ""
    @State private var resultMessage: String?
    @State private var resultIsError = false
    @State private var testing = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(
                header: Text("1-minute readings"),
                footer: Text(
                    "Sends FreeStyle Libre 3 / 3+ minute readings to Nightscout. Trio's own glucose data, the algorithm and its alarms do not change. Changes take effect when you tap Save."
                )
            ) {
                Toggle("Enable 1-minute export", isOn: $enabled)

                Picker("Send to", selection: $target) {
                    Text("Second server").tag(MinuteExportTarget.secondServer)
                    Text("Main Nightscout (experimental)").tag(MinuteExportTarget.primaryNightscout)
                }

                if target == .secondServer {
                    TextField("https://your-nocturne.example.com", text: $urlString)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API secret", text: $secret)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Text(
                        "All minute readings go to this separate server, for example Nocturne. Your main Nightscout keeps getting 5-minute data. Use the second server for viewing only; do not connect LoopFollow or other follower apps to it."
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                } else {
                    Text(
                        "Experimental: the minute readings Trio does not upload itself are added to your main Nightscout, using Trio's existing connection. Follower apps built for 5-minute data will see 1-minute data: LoopFollow then shows deltas about 5 times smaller, and its fast-drop alarm, which counts the drop per reading, may not fire. Only use this while nobody relies on those follower alarms."
                    )
                    .font(.footnote)
                    .foregroundColor(.orange)
                }

                Button("Save") { save() }

                Button {
                    test()
                } label: {
                    HStack {
                        Text("Test connection")
                        if testing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(testing || (target == .secondServer && urlString.trimmingCharacters(in: .whitespaces).isEmpty))

                if let resultMessage {
                    Text(resultMessage)
                        .font(.footnote)
                        .foregroundColor(resultIsError ? .red : .green)
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Status")) {
                statusRow("Libre 3 (LibreLoop) connected", exporter.status.isLibreLoopActive ? "Yes" : "No")
                statusRow("Export", exporter.isEnabled ? "On" : "Off")
                statusRow(
                    "Sending to",
                    exporter.target == .secondServer
                        ? String(localized: "Second server")
                        : String(localized: "Main Nightscout")
                )
                statusRow("Waiting to upload", "\(exporter.status.pendingCount)")
                statusRow("Last upload", formatted(exporter.status.lastUploadAt))
                statusRow("Newest reading uploaded", formatted(exporter.status.lastUploadedReadingAt))
                if let lastError = exporter.status.lastError {
                    Text(lastError)
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            }
            .listRowBackground(Color.chart)
        }
        .navigationTitle("1-Minute Export")
        .navigationBarTitleDisplayMode(.automatic)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .onAppear {
            enabled = exporter.isEnabled
            target = exporter.target
            urlString = exporter.configuredURLString
            secret = exporter.configuredSecret
        }
    }

    private func statusRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return "–" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func save() {
        do {
            try exporter.saveSettings(enabled: enabled, target: target, urlString: urlString, secret: secret)
            urlString = exporter.configuredURLString
            resultIsError = false
            resultMessage = enabled
                ? String(localized: "Saved. 1-minute export is ON.")
                : String(localized: "Saved. 1-minute export is OFF.")
        } catch {
            resultIsError = true
            resultMessage = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        resultMessage = nil
        exporter.testConnection(target: target, urlString: urlString, secret: secret) { result in
            testing = false
            switch result {
            case let .success(message):
                resultIsError = false
                resultMessage = message
            case let .failure(error):
                resultIsError = true
                resultMessage = error.localizedDescription
            }
        }
    }
}
