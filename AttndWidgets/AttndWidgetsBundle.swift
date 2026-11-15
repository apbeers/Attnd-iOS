// AttndWidgetsBundle.swift
// AttndWidgets (widget extension)
//
// The extension's entry point. It holds only the event's Live Activity ("Follow on Lock
// Screen", EventLiveActivity.swift); Home Screen widgets may join it later.

import SwiftUI
import WidgetKit

@main
struct AttndWidgetsBundle: WidgetBundle {
    var body: some Widget {
        EventLiveActivity()
    }
}
