// LogViewer.swift
// Attnd (app + App Clip)
//
// Options → About & support (shared logging spec §2–3):
//   - Dev builds: "Logs" (the viewer) and the install's debug code (always uploading).
//   - Production: "Recent Logs" (what the ring buffer keeps: errors only) and "Turn On Debug Logging for 10 Minutes": a consent line, then the
//     debug code `D-XXXXX` with Copy, a countdown and Turn Off. It turns itself off after 10
//     minutes, also across restarts (LogCore).
//   - The viewer: filters by level, category and text, errors only; Share exports the shown
//     lines as a `.jsonl` file.
// Never shown in screenshot mode.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Rows for the About & support section.
struct DiagnosticsRows: View {
    @State private var status = LogCore.shared.debugStatus
    @State private var didCopy = false

    var body: some View {
        if !ScreenshotMode.isActive {
            NavigationLink {
                LogViewerView()
            } label: {
                Label(LogPolicy.isDeveloperBuild ? "Logs" : "Recent Logs", systemImage: "list.bullet.rectangle")
            }
            if LogPolicy.isDevBuild {
                if let status { codeRow(status.code) }
                Text("Dev build: debug logs are sent to Attnd continuously under this code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let current = status, let until = current.until {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                    VStack(alignment: .leading, spacing: 8) {
                        codeRow(current.code)
                        Label("Debug logging on · \(remaining / 60):\(String(format: "%02d", remaining % 60)) left", systemImage: "record.circle")
                            .foregroundStyle(.orange)
                            .monospacedDigit()
                    }
                    .onChange(of: remaining == 0) { _, ended in
                        if ended { refresh() }
                    }
                }
                Button(role: .destructive) {
                    LogCore.shared.stopDebugMode()
                    refresh()
                } label: {
                    Label("Turn Off Debug Logging", systemImage: "stop.circle")
                }
            } else {
                Button {
                    LogCore.shared.startDebugMode()
                    refresh()
                } label: {
                    Label("Turn On Debug Logging for 10 Minutes", systemImage: "ladybug")
                }
                Text("Sends a technical log of what the app does, labelled only with this code, for 10 minutes. No search text, location or anything that identifies you.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func codeRow(_ code: String) -> some View {
        LabeledContent("Debug code") {
            HStack(spacing: 12) {
                Text(code)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                Button {
                    UIPasteboard.general.string = code
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private func refresh() {
        status = LogCore.shared.debugStatus
    }
}

// MARK: - Viewer

struct LogViewerView: View {
    @State private var records: [LogRecord] = []
    @State private var isLoading = true
    @State private var minimumLevel: LogLevel = .trace
    @State private var category: LogCategory?
    @State private var errorsOnly = false
    @State private var text = ""

    /// The newest lines shown (the export has every matching line).
    private static let displayLimit = 2_000

    private var filtered: [LogRecord] {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return records.filter { record in
            if errorsOnly, record.level < .error { return false }
            if record.level < minimumLevel { return false }
            if let category, record.cat != category { return false }
            if !query.isEmpty {
                let haystack = "\(record.event) \(record.msg) \(record.compactFields)".lowercased()
                if !haystack.contains(query) { return false }
            }
            return true
        }
    }

    var body: some View {
        let shown = filtered
        List {
            Section {
                Toggle("Errors Only", isOn: $errorsOnly)
                Picker("Level", selection: $minimumLevel) {
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.name.capitalized).tag(level)
                    }
                }
                Picker("Category", selection: $category) {
                    Text("All").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { category in
                        Text(category.rawValue).tag(LogCategory?.some(category))
                    }
                }
            } footer: {
                Text("\(shown.count) of \(records.count) lines")
            }
            Section {
                if isLoading {
                    ProgressView()
                } else if shown.isEmpty {
                    Text("No log lines match.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(shown.suffix(Self.displayLimit).reversed()) { record in
                        LogRecordRow(record: record)
                    }
                }
            }
        }
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter")
        .navigationTitle(LogPolicy.isDeveloperBuild ? "Logs" : "Recent Logs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: LogExport(records: shown), preview: SharePreview("Attnd logs (\(shown.count) lines)")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(shown.isEmpty)
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        records = await LogCore.shared.records()
        isLoading = false
    }
}

private struct LogRecordRow: View {
    let record: LogRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(record.level.name.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(levelColor)
                Text(record.cat.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(timeText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(record.event)
                .font(.caption.monospaced().weight(.semibold))
            if !record.msg.isEmpty {
                Text(record.msg)
                    .font(.caption)
            }
            let fields = record.compactFields
            if !fields.isEmpty {
                Text(fields)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
    }

    private var timeText: String {
        guard let date = record.date else { return record.ts }
        return date.formatted(.dateTime.hour().minute().second().secondFraction(.fractional(3)))
    }

    private var levelColor: Color {
        switch record.level {
        case .trace, .debug: return .secondary
        case .info, .notice: return .blue
        case .warning:       return .orange
        case .error, .fault: return .red
        }
    }
}

/// The shown lines as a `.jsonl` file, written when shared.
struct LogExport: Transferable {
    let records: [LogRecord]

    static let contentType = UTType(filenameExtension: "jsonl", conformingTo: .data) ?? .plainText

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: contentType) { export in
            AppLog.info(.logging, "logging.export", "Logs shared", ["entries": .int(export.records.count)])
            return SentTransferredFile(try LogStore.exportFile(export.records))
        }
    }
}
