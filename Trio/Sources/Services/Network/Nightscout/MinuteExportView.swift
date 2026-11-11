import SwiftUI

/// Settings > Nightscout > 1-Minute Readings (Libre 3) (fork feature, DIAforMary/Trio).
struct MinuteExportView: View {
    @ObservedObject private var exporter = MinuteGlucoseExporter.shared

    @State private var enabled = false
    @State private var resultMessage: String?
    @State private var resultIsError = false
    @State private var testing = false
    @State private var showInChart = false
    @State private var bubbleMode: MinuteBubbleMode = .off

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        List {
            Section(
                header: Text("Upload to main Nightscout (experimental)"),
                footer: Text(
                    "Adds the FreeStyle Libre 3 / 3+ minute readings that Trio does not upload itself to your main Nightscout, using Trio's existing Nightscout connection. Trio's own 5-minute entries, the algorithm and its alarms do not change. Changes take effect when you tap Save."
                )
            ) {
                Toggle("Upload minute readings", isOn: $enabled)

                Text(
                    "Follower apps built for 5-minute data will see 1-minute data: LoopFollow then shows deltas about 5 times smaller, and its fast-drop alarm, which counts the drop per reading, may not fire. Nightscout's own web page handles 1-minute data. Only use this while nobody relies on follower-app alarms."
                )
                .font(.footnote)
                .foregroundColor(.orange)

                if !exporter.hasPrimaryNightscout {
                    Text("No main Nightscout is connected in Trio. Please set it up under Settings > Nightscout first.")
                        .font(.footnote)
                        .foregroundColor(.red)
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
                .disabled(testing || !exporter.hasPrimaryNightscout)

                if let resultMessage {
                    Text(resultMessage)
                        .font(.footnote)
                        .foregroundColor(resultIsError ? .red : .green)
                }
            }
            .listRowBackground(Color.chart)

            // Fork feature (DIAforMary/Trio)
            Section(
                header: Text("Trio display"),
                footer: Text(
                    "Display only. The algorithm, bolus calculator, alarms, statistics, Watch, Live Activity, HealthKit and Tidepool keep using Trio's 5-minute data. Chart: minute readings as small, faded dots behind the 5-minute dots. Glucose bubble: \"Small line\" keeps the 5-minute value big and adds the newest minute reading below it with its minute after the last 5-minute reading (+1 to +4). \"Main value\" shows the newest minute reading as the big number, marked \"1-min\", with the change over the last 5 minutes as delta; the bolus calculator still uses the last 5-minute value. Both work without the upload above. When both are off, the stored minute readings are deleted."
                )
            ) {
                Toggle("Show minute readings in chart", isOn: $showInChart)
                    .onChange(of: showInChart) { _, newValue in
                        MinuteGlucoseStore.shared.setShownInChart(newValue)
                    }

                Picker("Glucose bubble", selection: $bubbleMode) {
                    Text("5-minute value only").tag(MinuteBubbleMode.off)
                    Text("Small line with minute reading").tag(MinuteBubbleMode.smallLine)
                    Text("Minute reading as main value").tag(MinuteBubbleMode.mainValue)
                }
                .onChange(of: bubbleMode) { _, newValue in
                    MinuteGlucoseStore.shared.setBubbleMode(newValue)
                }
            }
            .listRowBackground(Color.chart)

            Section(header: Text("Status")) {
                statusRow("Libre 3 (LibreLoop) connected", exporter.status.isLibreLoopActive ? "Yes" : "No")
                statusRow("Upload", exporter.isEnabled ? "On" : "Off")
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
        .navigationTitle("1-Minute Readings")
        .navigationBarTitleDisplayMode(.automatic)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .onAppear {
            enabled = exporter.isEnabled
            showInChart = MinuteGlucoseStore.shared.isShownInChart
            bubbleMode = MinuteGlucoseStore.shared.bubbleMode
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
            try exporter.saveSettings(enabled: enabled)
            resultIsError = false
            resultMessage = enabled
                ? String(localized: "Saved. Upload of minute readings is ON.")
                : String(localized: "Saved. Upload of minute readings is OFF.")
        } catch {
            resultIsError = true
            resultMessage = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        resultMessage = nil
        exporter.testConnection { result in
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
