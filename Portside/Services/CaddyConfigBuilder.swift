import Foundation

/// Renders Portside's sites into a Caddy JSON config, one exact-host route per domain.
enum CaddyConfigBuilder {
    static let serverName = "portside"

    /// What a single site host does. The builder decides this first, then renders JSON from it.
    enum Target: Equatable {
        case proxy(upstream: String, preserveHost: Bool)
        case files(root: String, logger: String?)
        case stopped(logger: String?)
    }

    struct HostRoute: Equatable {
        var host: String
        var target: Target
    }

    static func build(sites: [Site], suffix: DomainSuffix, enabledStaticSites: Set<Site.ID>, proxyPort: Int, adminPort: Int, logsDirectory: URL?) -> Data {
        let routes = hostRoutes(sites: sites, suffix: suffix, enabledStaticSites: enabledStaticSites, logging: logsDirectory != nil)
        let proxiedHosts = routes.compactMap { if case .proxy = $0.target { $0.host } else { nil } }

        var server: [String: Any] = [
            "listen": [":\(proxyPort)"],
            "automatic_https": ["disable": true],
            "routes": routes.map(render) + [fallbackRoute],
        ]
        if !proxiedHosts.isEmpty {
            server["errors"] = ["routes": [[
                "match": [["host": proxiedHosts]],
                "handle": [htmlResponse(status: 502, body: Pages.notRunning)],
                "terminal": true,
            ]]]
        }

        var config: [String: Any] = [
            "admin": ["listen": "127.0.0.1:\(adminPort)", "config": ["persist": false]],
        ]

        let staticLogs = logsDirectory.map { staticAccessLogs(sites: sites, suffix: suffix, in: $0) } ?? []
        if !staticLogs.isEmpty {
            server["logs"] = [
                "logger_names": Dictionary(uniqueKeysWithValues: staticLogs.map { ($0.host, [$0.logger]) }),
                "skip_unmapped_hosts": true,
            ]
            var logs: [String: Any] = ["default": ["exclude": staticLogs.map { "http.log.access.\($0.logger)" }]]
            for log in staticLogs {
                logs[log.logger] = [
                    "writer": ["output": "file", "filename": log.file.path],
                    "encoder": ["format": "json"],
                    "include": ["http.log.access.\(log.logger)"],
                ]
            }
            config["logging"] = ["logs": logs]
        }
        config["apps"] = ["http": ["servers": [serverName: server]]]

        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try! JSONSerialization.data(withJSONObject: config, options: options)
    }

    /// Where Caddy writes the access log for a static site.
    static func accessLogFile(siteName: String, in logsDirectory: URL) -> URL {
        logsDirectory.appendingPathComponent(siteName, isDirectory: true).appendingPathComponent("access.log")
    }

    static func hostRoutes(sites: [Site], suffix: DomainSuffix, enabledStaticSites: Set<Site.ID>, logging: Bool) -> [HostRoute] {
        var routes: [HostRoute] = []
        for site in sites {
            for process in site.processes {
                guard let host = site.domain(for: process, in: suffix) else { continue }
                let target: Target
                if process.id == site.main.id, process.isStatic {
                    let logger = logging ? loggerName(site) : nil
                    target = enabledStaticSites.contains(site.id) ? .files(root: site.folder, logger: logger) : .stopped(logger: logger)
                } else {
                    target = .proxy(upstream: process.upstream, preserveHost: process.preserveHost)
                }
                routes.append(HostRoute(host: host, target: target))
            }
        }
        return routes.sorted { $0.host < $1.host }
    }

    private static func loggerName(_ site: Site) -> String {
        "portside-\(site.name)"
    }

    private static func staticAccessLogs(sites: [Site], suffix: DomainSuffix, in directory: URL) -> [(host: String, logger: String, file: URL)] {
        sites.filter(\.isStatic)
            .sorted { $0.name < $1.name }
            .map { ($0.domain(in: suffix), loggerName($0), accessLogFile(siteName: $0.name, in: directory)) }
    }

    private static func render(_ route: HostRoute) -> [String: Any] {
        let handler: [String: Any]
        switch route.target {
        case let .proxy(upstream, preserveHost):
            var proxy: [String: Any] = [
                "handler": "reverse_proxy",
                "upstreams": [["dial": upstream]],
                "flush_interval": -1,
            ]
            // Dev servers such as Vite reject unknown Host headers, so default to the upstream's own.
            if !preserveHost {
                proxy["headers"] = ["request": ["set": [
                    "Host": ["{http.reverse_proxy.upstream.hostport}"],
                    "X-Forwarded-Host": ["{http.request.hostport}"],
                ]]]
            }
            handler = proxy
        case let .files(root, _):
            handler = ["handler": "file_server", "root": root, "index_names": ["index.html"]]
        case .stopped:
            handler = htmlResponse(status: 503, body: Pages.notRunning)
        }
        return ["match": [["host": [route.host]]], "handle": [handler], "terminal": true]
    }

    private static var fallbackRoute: [String: Any] {
        ["handle": [htmlResponse(status: 404, body: Pages.unknownHost)], "terminal": true]
    }

    private static func htmlResponse(status: Int, body: String) -> [String: Any] {
        [
            "handler": "static_response",
            "status_code": status,
            "headers": ["Content-Type": ["text/html; charset=utf-8"], "Cache-Control": ["no-store"]],
            "body": body,
        ]
    }

    /// Caddy inserts `{http.request.host}` unescaped. Go's HTTP server rejects Host headers
    /// containing `<`, `>` or quotes with a 400, so the placeholder cannot inject markup.
    enum Pages {
        static let notRunning = page(
            title: "{http.request.host} is not running",
            body: "<h1><code>{http.request.host}</code> is not running</h1><p>Start it from the Portside menu bar, then reload this page.</p>"
        )
        static let unknownHost = page(
            title: "No site for {http.request.host}",
            body: "<h1>No site for <code>{http.request.host}</code></h1><p>Portside has no site with this domain. Add one from the Portside menu bar.</p>"
        )

        private static func page(title: String, body: String) -> String {
            """
            <!doctype html><html><head><meta charset="utf-8"><title>\(title) · Portside</title>\
            <style>body{font:16px -apple-system,system-ui,sans-serif;color:#1d1d1f;background:#f5f5f7;display:grid;place-items:center;min-height:100vh;margin:0}\
            main{max-width:32rem;padding:2rem}h1{font-size:1.5rem;margin:0 0 .5rem}p{color:#6e6e73;margin:0}.brand{font-weight:600;color:#0a84ff;margin-bottom:1rem}\
            @media(prefers-color-scheme:dark){body{color:#f5f5f7;background:#1d1d1f}p{color:#a1a1a6}}</style></head>\
            <body><main><div class="brand">Portside</div>\(body)</main></body></html>
            """
        }
    }
}
