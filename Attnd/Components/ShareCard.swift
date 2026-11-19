// ShareCard.swift
// Attnd (app + App Clip)
//
// Sharing (assistant spec §7, attnd-web API-015 "shared plan links"):
//   - SharedPlanLink: builds and parses `https://attnd.app/p/<EVENT_CODE>/<payload>` (a trailing
//     `/` optional). The payload is base64url without padding of compact JSON
//     `{"v":1,"ids":[…],"d":"YYYY-MM-DD"}`, at most 1,500 characters; encoding and decoding that
//     JSON is the domain share codec's job (the assistant phase). Here the payload is only
//     checked for its alphabet and length. `/p/<code>/<payload>/qr.svg` is the server's QR
//     image, never ours.
//   - PendingSharedPlan: a shared plan link the app opened, kept on AppState until the
//     assistant shows it ("Use this plan" / "Merge with mine").
//   - QRCode: a QR image of a string (Core Image).
//   - ShareCard (`share` block): the QR code of a link plus the system share sheet (ShareLink).

import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

// MARK: - Links

enum SharedPlanLink {
    /// Universal Links are claimed for this host only (entitlement `applinks:attnd.app`).
    static let host = "attnd.app"
    /// The longest payload the server accepts.
    static let maxPayloadLength = 1_500

    /// `https://attnd.app/p/<code>/<payload>`; nil for an empty code or an invalid payload.
    static func url(eventCode: String, payload: String) -> URL? {
        let code = eventCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, isValidPayload(payload),
              let escaped = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))
        else { return nil }
        return URL(string: "https://\(host)/p/\(escaped)/\(payload)")
    }

    /// A shared plan link's event code, and its payload when it looks readable (base64url
    /// alphabet, no padding, ≤ 1,500 characters; nil otherwise: the link only joins the event).
    /// nil when the path isn't `/p/<code>/<payload>` (any host: dev servers too).
    static func parse(_ url: URL) -> (eventCode: String, payload: String?)? {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else { return nil }
        return parse(pathComponents: url.pathComponents)
    }

    /// `["/", "p", "<code>", "<payload>"]` (URL.pathComponents; a trailing slash adds nothing).
    static func parse(pathComponents: [String]) -> (eventCode: String, payload: String?)? {
        let parts = pathComponents.filter { $0 != "/" }
        guard parts.count == 3, parts[0] == "p", !parts[1].isEmpty else { return nil }
        let payload = parts[2]
        return (parts[1], isValidPayload(payload) ? payload : nil)
    }

    /// base64url characters only (A–Z, a–z, 0–9, `-`, `_`; no `=` padding), 1…1,500 long.
    static func isValidPayload(_ payload: String) -> Bool {
        guard !payload.isEmpty, payload.count <= maxPayloadLength else { return false }
        return payload.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", "-", "_": return true
            default: return false
            }
        }
    }
}

/// A shared plan link the app was opened with, waiting for the assistant.
struct PendingSharedPlan: Hashable, Sendable {
    var eventCode: String
    /// The link's payload, unread (the domain share codec decodes it).
    var payload: String
    var receivedAt: Date
}

// MARK: - QR code

enum QRCode {
    /// A crisp QR image of `text` (error correction M), `scale` device pixels per module.
    static func image(for text: String, scale: CGFloat = 12) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
        guard let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Share card

/// The `share` block: a QR code of `url` (someone next to you scans it) and a Share button
/// (the system share sheet). `title` is the shared thing ("My plan for Saturday").
struct ShareCard: View {
    let title: String
    let url: URL
    var subtitle: String? = nil
    var shareTitle = "Share"

    @State private var qr: (url: URL, image: UIImage)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: "square.and.arrow.up")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .center, spacing: 16) {
                Group {
                    if let qr, qr.url == url {
                        Image(uiImage: qr.image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Color(.systemGray5)
                    }
                }
                .frame(width: 120, height: 120)
                .padding(8)
                .background(.white, in: .rect(cornerRadius: 12))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("QR code of the link")
                .accessibilityAddTraits(.isImage)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan with a phone camera, or send the link.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    ShareLink(item: url, subject: Text(title), message: Text(title)) {
                        Label(shareTitle, systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .blockCardBackground()
        .task(id: url) {
            let text = url.absoluteString
            if let image = QRCode.image(for: text) { qr = (url, image) }
        }
    }
}
