// AttndWidgetsBundle.swift
// AttndWidgets (widget extension)
//
// The extension's entry point: the event's Live Activity ("Follow on Lock Screen",
// EventLiveActivity.swift). There is no Home Screen widget (removed Nov 19, 2026: people use the
// app only around an event, so the Live Activity is what follows them).

import SwiftUI
import WidgetKit

@main
struct AttndWidgetsBundle: WidgetBundle {
    var body: some Widget {
        EventLiveActivity()
    }
}
