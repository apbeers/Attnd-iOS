// AttndWidgetsBundle.swift
// AttndWidgets (widget extension)
//
// The extension's entry point: the event's Live Activity ("Follow on Lock Screen",
// EventLiveActivity.swift) and the "Now / Next in my plan" Home Screen and Lock Screen widget
// (PlanWidget.swift, reading the App Group file the app writes).

import SwiftUI
import WidgetKit

@main
struct AttndWidgetsBundle: WidgetBundle {
    var body: some Widget {
        EventLiveActivity()
        PlanWidget()
    }
}
