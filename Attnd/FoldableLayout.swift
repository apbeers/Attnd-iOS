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
///
/// Cheap (hitch audit, Nov 22, 2026): the regions are read by a small probe in the background
/// that re-runs only when the container's geometry changes (an `EquatableView` that is always
/// "equal", so the overlay's own updates never re-run it); the content re-renders with the stored
/// insets and nothing is recomputed per layout pass of the content.
struct ReservedRegionAvoiding<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var insets = ReservedRegionLayout.Insets()

    var body: some View {
        content
            .padding(EdgeInsets(
                top: insets.top,
                leading: insets.leading,
                bottom: insets.bottom,
                trailing: insets.trailing
            ))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                ReservedRegionProbe(insets: $insets).equatable()
            }
    }
}

/// Reads the reserved regions during layout and stores the insets that avoid them (only when
/// they changed). Equal to every other probe, so its parent's updates don't re-evaluate it; its
/// GeometryReader still re-runs on every geometry change (a fold, a resize).
struct ReservedRegionProbe: View, Equatable {
    @Binding var insets: ReservedRegionLayout.Insets

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { true }

    var body: some View {
        GeometryReader { proxy in
            let measured = ReservedRegionLayout.insets(
                container: proxy.size,
                avoiding: ReservedRegionReader.rects(in: proxy)
            )
            Color.clear
                .onAppear { if insets != measured { insets = measured } }
                .onChange(of: measured) { _, value in if insets != value { insets = value } }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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

    /// The fold alone (`.division`), active only while partly folded.
    @MainActor
    static func folds(in proxy: GeometryProxy) -> [CGRect] {
        #if IOS27_SDK
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division, options: []).map { $0.frame }
        }
        #endif
        return []
    }
}

// MARK: - Reserved-region audit (Debug / Dev builds only)

/// Draws the reserved regions (fold: red, cameras: orange) over the whole window and the frames of
/// floating controls (`debugFloatingFrame`) in blue, to catch overlaps in simulator screenshots.
/// On with the launch argument `-AttndDebugRegions YES` (scripts/ci/screenshots.sh passes it for
/// the Duo captures) or the `AttndDebugRegions` default; never in Release builds.
enum ReservedRegionDebug {
    static var isOn: Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "AttndDebugRegions")
        #else
        return false
        #endif
    }
}

struct ReservedRegionDebugOverlay: View {
    var body: some View {
        #if DEBUG
        if ReservedRegionDebug.isOn {
            GeometryReader { proxy in
                let folds = ReservedRegionReader.folds(in: proxy)
                let all = ReservedRegionReader.rects(in: proxy)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(all.enumerated()), id: \.offset) { _, rect in
                        let isFold = folds.contains(rect)
                        Rectangle()
                            .fill((isFold ? Color.red : Color.orange).opacity(0.25))
                            .overlay(Rectangle().stroke(isFold ? Color.red : Color.orange, lineWidth: 2))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        #endif
    }
}

extension View {
    /// Outlines a floating control in the reserved-region audit (Debug / Dev builds only).
    @ViewBuilder
    func debugFloatingFrame(_ name: String) -> some View {
        #if DEBUG
        if ReservedRegionDebug.isOn {
            self.overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .overlay(alignment: .topLeading) {
                        Text(name).font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                            .padding(1).background(Color.blue)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        } else {
            self
        }
        #else
        self
        #endif
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

#if DEBUG
// MARK: - Previews for both iPhone Duo displays (approximate point sizes: the outer display
// 1398×2034 px and the inner 2007×2853 px at 3×; Apple hasn't published point sizes).
private struct DuoPreviewProbe: View {
    @Environment(\.horizontalSizeClass) private var horizontal

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 8) {
                Text(horizontal == .regular ? "Inner display (regular)" : "Outer display (compact)").font(.headline)
                Text("\(Int(proxy.size.width)) × \(Int(proxy.size.height)) pt")
                Text(String(describing: FoldPosture.of(container: proxy.size, folds: ReservedRegionReader.folds(in: proxy))))
                    .font(.caption.monospaced())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay { ReservedRegionDebugOverlay() }
    }
}

#Preview("Duo outer", traits: .fixedLayout(width: 466, height: 678)) {
    DuoPreviewProbe().environment(\.horizontalSizeClass, .compact)
}

#Preview("Duo inner", traits: .fixedLayout(width: 669, height: 951)) {
    DuoPreviewProbe().environment(\.horizontalSizeClass, .regular)
}

#Preview("Duo inner landscape", traits: .fixedLayout(width: 951, height: 669)) {
    DuoPreviewProbe().environment(\.horizontalSizeClass, .regular)
}
#endif
