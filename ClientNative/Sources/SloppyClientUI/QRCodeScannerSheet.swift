#if os(iOS)
import SwiftUI
import Vision
import VisionKit
import SloppyClientCore
import SloppyRemoteProtocol

@MainActor
public struct QRCodeScannerButton: View {
    let onScannedCode: (URL) -> Void

    public init(onScannedCode: @escaping (URL) -> Void) {
        self.onScannedCode = onScannedCode
    }

    @State private var destination: Destination?
    @Environment(\.theme) private var theme

    private enum Destination: String, Identifiable {
        case scanner

        var id: String { rawValue }
    }

    public var body: some View {
        Button {
            destination = .scanner
        } label: {
            Label("Scan Sloppy QR", systemImage: "qrcode.viewfinder")
                .font(.system(size: theme.typography.body, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, theme.spacing.m)
        }
        .buttonStyle(.plain)
        .foregroundColor(theme.colors.accentCyan)
        .backportGlassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("authentication.scanDashboardQR")
        .sheet(item: $destination) { _ in
            QRCodeScannerSheet(onScannedCode: onScannedCode)
        }
    }
}

@MainActor
private struct QRCodeScannerSheet: View {
    let onScannedCode: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported {
                    ZStack(alignment: .bottom) {
                        DashboardQRCodeScanner(
                            onPayload: handlePayload,
                            onFailure: { errorMessage = $0 }
                        )
                        .ignoresSafeArea()

                        VStack(spacing: theme.spacing.s) {
                            Text(errorMessage ?? "Scan the QR in Sloppy → Settings → Remote, Console → Instances, or Dashboard → Connect Client.")
                                .font(.system(size: theme.typography.caption))
                                .foregroundStyle(errorMessage == nil ? theme.colors.textPrimary : theme.colors.statusBlocked)
                                .multilineTextAlignment(.center)
                        }
                        .padding(theme.spacing.m)
                        .frame(maxWidth: .infinity)
                        .background(.ultraThinMaterial)
                    }
                } else {
                    ContentUnavailableView(
                        "QR Scanner Unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("Open the Dashboard QR code with the system Camera app instead. Sloppy will handle the link automatically.")
                    )
                }
            }
            .navigationTitle("Connect with QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func handlePayload(_ payload: String) {
        guard let url = URL(string: payload),
              ConsoleConnectionCode.parse(url) != nil ||
              DevicePairingLink.parse(url) != nil ||
              (try? RemotePairingCode.decode(url)) != nil else {
            errorMessage = "This is not a Sloppy pairing code."
            return
        }
        dismiss()
        onScannedCode(url)
    }
}

@MainActor
private struct DashboardQRCodeScanner: UIViewControllerRepresentable {
    let onPayload: (String) -> Void
    let onFailure: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPayload: onPayload)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        Task { @MainActor in
            do {
                try scanner.startScanning()
            } catch {
                onFailure("Camera access is unavailable. Check Camera permission in Settings.")
            }
        }
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onPayload: (String) -> Void
        private var hasDeliveredPayload = false

        init(onPayload: @escaping (String) -> Void) {
            self.onPayload = onPayload
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasDeliveredPayload else { return }
            for item in addedItems {
                guard case .barcode(let barcode) = item,
                      let payload = barcode.payloadStringValue else {
                    continue
                }
                guard let url = URL(string: payload),
                      ConsoleConnectionCode.parse(url) != nil || DevicePairingLink.parse(url) != nil ||
                      (try? RemotePairingCode.decode(url)) != nil else {
                    onPayload(payload)
                    continue
                }
                hasDeliveredPayload = true
                onPayload(payload)
                return
            }
        }
    }
}
#endif
