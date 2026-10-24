# Testing Portside

Portside has two kinds of tests. The unit tests in [`PortsideTests`](../PortsideTests) run in CI on every push and pull request. The manual checklist below covers what unit tests cannot reach: the admin prompt, the system resolver, real browsers, and port 80.

## Run the unit tests

Run the whole suite from the repository root:

```sh
xcodebuild -project Portside.xcodeproj -scheme Portside -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

This is the command CI runs in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). The suite has 165 tests, which run in about 30 seconds after the build. `grep -h "func test" PortsideTests/*.swift | wc -l` counts them. It needs no network, no administrator password, and no bundled Caddy. The process tests spawn real `/bin/zsh` processes, and the DNS tests bind UDP sockets on loopback.

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
| `testBlogWithApiExtra` | A site with an `api` extra produces the self-test route, two proxy routes, the 502 error route, and the 404 fallback. |
| `testLocalhostSuffixMatchesLocalhostHosts` | The same site under `.localhost` matches `blog.localhost` and `api.blog.localhost`. |
| `testCustomSuffixRoutesStaticSiteAndItsAccessLog` | Under `.loc`, every host ends in `.loc`. |
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
| `testZoneIsAParameter` | A server for `localhost` answers `blog.localhost`, rejects `.test` names, and a `loc` server answers `portside-selftest.loc` with `127.0.0.53`. |
| `testMalformedPacketsAreDropped` | Short, truncated, and malformed packets get no reply. |
| `testServesQueriesOverUDP` | A started server answers a real UDP query. |
| `testResolverContentCheck` | `ResolverInstaller.status` reports installed, missing, and mismatched files. |
| `testResolverInstallScriptWritesExpectedFile` | The privileged shell command writes `/etc/resolver/<suffix>` for the given suffix. |
| `testResolverUninstallRemovesOnlyPortsidesFile` | Run against a temporary directory, the uninstall command keeps another tool's file and a Portside file for another port, and removes Portside's exact file. |
| `testLsofFieldParsing` | `PortChecker` parses the pid and command from `lsof -F pc` output. |
| `testPortCheckerSeesAListener` | `PortChecker` reports a bound UDP port as busy. |

### `DomainSuffixTests`

| Test | Checks |
| --- | --- |
| `testPresetsHaveLabelAndDisplay` | The presets are `.localhost`, `.test`, `.loc`, and `.local`. |
| `testCustomAcceptsOneLabelAndNormalizes` | A custom suffix accepts a leading dot and uppercase letters. |
| `testCustomRejectsMalformedLabels` | Empty, dotted, dashed at either end, underscored, spaced, and all-digit labels are rejected. |
| `testCustomRejectsRealAndHSTSPreloadedTLDs` | `com`, `dev`, `app`, and other real TLDs are rejected with a reason. |
| `testCustomPointsPresetsToTheirOption` | Typing a preset label points to its option. |
| `testNameCheckExplainsEachKindOfName` | Reserved names pass, `.local` warns about Bonjour, and `.loc`, `.lan`, `.internal`, and `.home` warn about collisions. |
| `testCodableRoundTripsAsTheLabel` | A suffix encodes as its label, and an unusable label fails to decode. |
| `testStoredSuffixFallsBackToLocalhost` | An unusable stored suffix loads as `.localhost`. |
| `testDomainsDeriveFromNameSubdomainAndSuffix` | Domains come from the name, the subdomain, and the suffix. |
| `testSystemResolverLoopbackCheck` | Only `127.0.0.0/8` and `::1` count as loopback. |

### `SuffixCheckTests`

These tests script the lookup and the HTTP request through `SuffixProbes`.

| Test | Checks |
| --- | --- |
| `testSystemResolvedSuffixWorksWithoutSetup` | A suffix that resolves to loopback with no resolver file gets the `system` strategy and three passing lines. |
| `testUnresolvedSuffixNeedsTheResolverFile` | A suffix that does not resolve needs `/etc/resolver/<suffix>`. |
| `testOnlyAnAllLoopbackAnswerCountsAsSystemResolved` | A lookup that also returns a public address does not count. |
| `testForeignResolverFileIsATakeoverEvenWhenItResolves` | Herd's `.test` file makes `.test` need Portside's DNS and shows the file's content. |
| `testPortsidesOwnResolverFileIsReady` | Portside's own file passes. |
| `testLocalIsOfferedWithItsBonjourWarning` | `.local` gets a warning, not a rejection. |
| `testEndToEndPassesWhenNameAndProxyBothAnswer` | The check passes for both strategies when DNS and Caddy answer. |
| `testEndToEndBlamesDNSFirst` | A wrong DNS answer fails the DNS step. |
| `testEndToEndNamesTheProxyPortOwner` | A port conflict names the program that holds the port. |
| `testEndToEndReportsCaddyDown` | A stopped Caddy, a refused connection, and another server on the port each fail the proxy step. |
| `testLoopbackHTTPSendsTheHostHeaderAndReadsTheReply` | The real socket request sends the `Host` header and parses the reply. |
| `testLoopbackHTTPReportsAClosedPort` | A closed port gives `unreachable`. |

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
| `testCommandOutputIsCapturedAndFinishingReportsItsCodeNotACrash` | A site command's output lands in its buffer, and its exit code 0 or 2 reaches `onCommandFinished`, never `onUnexpectedExit`. |
| `testCommandRunsInItsFolderWithTheSiteEnvironment` | A command runs in its own folder and gets `PORTSIDE`, `PORTSIDE_SITE`, and `PORTSIDE_URL` but no `PORT`. |
| `testStoppingASiteLeavesItsRunningCommandAlive` | Stopping a site leaves its running command alive, and stopping the command reports no finish. |
| `testApplyStopsARunningCommandThatWasRemoved` | Saving a site without a running command stops that command. |
| `testRelaunchKillsGroupsLeftByACrashedRun` | A new `ProcessManager` kills the groups recorded in `pids.json` by a crashed run. |

### `PortsideControllerTests`

| Test | Checks |
| --- | --- |
| `testURLsCarryANonDefaultProxyPort` | URLs use `.localhost` by default and gain a non-default proxy port. |
| `testSystemResolvedSuffixRunsNoDNSServer` | Choosing a suffix that macOS resolves leaves the DNS server stopped and asks for no resolver. |
| `testSuffixNeedingPortsideDNSStartsItForThatZoneAndAsksForTheResolver` | Choosing `.test` starts the DNS server and asks for the resolver. Switching back to `.localhost` stops the server. |
| `testSuffixChangeWhileRunningAsksForRestart` | A suffix change while a site runs sets the `PORTSIDE_URL` restart notice. |
| `testOnlyPortsidesOwnLeftoverResolverIsOfferedForRemoval` | After a switch, only Portside's own file for the old suffix is offered for removal. |
| `testSuffixSurvivesRelaunch` | The suffix and the onboarding flag persist. |
| `testRunningACommandThatShowsLogsSelectsItsTab` | Running a command with **Show logs** selects its logs tab. A background command leaves the tab alone. |
| `testSavingAStoppedSiteWithoutARunningCommandStopsIt` | Removing a running command from a stopped site stops it and gives no notice. |
| `testDeletingASiteStopsItsCommands` | Deleting a site stops its running commands. |

The other tests in this class cover start, stop, save, delete, and the menu bar status.

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
| `testSitesWithoutCommandsLoadAndCommandsRoundTrip` | A `sites.json` without `commands` loads, and saved commands survive a reload. |
| `testDuplicateGivesCommandsFreshIds` | A duplicated site's commands get new ids. |
| `testRejectsIncompleteAndDuplicateCommands` | A command without a name or command line, with a missing folder, or with a name used twice blocks a save. |
| `testSanitizeLabel` | Name input is lowercased and stripped to `[a-z0-9-]`. |
| `testSiteStatusDerivation` | `SiteStatus` follows from the process states. |

### `EnvPortDetectorTests`

These tests pass the dotenv files in as strings, except the last one, which reads a real `.env`.

| Test | Checks |
| --- | --- |
| `testNoFilesDetectsNothing` | No dotenv file, or one with no port, detects nothing. |
| `testPortWinsOverOtherWebKeys` | `PORT` beats `APP_PORT` and `VITE_PORT`. |
| `testPriorityTableOrder` | The named keys win in table order. |
| `testDatabaseAndServicePortsAreIgnored` | `DB_PORT`, `FORWARD_DB_PORT`, `REDIS_PORT`, and similar keys never count. |
| `testOtherPortKeyFallsBackInFileOrder` | Another `*_PORT` key counts, and the first one in the file wins. |
| `testLaterFilesOverrideEarlierOnes` | `.env.development` overrides `.env.local`, which overrides `.env`. |
| `testExampleFileIsNotRead` | `.env.example` is ignored. |
| `testQuotesCommentsAndExport` | Quotes, comment lines, trailing comments, `export`, and spaces around `=` parse. |
| `testTrivialReferenceIsExpanded` | `PORT=${SERVER_PORT}` takes the referenced value, and a missing reference is skipped. |
| `testInvalidValuesAreSkipped` | `0`, `70000`, text, and negative numbers are skipped. |
| `testLocalURLWithExplicitPortIsTheLastResort` | A localhost URL with a port counts only when no port key does. |
| `testReadsFilesFromDisk` | A real `.env` with `DB_PORT` and `APP_PORT` gives `APP_PORT`. |

### `CommandDetectorTests`

These tests pass the folder's files in as strings, except the last one, which reads a real folder.

| Test | Checks |
| --- | --- |
| `testEmptyFolderDetectsNothing` | An empty folder, or one with only HTML and docs, detects nothing. |
| `testPackageDevScript` | `scripts.dev` gives `npm run dev` from `package.json (scripts.dev)`. |
| `testPackageStartScriptWhenNoDev` | `scripts.start` gives `npm start` when there is no `dev` script. |
| `testPackageWithoutDevOrStartFallsThrough` | A `package.json` with neither script detects nothing and lets later rules match. |
| `testLockfilePicksThePackageManager` | `pnpm-lock.yaml`, `yarn.lock`, `bun.lockb`, and `bun.lock` pick pnpm, yarn, and bun, including `bun run start`. |
| `testPackageManagerFieldBeatsLockfiles` | `"packageManager": "pnpm@9.1.0"` wins over a `yarn.lock`. |
| `testMalformedPackageJsonFallsThroughToTheNextRule` | Broken JSON detects nothing and lets a Makefile match. |
| `testPackageJsonWithCommentsStillParses` | Comments and trailing commas in `package.json` parse. |
| `testMakefileTargets` | `dev`, `run`, and `serve` targets give `make <target>` in `Makefile`, `makefile`, and `GNUmakefile`. |
| `testMakefileDevBeatsRunAndServe` | `dev` wins over `run` and `serve`. |
| `testMakefileIgnoresVariablesRecipesAndOtherTargets` | `dev := 1`, `run ::= 2`, recipe lines, and other targets do not count. |
| `testArtisan` | An `artisan` file gives `php artisan serve --port=$PORT`. |
| `testProcfileWebLine` | The `web:` line of a `Procfile` is the command. |
| `testProcfileDevBeatsProcfile` | `Procfile.dev` wins over `Procfile`. |
| `testProcfileWithoutWebFallsThrough` | A `Procfile` with no `web:` line detects nothing. |
| `testDjango` | `manage.py` gives `python3 manage.py runserver $PORT`. |
| `testRailsNeedsTheGemAndBinRails` | A Gemfile with `gem "rails"` and a `bin/rails` give `bin/rails server -p $PORT`, and either alone, or `rails-html-sanitizer`, does not. |
| `testGo` | `.air.toml` gives `air`, and `go.mod` alone gives `go run .`. |
| `testCargo` | `Cargo.toml` gives `cargo run`. |
| `testDenoTasks` | A `dev` task in `deno.json` or a commented `deno.jsonc` gives `deno task dev`, and other tasks do not. |
| `testPackageJsonBeatsMakefile` | A `dev` script wins over a Makefile `dev` target. |
| `testFrameworkServerBeatsPackageJsonAssetScripts` | Laravel, Django, and Rails servers win over the `package.json` that builds their assets. |
| `testExplicitProjectFilesBeatLanguageDefaults` | A Makefile wins over `go.mod`, and a `Procfile` wins over `Cargo.toml`. |
| `testReadsTheRealFolder` | A real folder with `package.json` and `yarn.lock` gives `yarn run dev`. |

### `FolderAutofillTests`

| Test | Checks |
| --- | --- |
| `testNewSiteGetsNameFromFolderAndDetectedPort` | A new site takes `mycrm` from `My CRM` and the detected port. |
| `testTypedPortIsKept` | A port the user typed stays. |
| `testEmptyPortIsFilled` | An empty port takes the detected one. |
| `testTypedNameIsKept` | A name the user typed stays. |
| `testFilledValuesFollowTheNextFolder` | A name, port, and command Portside filled change with the next folder. |
| `testEditedSiteKeepsItsSavedPortAndName` | Editing a saved site never replaces its name, port, or command. |
| `testEmptyCommandIsFilledFromTheFolder` | An empty command takes the detected one. |
| `testTypedCommandIsKept` | A command the user typed stays. |
| `testFilledCommandClearsForAFolderWithNoCommand` | A command Portside filled empties when the next folder has none, so the site reads as static. |
| `testStaticSiteGetsACommandWhenItsFolderChanges` | A saved static site moved to a folder with a command takes that command. |

## Manual integration checklist

Run this checklist before a release, on a release build from [`scripts/build-release.sh`](../scripts/build-release.sh). Each step says what you should see.

### Prepare

- [ ] Create a new macOS user account in **System Settings > Users & Groups** and log in to it. A fresh account has no Portside settings.
- [ ] Remove an old Portside resolver file, if there is one: `sudo rm -f /etc/resolver/test`. Skip this step on a Mac where Herd or Valet owns the file.
- [ ] Create a Vite project: `npm create vite@latest blog -- --template vanilla`, then `cd blog && npm install`.
- [ ] Check that port 80 is free: `lsof -nP -iTCP:80 -sTCP:LISTEN` prints nothing.

### First run

- [ ] Copy `Portside.app` to `/Applications` and open it. macOS blocks the first launch because the app is not notarized. On macOS 14, Control-click the app and choose **Open**. On macOS 15 or later, open **System Settings > Privacy & Security** and click **Open Anyway**.
- [ ] The Portside icon appears in the menu bar. No Dock icon appears.
- [ ] The **Choose Your Local Domain** window opens. `.localhost` is selected and shows three green lines. No password prompt appears.
- [ ] Click **Continue**. The window shows "Works end to end" with a green mark. Click **Done**.
- [ ] `lsof -nP -iUDP:35353` prints nothing. Portside runs no DNS server for `.localhost`.
- [ ] **Settings > Network** shows `/etc/resolver/localhost` as "Built in, no setup needed".

If the window says this Mac does not resolve `.localhost`, follow the `.test` steps below with `localhost` in place of `test`.

### The `.test` suffix

- [ ] In **Settings > Network**, choose `.test` and click **Use .test**. The resolver window explains `/etc/resolver/test`.
- [ ] Click **Install Resolver** and enter your administrator password.
- [ ] `cat /etc/resolver/test` prints `nameserver 127.0.0.1` and `port 35353`.
- [ ] `dig @127.0.0.1 -p 35353 blog.test +short` prints `127.0.0.1`.
- [ ] `dig @127.0.0.1 -p 35353 portside-selftest.test +short` prints `127.0.0.53`.
- [ ] `dscacheutil -q host -a name blog.test` lists `127.0.0.1`. This proves macOS sends `.test` lookups to Portside.
- [ ] **Test Now** in **Settings > Network** shows "Works end to end".
- [ ] Choose `.localhost` again. Settings offers **Remove /etc/resolver/test…**. Click it and enter your password. The file is gone, and `lsof -nP -iUDP:35353` prints nothing.

### A Vite site

- [ ] Click **Add Site**. Enter the name `blog`, choose the Vite project folder, enter the command `npm run dev -- --port 5474 --strictPort`, and enter the port `5474`. Click **Save**.
- [ ] Click the start button. The dot pulses while the site starts, then turns green.
- [ ] Open the logs window. The Vite banner appears with its colors.
- [ ] `curl -s -o /dev/null -w '%{http_code}\n' http://blog.localhost` prints `200`.
- [ ] Open `http://blog.localhost` in Safari and in Chrome. Both show the Vite page with no "Blocked request" error.
- [ ] Edit `main.js` and save. Both browsers update without a full reload. This proves the HMR WebSocket passes through Caddy.

### A port from `.env`

- [ ] Create a folder with a `.env` that contains `DB_PORT=5432` and `APP_PORT=8000`.
- [ ] Click **Add Site** and choose that folder. The name fills in from the folder name, the port becomes `8000`, and the line under the port says "Port 8000 from .env (APP_PORT)".
- [ ] Change the port to `3001`. The line says ".env says 8000 (APP_PORT) ·" with a **Use** button. Click **Use**, and the port returns to `8000`.

### A command from the folder

- [ ] Create a folder with a `package.json` that contains `{"scripts": {"dev": "node server.js"}}`.
- [ ] Click **Add Site** and choose that folder. Command becomes `npm run dev`, and the line under it says "from package.json (scripts.dev)".
- [ ] Change the command to `node server.js`. The line says "package.json (scripts.dev) says npm run dev ·" with a **Use** button. Click **Use**, and the command returns to `npm run dev`.
- [ ] Clear the command. The line says "Static site: Portside serves this folder's files directly. Add a command to run a dev server." with a **Use npm run dev** button.
- [ ] Click **Add Site** and choose an empty folder. Command stays empty, its placeholder reads `e.g. npm run dev`, and the static-site line shows.
- [ ] Save the empty-folder site. Its row in the menu has a switch, and hovering the switch shows "Static site, served from the folder".

### An extra process on a subdomain

- [ ] Edit the site. Click **Add Process** and enter the label `API`, the subdomain `api`, the command `python3 -m http.server 8185`, and the port `8185`. Save while the site runs.
- [ ] Only the new API process starts. The Vite process keeps its pid, which the `▶` line in its log shows.
- [ ] `curl -s http://api.blog.localhost/ | head -n 3` prints the directory listing from Python.
- [ ] Find the API's pid in its log and run `kill <pid>`. The site's dot turns red, the API row shows the exit code, and a notification appears.

### A site command

- [ ] Edit the site and open the **Commands** tab. Add a command named `Deploy` with the command `echo "deploying $PORTSIDE_SITE"; sleep 5; echo done`. Save.
- [ ] Open the site's … menu. `Deploy` sits between **Duplicate** and **Delete…**, with a divider on each side. Choose it. The popover closes and the logs window opens on a `Deploy` tab that prints `deploying blog`.
- [ ] Open the … menu again within 5 seconds. The item reads **Stop Deploy**. Stop the site with the row's stop button. The command keeps running and prints `done`.
- [ ] Turn **Show logs** off and save. Run `Deploy` again. No window opens, and after 5 seconds a notification says `blog · Deploy finished` with `done` as its text. Click **Show logs** on it. The logs window opens on the `Deploy` tab.
- [ ] Change the command to `exit 3` and run it. The notification says `blog · Deploy failed with code 3`.

### Stopped and unknown sites

- [ ] Stop the site. The dot turns grey.
- [ ] `lsof -nP -iTCP:5474 -sTCP:LISTEN` and `lsof -nP -iTCP:8185 -sTCP:LISTEN` print nothing.
- [ ] Open `http://blog.localhost`. A Portside page says the site is not running and to start it from the Portside menu bar. `curl` reports status `502`.
- [ ] Open `http://nothing-here.localhost`. A Portside page says there is no site for this host. `curl` reports status `404`.

### A static site

- [ ] Create a folder with an `index.html`. Add a site named `docs` with that folder, an empty command, and any port.
- [ ] Turn the site on. `http://docs.localhost` shows the `index.html`.
- [ ] Turn the site off. `http://docs.localhost` shows the not-running page, and `curl` reports status `503`.

### Port 80 is busy

- [ ] Quit Portside. Run `python3 -m http.server 80` in a terminal, then open Portside.
- [ ] Portside says port 80 is in use and names the Python process and its pid.
- [ ] In **Settings > Network**, set the proxy port to `8080`. Every URL in the menu now ends in `:8080`.
- [ ] `curl -s -o /dev/null -w '%{http_code}\n' http://blog.localhost:8080` prints `200` while the site runs.
- [ ] Stop the Python server and set the proxy port back to `80`.

### Laravel Herd or Valet

Run this section on a Mac with Herd or Valet installed. Both write `nameserver 127.0.0.1` to `/etc/resolver/test` and both use port 80.

- [ ] With `.localhost` chosen, Portside does not mention `/etc/resolver/test`, and the `.test` option in **Settings > Network** shows the Herd file with a takeover warning.
- [ ] Portside reports port 80 in use by Herd's nginx. Move the proxy to port 8080 and check that `http://blog.localhost:8080` works while Herd sites still resolve.
- [ ] Choose `.test`. Portside says the resolver file belongs to another tool and asks before it replaces the file.
- [ ] Decline. `.test` lookups keep going to Herd, and **Test Now** reports that `portside-selftest.test` does not resolve through Portside's DNS server.
- [ ] Repair the resolver from **Settings** and accept. `cat /etc/resolver/test` shows `port 35353`, and **Test Now** passes.
- [ ] Switch back to Herd with Herd's own repair, or with `sudo sh -c 'printf "nameserver 127.0.0.1\n" > /etc/resolver/test'`. Herd sites resolve again.

### Quit and crash recovery

- [ ] Start the site, then choose **Quit Portside**. Afterwards, `lsof -nP -iTCP:80 -sTCP:LISTEN`, `lsof -nP -iTCP:5474 -sTCP:LISTEN`, and `pgrep -x caddy` print nothing.
- [ ] Open Portside and start the site again. Run `pkill -9 -x Portside`. The dev server and Caddy keep running.
- [ ] Open Portside again. Within a few seconds, `lsof -nP -iTCP:5474 -sTCP:LISTEN` prints nothing, and only the new Caddy listens on port 80.
