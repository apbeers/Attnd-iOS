// QRScannerView.swift
// Attnd
//
// Full-screen QR scanner sheet using DataScannerViewController (VisionKit, iOS 16+).
// Calls onCode(_ raw: String) the first time a QR code is recognised, then dismisses.

import SwiftUI
import VisionKit

// MARK: - QRScannerSheet

struct QRScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    _DataScannerRepresentable { raw in
                        dismiss()
                        onCode(raw)
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text("Point your camera at the event QR code")
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
                            .padding(.bottom, 32)
                    }
                } else {
                    ContentUnavailableView(
                        "Scanner Unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("QR scanning is not supported on this device. Enter the event code manually.")
                    )
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - UIViewControllerRepresentable wrapper

private struct _DataScannerRepresentable: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        var didFire = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didFire else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue {
                    didFire = true
                    dataScanner.stopScanning()
                    onCode(raw)
                    return
                }
            }
        }
    }
}
