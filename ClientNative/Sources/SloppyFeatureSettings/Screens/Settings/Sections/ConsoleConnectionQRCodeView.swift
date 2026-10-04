import CoreImage.CIFilterBuiltins
import SloppyClientCore
import SwiftUI

struct ConsoleConnectionQRCodeView: View {
    let code: ConsoleConnectionCode

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect your phone").font(.headline)
            Text("On your phone, scan this QR in Sloppy or with Camera. Sign in to the same account and approve device access in Console if requested.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let url = code.url, let image = qrImage(url) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none).resizable().frame(width: 220, height: 220)
                    .padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Server connection QR")
                ShareLink("Share connection link", item: url)
            }
            Text("Certificate SHA-256").font(.caption).foregroundStyle(.secondary)
            Text(code.fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("settings.remote.connectionQR")
    }

    private func qrImage(_ url: URL) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
