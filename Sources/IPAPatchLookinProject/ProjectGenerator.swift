import CryptoKit
import Foundation
import IPAPatchLookinCore

public struct GeneratedProjectManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let appName: String
    public let originalBundleIdentifier: String
    public let patchedBundleIdentifier: String
    public let platform: IPAPlatform
    public let architectures: [String]
    public let ipaSHA256: String
    public let inputIPAPath: String
    public let projectFileName: String
}

public struct GeneratedProject: Equatable, Sendable {
    public let directoryURL: URL
    public let projectURL: URL
    public let manifest: GeneratedProjectManifest
    public let wasCreated: Bool
}

public enum ProjectGenerationError: LocalizedError, Equatable {
    case invalidFingerprint
    case missingTemplate(String)
    case incompleteProject(String)
    case fingerprintCollision(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFingerprint:
            "The IPA fingerprint is not a valid SHA-256 value."
        case let .missingTemplate(path):
            "The project template is missing: \(path)"
        case let .incompleteProject(path):
            "The generated project is incomplete: \(path)"
        case let .fingerprintCollision(path):
            "A different IPA already uses the generated project path: \(path)"
        }
    }
}

public struct ProjectGenerator {
    public static let manifestFileName = "IPAPatchProject.json"
    public static let projectFileName = "IPAPatch.xcodeproj"
    public static let schemaVersion = 1

    private let repositoryRoot: URL
    private let fileManager: FileManager

    public init(
        repositoryRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.repositoryRoot = repositoryRoot.standardizedFileURL.resolvingSymlinksInPath()
        self.fileManager = fileManager
    }

