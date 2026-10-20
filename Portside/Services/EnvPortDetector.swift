import Foundation

struct DetectedPort: Equatable {
    var port: Int
    var key: String
    var file: String
}

/// Reads a project's dotenv files and guesses the port its dev server listens on.
enum EnvPortDetector {
    /// Later files override earlier ones, as in dotenv. `.env.example` holds placeholders, so it is not read.
    static let files = [".env", ".env.local", ".env.development", ".env.development.local"]

    enum Rule: Equatable {
        case key(String)
        case anyPortKey
        case urlKey(String)
    }

    static let priority: [Rule] = [
        .key("PORT"), .key("APP_PORT"), .key("SERVER_PORT"), .key("HTTP_PORT"),
        .key("WEB_PORT"), .key("VITE_PORT"), .key("DEV_PORT"),
        .anyPortKey,
        .urlKey("APP_URL"), .urlKey("BASE_URL"), .urlKey("PUBLIC_URL"), .urlKey("SITE_URL"), .urlKey("URL"),
    ]

    /// A `*_PORT` key with any of these words belongs to a backing service, not the web server.
    /// Matching words rather than whole keys also covers Sail's `FORWARD_DB_PORT` and the like.
    static let serviceWords: Set<String> = [
        "DB", "DATABASE", "POSTGRES", "POSTGRESQL", "PG", "PGSQL", "MYSQL", "MARIADB", "MSSQL", "SQL",
        "REDIS", "MONGO", "MONGODB", "MEMCACHED", "CACHE", "MAIL", "SMTP", "IMAP", "POP3", "MAILPIT", "MAILHOG",
        "RABBITMQ", "AMQP", "KAFKA", "ELASTICSEARCH", "MEILISEARCH", "TYPESENSE", "MINIO", "S3", "LDAP",
        "DEBUG", "XDEBUG", "HMR", "DASHBOARD",
    ]

    struct Entry: Equatable {
        var value: String
        var file: String
    }

    static func detect(in folder: URL, read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }) -> DetectedPort? {
        var env: [String: Entry] = [:]
        var order: [String] = []
        for file in files {
            guard let text = read(folder.appendingPathComponent(file)) else { continue }
            for (key, value) in parse(text) {
                if env[key] == nil { order.append(key) }
                env[key] = Entry(value: value, file: file)
            }
        }
        return pick(env, order: order)
    }

    static func pick(_ env: [String: Entry], order: [String]) -> DetectedPort? {
        func resolved(_ key: String) -> String? {
            guard let value = env[key]?.value else { return nil }
            if value.hasPrefix("${"), value.hasSuffix("}") {
                return env[String(value.dropFirst(2).dropLast())]?.value
            }
            return value
        }
        func found(_ key: String, _ port: Int?) -> DetectedPort? {
            port.map { DetectedPort(port: $0, key: key, file: env[key]!.file) }
        }
        for rule in priority {
            switch rule {
            case .key(let key):
                if let hit = found(key, resolved(key).flatMap(port(from:))) { return hit }
            case .anyPortKey:
                for key in order where key.hasSuffix("_PORT") && !isServiceKey(key) {
                    if let hit = found(key, resolved(key).flatMap(port(from:))) { return hit }
                }
            case .urlKey(let key):
                if let hit = found(key, resolved(key).flatMap(port(fromURL:))) { return hit }
            }
        }
        return nil
    }

    static func isServiceKey(_ key: String) -> Bool {
        !serviceWords.isDisjoint(with: key.split(separator: "_").map(String.init))
    }

    static func port(from value: String) -> Int? {
        Int(value).flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    static func port(fromURL value: String) -> Int? {
        guard let components = URLComponents(string: value),
              let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1"].contains(host),
              let port = components.port else { return nil }
        return (1...65535).contains(port) ? port : nil
    }

    /// Dotenv lines in file order. A key set twice appears twice; the caller keeps the last.
    static func parse(_ text: String) -> [(key: String, value: String)] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { return nil }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { return nil }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") else { return nil }
            return (key, unquote(line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)))
        }
    }

    private static func unquote(_ value: String) -> String {
        if let quote = value.first, quote == "\"" || quote == "'",
           let close = value.dropFirst().firstIndex(of: quote) {
            return String(value[value.index(after: value.startIndex)..<close])
        }
        if let comment = value.range(of: " #") ?? value.range(of: "\t#") {
            return value[..<comment.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        return value
    }
}
