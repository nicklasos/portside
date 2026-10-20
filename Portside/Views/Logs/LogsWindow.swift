import AppKit
import SwiftUI

struct LogsWindow: View {
    let siteID: Site.ID
    @Environment(PortsideController.self) private var controller
    @State private var selection: ProcessConfig.ID?

    var body: some View {
        Group {
            if let site = controller.store.site(id: siteID) {
                let current = site.processes.first { $0.id == selection } ?? site.main
                VStack(spacing: 0) {
                    tabStrip(site, selected: current.id)
                    Divider()
                    LogPane(site: site, process: current)
                        .id(current.id)
                }
                .navigationTitle("\(site.name) — Logs")
            } else {
                Text("This site no longer exists.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 560, minHeight: 300)
        .background(WindowFrameAutosave(name: "PortsideLogs-\(siteID.uuidString)"))
    }

    private func tabStrip(_ site: Site, selected: ProcessConfig.ID) -> some View {
        HStack(spacing: 4) {
            ForEach(site.processes) { process in
                let isSelected = process.id == selected
                Button {
                    selection = process.id
                } label: {
                    HStack(spacing: 6) {
                        StatusDot(controller.processes.state(of: process.id), size: 7)
                        Text(tabTitle(process, in: site))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.primary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(controller.processes.state(of: process.id).summary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabTitle(_ process: ProcessConfig, in site: Site) -> String {
        if !process.label.isEmpty { return process.label }
        if process.isStatic, process.id == site.main.id { return "Access log" }
        return process.command
    }
}

private struct LogPane: View {
    let site: Site
    let process: ProcessConfig
    @Environment(PortsideController.self) private var controller
    @State private var follow = true
    @State private var query = ""
    @State private var matchCount = 0
    @State private var findNextToken = 0
    @State private var accessLog: AccessLogTail?
    @FocusState private var searchFocused: Bool

    private var isStaticMain: Bool { process.isStatic && process.id == site.main.id }

    private var buffer: LogBuffer {
        if isStaticMain, let accessLog { return accessLog.buffer }
        return controller.processes.buffer(for: process.id)
    }

    var body: some View {
        let buffer = buffer
        let snapshot = buffer.snapshot()
        let _ = buffer.revision
        VStack(spacing: 0) {
            toolbar(lineCount: snapshot.lines.count)
            Divider()
            if snapshot.dropped > 0 {
                Text("… \(snapshot.dropped.formatted()) older lines dropped")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: LogTextView.background))
            }
            LogTextView(buffer: buffer, follow: $follow, query: query, findNextToken: findNextToken) { matchCount = $0 }
        }
        .onAppear {
            guard isStaticMain, accessLog == nil else { return }
            let tail = AccessLogTail(file: CaddyConfigBuilder.accessLogFile(siteName: site.name, in: controller.configuration.logsDirectory))
            tail.start()
            accessLog = tail
        }
        .onDisappear { accessLog?.stop() }
    }

    private func toolbar(lineCount: Int) -> some View {
        let state = controller.processes.state(of: process.id)
        return HStack(spacing: 2) {
            if state.isAlive {
                IconButton("stop.fill", help: isStaticMain ? "Stop serving" : "Stop \(name)") {
                    Task { await controller.stop(process) }
                }
                if !process.isStatic {
                    IconButton("arrow.clockwise", help: "Restart \(name)") {
                        Task { await controller.restart(process, in: site) }
                    }
                }
            } else {
                IconButton("play.fill", help: isStaticMain ? "Serve folder" : "Start \(name)") {
                    Task { await controller.start(process, in: site) }
                }
                .disabled(process.isStatic && !isStaticMain)
            }
            Divider().frame(height: 16).padding(.horizontal, 4)
            if let url = controller.url(for: site, process: process) {
                IconButton("safari", help: "Open \(url.absoluteString)") { controller.openURL(site, process: process) }
            }
            IconButton("folder", help: "Reveal folder in Finder") { controller.openFolder(site.workingDirectory(for: process)) }
            IconButton("terminal", help: "Open in Terminal") { controller.openInTerminal(site.workingDirectory(for: process)) }

            Spacer(minLength: 8)

            searchField
            Toggle(isOn: $follow) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Keep scrolling to the newest line")
            Button("Clear") { buffer.clear() }
                .controlSize(.small)
            Button("Copy All", action: copyAll)
                .controlSize(.small)
            Text("\(lineCount.formatted()) lines")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .padding(.leading, 4)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 150)
                .focused($searchFocused)
                .onSubmit { findNextToken += 1 }
            if !query.isEmpty {
                Text("\(matchCount)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
                .frame(width: 0)
        }
        .padding(.trailing, 4)
    }

    private var name: String { process.label.isEmpty ? process.command : process.label }

    private func copyAll() {
        let text = buffer.snapshot().lines.map { ANSIParser.runs($0).map(\.text).joined() }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Restores and remembers a window's frame under `name`, so each site's logs window reopens where it was.
private struct WindowFrameAutosave: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> NSView { Probe(name: name) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class Probe: NSView {
        let name: String
        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.frameAutosaveName != name else { return }
            window.setFrameUsingName(name)
            window.setFrameAutosaveName(name)
        }
    }
}
