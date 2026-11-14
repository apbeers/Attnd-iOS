// FoldableLayout.swift
// Attnd
//
// Small adapters for the foldable-era SwiftUI APIs (iPhone Duo). Everything that
// depends on an API introduced alongside it lives here, behind one availability
// check, so spelling or signature differences can be fixed in one place.
//
// ⚠️ COMPILE-TIME CHECK: these APIs were written from Apple's "Preparing your app
// for iPhone Duo" guidance without a compiler. If a symbol below doesn't resolve,
// fix it here — callers only use the wrappers.
//   - GeometryProxy.reservedRegions(kind:options:layoutDirectionBehavior:) → [ReservedRegion]
//   - ToolbarItemPlacement.topBarPinnedTrailing
// The availability version (iOS 27) is the assumed SDK that introduced them; if they
// shipped earlier, the checks still compile and only gate older systems.

import SwiftUI

// MARK: - Reserved regions (fold / camera housings)

/// Lays out floating overlay content (map buttons, cards, chips) inside the part
/// of the container that is clear of reserved hardware regions — the hinge of a
/// foldable and camera housings — using `ReservedRegionLayout.insets`.
/// Fills its container; empty space stays transparent to touches.
struct ReservedRegionAvoiding<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { proxy in
            let insets = ReservedRegionLayout.insets(
                container: proxy.size,
                avoiding: ReservedRegionReader.rects(in: proxy)
            )
            content
                .padding(EdgeInsets(
                    top: insets.top,
                    leading: insets.leading,
                    bottom: insets.bottom,
                    trailing: insets.trailing
                ))
                .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

enum ReservedRegionReader {
    /// Reserved hardware regions in the proxy's local coordinate space, leading = minX.
    @MainActor
    static func rects(in proxy: GeometryProxy) -> [CGRect] {
        // Compiled only against the iOS 27+ SDK (IOS27_SDK, set in Config/*.xcconfig).
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            // ⚠️ VERIFY: exact parameter types/values and the element's rect property.
            // Intent: every kind of hardware occlusion (fold + camera), in local
            // coordinates, with leading/trailing resolved for the layout direction.
            let regions = proxy.reservedRegions(
                kind: .all,
                options: [],
                layoutDirectionBehavior: .mirrors
            )
            return regions.map { $0.frame }
        }
        #endif
        return []
    }
}

// MARK: - Toolbar placements

extension ToolbarItemPlacement {
    /// A trailing item the system keeps visible (never moved to the overflow menu,
    /// still shown in the vertical bars of iPhone Duo's wide postures).
    static var pinnedTrailing: ToolbarItemPlacement {
        #if IOS27_SDK
        if #available(iOS 27.0, *) {
            return .topBarPinnedTrailing // ⚠️ VERIFY spelling
        }
        #endif
        return .topBarTrailing
    }
}
