// ThemeColors.swift
// Attnd (app and App Clip)
//
// API-023 colour themes in the app: `event.theme` (light / dark × primary / secondary / tertiary,
// already contrast-adjusted by the server) becomes dynamic colours that follow the appearance.
//   - primary → the tint (TabView accent, glass prominent buttons, links), instead of
//     `accent_color`; without a theme (or a role) the tint stays `accent_color`, else the asset
//     AccentColor (brand purple).
//   - secondary → soft surfaces: a light wash on cards (`blockCardBackground`).
//   - tertiary → highlights: progress bars.
// Screenshot mode keeps the brand purple (no theme, no accent).

import SwiftUI
import UIKit

enum ThemePalette {
    /// A colour that is `light` in light mode and `dark` in dark mode; a missing side uses
    /// `fallback` (nil everywhere → nil).
    static func dynamic(light: String?, dark: String?, fallback: String? = nil) -> Color? {
        let lightHex = light ?? fallback
        let darkHex = dark ?? fallback
        guard let lightColor = uiColor(lightHex) ?? uiColor(darkHex),
              let darkColor = uiColor(darkHex) ?? uiColor(lightHex) else { return nil }
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? darkColor : lightColor
        })
    }

    static func uiColor(_ hex: String?) -> UIColor? {
        HexColor.components(hex).map { UIColor(red: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
    }
}

extension AppState {
    /// The event's theme for the apps (API-023), never in screenshot mode.
    var eventTheme: EventTheme? {
        ScreenshotMode.isActive ? nil : currentEvent?.theme
    }

    /// The tint: the theme's primary, else `accent_color`; nil = the asset AccentColor.
    var tintColor: Color? {
        guard !ScreenshotMode.isActive else { return nil }
        let accent = accentHex
        guard let theme = eventTheme else { return ThemePalette.dynamic(light: accent, dark: accent) }
        return ThemePalette.dynamic(light: theme.hex(\.primary, dark: false), dark: theme.hex(\.primary, dark: true), fallback: accent)
    }

    /// Soft surfaces (the theme's secondary), nil without a theme.
    var themeSoftColor: Color? {
        eventTheme.flatMap { ThemePalette.dynamic(light: $0.hex(\.secondary, dark: false), dark: $0.hex(\.secondary, dark: true)) }
    }

    /// Highlights (the theme's tertiary), nil without a theme.
    var themeHighlightColor: Color? {
        eventTheme.flatMap { ThemePalette.dynamic(light: $0.hex(\.tertiary, dark: false), dark: $0.hex(\.tertiary, dark: true)) }
    }

    /// The Live Activity's accent: the theme's light primary, else `accent_color`.
    var liveActivityAccentHex: String? {
        eventTheme?.hex(\.primary, dark: false) ?? accentHex
    }
}

extension EnvironmentValues {
    /// API-023 secondary (soft surfaces), set at the top of the event UI.
    @Entry var themeSoft: Color? = nil
    /// API-023 tertiary (highlights).
    @Entry var themeHighlight: Color? = nil
}

extension View {
    /// The tint and theme colours of the joined event, for the tab view and its sheets.
    func eventTheme(_ appState: AppState) -> some View {
        self
            .tint(appState.tintColor ?? Color.accentColor)
            .environment(\.themeSoft, appState.themeSoftColor)
            .environment(\.themeHighlight, appState.themeHighlightColor)
    }
}
