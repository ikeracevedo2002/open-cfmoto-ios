import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: statusIcon)
                            .font(.system(size: 28))
                            .foregroundStyle(statusColor)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(model.statusTitle).font(.headline)
                                if model.isMockMode {
                                    Text("MOCK")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .foregroundStyle(.white)
                                        .background(.orange, in: Capsule())
                                }
                            }
                            Text(model.bike?.displayName ?? "Scan the QR shown by the dashboard")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Connection") {
                    Button {
                        model.isScannerPresented = true
                    } label: {
                        Label("Scan bike QR", systemImage: "qrcode.viewfinder")
                    }

                    if model.isMockMode {
                        Text("The app is using an in-process motorcycle simulator. No QR, Wi-Fi or dashboard is required.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Restart motorcycle simulator") { model.useMockMotorcycle() }
                        Button("Switch to real motorcycle") { model.useRealMotorcycle() }
                        Button("Stop simulator", role: .destructive) { model.stop() }
                    } else if model.bike != nil {
                        if case .awaitingManualWiFi = model.state {
                            Text("Open Settings → Wi-Fi, join the network shown below, then return here.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button("I joined the bike Wi-Fi") { model.continueAfterManualWiFi() }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Reconnect") { model.reconnect() }
                        }
                        Button("Stop", role: .destructive) { model.stop() }
                    }

#if DEBUG
                    if !model.isMockMode {
                        Button {
                            model.useMockMotorcycle()
                        } label: {
                            Label("Use motorcycle simulator", systemImage: "motorcycle")
                        }
                    }
#endif
                }

                if let bike = model.bike {
                    Section(model.isMockMode ? "Simulated bike" : "Bike") {
                        LabeledContent("Wi-Fi", value: bike.ssid)
                        if !bike.password.isEmpty {
                            LabeledContent("Password", value: bike.password)
                                .textSelection(.enabled)
                        }
                        LabeledContent("Model", value: bike.modelID ?? "Unknown")
                        LabeledContent("Transport", value: bike.transportDescription)
                    }
                }

                Section("Diagnostics") {
                    if model.logs.isEmpty {
                        Text("Connection events will appear here.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                }
            }
            .navigationTitle("OpenCFMoto")
            .sheet(isPresented: $model.isScannerPresented) {
                NavigationStack {
                    QRScannerView(onCode: model.accept)
                        .navigationTitle("Scan bike")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") { model.isScannerPresented = false }
                            }
                        }
                }
            }
        }
    }

    private var statusIcon: String {
        switch model.state {
        case .idle: return "motorcycle"
        case .awaitingManualWiFi: return "wifi"
        case .discovering, .handshaking: return "antenna.radiowaves.left.and.right"
        case .linked: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .linked: return model.isMockMode ? .orange : .green
        case .failed: return .red
        default: return .accentColor
        }
    }
}
