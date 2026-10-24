# Changelog

All notable changes to this project are documented here.

## [Unreleased]

## [0.2.0] - 2026-10-24

### Added

- Per-site commands, such as a deploy, run from the site's … menu in the popover. The site editor has a **Commands** tab where each command gets a name, a shell line, a folder, and a **Show logs** switch. With **Show logs** on, the logs window opens on the command's tab. With it off, the command runs in the background and a notification says whether it finished or failed.

### Fixed

- Clicking the menu bar icon brings open Logs and Site windows back in front of other apps' windows, since a menu bar app has no ⌘Tab entry to reach them.

## [0.1.0] - 2026-10-21

### Added

- Menu bar popover listing sites with status dots, start/stop, logs, open and a per-site menu.
- Site editor with live URL previews, inline validation and additional processes on subdomains.
- Choosing a folder in the site editor fills the name from the folder and the port from the project's `.env` files, and says which key the port came from. A port you typed stays, and a **Use** button offers the `.env` value.
- Choosing a folder also fills the command that runs its dev server, such as `npm run dev` from `package.json`, `make dev` from a Makefile, or `php artisan serve --port=$PORT` for Laravel, and says which file it came from. A command you typed stays.
- An empty command now says the site is static under the field, and the command placeholder reads `e.g. npm run dev` instead of cycling through examples that looked like a filled value. A static site's switch in the menu says it serves the folder.
- Process manager that runs each command in its own process group under an interactive login shell and stops the whole group.
- A choice of domain suffix on first launch and in Settings: `.localhost` (the default), `.test`, `.loc`, `.local`, or a custom suffix. Each option shows what it needs on this Mac. Real public TLDs and HSTS-preloaded TLDs such as `.dev` are refused.
- `.localhost` works with no password on Macs that resolve it, which Portside checks at launch. Other suffixes use a DNS server and a guarded `/etc/resolver/<suffix>` installer that asks before it replaces another tool's resolver. Settings removes a resolver file Portside no longer uses.
- An end-to-end check that resolves `portside-selftest.<suffix>`, fetches it through Caddy, and names the step that fails.
- Bundled Caddy 2.11.7 reverse proxy with live reconfiguration, branded stopped and unknown-host pages, and static folder sites.
- Tabbed logs window with ANSI colors, search, clear and copy. It shows the newest 1,000 lines with a button to load earlier ones, opens at the newest line, and follows new output only when you turn Follow on.
- Settings for ports, launch at login, notifications and log mirroring.
- Crash notifications, Sparkle updates, ad-hoc signed release builds and an appcast pipeline.
