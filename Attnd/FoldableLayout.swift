// FoldableLayout.swift
// Attnd
//
// Small adapters for the foldable-era SwiftUI APIs (iPhone Duo). Everything that
// depends on an API introduced alongside it lives here, behind one availability
// check, so spelling or signature differences can be fixed in one place.
//
// The iPhone Duo APIs shipped in iOS 27.1 (Xcode 27.1+):
//   - GeometryProxy.reservedRegions(kind:options:) → [ReservedRegion], one kind per call:
//     .division (the fold) and .occlusion (camera housings). Each region's `frame`
//     already includes its margins. Read them during layout; don't cache them.
//   - ToolbarItemPlacement.topBarPinnedTrailing (never moves to the overflow menu)
// They compile only against the 27.1+ SDK (IOS27_SDK in Config/*.xcconfig) and run
// behind `#available(iOS 27.1, *)`.

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
        // Compiled only against the iOS 27.1+ SDK (IOS27_SDK, set in Config/*.xcconfig).
        #if IOS27_SDK
        if #available(iOS 27.1, *) {
            // Active regions only: the fold when the device is open, camera housings always.
            let fold = proxy.reservedRegions(kind: .division, options: [])
            let cameras = proxy.reservedRegions(kind: .occlusion, options: [])
            return (fold + cameras).map { $0.frame }
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
        if #available(iOS 27.1, *) {
            return .topBarPinnedTrailing
        }
        #endif
        return .topBarTrailing
    }
}
