// FlyerView.swift
// Attnd

import SwiftUI
import WebKit

/// Renders the event flyer (image or PDF) from `flyer_url`. The file comes from the offline
/// cache (`ImageStore`, prefetched with the bundle) when it's there, so the flyer opens with
/// no signal; otherwise it is downloaded (and kept), falling back to loading the URL directly.
struct FlyerView: View {
    let flyerUrl: URL?

    /// The cache lookup for `url`: the file's bytes, or nil to load the URL in the web view.
    @State private var resolved: (url: URL, data: Data?)?

    var body: some View {
        Group {
            if let flyerUrl {
                if let resolved, resolved.url == flyerUrl {
                    FlyerWebView(url: flyerUrl, data: resolved.data)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No Flyer",
                    systemImage: "doc.slash",
                    description: Text("No flyer has been added for this event.")
                )
            }
        }
        .navigationTitle("Flyer")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: flyerUrl) {
            guard let flyerUrl else { return }
            let data = await ImageStore.shared.data(for: flyerUrl)
            guard !Task.isCancelled else { return }
            resolved = (flyerUrl, data)
        }
    }
}

// MARK: - WKWebView Wrapper

private struct FlyerWebView: UIViewRepresentable {
    let url: URL
    /// The cached file. Loaded with its sniffed MIME type (PDF or image); nil or an
    /// unrecognised type loads `url` from the network as before.
    let data: Data?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.scrollView.isScrollEnabled = true
        load(in: webView, context: context)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // SwiftUI calls this on every layout pass (rotation, folding); only reload
        // when the flyer itself (or where it comes from) changed.
        if context.coordinator.loadedKey != loadKey {
            load(in: webView, context: context)
        }
    }

    private var mimeType: String? { data.flatMap(MediaCache.sniffMIMEType) }

    private var loadKey: String { url.absoluteString + (mimeType == nil ? "" : "#cached") }

    private func load(in webView: WKWebView, context: Context) {
        context.coordinator.loadedKey = loadKey
        if let data, let mimeType {
            webView.load(data, mimeType: mimeType, characterEncodingName: "utf-8", baseURL: url)
        } else {
            webView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator {
        var loadedKey: String?
    }
}

#Preview {
    NavigationStack {
        FlyerView(flyerUrl: nil)
    }
}
