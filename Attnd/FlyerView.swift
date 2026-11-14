// FlyerView.swift
// Attnd

import SwiftUI
import WebKit

/// Renders the event flyer (image or PDF) from `flyer_url`.
struct FlyerView: View {
    let flyerUrl: URL?

    var body: some View {
        Group {
            if let flyerUrl {
                FlyerWebView(url: flyerUrl)
                    .ignoresSafeArea(edges: .bottom)
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
    }
}

// MARK: - WKWebView Wrapper

private struct FlyerWebView: UIViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.scrollView.isScrollEnabled = true
        load(url, in: webView, context: context)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // SwiftUI calls this on every layout pass (rotation, folding); only reload
        // when the flyer itself changed.
        if context.coordinator.requestedURL != url {
            load(url, in: webView, context: context)
        }
    }

    private func load(_ url: URL, in webView: WKWebView, context: Context) {
        context.coordinator.requestedURL = url
        webView.load(URLRequest(url: url))
    }

    @MainActor
    final class Coordinator {
        var requestedURL: URL?
    }
}

#Preview {
    NavigationStack {
        FlyerView(flyerUrl: nil)
    }
}
