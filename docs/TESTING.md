# Testing Portside

Portside has two kinds of tests. The unit tests in [`PortsideTests`](../PortsideTests) run in CI on every push and pull request. The manual checklist below covers what unit tests cannot reach: the admin prompt, the system resolver, real browsers, and port 80.

## Run the unit tests

Run the whole suite from the repository root:

```sh
xcodebuild -project Portside.xcodeproj -scheme Portside -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

This is the command CI runs in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). The suite has 48 tests, which run in about 13 seconds after the build. It needs no network, no administrator password, and no bundled Caddy. The process tests spawn real `/bin/zsh` processes, and the DNS tests bind UDP sockets on loopback.

To run one test class, add `-only-testing`:

```sh
xcodebuild -project Portside.xcodeproj -scheme Portside -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -only-testing:PortsideTests/ProcessManagerTests test
```

You can also press ⌘U in Xcode.

## Unit test inventory

To list every test, run:

```sh
grep -h "func test" PortsideTests/*.swift
```

### `CaddyConfigBuilderTests`

These tests compare the builder's output byte for byte with the golden files in [`PortsideTests/Fixtures`](../PortsideTests/Fixtures).

| Test | Checks |
| --- | --- |
| `testPlanExampleSmartcityWithApiExtra` | A site with an `api` extra produces two proxy routes, the 502 error route, and the 404 fallback. |
| `testPreserveHostPassesOriginalHost` | A process with `preserveHost` gets no `Host` rewrite. |
| `testStaticSiteEnabledServesFolderWithAccessLog` | An enabled static site gets a `file_server` route and its own access log. |
| `testStaticSiteDisabledShowsStoppedPage` | A disabled static site gets the 503 page. |
| `testNoSitesOnlyHasUnknownHostFallback` | No sites means only the 404 fallback route. |
| `testAllSitesOnAlternateProxyPort` | Every route works with the proxy on port 8080. |
| `testOutputIsIndependentOfSiteOrder` | Reordering sites does not change the JSON. |
| `testAccessLogPath` | The access log path is `<logs>/<site>/access.log`. |

### `DNSServerTests`

| Test | Checks |
| --- | --- |
| `testAQueryUnderTestAnswersIPv4Loopback` | An A query under `.test` gets `127.0.0.1`. |
| `testSelfTestNameGetsPortsideOnlyAddress` | `portside-selftest.test` gets `127.0.0.53`. |
| `testAAAAQueryAnswersIPv6Loopback` | An AAAA query gets `::1`. |
| `testAnyQueryAnswersBothFamilies` | An ANY query gets both records. |
| `testOtherTypesUnderTestAreEmptyNoError` | Other record types get an empty NOERROR reply. |
| `testUppercaseNameMatchesAndQuestionIsEchoedVerbatim` | Matching ignores case, and the reply echoes the question as sent. |
| `testNameOutsideTestIsNXDomainWithoutAuthority` | Names outside `.test` get NXDOMAIN. |
| `testNameThatOnlyContainsTestIsNotInZone` | A name such as `test.example` is not in the zone. |
| `testMalformedPacketsAreDropped` | Short, truncated, and malformed packets get no reply. |
| `testServesQueriesOverUDP` | A started server answers a real UDP query. |
| `testResolverContentCheck` | `ResolverInstaller.status` reports installed, missing, and mismatched files. |
| `testResolverInstallScriptWritesExpectedFile` | The privileged shell command writes the expected resolver file. |
| `testLsofFieldParsing` | `PortChecker` parses the pid and command from `lsof -F pc` output. |
| `testPortCheckerSeesAListener` | `PortChecker` reports a bound UDP port as busy. |

### `LogBufferTests`

| Test | Checks |
| --- | --- |
| `testJoinsPartialLinesAcrossChunksAndTreatsCRLFAsOneNewline` | Lines split across reads are joined, and `\r\n` ends one line. |
| `testFlushEmitsUnterminatedTail` | A last line with no newline appears after `flush()`. |
| `testKeepsAnsiEscapesAndLoneCarriageReturns` | Color codes and a lone `\r` stay in the text. |
| `testTrimsToCapacityAndCountsDropped` | Lines past capacity are dropped and counted. |
| `testClearEmptiesLinesButKeepsTotal` | `clear()` empties the buffer and keeps the total count. |
| `testRevisionBumpsOnMainAfterAppendsAndCoalesces` | 500 appends bump `revision` once. |
| `testMirrorsLinesToDisk` | Mirrored lines reach the log file. |

### `ProcessManagerTests`

| Test | Checks |
| --- | --- |
| `testStopKillsTheWholeProcessGroup` | Stopping a site kills the shell and the child it forked. |
| `testStartingBecomesRunningAndRequestedStopDoesNotReportAnExit` | A process moves from `starting` to `running`, and a requested stop does not call `onUnexpectedExit`. |
| `testProcessExitingOnItsOwnReportsItsCode` | A process that exits on its own reports `exited(code)`. |
| `testSignalDeathMapsTo128PlusSignal` | A process killed by a signal reports `128 + signal`. |
| `testEnvironmentReachesTheChild` | `PORT`, `PORTSIDE_SITE`, and the other variables reach the command. |
| `testProcessIgnoringSigtermIsKilledWithinSixSeconds` | A process that ignores `SIGTERM` gets `SIGKILL` after the 5 second grace period. |
| `testApplyRestartsOnlyChangedProcessesAndStopsRemovedOnes` | Editing a running site restarts only the changed processes. |
| `testStaticSiteTogglesWithoutSpawningMain` | Starting a static site enables the folder without a process, starts extras that have a command, and leaves extras with a blank command stopped. |
| `testBadWorkingDirectoryFails` | A missing working directory gives `failed`. |
| `testRelaunchKillsGroupsLeftByACrashedRun` | A new `ProcessManager` kills the groups recorded in `pids.json` by a crashed run. |

### `SiteStoreTests`

| Test | Checks |
| --- | --- |
| `testAddEditDeleteRoundTripsThroughDisk` | Add, edit, and delete survive a reload from `sites.json`. |
| `testFileHasVersionEnvelope` | `sites.json` has `version: 1` and a `sites` array. |
| `testLoadToleratesUnknownAndMissingKeys` | Loading ignores unknown keys and fills in defaults. |
| `testRejectsInvalidAndDuplicateNames` | Invalid and duplicate names block a save. |
| `testRejectsMissingFolderBadPortAndDuplicateSubdomain` | A missing folder, a bad port, and a repeated subdomain block a save. |
| `testSharedUpstreamIsWarningNotError` | Two processes on one `host:port` give a warning, not an error. |
| `testDuplicateGetsFreshIdsAndName` | Duplicating a site gives new ids and a `-copy` name. |
| `testSanitizeLabel` | Name input is lowercased and stripped to `[a-z0-9-]`. |
| `testSiteStatusDerivation` | `SiteStatus` follows from the process states. |

## Manual integration checklist

Run this checklist before a release, on a release build from [`scripts/build-release.sh`](../scripts/build-release.sh). Each step says what you should see.

### Prepare

- [ ] Create a new macOS user account in **System Settings > Users & Groups** and log in to it. A fresh account has no Portside settings and no `/etc/resolver/test` from an earlier install, unless another user created one.
- [ ] Remove an old resolver file, if there is one: `sudo rm -f /etc/resolver/test`.
- [ ] Create a Vite project: `npm create vite@latest smartcity -- --template vanilla`, then `cd smartcity && npm install`.
- [ ] Check that port 80 is free: `lsof -nP -iTCP:80 -sTCP:LISTEN` prints nothing.

### First run

- [ ] Copy `Portside.app` to `/Applications` and open it. macOS blocks the first launch because the app is not notarized. On macOS 14, Control-click the app and choose **Open**. On macOS 15 or later, open **System Settings > Privacy & Security** and click **Open Anyway**.
- [ ] The Portside icon appears in the menu bar. No Dock icon appears.
- [ ] Portside explains the resolver and asks for your administrator password. Enter it.
- [ ] `cat /etc/resolver/test` prints `nameserver 127.0.0.1` and `port 35353`.
- [ ] `dig @127.0.0.1 -p 35353 smartcity.test +short` prints `127.0.0.1`.
- [ ] `dig @127.0.0.1 -p 35353 portside-selftest.test +short` prints `127.0.0.53`.
- [ ] `dscacheutil -q host -a name smartcity.test` lists `127.0.0.1`. This proves macOS sends `.test` lookups to Portside.
- [ ] **Settings > Network** shows the resolver as installed and responding.

### A Vite site

- [ ] Click **Add Site**. Enter the name `smartcity`, choose the Vite project folder, enter the command `npm run dev -- --port 5474 --strictPort`, and enter the port `5474`. Click **Save**.
- [ ] Click the start button. The dot pulses while the site starts, then turns green.
- [ ] Open the logs window. The Vite banner appears with its colors.
- [ ] `curl -s -o /dev/null -w '%{http_code}\n' http://smartcity.test` prints `200`.
- [ ] Open `http://smartcity.test` in Safari and in Chrome. Both show the Vite page with no "Blocked request" error.
- [ ] Edit `main.js` and save. Both browsers update without a full reload. This proves the HMR WebSocket passes through Caddy.

### An extra process on a subdomain

- [ ] Edit the site. Add a process with the label `API`, the subdomain `api`, the command `python3 -m http.server 8185`, and the port `8185`. Save while the site runs.
- [ ] Only the new API process starts. The Vite process keeps its pid, which the `▶` line in its log shows.
- [ ] `curl -s http://api.smartcity.test/ | head -n 3` prints the directory listing from Python.
- [ ] Find the API's pid in its log and run `kill <pid>`. The site's dot turns red, the API row shows the exit code, and a notification appears.

### Stopped and unknown sites

- [ ] Stop the site. The dot turns grey.
- [ ] `lsof -nP -iTCP:5474 -sTCP:LISTEN` and `lsof -nP -iTCP:8185 -sTCP:LISTEN` print nothing.
- [ ] Open `http://smartcity.test`. A Portside page says the site is not running and to start it from the Portside menu bar. `curl` reports status `502`.
- [ ] Open `http://nothing-here.test`. A Portside page says there is no site for this host. `curl` reports status `404`.

### A static site

- [ ] Create a folder with an `index.html`. Add a site named `blog` with that folder, an empty command, and any port.
- [ ] Turn the site on. `http://blog.test` shows the `index.html`.
- [ ] Turn the site off. `http://blog.test` shows the not-running page, and `curl` reports status `503`.

### Port 80 is busy

- [ ] Quit Portside. Run `python3 -m http.server 80` in a terminal, then open Portside.
- [ ] Portside says port 80 is in use and names the Python process and its pid.
- [ ] In **Settings > Network**, set the proxy port to `8080`. Every URL in the menu now ends in `:8080`.
- [ ] `curl -s -o /dev/null -w '%{http_code}\n' http://smartcity.test:8080` prints `200` while the site runs.
- [ ] Stop the Python server and set the proxy port back to `80`.

### Laravel Herd or Valet

Run this section on a Mac with Herd or Valet installed. Both write `nameserver 127.0.0.1` to `/etc/resolver/test` and both use port 80.

- [ ] Open Portside. It says the resolver file belongs to another tool and asks before it replaces the file.
- [ ] Decline. `.test` lookups keep going to Herd, and the DNS health check in **Settings** fails.
- [ ] Repair the resolver from **Settings** and accept. `cat /etc/resolver/test` shows `port 35353`, and the self-test passes.
- [ ] Portside reports port 80 in use by Herd's nginx. Move the proxy to port 8080 and check that `http://smartcity.test:8080` works.
- [ ] Switch back to Herd with Herd's own repair, or with `sudo sh -c 'printf "nameserver 127.0.0.1\n" > /etc/resolver/test'`. Herd sites resolve again.

### Quit and crash recovery

- [ ] Start the site, then choose **Quit Portside**. Afterwards, `lsof -nP -iTCP:80 -sTCP:LISTEN`, `lsof -nP -iTCP:5474 -sTCP:LISTEN`, and `pgrep -x caddy` print nothing.
- [ ] Open Portside and start the site again. Run `pkill -9 -x Portside`. The dev server and Caddy keep running.
- [ ] Open Portside again. Within a few seconds, `lsof -nP -iTCP:5474 -sTCP:LISTEN` prints nothing, and only the new Caddy listens on port 80.
