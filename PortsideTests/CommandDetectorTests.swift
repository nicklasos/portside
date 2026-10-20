import XCTest
@testable import Portside

final class CommandDetectorTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)

    private func detect(_ files: [String: String]) -> DetectedCommand? {
        func name(_ url: URL) -> String { String(url.path.dropFirst(folder.path.count + 1)) }
        return CommandDetector.detect(in: folder, read: { files[name($0)] }, exists: { files[name($0)] != nil })
    }

    private func command(_ files: [String: String]) -> String? { detect(files)?.command }

    private let devScript = #"{"scripts": {"dev": "node server.js", "start": "node index.js"}}"#
    private let startScript = #"{"scripts": {"start": "node index.js"}}"#

    func testEmptyFolderDetectsNothing() {
        XCTAssertNil(detect([:]))
        XCTAssertNil(detect(["index.html": "<h1>hi</h1>", "README.md": "# docs"]))
    }

    func testPackageDevScript() {
        XCTAssertEqual(detect(["package.json": devScript]), DetectedCommand(command: "npm run dev", source: "package.json (scripts.dev)"))
    }

    func testPackageStartScriptWhenNoDev() {
        XCTAssertEqual(detect(["package.json": startScript]), DetectedCommand(command: "npm start", source: "package.json (scripts.start)"))
    }

    func testPackageWithoutDevOrStartFallsThrough() {
        XCTAssertNil(detect(["package.json": #"{"scripts": {"build": "vite build"}}"#]))
        XCTAssertEqual(command(["package.json": #"{"name": "x"}"#, "go.mod": "module x"]), "go run .")
    }

    func testLockfilePicksThePackageManager() {
        XCTAssertEqual(command(["package.json": devScript, "pnpm-lock.yaml": ""]), "pnpm run dev")
        XCTAssertEqual(command(["package.json": devScript, "yarn.lock": ""]), "yarn run dev")
        XCTAssertEqual(command(["package.json": devScript, "bun.lockb": ""]), "bun run dev")
        XCTAssertEqual(command(["package.json": devScript, "bun.lock": ""]), "bun run dev")
        XCTAssertEqual(command(["package.json": startScript, "pnpm-lock.yaml": ""]), "pnpm start")
        XCTAssertEqual(command(["package.json": startScript, "yarn.lock": ""]), "yarn start")
        XCTAssertEqual(command(["package.json": startScript, "bun.lock": ""]), "bun run start")
    }

    func testPackageManagerFieldBeatsLockfiles() {
        let package = #"{"packageManager": "pnpm@9.1.0", "scripts": {"dev": "vite"}}"#
        XCTAssertEqual(command(["package.json": package, "yarn.lock": ""]), "pnpm run dev")
    }

    func testMalformedPackageJsonFallsThroughToTheNextRule() {
        XCTAssertNil(detect(["package.json": "{ \"scripts\": "]))
        XCTAssertEqual(command(["package.json": "not json", "Makefile": "dev:\n\tnpm run dev\n"]), "make dev")
    }

    func testPackageJsonWithCommentsStillParses() {
        XCTAssertEqual(command(["package.json": "{\n  // local\n  \"scripts\": {\"dev\": \"vite\",},\n}"]), "npm run dev")
    }

    func testMakefileTargets() {
        XCTAssertEqual(detect(["Makefile": ".PHONY: dev\ndev:\n\tair\n"]), DetectedCommand(command: "make dev", source: "Makefile (dev target)"))
        XCTAssertEqual(command(["Makefile": "build:\n\tgo build\nrun: build\n\t./app\n"]), "make run")
        XCTAssertEqual(command(["Makefile": "serve:\n\thugo server\n"]), "make serve")
        XCTAssertEqual(command(["makefile": "dev:\n\tair\n"]), "make dev")
        XCTAssertEqual(command(["GNUmakefile": "dev:\n\tair\n"]), "make dev")
    }

    func testMakefileDevBeatsRunAndServe() {
        XCTAssertEqual(command(["Makefile": "serve:\n\tx\nrun:\n\ty\ndev:\n\tz\n"]), "make dev")
    }

    func testMakefileIgnoresVariablesRecipesAndOtherTargets() {
        XCTAssertNil(detect(["Makefile": "dev := 1\nrun ::= 2\nbuild:\n\tdev: not a target\ntest:\n"]))
    }

    func testArtisan() {
        XCTAssertEqual(detect(["artisan": "#!/usr/bin/env php"]), DetectedCommand(command: "php artisan serve --port=$PORT", source: "artisan (Laravel)"))
    }

    func testProcfileWebLine() {
        XCTAssertEqual(
            detect(["Procfile": "release: rake db:migrate\nweb: bundle exec puma -p $PORT\n"]),
            DetectedCommand(command: "bundle exec puma -p $PORT", source: "Procfile (web)")
        )
    }

    func testProcfileDevBeatsProcfile() {
        XCTAssertEqual(
            detect(["Procfile": "web: node index.js\n", "Procfile.dev": "web: node dev.js\ncss: tailwind -w\n"]),
            DetectedCommand(command: "node dev.js", source: "Procfile.dev (web)")
        )
    }

    func testProcfileWithoutWebFallsThrough() {
        XCTAssertNil(detect(["Procfile": "worker: rake jobs:work\n"]))
    }

    func testDjango() {
        XCTAssertEqual(detect(["manage.py": ""]), DetectedCommand(command: "python3 manage.py runserver $PORT", source: "manage.py (Django)"))
    }

    func testRailsNeedsTheGemAndBinRails() {
        let gemfile = "source \"https://rubygems.org\"\ngem \"rails\", \"~> 7.1\"\n"
        XCTAssertEqual(detect(["Gemfile": gemfile, "bin/rails": ""]), DetectedCommand(command: "bin/rails server -p $PORT", source: "Gemfile (Rails)"))
        XCTAssertNil(detect(["Gemfile": gemfile]))
        XCTAssertNil(detect(["Gemfile": "gem 'sinatra'\ngem 'rails-html-sanitizer'\n", "bin/rails": ""]))
    }

    func testGo() {
        XCTAssertEqual(detect([".air.toml": "", "go.mod": "module x"]), DetectedCommand(command: "air", source: ".air.toml"))
        XCTAssertEqual(detect(["go.mod": "module x"]), DetectedCommand(command: "go run .", source: "go.mod"))
    }

    func testCargo() {
        XCTAssertEqual(detect(["Cargo.toml": "[package]"]), DetectedCommand(command: "cargo run", source: "Cargo.toml"))
    }

    func testDenoTasks() {
        XCTAssertEqual(detect(["deno.json": #"{"tasks": {"dev": "deno run -A main.ts"}}"#]), DetectedCommand(command: "deno task dev", source: "deno.json (tasks.dev)"))
        XCTAssertEqual(command(["deno.jsonc": "{\n  // tasks\n  \"tasks\": {\"dev\": \"deno run main.ts\"}\n}"]), "deno task dev")
        XCTAssertNil(detect(["deno.json": #"{"tasks": {"test": "deno test"}}"#]))
    }

    func testPackageJsonBeatsMakefile() {
        XCTAssertEqual(command(["package.json": devScript, "Makefile": "dev:\n\tdocker compose up\n"]), "npm run dev")
    }

    func testFrameworkServerBeatsPackageJsonAssetScripts() {
        let laravelMix = #"{"scripts": {"dev": "npm run development"}}"#
        XCTAssertEqual(command(["artisan": "", "package.json": laravelMix, "Makefile": "dev:\n\tnpm run dev\n"]), "php artisan serve --port=$PORT")
        XCTAssertEqual(command(["manage.py": "", "package.json": devScript]), "python3 manage.py runserver $PORT")
        XCTAssertEqual(command(["Gemfile": "gem 'rails'", "bin/rails": "", "package.json": devScript, "Procfile.dev": "web: bin/rails s\n"]), "bin/rails server -p $PORT")
    }

    func testExplicitProjectFilesBeatLanguageDefaults() {
        XCTAssertEqual(command(["Makefile": "run:\n\tgo run ./cmd\n", "go.mod": "module x"]), "make run")
        XCTAssertEqual(command(["Procfile": "web: ./bin/server\n", "Cargo.toml": ""]), "./bin/server")
    }

    func testReadsTheRealFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try devScript.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("yarn.lock"), atomically: true, encoding: .utf8)
        XCTAssertEqual(CommandDetector.detect(in: dir), DetectedCommand(command: "yarn run dev", source: "package.json (scripts.dev)"))
    }
}
