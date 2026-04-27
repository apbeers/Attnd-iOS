// FlyerView.swift
// Attnd

import SwiftUI
import WebKit

/// Renders a flyer from a URL — supports images and PDFs via WKWebView.
struct FlyerView: View {
    let flyerUrl: String?

    init(flyerUrl: String? = nil) {
        self.flyerUrl = flyerUrl
    }

    var body: some View {
        Group {
            if let urlString = flyerUrl, let url = URL(string: urlString) {
                FlyerWebView(url: url)
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

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.load(URLRequest(url: url))
    }
}

#Preview {
    NavigationStack {
        FlyerView(flyerUrl: nil)
    }
}
