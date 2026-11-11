import SwiftUI

/// Settings > Nightscout > 1-Minute Export (fork feature, DIAforMary/Trio).
struct MinuteExportView: View {
    @ObservedObject private var exporter = MinuteGlucoseExporter.shared

    @State private var enabled = false
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
                header: Text("Second server"),
                footer: Text(
                    "Sends every FreeStyle Libre 3 / 3+ minute reading to a second Nightscout-compatible server, for example Nocturne. Trio's own glucose data, the algorithm, alarms and the upload to your primary Nightscout do not change. Use the second server for viewing only; do not connect LoopFollow or other follower apps to it."
                )
            ) {
                Toggle("Enable 1-minute export", isOn: $enabled)

                TextField("https://your-nocturne.example.com", text: $urlString)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField("API secret", text: $secret)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

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
                .disabled(testing || urlString.trimmingCharacters(in: .whitespaces).isEmpty)

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
            try exporter.saveSettings(enabled: enabled, urlString: urlString, secret: secret)
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
        exporter.testConnection(urlString: urlString, secret: secret) { result in
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