    public static func fingerprint(of ipaURL: URL) throws -> String {
        let data = try Data(contentsOf: ipaURL, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func generate(
        inspection: IPAInspection,
        fingerprint: String,
        patchedBundleIdentifier: String
    ) throws -> GeneratedProject {
        guard fingerprint.count == 64,
              fingerprint.allSatisfy({ $0.isHexDigit }) else {
            throw ProjectGenerationError.invalidFingerprint
        }

        let projectsURL = repositoryRoot.appendingPathComponent(
            "Projects",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: projectsURL,
            withIntermediateDirectories: true
        )

        let safeName = Self.safeFileComponent(inspection.appName)
        let directoryName = "\(safeName)-\(fingerprint.prefix(12))"
        let projectDirectory = projectsURL.appendingPathComponent(
            directoryName,
            isDirectory: true
        )

        if fileManager.fileExists(atPath: projectDirectory.path) {
            return try existingProject(
                at: projectDirectory,
                expectedFingerprint: fingerprint,
                repairInputFrom: inspection.ipaURL
            )
        }

        let stagingDirectory = projectsURL.appendingPathComponent(
            ".\(directoryName).\(UUID().uuidString).tmp",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }

        try populateProject(
            at: stagingDirectory,
            inspection: inspection,
            fingerprint: fingerprint,
            patchedBundleIdentifier: patchedBundleIdentifier
        )
        try fileManager.moveItem(at: stagingDirectory, to: projectDirectory)
        shouldRemoveStaging = false

        let finalDirectory = projectDirectory.resolvingSymlinksInPath()
        let manifest = try loadManifest(from: finalDirectory)
        return GeneratedProject(
            directoryURL: finalDirectory,
            projectURL: finalDirectory.appendingPathComponent(
                manifest.projectFileName,
                isDirectory: true
            ),
            manifest: manifest,
            wasCreated: true
        )
    }

    public func projects() throws -> [GeneratedProject] {
        let projectsURL = repositoryRoot.appendingPathComponent(
            "Projects",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: projectsURL.path) else {
            return []
        }
        let directories = try fileManager.contentsOfDirectory(
            at: projectsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try directories.compactMap { directory in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true else {
                return nil
            }
            let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                return nil
            }
            let stableDirectory = projectsURL.appendingPathComponent(
                directory.lastPathComponent,
                isDirectory: true
            )
            return try existingProject(
                at: stableDirectory,
                expectedFingerprint: nil,
                repairInputFrom: nil
            )
        }.sorted { lhs, rhs in
            let nameOrder = lhs.manifest.appName.localizedStandardCompare(
                rhs.manifest.appName
            )
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return lhs.directoryURL.path < rhs.directoryURL.path
        }
    }

    private func populateProject(
        at directory: URL,
        inspection: IPAInspection,
        fingerprint: String,
        patchedBundleIdentifier: String
    ) throws {
        let templateProject = repositoryRoot.appendingPathComponent(
            Self.projectFileName,
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: templateProject.path) else {
            throw ProjectGenerationError.missingTemplate(templateProject.path)
        }

        let projectURL = directory.appendingPathComponent(
            Self.projectFileName,
            isDirectory: true
        )
        try fileManager.copyItem(at: templateProject, to: projectURL)
        try removeUserData(from: projectURL)

        for sharedPath in [
            "IPAPatch",
            "IPAPatch-DummyApp",
            "IPAPatch-MacDummyApp",
            "IPAPatchFrameworkMac",
            "Sources",
            "Tools",
        ] {
            try fileManager.createSymbolicLink(
                atPath: directory.appendingPathComponent(sharedPath).path,
                withDestinationPath: "../../\(sharedPath)"
            )
        }

        let assetsURL = directory.appendingPathComponent("Assets", isDirectory: true)
        try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let sharedAssets: [(String, String)] = [
            ("Dylibs", "../../../Assets/Dylibs"),
            ("Frameworks", "../../../Assets/Frameworks"),
            ("macapp.app", "../../../Assets/macapp.app"),
        ]
        for (name, destination) in sharedAssets {
            try fileManager.createSymbolicLink(
                atPath: assetsURL.appendingPathComponent(name).path,
                withDestinationPath: destination
            )
        }
        let resourcesTemplate = repositoryRoot.appendingPathComponent(
            "Assets/Resources",
            isDirectory: true
        )
        guard fileManager.fileExists(atPath: resourcesTemplate.path) else {
            throw ProjectGenerationError.missingTemplate(resourcesTemplate.path)
        }
        try fileManager.copyItem(
            at: resourcesTemplate,
            to: assetsURL.appendingPathComponent("Resources", isDirectory: true)
        )

        let inputDirectory = directory.appendingPathComponent("Input", isDirectory: true)
        try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)
        let inputIPA = inputDirectory.appendingPathComponent("App.ipa")
        try cloneOrCopyInput(from: inspection.ipaURL, to: inputIPA)

        let configDirectory = directory.appendingPathComponent("Config", isDirectory: true)
        try fileManager.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let config = """
        // Generated by IPAPatch-Lookin. Edit signing in Xcode, not this IPA path.
        IPAPATCH_INPUT_IPA = $(SRCROOT)/Input/App.ipa
        IPAPATCH_PRODUCT_BUNDLE_IDENTIFIER = \(patchedBundleIdentifier)

        """
        try Data(config.utf8).write(
            to: configDirectory.appendingPathComponent("AppConfig.xcconfig"),
            options: .atomic
        )

        let manifest = GeneratedProjectManifest(
            schemaVersion: Self.schemaVersion,
            appName: inspection.appName,
            originalBundleIdentifier: inspection.bundleIdentifier,
            patchedBundleIdentifier: patchedBundleIdentifier,
            platform: inspection.platform,
            architectures: inspection.architectures,
            ipaSHA256: fingerprint,
            inputIPAPath: "Input/App.ipa",
            projectFileName: Self.projectFileName
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var manifestData = try encoder.encode(manifest)
        manifestData.append(0x0a)
        try manifestData.write(
            to: directory.appendingPathComponent(Self.manifestFileName),
            options: .atomic
        )
    }

    private func existingProject(
        at directory: URL,
        expectedFingerprint: String?,
        repairInputFrom sourceIPA: URL?
    ) throws -> GeneratedProject {
        let directoryValues = try directory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw ProjectGenerationError.incompleteProject(directory.path)
        }
        let manifest = try loadManifest(from: directory)
        if let expectedFingerprint, manifest.ipaSHA256 != expectedFingerprint {
            throw ProjectGenerationError.fingerprintCollision(directory.path)
        }
        guard manifest.schemaVersion == Self.schemaVersion,
              manifest.projectFileName == Self.projectFileName,
              manifest.inputIPAPath == "Input/App.ipa" else {
            throw ProjectGenerationError.incompleteProject(directory.path)
        }
        let projectURL = directory.appendingPathComponent(
            Self.projectFileName,
            isDirectory: true
        )
        let inputIPA = directory.appendingPathComponent("Input/App.ipa")
        let config = directory.appendingPathComponent("Config/AppConfig.xcconfig")
        guard fileManager.fileExists(atPath: projectURL.path),
              fileManager.fileExists(atPath: config.path) else {
            throw ProjectGenerationError.incompleteProject(directory.path)
        }
        if let expectedFingerprint, let sourceIPA {
            let cachedFingerprint = try? Self.fingerprint(of: inputIPA)
            if cachedFingerprint != expectedFingerprint {
                try replaceCachedInput(from: sourceIPA, at: inputIPA)
            }
        } else if !fileManager.fileExists(atPath: inputIPA.path) {
            throw ProjectGenerationError.incompleteProject(directory.path)
        }
        return GeneratedProject(
            directoryURL: directory,
            projectURL: projectURL,
            manifest: manifest,
            wasCreated: false
        )
    }

    private func loadManifest(from directory: URL) throws -> GeneratedProjectManifest {
        let manifestURL = directory.appendingPathComponent(Self.manifestFileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw ProjectGenerationError.incompleteProject(directory.path)
        }
        return try JSONDecoder().decode(
            GeneratedProjectManifest.self,
            from: Data(contentsOf: manifestURL)
        )
    }

    private func cloneOrCopyInput(from source: URL, to destination: URL) throws {
        do {
            try CommandRunner.run(
                "/bin/cp",
                arguments: ["-c", source.path, destination.path]
            )
        } catch {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
        }
    }

    private func replaceCachedInput(from source: URL, at destination: URL) throws {
        let inputDirectory = destination.deletingLastPathComponent()
        let directoryValues = try inputDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw ProjectGenerationError.incompleteProject(inputDirectory.path)
        }

        let replacement = inputDirectory.appendingPathComponent(
            ".App.\(UUID().uuidString).tmp"
        )
        var shouldRemoveReplacement = true
        defer {
            if shouldRemoveReplacement {
                try? fileManager.removeItem(at: replacement)
            }
        }
        try cloneOrCopyInput(from: source, to: replacement)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try fileManager.moveItem(at: replacement, to: destination)
        }
        shouldRemoveReplacement = false
    }

    private func removeUserData(from projectURL: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: projectURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }
        var userDataDirectories: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "xcuserdata" {
            userDataDirectories.append(url)
            enumerator.skipDescendants()
        }
        for url in userDataDirectories {
            try fileManager.removeItem(at: url)
        }
    }

    private static func safeFileComponent(_ value: String) -> String {
        let mapped = value.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let fallback = collapsed.isEmpty ? "App" : collapsed
        return String(fallback.prefix(48))
    }
}
