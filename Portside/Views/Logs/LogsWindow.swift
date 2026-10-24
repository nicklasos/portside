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
                LogPane(site: site, tab: current) {
                    tabStrip(tabs, in: site, selected: current.id)
                }
                .id(current.id)
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

    /// One recessed toggle per process or command, with its status dot, as in a scope bar.
    private func tabStrip(_ tabs: [LogTab], in site: Site, selected: UUID) -> some View {
        HStack(spacing: 4) {
            ForEach(tabs) { tab in
                Toggle(isOn: Binding(get: { tab.id == selected }, set: { if $0 { controller.logTabs[siteID] = tab.id } })) {
                    HStack(spacing: 6) {
                        StatusDot(controller.processes.state(of: tab.id), size: 7)
                        if case .command = tab {
                            Image(systemName: "terminal")
                        }
                        Text(tabTitle(tab, in: site))
                    }
                }
                .toggleStyle(.button)
                .help(controller.processes.state(of: tab.id).summary)
            }
        }
        .buttonStyle(.accessoryBar)
    }

    private func tabTitle(_ tab: LogTab, in site: Site) -> String {
        guard case .process(let process) = tab else { return tab.name }
        if !process.label.isEmpty { return process.label }
        if process.isStatic, process.id == site.main.id { return "Access log" }
        return process.command
    }
}

private struct LogPane<Tabs: View>: View {
    let site: Site
    let tab: LogTab
    @ViewBuilder let tabs: Tabs
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
            // A scope bar: the tabs, and the search that applies to the selected one.
            HStack(spacing: 8) {
                tabs
                Spacer(minLength: 8)
                searchField
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Divider()
            if window.hidden > 0 || window.dropped > 0 {
                notShownBar(window, bufferCount: snapshot.lines.count)
            }
            LogTextView(buffer: buffer, state: $view, query: query, findNextToken: findNextToken) { matchCount = $0 }
        }
        .background {
            Button("Find") { searchFocused = true }
                .keyboardShortcut("f")
                .hidden()
        }
        .toolbar { toolbar }
        .navigationSubtitle(snapshot.lines.count == 1 ? "1 line" : "\(snapshot.lines.count.formatted()) lines")
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
            case "find": searchFocused = true
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

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            switch tab {
            case .process(let process): processControls(process)
            case .command(let command): commandControls(command)
            }
        }
        ToolbarItemGroup {
            if case .process(let process) = tab, let url = controller.url(for: site, process: process) {
                toolbarButton("Open in Browser", systemImage: "safari", help: "Open \(url.absoluteString)") { controller.openURL(site, process: process) }
            }
            toolbarButton("Reveal in Finder", systemImage: "folder", help: "Reveal folder in Finder") { controller.openFolder(tab.workingDirectory(in: site)) }
            toolbarButton("Open in Terminal", systemImage: "terminal", help: "Open in Terminal") { controller.openInTerminal(tab.workingDirectory(in: site)) }
        }
        ToolbarItemGroup {
            Toggle(isOn: $view.follow) {
                Label("Follow", systemImage: "arrow.down.to.line")
            }
            .help("Keep scrolling to the newest line")
            toolbarButton("Clear", systemImage: "trash", help: "Clear the log", action: clear)
            toolbarButton("Copy All", systemImage: "doc.on.doc", help: "Copy the whole log", action: copyAll)
        }
    }

    private func toolbarButton(_ title: String, systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .help(help)
    }

    @ViewBuilder
    private func processControls(_ process: ProcessConfig) -> some View {
        if controller.processes.state(of: process.id).isAlive {
            toolbarButton("Stop", systemImage: "stop.fill", help: isStaticMain ? "Stop serving" : "Stop \(tab.name)") {
                Task { await controller.stop(process) }
            }
            if !process.isStatic {
                toolbarButton("Restart", systemImage: "arrow.clockwise", help: "Restart \(tab.name)") {
                    Task { await controller.restart(process, in: site) }
                }
            }
        } else {
            toolbarButton("Start", systemImage: "play.fill", help: isStaticMain ? "Serve folder" : "Start \(tab.name)") {
                Task { await controller.start(process, in: site) }
            }
            .disabled(process.isStatic && !isStaticMain)
        }
    }

    @ViewBuilder
    private func commandControls(_ command: SiteCommand) -> some View {
        if controller.isRunning(command) {
            toolbarButton("Stop", systemImage: "stop.fill", help: "Stop \(command.name)") {
                Task { await controller.stopCommand(command) }
            }
        } else {
            toolbarButton("Run", systemImage: "play.fill", help: "Run \(command.name)") {
                Task { await controller.run(command, in: site) }
            }
        }
    }

    private var searchField: some View {
        TextField("Search shown lines", text: $query)
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .frame(width: 180)
            .focused($searchFocused)
            .onSubmit { findNextToken += 1 }
            .overlay(alignment: .trailing) {
                if !query.isEmpty {
                    Text("\(matchCount)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.trailing, 6)
                }
            }
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
