# Portside — Implementation Plan

> A macOS menu bar app that turns your local dev servers into `*.test` domains.
> One click starts every process of a project, `smartcity.test` proxies to `localhost:5474`,
> `api.smartcity.test` to `localhost:8185`, and a log window replaces a pile of terminal tabs.

This document is the single source of truth for building Portside. It is written for an
AI coding agent (Claude Code) and for humans. Work through the phases in order; each phase
ends with a verifiable milestone. Do not skip ahead — later phases assume earlier ones work.

---

## 0. Project facts

| Item | Value |
|---|---|
| App name | **Portside** |
| Bundle ID | `com.nicklasos.portside` |
| Repo | `/Users/nicklasos/Projects/portside` (GitHub: `nicklasos/portside`) |
| Platform | macOS only, **minimum macOS 14 (Sonoma)** |
| Language | Swift 5.10+, SwiftUI + AppKit where needed |
| Build system | Xcode project generated from `project.yml` via **XcodeGen** (keeps the repo diff-friendly). SwiftPM for dependencies. |
| Dependencies | [Sparkle 2](https://github.com/sparkle-project/Sparkle) (updates), [swift-nio](https://github.com/apple/swift-nio) (DNS responder), bundled **Caddy** binary (reverse proxy) |
| Distribution | Unsigned / ad-hoc signed. Free. No Apple Developer account. Users right-click → Open once. Updates via Sparkle from GitHub Releases. |
| Config location | `~/Library/Application Support/Portside/sites.json` |
| Logs location | in-memory ring buffer per process; optionally mirrored to `~/Library/Logs/Portside/<site>/<process>.log` |
| License | MIT |

### Terminology

- **Site** — one project. Has a name (`smartcity`), a folder, one **main process**, and zero or more **additional processes**.
- **Process** — a shell command (`make dev`), host (`localhost`), port (`5474`), and optional **subdomain** (additional processes only).
- **Domain** — `<name>.test` for the main process; `<subdomain>.<name>.test` for an additional process with a subdomain.
- **Running** — all of a site's processes are alive. **Stopped** — none are. **Partial/Crashed** — some died (red dot).

---

## 1. Architecture overview

```
┌──────────────────────────────────────────────────────────────────┐
│  Portside.app (Swift)                                            │
│                                                                  │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────────────┐  │
│  │ MenuBar UI   │  │ Edit Sheet    │  │ Logs Window (tabs)   │  │
│  │ (MenuBarExtra│  │ (SwiftUI)     │  │ (SwiftUI + NSText)   │  │
│  └──────┬───────┘  └───────┬───────┘  └──────────┬───────────┘  │
│         └──────────────────┼─────────────────────┘              │
│                    ┌───────▼────────┐                            │
│                    │  SiteStore     │  @Observable, persists     │
│                    │  (sites.json)  │  to Application Support    │
│                    └───────┬────────┘                            │
│          ┌─────────────────┼───────────────────┐                 │
│  ┌───────▼────────┐ ┌──────▼───────┐ ┌─────────▼────────┐        │
│  │ ProcessManager │ │ DNSServer    │ │ ProxyManager     │        │
│  │ spawn/kill pg, │ │ UDP :35353   │ │ spawns caddy,    │        │
│  │ pipe → ring buf│ │ *.test → ::1 │ │ pushes JSON cfg  │        │
│  └───────┬────────┘ └──────────────┘ └─────────┬────────┘        │
│          │                                     │                 │
└──────────┼─────────────────────────────────────┼─────────────────┘
           ▼                                     ▼
   /bin/zsh -lc "make dev"             caddy (bundled binary)
   cwd = site folder                   :80 → Host-header routing
                                       admin API on 127.0.0.1:2019

   /etc/resolver/test  ←  written once with admin privileges:
                          nameserver 127.0.0.1
                          port 35353
```

### Request flow

1. Browser resolves `smartcity.test` → macOS checks `/etc/resolver/test` → asks `127.0.0.1:35353` → Portside's DNS answers `127.0.0.1`.
2. Browser connects to `127.0.0.1:80` with `Host: smartcity.test`.
3. Caddy matches the host → `reverse_proxy localhost:5474`. WebSockets (Vite HMR etc.) pass through.
4. `api.smartcity.test` → `reverse_proxy localhost:8185`.

### Why these choices

- **Caddy, not a hand-written proxy**: WebSocket upgrade, HTTP/2, streaming, chunked bodies and HTTPS (later) are solved. Live reconfiguration via admin API means no restarts when sites change. ~40 MB binary cost is acceptable.
- **Process groups**: `make dev` and `npm run dev` spawn children. Killing only the parent leaks servers holding ports. We `setsid`-style spawn and kill the whole group.
- **Login shell (`zsh -lc`)**: picks up `nvm`, `asdf`, `$GOPATH/bin`, Homebrew PATH. Without it half of users' commands won't be found.
- **No sandbox**: binding :80, spawning arbitrary shells and writing `/etc/resolver` rule out the App Store. Fine — Sparkle handles updates.

---

## 2. Repository layout (target)

```
portside/
├── README.md
├── LICENSE                       (MIT)
├── CHANGELOG.md
├── project.yml                   (XcodeGen spec)
├── Portside.xcodeproj/           (generated, committed for convenience)
├── Portside/
│   ├── App/
│   │   ├── PortsideApp.swift             @main, MenuBarExtra, Sparkle wiring
│   │   ├── AppDelegate.swift             quit handling, first-run setup
│   │   └── Info.plist                    LSUIElement=YES, SUFeedURL, SUPublicEDKey
│   ├── Models/
│   │   ├── Site.swift
│   │   ├── ProcessConfig.swift
│   │   └── SiteStatus.swift
│   ├── Store/
│   │   ├── SiteStore.swift               @Observable; CRUD; JSON persistence
│   │   └── Persistence.swift
│   ├── Services/
│   │   ├── ProcessManager.swift          spawn, process-group kill, pipes
│   │   ├── ManagedProcess.swift          one running process + LogBuffer
│   │   ├── LogBuffer.swift               thread-safe ring buffer of lines
│   │   ├── DNSServer.swift               SwiftNIO UDP, answers A/AAAA for *.test
│   │   ├── ResolverInstaller.swift       writes /etc/resolver/test (admin prompt)
│   │   ├── ProxyManager.swift            launches caddy, builds+pushes JSON config
│   │   ├── CaddyConfigBuilder.swift      Sites → Caddy JSON
│   │   ├── PortChecker.swift             detects :80 / :35353 conflicts
│   │   └── UpdaterService.swift          Sparkle SPUStandardUpdaterController
│   ├── Views/
│   │   ├── MenuBar/
│   │   │   ├── MenuBarView.swift         site list + footer actions
│   │   │   ├── SiteRowView.swift         dot, name, play/stop, logs, open
│   │   │   └── StatusDot.swift
│   │   ├── Editor/
│   │   │   ├── SiteEditorView.swift      add/edit sheet
│   │   │   ├── ProcessEditorView.swift   host/port/command/subdomain block
│   │   │   └── FolderPicker.swift        text field + "Choose…" (NSOpenPanel)
│   │   ├── Logs/
│   │   │   ├── LogsWindow.swift          one window per site, tabs
│   │   │   └── LogTextView.swift         NSTextView wrapper, autoscroll, pause
│   │   └── Settings/
│   │       └── SettingsView.swift        proxy port, DNS port, launch at login, updates
│   ├── Resources/
│   │   ├── Assets.xcassets/              AppIcon + menu bar template icons
│   │   └── caddy                         bundled binary (universal, see §9)
│   └── Portside.entitlements             (empty — no sandbox)
├── PortsideTests/
│   ├── CaddyConfigBuilderTests.swift
│   ├── SiteStoreTests.swift
│   ├── DNSServerTests.swift
│   └── ProcessManagerTests.swift
├── assets/                               brand/README assets
│   ├── icon/
│   │   ├── portside.svg                  master vector icon
│   │   ├── portside-1024.png
│   │   ├── menubar-template.svg          monochrome 18pt glyph
│   │   └── generate-icns.sh
│   └── screenshots/
│       ├── menubar.png
│       ├── editor.png
│       └── logs.png
├── scripts/
│   ├── bootstrap.sh                      installs xcodegen, downloads caddy
│   ├── fetch-caddy.sh
│   ├── build-release.sh                  archive → .app → .dmg/.zip, ad-hoc sign
│   └── generate-appcast.sh
├── docs/
│   ├── PLAN.md                           (this file)
│   ├── ARCHITECTURE.md                   (written in Phase 8 from this plan)
│   └── RELEASING.md
└── .github/
    └── workflows/
        ├── ci.yml                        build + test on PR
        └── release.yml                   tag → build → appcast → GitHub Release
```

---

## 3. Data model

```swift
struct Site: Identifiable, Codable, Hashable {
    var id: UUID = .init()
    var name: String                 // "smartcity" → smartcity.test; lowercase, [a-z0-9-]
    var folder: String               // absolute path; "~" expanded on load
    var main: ProcessConfig          // subdomain is always nil for main
    var extras: [ProcessConfig] = []
    var autoStart: Bool = false      // start when Portside launches

    var domain: String { "\(name).test" }
    var url: URL { URL(string: "http://\(domain)")! }
}

struct ProcessConfig: Identifiable, Codable, Hashable {
    var id: UUID = .init()
    var label: String                // "Frontend", "API", "Worker" — shown as log tab title
    var command: String              // "make dev"; empty allowed for static sites (see §6.3)
    var host: String = "localhost"
    var port: Int                    // 1...65535
    var subdomain: String? = nil     // extras only; "api" → api.smartcity.test; nil = no domain
    var workingDirectory: String? = nil  // optional override; defaults to Site.folder
    var env: [String: String] = [:]  // optional extra env vars (v1.1)

    var upstream: String { "\(host):\(port)" }
}

enum ProcessState: Equatable { case stopped, starting, running, exited(code: Int32), failed(String) }

enum SiteStatus { case stopped, running, partial, starting }
// partial = at least one process running and at least one exited/failed → red dot
```

Validation rules (enforced in the editor, surfaced inline):
- `name`: required, unique, matches `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`.
- `folder`: required, must exist and be a directory.
- `main.port`: required, 1–65535. `main.command` optional (empty → static file server, §6.3).
- `extras[].subdomain`: optional; if present must match the same regex as `name` and be unique within the site.
- Warn (not block) if two processes in any site share the same `host:port`.

Persistence: `sites.json` with `{ "version": 1, "sites": [...] }`. Write atomically (`.tmp` + rename). Load tolerant of unknown keys.

---

## 4. Phases

Each phase: implement → run the listed verification → commit with a conventional message (`feat:`, `fix:`, `chore:`, `docs:`).

### Phase 0 — Bootstrap (½ day)

1. `scripts/bootstrap.sh`: `brew install xcodegen` if missing; run `scripts/fetch-caddy.sh`.
2. `project.yml` for XcodeGen: app target `Portside` (macOS 14.0), test target `PortsideTests`, SwiftPM packages Sparkle (`from: "2.6.0"`) and swift-nio (`from: "2.65.0"`). Copy `Resources/caddy` into `Contents/MacOS/` with a "Copy Files" phase and mark it executable.
3. `Info.plist`: `LSUIElement = YES` (no Dock icon), `CFBundleIdentifier = com.nicklasos.portside`, `SUFeedURL`, `SUPublicEDKey` (placeholder until Phase 7), `SUEnableInstallerLauncherService = NO`.
4. `PortsideApp.swift`: `MenuBarExtra("Portside", systemImage: "circle")` with a placeholder popover. Confirm it shows in the menu bar.
5. `.gitignore` (Xcode standard + `Resources/caddy` **ignored**, fetched by script, since it's 40 MB), `LICENSE` (MIT), minimal `README.md` stub, `CHANGELOG.md`.
6. `ci.yml`: `macos-14` runner, `xcodegen`, `xcodebuild build test`.

**Verify:** `xcodegen && xcodebuild -scheme Portside build` succeeds; app launches as menu bar item; CI green.

### Phase 1 — Models, store, menu bar list (1 day)

1. Implement `Site`, `ProcessConfig`, `SiteStatus`, `SiteStore` (`@Observable`, `@MainActor`), `Persistence` (atomic JSON write to Application Support).
2. `MenuBarView`: `ForEach(store.sites)` → `SiteRowView` with grey `StatusDot`, name, `.test` domain in secondary text. Footer: divider, "Add Site…", "Check for Updates…" (disabled stub), "Settings…", divider, "Quit Portside ⌘Q".
3. Empty state: "No sites yet. Add one to get started."
4. Use `MenuBarExtra(...) { ... }.menuBarExtraStyle(.window)` for a popover with real SwiftUI controls (not `.menu`, which can't host buttons per row).
5. Right-click / `⌥`-click alternatives are **not** needed; everything goes through the popover.

**Verify:** Unit tests for store CRUD + persistence round-trip. Add a hard-coded site in debug, see it listed.

### Phase 2 — Site editor (1 day)

Sheet (`SiteEditorView`) opened from "Add Site…" and from a row's pencil/⋯ menu. Layout, top to bottom:

```
┌──────────────────────────────────────────────────────────┐
│  New Site                                                 │
│                                                           │
│  Name      [ smartcity            ] .test   [↗ Open]      │
│  Folder    [ ~/Projects/smartcity ]          [Choose…]    │
│                                                           │
│  ── Main process ────────────────────────────────────────  │
│  Label     [ Frontend ]                                   │
│  Command   [ make dev            ]  (placeholder shown)   │
│  Host      [ localhost ]   Port [ 5474 ]                  │
│  → http://smartcity.test  ⇄  http://localhost:5474        │
│                                                           │
│  ── Additional processes ───────────────────────── [+ Add] │
│  ┌ ───────────────────────────────────────────── [Remove] ┐│
│  │ Label [ API ]   Subdomain [ api ] .smartcity.test      ││
│  │ Command [ make dev ]  Host [ localhost ] Port [ 8185 ] ││
│  │ Folder  [ (inherits site folder) ]          [Choose…] ││
│  │ → http://api.smartcity.test ⇄ http://localhost:8185   ││
│  └────────────────────────────────────────────────────── ┘│
│                                                           │
│  [ ] Start automatically when Portside launches           │
│                                                           │
│                                   [Cancel]   [Save]       │
└──────────────────────────────────────────────────────────┘
```

Details:
- Name field lowercases and strips invalid chars as you type; `.test` suffix is a static label; "Open" button opens `http://<name>.test` (disabled until name valid and site saved).
- Folder field: editable text + `Choose…` → `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`). Show a subtle red hint if path doesn't exist.
- Command placeholder cycles: `make dev`, `npm run dev`, `go run .`, `air`. Leave empty for a static site (hint text: "Leave empty to serve the folder as static files").
- Live URL preview line under each process block updates as you type.
- Additional processes: `+ Add` appends a block; `Remove` deletes; drag reorder optional (v1.1).
- Save validates (§3). Editing an **existing running** site: save applies immediately to proxy config; processes whose command/folder changed are restarted; show a one-line notice.
- Delete: from row's ⋯ menu → confirmation alert → stops processes → removes from store → proxy reconfigured.

**Verify:** Create, edit, delete sites; `sites.json` reflects changes; invalid input blocked with inline messages.

### Phase 3 — Process manager (1–1.5 days)

`ProcessManager` (actor) owns `[Site.ID: [ProcessConfig.ID: ManagedProcess]]`.

`ManagedProcess.start()`:
```swift
let p = Process()
p.executableURL = URL(fileURLWithPath: "/bin/zsh")
p.arguments = ["-lc", config.command]
p.currentDirectoryURL = URL(fileURLWithPath: cwd)
var env = ProcessInfo.processInfo.environment
env["PORT"] = String(config.port)        // convenience; many dev servers honor it
env["HOST"] = config.host
env["PORTSIDE"] = "1"
env["PORTSIDE_SITE"] = site.name
env["PORTSIDE_URL"] = "http://\(domainOrNil)"
env.merge(config.env) { $1 }
env["TERM"] = "xterm-256color"; env["FORCE_COLOR"] = "1"   // colored logs
p.environment = env
let out = Pipe(), err = Pipe()
p.standardOutput = out; p.standardError = err
p.terminationHandler = { ... state = .exited(code) ... }
```

**Process-group killing** — essential. `Foundation.Process` has no `setsid`. Two acceptable approaches; implement **A**, fall back to B if problematic:
- **A.** Launch via `posix_spawn` with `POSIX_SPAWN_SETSID` (available on macOS 10.15+) using a small C shim or `posix_spawnattr_setflags`. Store the pid; stop with `kill(-pid, SIGTERM)`, wait up to 5 s, then `kill(-pid, SIGKILL)`.
- **B.** Wrap: `/bin/zsh -lc "exec setsid …"` is not available on macOS; instead use `script -q /dev/null` or enumerate children via `proc_listchildpids` and kill them individually. Less clean.

Pipes: read on a `DispatchQueue(label:"portside.io")` via `readabilityHandler`, split by `\n`, strip/keep ANSI (keep; render colors in Phase 5), append to `LogBuffer` (capacity 10 000 lines, `OSAllocatedUnfairLock`-guarded, publishes batched updates to main at ≤30 Hz).

Status derivation: `SiteStatus` computed from all `ManagedProcess.state`; published to `SiteStore` so rows update. Exit codes ≠ 0 → `.exited(code)` → red dot + "Exited (1)" tooltip; log buffer keeps the output.

Menu bar actions: row ▶ starts all processes of the site (sequentially, main first, 300 ms stagger); ■ stops all. "Start All" / "Stop All" in the footer. Sites with `autoStart` start on launch.

**Quit**: `applicationShouldTerminate` → `.terminateLater`; stop every site (SIGTERM, 5 s grace, SIGKILL), stop caddy, then `reply(toApplicationShouldTerminate: true)`. Also install `SIGTERM`/`SIGINT` handlers that do the same so `kill <Portside>` doesn't orphan servers.

**Verify:** Tests spawn `sh -c 'sleep 30 & wait'` and prove the child is gone after `stop()`. Manual: start a Vite project, stop, `lsof -i :5474` empty.

### Phase 4 — DNS + resolver (½–1 day)

1. `DNSServer` with SwiftNIO `DatagramBootstrap` on `127.0.0.1:35353` (configurable). Parse the question; for any name ending in `.test` answer **A → 127.0.0.1** and **AAAA → ::1** (answer AAAA too, otherwise Safari/Chrome stall on IPv6 lookup timeouts). TTL 60. For anything else respond `NXDOMAIN`. Handle only `QTYPE` A/AAAA/ANY; others → empty NOERROR.
2. `ResolverInstaller.ensureInstalled()`: check `/etc/resolver/test` exists with expected content. If not, prompt (first-run UI explaining why) then run via `NSAppleScript`:
   ```
   do shell script "mkdir -p /etc/resolver && printf 'nameserver 127.0.0.1\\nport 35353\\n' > /etc/resolver/test" with administrator privileges
   ```
   Then `dscacheutil -flushcache; killall -HUP mDNSResponder` (also via the same privileged call).
3. Health check in Settings: "DNS: ✓ resolver installed · ✓ responding" with a "Repair" button. Use `getaddrinfo("portside-selftest.test")` to self-test.

**Verify:** `dig @127.0.0.1 -p 35353 smartcity.test` returns `127.0.0.1`; `ping smartcity.test` resolves after resolver file exists.

### Phase 5 — Proxy (Caddy) (1 day)

1. `scripts/fetch-caddy.sh`: download the latest Caddy release for `darwin_arm64` and `darwin_amd64`, `lipo -create` into a universal `Resources/caddy`, `chmod +x`, verify checksum. Pin version in `scripts/CADDY_VERSION`.
2. `ProxyManager.start()`: launch `<bundle>/Contents/MacOS/caddy run --config <appsupport>/caddy.json --adapter json` as a child process (also killed on quit; same process-group handling). Admin endpoint on `127.0.0.1:2019` (configurable). Wait for `/config/` to respond.
3. `CaddyConfigBuilder.build(sites:) -> Data` produces JSON:
   ```json
   {
     "admin": { "listen": "127.0.0.1:2019" },
     "apps": { "http": { "servers": { "portside": {
       "listen": [":80"],
       "routes": [
         { "match": [{ "host": ["smartcity.test"] }],
           "handle": [{ "handler": "reverse_proxy", "upstreams": [{ "dial": "localhost:5474" }] }],
           "terminal": true },
         { "match": [{ "host": ["api.smartcity.test"] }],
           "handle": [{ "handler": "reverse_proxy", "upstreams": [{ "dial": "localhost:8185" }] }],
           "terminal": true },
         { "handle": [{ "handler": "static_response", "status_code": 502,
             "body": "<html>…Portside: no site for this host…</html>" }] }
       ]
     }}}}
   }
   ```
   - Routes for **all** configured sites exist regardless of running state (so a stopped site shows a friendly Portside "site is stopped — start it from the menu bar" page instead of a connection error). Implement by pointing the reverse_proxy at the upstream and letting `handle_errors` render a Portside-branded 502 page with the site name and a hint.
   - Static site (empty command): `file_server` with `root` = site folder, `browse` off, `index.html` default.
   - `reverse_proxy` with default `transport` passes WebSocket upgrades; also set `headers.request.set.Host = ["{http.request.host}"]`? **No** — most dev servers (Vite) check Host and expect `localhost`. Default Caddy behavior (passes original Host) breaks Vite's host check. Set `"headers": {"request": {"set": {"Host": ["{http.reverse_proxy.upstream.hostport}"]}}}` and add `X-Forwarded-Host`. Make this a per-process toggle "Preserve Host header" (default off) for backends that need the real host.
4. On every `SiteStore` change: rebuild JSON → `POST http://127.0.0.1:2019/load` (Content-Type application/json). Debounce 200 ms.
5. `PortChecker`: before starting caddy, test bind on `:80`. If occupied, identify the owner (`lsof -nP -iTCP:80 -sTCP:LISTEN`) and show in menu bar: "⚠ Port 80 is used by nginx (pid 123)". Offer Settings → alternate port (e.g. 8080) which then produces URLs like `smartcity.test:8080` (shown in UI).
6. Add Caddy's `vite`-friendly bits: `"flush_interval": -1` for streaming/SSE; `"read_timeout"`/`"write_timeout"` none.

**Verify:** Start a site; `curl -H 'Host: smartcity.test' 127.0.0.1` returns the dev server's HTML; open `http://smartcity.test` in a browser; Vite HMR works (edit a file, browser updates). Unit tests for `CaddyConfigBuilder` with golden JSON.

### Phase 6 — Logs window (1 day)

- One `NSWindow` per site (`Window` scene keyed by site id, or `NSWindowController` cache). Title: `smartcity — Logs`. Remember size/position per site.
- `TabView` with one tab per process, **main first**, then extras in configured order. Tab label = process label; small dot shows that process's state.
- `LogTextView`: `NSTextView` (read-only, monospaced 12pt, dark background), ANSI color rendering (write a small ANSI→`NSAttributedString` parser; support SGR 0,1,30–37,90–97, 38;5;n), append-only with coalesced updates, autoscroll with "⤓ Follow" toggle that disables when the user scrolls up, "Clear", "Copy all", search field (⌘F) with highlight, line count badge.
- Toolbar per tab: ▶/■/↻ for that single process, "Open in browser" if it has a domain, "Reveal folder in Finder", "Open in Terminal/iTerm" (`open -a iTerm <folder>` if installed else Terminal).
- Keep last 10 000 lines; show "… older lines dropped" banner when trimmed.

**Verify:** Logs appear live for two processes, colors render, follow toggle behaves, window restores.

### Phase 7 — Updates with Sparkle, release pipeline (1 day)

Free path (no Apple Developer account):
1. Generate Sparkle EdDSA keys once locally: `./bin/generate_keys` → private key stays in Keychain / GitHub secret `SPARKLE_PRIVATE_KEY`; public key → `Info.plist` `SUPublicEDKey`.
2. `SUFeedURL = https://github.com/nicklasos/portside/releases/latest/download/appcast.xml` (stable URL; each release re-uploads `appcast.xml` as an asset). Alternative: `https://raw.githubusercontent.com/nicklasos/portside/main/appcast.xml` committed by CI. Use the releases/latest/download approach — no commit noise.
3. `UpdaterService` wraps `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`. Menu item "Check for Updates…" → `checkForUpdates()`. Settings: "Automatically check for updates" toggle, "Current version x.y.z (build n)".
4. `scripts/build-release.sh`:
   - `xcodegen`, `xcodebuild archive` (Release), export `.app`.
   - **Ad-hoc sign**: `codesign --force --deep --sign - --options runtime Portside.app` (no account needed; prevents "damaged" errors). Note: Sparkle requires the app be signed consistently between versions — ad-hoc is consistent (`-` identity).
   - Zip with `ditto -c -k --keepParent Portside.app Portside-x.y.z.zip` (Sparkle prefers zip/dmg; zip is simpler).
   - Optionally also build a `.dmg` with `create-dmg` for first-time installs.
5. `scripts/generate-appcast.sh`: `generate_appcast --ed-key-file <key> -o appcast.xml <dir with zips>`; include release notes from `CHANGELOG.md` section.
6. `release.yml`: on `v*` tag → macOS runner → build → sign → zip → appcast → `gh release create` with `.zip`, `.dmg`, `appcast.xml`, notes from changelog.
7. `docs/RELEASING.md`: bump `MARKETING_VERSION` + `CURRENT_PROJECT_VERSION` in `project.yml`, update changelog, tag, push.
8. First-run doc note in README: "macOS will say the app is from an unidentified developer. Right-click → Open once. Updates install in place and won't ask again."

**Verify:** Build v0.1.0, install, bump to v0.1.1, publish, "Check for Updates…" finds, downloads, installs and relaunches without a Gatekeeper prompt.

### Phase 8 — Icon, README, polish (1 day)

See §5 (icon) and §7 (README). Plus:
- Launch at login toggle (`SMAppService.mainApp.register()`).
- Menu bar icon reflects global state: outline bollard when nothing runs, filled when ≥1 site runs, with badge dot red if any site is partial/crashed.
- Keyboard: `⌘,` settings, `⌘Q` quit, `⌘N` new site.
- Notifications (UNUserNotificationCenter) when a process exits unexpectedly: "smartcity · API exited with code 1 — Show logs".
- `docs/ARCHITECTURE.md` distilled from this plan, kept current.

### Phase 9 — v1.1 backlog (not for first release)

- HTTPS via Caddy internal CA (`tls internal`), with one-time "trust Portside CA" prompt (`security add-trusted-cert`). Then `https://smartcity.test`.
- Import from `Procfile` / detect `package.json` scripts & `Makefile` targets to suggest commands.
- Env var editor per process; `.env` file loading.
- Per-process restart-on-crash with backoff.
- Spotlight/Raycast-style quick switcher (`⌥Space`) to open any site URL.
- Export/import `sites.json`; optional sync of config via `~/.config/portside`.
- CLI `portside start smartcity` talking to the app over a UNIX socket.
- Drag-reorder sites and processes.

---

## 5. Icon & brand

### Concept: the bollard

A **bollard** — the short, sturdy post on a quay that ships tie their lines to — is the Portside mark. It is literal (port side, mooring), geometric enough to read at 16 px, and maps to the product: each running site is a line made fast to the post. The status dot sits on top like the bollard's cap.

### App icon (1024 × 1024, macOS 14 squircle)

- **Background:** deep navy → teal vertical gradient (`#0B1E3A` top → `#0F3D5E` bottom), subtle horizontal "waterline" at ~70 % height: a lighter band `#1C5A80` with a faint sine ripple; the bollard's base sits on the waterline.
- **Bollard:** centered, off-white `#F4F1EA`, about 55 % of canvas height. Shape: a rounded cylinder (width ≈ 30 % canvas) with a wider rounded cap (≈ 40 % width) and a slightly flared base. Soft bottom shadow onto the water. One thin dark groove below the cap for depth.
- **Rope:** a single mustard/orange rope `#F2A33C` loops once around the post just under the cap and trails off to the lower-right, ending outside the squircle (cropped). Rope thickness ≈ 4 % of canvas. This is the "line made fast" — the one warm color.
- **Status cap:** the very top of the bollard carries a small green dot `#34C759` (Apple system green) — the same dot used in the UI. On the icon it reads as a navigation light.
- **No text.** No bevels or glossy highlights; flat with one soft shadow (macOS 14 style).

### Menu bar glyph (template image, 18 × 18 pt @1x/@2x)

- Monochrome black, `isTemplate = true` so macOS tints it for light/dark menu bars.
- Simplified bollard silhouette: cap (rounded rect 12 × 4), post (rounded rect 8 × 9), base (rounded rect 12 × 2). Two states as separate assets: `menubar-idle` (outlined, 1.5 pt stroke) and `menubar-active` (filled). The red "attention" badge is drawn programmatically (a 5 pt circle at top-right) so it keeps color despite the template.

### Deliverables & how to produce them

1. `assets/icon/portside.svg` — hand-write the SVG (simple shapes: rects with `rx`, one `path` for the rope, two gradients). Target ~40 lines.
2. `assets/icon/generate-icns.sh` — render SVG → PNG at 16, 32, 64, 128, 256, 512, 1024 (+@2x) with `rsvg-convert` (`brew install librsvg`) or `qlmanage -t`, build `Portside.iconset`, then `iconutil -c icns`. Copy sizes into `Assets.xcassets/AppIcon.appiconset` with its `Contents.json`.
3. `assets/icon/menubar-template.svg` → `Assets.xcassets/MenuBarIdle.imageset` & `MenuBarActive.imageset` (PNG 18/36/54 px, "Render As: Template").
4. `assets/icon/portside-1024.png` and `assets/icon/portside-256.png` for the README header and GitHub social preview.
5. GitHub repo: set social preview to a 1280 × 640 banner: icon left, "Portside" wordmark (SF Pro Rounded Semibold, `#F4F1EA`) right, tagline "Local dev servers, on `.test` domains." Export from an HTML/SVG template in `assets/banner/`.

### Wordmark

"Portside" in **SF Pro Rounded Semibold** (free with macOS) in the UI's About panel; `#0B1E3A` on light, `#F4F1EA` on dark. No custom font needed.

---

## 6. UI specification notes

### 6.1 Menu bar popover

```
┌─────────────────────────────────────────────┐
│ Portside                          ⚙  ⟳     │
├─────────────────────────────────────────────┤
│ ● smartcity                 ■  ☰  ↗  ⋯      │   ● green = running
│   smartcity.test · api.smartcity.test       │
│ ○ blog                      ▶  ☰  ↗  ⋯      │   ○ grey = stopped
│   blog.test                                 │
│ ● crm                       ■  ☰  ↗  ⋯      │   ● red = partial (API exited 1)
│   crm.test · admin.crm.test                 │
├─────────────────────────────────────────────┤
│ ＋ Add Site…                           ⌘N   │
│   Start All        Stop All                 │
├─────────────────────────────────────────────┤
│ Check for Updates…                          │
│ Settings…                              ⌘,   │
│ Quit Portside                          ⌘Q   │
└─────────────────────────────────────────────┘
```
- ▶/■ toggles start/stop; ☰ opens logs window; ↗ opens main URL; ⋯ menu → Edit…, Open folder, Open in Terminal, Duplicate, Delete….
- Row hover highlights; status dot animates (pulse) while `.starting`.
- Width ~340 pt; scroll when > 8 sites.

### 6.2 Settings

Tabs: **General** (launch at login, auto-check updates, notifications), **Network** (proxy port default 80, DNS port default 35353, "Preserve Host header" default, repair resolver), **Advanced** (Caddy admin port, open config folder, reveal logs folder, reset).

### 6.3 Static sites

If `main.command` is empty, Portside does not spawn a process; Caddy serves `folder` with `file_server`. Status dot green when the site is "enabled" (toggle instead of ▶). Logs tab shows Caddy access log for that host (enable `log` in the route with a per-site file, tail it).

---

## 7. README specification

`README.md` structure (write it in Phase 8 with real screenshots):

1. **Header:** centered `assets/icon/portside-256.png`, `# Portside`, one-line tagline, badges (latest release, CI, macOS 14+, MIT, downloads).
2. **Hero screenshot:** `assets/screenshots/menubar.png` (popover open with 3 sites in mixed states, on a dark desktop, retina, shadow preserved).
3. **What it does** — 4 bullets: `*.test` domains → local ports · one-click start/stop of all processes · tabbed logs · additional processes on subdomains.
4. **Install** — download `.dmg` from Releases, drag to Applications, **right-click → Open** the first time (explain why: unsigned, free project), allow the one admin prompt (explains `/etc/resolver/test`). Homebrew cask (`brew install --cask nicklasos/tap/portside`) as a stretch goal.
5. **Quick start** — screenshot `editor.png`; 5 numbered steps from "Add Site" to opening `smartcity.test`.
6. **How it works** — the ASCII/flow diagram from §1 (render it as an SVG in `assets/diagram.svg` for prettiness), short paragraphs on DNS, proxy, process groups.
7. **Logs** — screenshot `logs.png`.
8. **FAQ** — port 80 in use; Vite "Invalid Host header"; command not found (login shell/PATH); HTTPS?; uninstall (`sudo rm /etc/resolver/test`, delete app + Application Support).
9. **Development** — `./scripts/bootstrap.sh`, `xcodegen`, open in Xcode, tests; link to `docs/ARCHITECTURE.md`.
10. **Releasing** — link to `docs/RELEASING.md`.
11. **Acknowledgements** — Laravel Herd (inspiration), puma-dev (resolver technique), Caddy, Sparkle.
12. **License** — MIT.

Screenshots: capture with `⌘⇧4` + Space on a 2× display, keep window shadow, save PNG, run through `pngquant`/`oxipng`. Use the same three demo sites (`smartcity`, `blog`, `crm`) in every shot for consistency.

---

## 8. Testing strategy

- **Unit:** `CaddyConfigBuilder` (golden JSON), `SiteStore` (CRUD, validation, persistence), DNS packet parse/answer, ANSI parser, process-group termination.
- **Integration (manual checklist in `docs/TESTING.md`):** fresh macOS user → first run → resolver prompt → add Vite site → open in Safari & Chrome → HMR works → add API extra → `api.<site>.test` works → stop → friendly stopped page → quit → `lsof -i :80` and `:5474` empty.
- **CI:** build + unit tests on `macos-14`. No UI tests in v1.

---

## 9. Caddy bundling details

- Pin `CADDY_VERSION=2.8.4` (or latest 2.x at implementation time; check https://github.com/caddyserver/caddy/releases).
- URLs: `https://github.com/caddyserver/caddy/releases/download/v${V}/caddy_${V}_mac_arm64.tar.gz` and `…_mac_amd64.tar.gz`. Extract, `lipo -create -output caddy caddy_arm64 caddy_amd64`.
- Verify SHA-256 against `caddy_${V}_checksums.txt`.
- Caddy is Apache-2.0; include its LICENSE in `Portside.app/Contents/Resources/Licenses/` and credit in About + README.
- Run caddy with `XDG_CONFIG_HOME`/`XDG_DATA_HOME` pointed into Portside's Application Support so it never touches `~/.config`.

---

## 10. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Port 80 occupied (Docker, Herd, nginx, Apache) | Detect, show owner, allow alternate proxy port |
| Vite/Next reject `Host: smartcity.test` | Rewrite Host to upstream by default; per-process "preserve host" toggle; document `server.allowedHosts` for Vite 6 |
| Orphaned child processes | Process-group spawn/kill; verified by tests; SIGTERM handler on quit |
| Login shell slow (nvm) → delayed start | Show "starting" state; it's a one-time cost per process |
| Gatekeeper friction (unsigned) | Clear README; Sparkle updates avoid repeat prompts; keep ad-hoc identity stable |
| `/etc/resolver` removed by OS update | Health check + Repair button on every launch |
| IPv6 lookups stalling browsers | DNS answers AAAA `::1`, Caddy listens on both stacks |
| User edits site while running | Reconfigure proxy live; restart only affected processes |

---

## 11. Definition of done for v1.0.0

- [ ] Menu bar app with site list, status dots, start/stop, logs, open-URL, add/edit/delete.
- [ ] `*.test` resolution and reverse proxy working for main + subdomain processes, incl. WebSockets.
- [ ] All processes of a site start/stop together; quit kills everything.
- [ ] Tabbed log window with ANSI colors.
- [ ] Static-folder sites.
- [ ] "Check for Updates…" working end-to-end from GitHub Releases via Sparkle.
- [ ] App icon + menu bar glyph + README with three screenshots and banner.
- [ ] CI green; release workflow produces `.zip`, `.dmg`, `appcast.xml`.
- [ ] `docs/ARCHITECTURE.md`, `docs/RELEASING.md`, `docs/TESTING.md` present.
