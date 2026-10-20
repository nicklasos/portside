import Foundation

struct DetectedCommand: Equatable {
    var command: String
    var source: String
}

/// Guesses the command that runs a project's dev server from the files in its folder.
enum CommandDetector {
    struct Folder {
        var url: URL
        var read: (URL) -> String?
        var exists: (URL) -> Bool

        func text(_ name: String) -> String? { read(url.appendingPathComponent(name)) }
        func has(_ name: String) -> Bool { exists(url.appendingPathComponent(name)) }
    }

    typealias Rule = (Folder) -> DetectedCommand?

    /// First match wins. Framework servers come before package.json because in Laravel, Django and
    /// Rails apps package.json only builds assets, and its `dev` script runs Vite or Mix, not the app.
    static let rules: [Rule] = [
        { $0.has("artisan") ? DetectedCommand(command: "php artisan serve --port=$PORT", source: "artisan (Laravel)") : nil },
        { $0.has("manage.py") ? DetectedCommand(command: "python3 manage.py runserver $PORT", source: "manage.py (Django)") : nil },
        rails,
        packageScript,
        makeTarget,
        procfile,
        denoTask,
        { $0.has(".air.toml") ? DetectedCommand(command: "air", source: ".air.toml") : nil },
        { $0.has("go.mod") ? DetectedCommand(command: "go run .", source: "go.mod") : nil },
        { $0.has("Cargo.toml") ? DetectedCommand(command: "cargo run", source: "Cargo.toml") : nil },
    ]

    static func detect(
        in folder: URL,
        read: @escaping (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) },
        exists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> DetectedCommand? {
        let folder = Folder(url: folder, read: read, exists: exists)
        for rule in rules {
            if let hit = rule(folder) { return hit }
        }
        return nil
    }

    static func rails(_ folder: Folder) -> DetectedCommand? {
        guard folder.has("bin/rails"), let gemfile = folder.text("Gemfile"),
              gemfile.split(whereSeparator: \.isNewline).contains(where: { $0.range(of: #"^\s*gem\s+["']rails["']"#, options: .regularExpression) != nil })
        else { return nil }
        return DetectedCommand(command: "bin/rails server -p $PORT", source: "Gemfile (Rails)")
    }

    static func packageScript(_ folder: Folder) -> DetectedCommand? {
        guard let package = json(folder.text("package.json")),
              let scripts = package["scripts"] as? [String: Any] else { return nil }
        let pm = packageManager(package, folder)
        if scripts["dev"] is String {
            return DetectedCommand(command: "\(pm) run dev", source: "package.json (scripts.dev)")
        }
        if scripts["start"] is String {
            return DetectedCommand(command: pm == "bun" ? "bun run start" : "\(pm) start", source: "package.json (scripts.start)")
        }
        return nil
    }

    static let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"), ("bun.lock", "bun")]

    static func packageManager(_ package: [String: Any], _ folder: Folder) -> String {
        if let field = package["packageManager"] as? String,
           let name = field.split(separator: "@").first.map(String.init),
           ["npm", "pnpm", "yarn", "bun"].contains(name) {
            return name
        }
        return lockfiles.first { folder.has($0.0) }?.1 ?? "npm"
    }

    static func makeTarget(_ folder: Folder) -> DetectedCommand? {
        for file in ["GNUmakefile", "Makefile", "makefile"] {
            guard let text = folder.text(file) else { continue }
            let targets = makeTargets(text)
            if let target = ["dev", "run", "serve"].first(where: targets.contains) {
                return DetectedCommand(command: "make \(target)", source: "\(file) (\(target) target)")
            }
            return nil
        }
        return nil
    }

    /// Rule names declared at the start of a line, skipping recipes and `name := value` assignments.
    static func makeTargets(_ text: String) -> Set<String> {
        var targets: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("\t") && !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let after = line[colon...].drop { $0 == ":" }
            if after.hasPrefix("=") || line[..<colon].contains("=") { continue }
            targets.formUnion(line[..<colon].split(separator: " ").map(String.init))
        }
        return targets
    }

    static func procfile(_ folder: Folder) -> DetectedCommand? {
        for file in ["Procfile.dev", "Procfile"] {
            guard let text = folder.text(file) else { continue }
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "web" else { continue }
                let command = parts[1].trimmingCharacters(in: .whitespaces)
                if !command.isEmpty { return DetectedCommand(command: command, source: "\(file) (web)") }
            }
        }
        return nil
    }

    static func denoTask(_ folder: Folder) -> DetectedCommand? {
        for file in ["deno.json", "deno.jsonc"] {
            if let tasks = json(folder.text(file))?["tasks"] as? [String: Any], tasks["dev"] != nil {
                return DetectedCommand(command: "deno task dev", source: "\(file) (tasks.dev)")
            }
        }
        return nil
    }

    /// JSON5 parsing accepts the comments and trailing commas that deno.jsonc and some package.json files carry.
    private static func json(_ text: String?) -> [String: Any]? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: .json5Allowed)) as? [String: Any]
    }
}
