// PanePair.swift
// Attnd
//
// The app's one two-pane container. A screen is made of self-contained panes (a map, a list,
// a chat, a flyer…); this decides how two of them share the space, so no screen does its own
// fold maths.
//
//   - iOS 27.1+ (every iPhone, iPhone Duo included): SwiftUI's `ArrangementView` with the split
//     style. The system places the panes: side by side when the container is wider than tall,
//     stacked when taller, around the fold when the Duo is partly folded, the primary alone when
//     the secondary isn't wanted (closed Duo in landscape: the primary alone, Apple's rule).
//   - iOS 26 (ordinary iPhones only, no Duo): the same panes in a plain row / column with the
//     same rules, so nothing is drawn twice.
//
// The primary pane is always the same view in the same place of the tree, so it keeps its
// identity when the secondary comes and goes (one MKMapView, one chat scroll position, one flyer
// across fold / unfold / rotation). Rules from Apple's "Preparing your app for iPhone Duo" and
// HIG "Designing for iPhone Duo": the container sits at the top of a tab or cover, never inside a
// NavigationSplitView, List or ScrollView; each pane brings its own NavigationStack; decisions
// follow the container's geometry and size class, never the device.

import SwiftUI

struct PanePair<Primary: View, Secondary: View>: View {
    /// Whether the screen wants the secondary pane at all right now (data, size class, setting).
    let showsSecondary: Bool
    /// The axes along which the panes may sit next to each other: `.horizontal` = side by side
    /// only when wider than tall (taller containers show the primary alone).
    var axes: Axis.Set = [.horizontal, .vertical]
    /// The primary's share of the space (nil = the system's equal split).
    var primaryRatio: CGFloat?
    /// The primary, told whether the secondary is on screen beside it (a pane alone may show
    /// what the other one would, e.g. Home's second column or the map's floating button).
    @ViewBuilder var primary: (_ split: Bool) -> Primary
    @ViewBuilder var secondary: () -> Secondary

    var body: some View {
        GeometryReader { proxy in
            let split = PanePairRule.isSplit(wanted: showsSecondary, axes: axes, size: proxy.size)
            arranged(split: split, size: proxy.size)
        }
    }

    @ViewBuilder
    private func arranged(split: Bool, size: CGSize) -> some View {
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary(split)
                    .modifier(PrimaryRatio(ratio: primaryRatio))
            } secondary: {
                if split { secondary() }
            }
            // No axes = the primary alone (Apple: "for axes that you don't include, the
            // arrangement view only displays the primary view").
            .arrangementViewStyle(.split.axes(split ? axes : Axis.Set()))
        } else {
            let wide = size.width >= size.height
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            let share = primaryRatio ?? 0.5
            layout {
                primary(split)
                    .frame(width: split && wide ? size.width * share : nil,
                           height: split && !wide ? size.height * share : nil)
                if split { secondary() }
            }
        }
    }
}

/// The primary's share of a split arrangement (iOS 27.1+).
private struct PrimaryRatio: ViewModifier {
    let ratio: CGFloat?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *), let ratio {
            content.splitArrangementLayoutRatio(ratio)
        } else {
            content
        }
    }
}

/// When two panes share the space. Pure (tested in `PanePairTests`): the system's split rule,
/// written down so the primary knows whether it is alone.
enum PanePairRule {
    static func isSplit(wanted: Bool, axes: Axis.Set, size: CGSize) -> Bool {
        guard wanted, size.width > 0, size.height > 0 else { return false }
        return size.width >= size.height ? axes.contains(.horizontal) : axes.contains(.vertical)
    }
}
