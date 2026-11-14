// QRScannerView.swift
// Attnd
//
// QR scanner sheet using DataScannerViewController (VisionKit).
// Calls onCode(_ raw: String) the first time a QR code is recognised, then dismisses.
//
// Folding, unfolding and rotating resize the camera preview; the scanner is
// stopped and restarted around size changes, and paused while the scene is not
// active, so the camera never freezes mid-transition.

import SwiftUI
import VisionKit

// MARK: - QRScannerSheet

struct QRScannerSheet: View {
    var onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    GeometryReader { proxy in
                        DataScannerRepresentable(
                            isActive: scenePhase == .active,
                            containerSize: proxy.size
                        ) { raw in
                            dismiss()
                            onCode(raw)
                        }
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
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Label("Cancel", systemImage: "xmark")
                    }
                }
            }
        }
    }
}

// MARK: - UIViewControllerRepresentable wrapper

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    /// False while the scene is inactive or backgrounded.
    var isActive: Bool
    /// The preview's size; a change (fold, unfold, rotation) restarts scanning.
    var containerSize: CGSize
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
        return vc
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCode = onCode
        coordinator.update(scanner, isActive: isActive, containerSize: containerSize)
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.cancelPendingRestart()
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    @MainActor
    final class Coordinator: NSObject {
        var onCode: (String) -> Void
        private var didFire = false
        private var lastSize: CGSize?
        private var restartTask: Task<Void, Never>?

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func update(_ scanner: DataScannerViewController, isActive: Bool, containerSize: CGSize) {
            guard !didFire else { return }
            guard isActive else {
                cancelPendingRestart()
                scanner.stopScanning()
                return
            }
            if let lastSize, lastSize != containerSize {
                // Size changed: stop now, restart once the transition has settled.
                scanner.stopScanning()
                self.lastSize = containerSize
                scheduleRestart(scanner)
                return
            }
            lastSize = containerSize
            if restartTask == nil, !scanner.isScanning {
                try? scanner.startScanning()
            }
        }

        func cancelPendingRestart() {
            restartTask?.cancel()
            restartTask = nil
        }

        private func scheduleRestart(_ scanner: DataScannerViewController) {
            cancelPendingRestart()
            restartTask = Task { [weak self, weak scanner] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self, let scanner, !self.didFire else { return }
                self.restartTask = nil
                if !scanner.isScanning {
                    try? scanner.startScanning()
                }
            }
        }

        fileprivate func recognized(_ raw: String, in scanner: DataScannerViewController) {
            guard !didFire else { return }
            didFire = true
            cancelPendingRestart()
            scanner.stopScanning()
            onCode(raw)
        }
    }
}

// DataScannerViewControllerDelegate is @MainActor in VisionKit, like the coordinator, so the
// conformance is isolated as is (no @preconcurrency needed).
extension DataScannerRepresentable.Coordinator: DataScannerViewControllerDelegate {
    func dataScanner(
        _ dataScanner: DataScannerViewController,
        didAdd addedItems: [RecognizedItem],
        allItems: [RecognizedItem]
    ) {
        for item in addedItems {
            if case .barcode(let barcode) = item, let raw = barcode.payloadStringValue {
                recognized(raw, in: dataScanner)
                return
            }
        }
    }
}
