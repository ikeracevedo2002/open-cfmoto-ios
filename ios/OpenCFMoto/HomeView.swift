import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var displayProtection = DisplayProtectionController()
    @StateObject private var navigation = NavigationModel()
    @State private var isGPXImporterPresented = false

    var body: some View {
        ZStack {
            content

            if displayProtection.shouldBlockTouches {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(count: 3) {
                        displayProtection.restoreDisplay()
                    }
                    .accessibilityLabel("Protected display")
                    .accessibilityHint("Triple tap to restore the phone display")
                    .accessibilityAction {
                        displayProtection.restoreDisplay()
                    }
                    .zIndex(100)
            }
        }
    }

    private var content: some View {
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
                                    modeBadge("MOCK", color: .orange)
                                } else if model.isMacSimulatorMode {
                                    modeBadge("MAC", color: .blue)
                                }
                            }
                            Text(model.bike?.displayName ?? "Scan the QR shown by the dashboard")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Navigation") {
                    TextField("Destination, address or place", text: $navigation.destinationQuery)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.route)
                        .onSubmit { navigation.calculateRoute() }

                    Button {
                        navigation.calculateRoute()
                    } label: {
                        if navigation.isCalculating {
                            Label("Calculating route…", systemImage: "hourglass")
                        } else {
                            Label("Project route", systemImage: "map.fill")
                        }
                    }
                    .disabled(navigation.isCalculating || navigation.destinationQuery.isEmpty)

                    Button {
                        isGPXImporterPresented = true
                    } label: {
                        Label("Import GPX route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    }

                    Text(navigation.status)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if !navigation.routeSummary.isEmpty {
                        LabeledContent("Route", value: navigation.routeSummary)
                        if navigation.progressPercent > 0 {
                            ProgressView(value: Double(navigation.progressPercent), total: 100)
                                .overlay(alignment: .trailing) {
                                    Text("\(navigation.progressPercent)%")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                        }
                        if navigation.alternativesCount > 1 {
                            Button("Try next route (\(navigation.alternativesCount) available)") {
                                navigation.selectNextAlternative()
                            }
                        }
                        Button("Clear route", role: .destructive) { navigation.clearRoute() }
                    }
                }

                Section("Phone display") {
                    Button {
                        displayProtection.protectDisplay()
                    } label: {
                        Label("Protect and dim phone display", systemImage: "moon.fill")
                    }
                    Text("Blocks touches, prevents Auto-Lock, lowers brightness and enables the proximity fallback. Triple-tap the black screen with one finger to restore it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Toggle(
                        "Proximity fallback",
                        isOn: Binding(
                            get: { displayProtection.isProximityFallbackEnabled },
                            set: { displayProtection.setProximityFallback(enabled: $0) }
                        )
                    )

                    LabeledContent(
                        "VoiceOver",
                        value: displayProtection.isVoiceOverRunning ? "Enabled" : "Disabled"
                    )
                    Text("For a truly powered-off panel while the app remains active, enable VoiceOver and use its three-finger triple-tap Screen Curtain gesture. iOS does not let apps activate Screen Curtain automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                }

#if DEBUG
                Section("Development") {
                    Button {
                        model.connectToMacSimulator()
                    } label: {
                        Label("Connect to Mac EasyConn simulator", systemImage: "laptopcomputer.and.iphone")
                    }
                    if !model.isMockMode {
                        Button {
                            model.useMockMotorcycle()
                        } label: {
                            Label("Use motorcycle simulator", systemImage: "motorcycle")
                        }
                    }
                }
#endif

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
            .task { navigation.start() }
            .fileImporter(
                isPresented: $isGPXImporterPresented,
                allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml]
            ) { result in
                guard case .success(let url) = result else { return }
                let secured = url.startAccessingSecurityScopedResource()
                defer { if secured { url.stopAccessingSecurityScopedResource() } }
                do {
                    navigation.importGPX(
                        data: try Data(contentsOf: url),
                        name: url.deletingPathExtension().lastPathComponent
                    )
                } catch {
                    navigation.importGPX(data: Data(), name: "Invalid GPX: \(error.localizedDescription)")
                }
            }
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

    private func modeBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(.white)
            .background(color, in: Capsule())
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
        case .linked:
            if model.isMockMode { return .orange }
            if model.isMacSimulatorMode { return .blue }
            return .green
        case .failed: return .red
        default: return .accentColor
        }
    }
}
