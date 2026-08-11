import Foundation
import IPAPatchLookinCore
import Darwin

@_silgen_name("flock")
private func systemFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

struct LocalConfiguration: Codable {
    var teamID: String?
    var bundleIDPrefix: String?
    var device: String?
    var simulator: String?
}

struct ConfigurationStore {
    let url: URL

    func load() throws -> LocalConfiguration {
        try withLock(at: lockURL, operation: LOCK_SH) {
            try loadUnlocked()
        }
    }

    @discardableResult
    func update(
        _ mutation: (inout LocalConfiguration) throws -> Void
    ) throws -> LocalConfiguration {
        try withLock(at: lockURL, operation: LOCK_EX) {
            var configuration = try loadUnlocked()
            try mutation(&configuration)
            try saveUnlocked(configuration)
            return configuration
        }
    }

    func withPreparationLock<T>(_ body: () throws -> T) throws -> T {
        try withLock(at: preparationLockURL, operation: LOCK_EX, body)
    }

    private var lockURL: URL {
        URL(fileURLWithPath: url.path + ".lock")
    }

    private var preparationLockURL: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".ipapatch-lookin.prepare.lock")
    }

    private func loadUnlocked() throws -> LocalConfiguration {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LocalConfiguration()
        }
        return try JSONDecoder().decode(
            LocalConfiguration.self,
            from: Data(contentsOf: url)
        )
    }

    private func saveUnlocked(_ configuration: LocalConfiguration) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(configuration)
        data.append(0x0a)
        try data.write(to: url, options: .atomic)
    }

    private func withLock<T>(
        at lockURL: URL,
        operation: Int32,
        _ body: () throws -> T
    ) throws -> T {
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CLIError("Unable to open local workflow lock at \(lockURL.path)")
        }
        defer {
            Darwin.close(descriptor)
        }

        while systemFlock(descriptor, operation) != 0 {
            guard errno == EINTR else {
                throw CLIError("Unable to acquire local workflow lock at \(lockURL.path)")
            }
        }
        defer {
            _ = systemFlock(descriptor, LOCK_UN)
        }

        return try body()
    }
}

enum ConfigurationSupport {
    static func inferredDevelopmentTeams() -> [String] {
        guard let result = try? CommandRunner.run(
            "/usr/bin/security",
            arguments: ["find-identity", "-v", "-p", "codesigning"]
        ) else {
            return []
        }

        let pattern = #""Apple Development:[^"]*\(([A-Z0-9]{10})\)""#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(
            result.standardOutput.startIndex..<result.standardOutput.endIndex,
            in: result.standardOutput
        )
        let teams = expression.matches(
            in: result.standardOutput,
            range: range
        ).compactMap { match -> String? in
            guard let swiftRange = Range(match.range(at: 1), in: result.standardOutput) else {
                return nil
            }
            return String(result.standardOutput[swiftRange])
        }
        return Array(Set(teams)).sorted()
    }

    static func defaultBundleIDPrefix() -> String {
        let username = NSUserName()
            .lowercased()
            .map { character -> Character in
                character.isLetter || character.isNumber ? character : "-"
            }
        let component = String(username).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "com.\(component.isEmpty ? "local" : component).ipapatchlookin"
    }

    static func validateTeamID(_ value: String) throws -> String {
        let normalized = value.uppercased()
        guard normalized.range(
            of: #"^[A-Z0-9]{10}$"#,
            options: .regularExpression
        ) != nil else {
            throw CLIError("Invalid Apple development team ID: \(value)")
        }
        return normalized
    }

    static func validateBundleIdentifier(_ value: String) throws -> String {
        guard value.count <= 255,
              value.range(
                of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#,
                options: .regularExpression
              ) != nil else {
            throw CLIError("Invalid bundle identifier or prefix: \(value)")
        }
        return value
    }
}
