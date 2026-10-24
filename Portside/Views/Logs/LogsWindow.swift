import AppKit
import SwiftUI

/// One tab of a site's logs window: a configured process, or a command that has run this session.
private enum LogTab: Identifiable {
    case process(ProcessConfig)
    case command(SiteCommand)

    var id: UUID {
        switch self {
        case .process(let p): p.id
        case .command(let c): c.id
        }
    }

    var name: String {
        switch self {
        case .process(let p): p.label.isEmpty ? p.command : p.label
        case .command(let c): c.name
        }
    }

    func workingDirectory(in site: Site) -> String {
        switch self {
        case .process(let p): site.workingDirectory(for: p)
        case .command(let c): site.workingDirectory(for: c)
        }
    }
}

struct LogsWindow: View {
    let siteID: Site.ID
    @Environment(PortsideController.self) private var controller

    var body: some View {
        Group {
            if let site = controller.store.site(id: siteID) {
                let tabs = site.processes.map(LogTab.process) + site.commands.filter { controller.processes.hasRun($0.id) }.map(LogTab.command)
                let current = tabs.first { $0.id == controller.logTabs[siteID] } ?? tabs[0]
                VStack(spacing: 0) {
                    tabStrip(tabs, in: site, selected: current.id)
                    Divider()
                    LogPane(site: site, tab: current)
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

    private func tabStrip(_ tabs: [LogTab], in site: Site, selected: UUID) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                let isSelected = tab.id == selected
                Button {
                    controller.logTabs[siteID] = tab.id
                } label: {
                    HStack(spacing: 6) {
                        StatusDot(controller.processes.state(of: tab.id), size: 7)
                        if case .command = tab {
                            Image(systemName: "terminal")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Text(tabTitle(tab, in: site))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.primary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(controller.processes.state(of: tab.id).summary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func tabTitle(_ tab: LogTab, in site: Site) -> String {
        guard case .process(let process) = tab else { return tab.name }
        if !process.label.isEmpty { return process.label }
        if process.isStatic, process.id == site.main.id { return "Access log" }
        return process.command
    }
}

private struct LogPane: View {
    let site: Site
    let tab: LogTab
    @Environment(PortsideController.self) private var controller
    @State private var view = LogViewState()
    @State private var query = ""
    @State private var matchCount = 0
    @State private var findNextToken = 0
    @State private var accessLog: AccessLogTail?
    @FocusState private var searchFocused: Bool

    private var isStaticMain: Bool {
        guard case .process(let process) = tab else { return false }
        return process.isStatic && process.id == site.main.id
    }

    private var buffer: LogBuffer {
        if isStaticMain, let accessLog { return accessLog.buffer }
        return controller.processes.buffer(for: tab.id)
    }

    var body: some View {
        let buffer = buffer
        let snapshot = buffer.snapshot()
        let _ = buffer.revision
        let window = LogWindow(snapshot: snapshot, limit: view.shownLimit)
        VStack(spacing: 0) {
            toolbar(lineCount: snapshot.lines.count)
            Divider()
            if window.hidden > 0 || window.dropped > 0 {
                notShownBar(window, bufferCount: snapshot.lines.count)
            }
            LogTextView(buffer: buffer, state: $view, query: query, findNextToken: findNextToken) { matchCount = $0 }
        }
        .onAppear {
            guard isStaticMain, accessLog == nil else { return }
            let tail = AccessLogTail(file: CaddyConfigBuilder.accessLogFile(siteName: site.name, in: controller.configuration.logsDirectory))
            tail.start()
            accessLog = tail
        }
        .onDisappear { accessLog?.stop() }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: DebugLaunch.logsAction)) { note in
            switch note.object as? String {
            case "follow": view.follow.toggle()
            case "earlier": view.showEarlier(than: window)
            case "clear": clear()
            default: break
            }
        }
        #endif
    }

    /// The one place that says which lines the view is not showing and why.
    private func notShownBar(_ window: LogWindow, bufferCount: Int) -> some View {
        HStack(spacing: 6) {
            if window.hidden > 0 {
                Text("\(window.lines.count.formatted()) of \(bufferCount.formatted()) lines shown")
                Text("·")
                Button("Show \(window.nextChunk.formatted()) earlier") { view.showEarlier(than: window) }
                    .buttonStyle(.link)
                    .foregroundStyle(Color(nsColor: .linkColor))
            }
            if window.hidden > 0, window.dropped > 0 {
                Text("·")
            }
            if window.dropped > 0 {
                Text("\(window.dropped.formatted()) older lines dropped")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Color(white: 0.62))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color(nsColor: LogTextView.background))
    }

    private func toolbar(lineCount: Int) -> some View {
        HStack(spacing: 2) {
            switch tab {
            case .process(let process): processControls(process)
            case .command(let command): commandControls(command)
            }
            IconButton("folder", help: "Reveal folder in Finder") { controller.openFolder(tab.workingDirectory(in: site)) }
            IconButton("terminal", help: "Open in Terminal") { controller.openInTerminal(tab.workingDirectory(in: site)) }

            Spacer(minLength: 8)

            searchField
            Toggle(isOn: $view.follow) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Keep scrolling to the newest line")
            Button("Clear", action: clear)
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

    @ViewBuilder
    private func processControls(_ process: ProcessConfig) -> some View {
        if controller.processes.state(of: process.id).isAlive {
            IconButton("stop.fill", help: isStaticMain ? "Stop serving" : "Stop \(tab.name)") {
                Task { await controller.stop(process) }
            }
            if !process.isStatic {
                IconButton("arrow.clockwise", help: "Restart \(tab.name)") {
                    Task { await controller.restart(process, in: site) }
                }
            }
        } else {
            IconButton("play.fill", help: isStaticMain ? "Serve folder" : "Start \(tab.name)") {
                Task { await controller.start(process, in: site) }
            }
            .disabled(process.isStatic && !isStaticMain)
        }
        Divider().frame(height: 16).padding(.horizontal, 4)
        if let url = controller.url(for: site, process: process) {
            IconButton("safari", help: "Open \(url.absoluteString)") { controller.openURL(site, process: process) }
        }
    }

    @ViewBuilder
    private func commandControls(_ command: SiteCommand) -> some View {
        if controller.isRunning(command) {
            IconButton("stop.fill", help: "Stop \(command.name)") {
                Task { await controller.stopCommand(command) }
            }
        } else {
            IconButton("play.fill", help: "Run \(command.name)") {
                Task { await controller.run(command, in: site) }
            }
        }
        Divider().frame(height: 16).padding(.horizontal, 4)
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TextField("Search shown lines", text: $query)
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

    private func clear() {
        buffer.clear()
        view.clear()
    }

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
