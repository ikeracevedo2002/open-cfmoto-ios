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
                            Text(model.state.title).font(.headline)
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

                    if model.bike != nil {
                        Button("Reconnect") { model.reconnect() }
                        Button("Stop", role: .destructive) { model.stop() }
                    }
                }

                if let bike = model.bike {
                    Section("Bike") {
                        LabeledContent("Wi-Fi", value: bike.ssid)
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
        case .joiningWiFi, .discovering, .handshaking: return "antenna.radiowaves.left.and.right"
        case .linked: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .linked: return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
}
