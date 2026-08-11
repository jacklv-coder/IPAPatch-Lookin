import Foundation
import Testing
@testable import IPAPatchLookinCore
@testable import IPAPatchLookinProject

struct ProjectGeneratorTests {
    @Test
    func generatesIndependentProjectsAndReusesMatchingIPA() throws {
        let fixture = try ProjectRepositoryFixture()
        defer { fixture.remove() }
        let generator = ProjectGenerator(repositoryRoot: fixture.root)

        let firstIPA = try fixture.makeIPA(named: "First.ipa", contents: "first")
        let secondIPA = try fixture.makeIPA(named: "Second.ipa", contents: "second")
        let firstFingerprint = try ProjectGenerator.fingerprint(of: firstIPA)
        let secondFingerprint = try ProjectGenerator.fingerprint(of: secondIPA)

        let first = try generator.generate(
            inspection: fixture.inspection(for: firstIPA, appName: "Demo App"),
            fingerprint: firstFingerprint,
            patchedBundleIdentifier: "com.example.demo.first"
        )
        let second = try generator.generate(
            inspection: fixture.inspection(for: secondIPA, appName: "Demo App"),
            fingerprint: secondFingerprint,
            patchedBundleIdentifier: "com.example.demo.second"
        )
        let reused = try generator.generate(
            inspection: fixture.inspection(for: firstIPA, appName: "Demo App"),
            fingerprint: firstFingerprint,
            patchedBundleIdentifier: "com.example.changed"
        )
        let cachedInput = first.directoryURL.appendingPathComponent("Input/App.ipa")
        try fileManager.removeItem(at: cachedInput)
        let repairedMissingInput = try generator.generate(
            inspection: fixture.inspection(for: firstIPA, appName: "Demo App"),
            fingerprint: firstFingerprint,
            patchedBundleIdentifier: "com.example.changed"
        )
        try Data("tampered".utf8).write(to: cachedInput)
        let repairedMismatchedInput = try generator.generate(
            inspection: fixture.inspection(for: firstIPA, appName: "Demo App"),
            fingerprint: firstFingerprint,
            patchedBundleIdentifier: "com.example.changed"
        )

        #expect(first.wasCreated)
        #expect(second.wasCreated)
        #expect(!reused.wasCreated)
        #expect(!repairedMissingInput.wasCreated)
        #expect(!repairedMismatchedInput.wasCreated)
        #expect(first.directoryURL != second.directoryURL)
        #expect(reused.directoryURL == first.directoryURL)
        #expect(reused.manifest.patchedBundleIdentifier == "com.example.demo.first")
        #expect(try Data(contentsOf: cachedInput) == Data("first".utf8))
        #expect(try Data(contentsOf: second.directoryURL.appendingPathComponent("Input/App.ipa")) == Data("second".utf8))
        #expect(fileManager.fileExists(atPath: first.projectURL.path))
        #expect(try symbolicDestination(first.directoryURL.appendingPathComponent("Tools")) == "../../Tools")

        let config = try String(
            contentsOf: first.directoryURL.appendingPathComponent("Config/AppConfig.xcconfig"),
            encoding: .utf8
        )
        #expect(config.contains("IPAPATCH_INPUT_IPA = $(SRCROOT)/Input/App.ipa"))
        #expect(config.contains("IPAPATCH_PRODUCT_BUNDLE_IDENTIFIER = com.example.demo.first"))
        let expectedProjects = Set([first, second].map(\.directoryURL))
        let listedProjects = Set(try generator.projects().map(\.directoryURL))
        #expect(listedProjects == expectedProjects)
    }

    @Test
    func rejectsAProjectDirectoryWithMismatchedManifest() throws {
        let fixture = try ProjectRepositoryFixture()
        defer { fixture.remove() }
        let generator = ProjectGenerator(repositoryRoot: fixture.root)
        let ipa = try fixture.makeIPA(named: "Demo.ipa", contents: "demo")
        let fingerprint = try ProjectGenerator.fingerprint(of: ipa)
        let generated = try generator.generate(
            inspection: fixture.inspection(for: ipa, appName: "Demo"),
            fingerprint: fingerprint,
            patchedBundleIdentifier: "com.example.demo"
        )

        var manifest = generated.manifest
        let replacement = GeneratedProjectManifest(
            schemaVersion: manifest.schemaVersion,
            appName: manifest.appName,
            originalBundleIdentifier: manifest.originalBundleIdentifier,
            patchedBundleIdentifier: manifest.patchedBundleIdentifier,
            platform: manifest.platform,
            architectures: manifest.architectures,
            ipaSHA256: String(repeating: "0", count: 64),
            inputIPAPath: manifest.inputIPAPath,
            projectFileName: manifest.projectFileName
        )
        manifest = replacement
        let encoder = JSONEncoder()
        try encoder.encode(manifest).write(
            to: generated.directoryURL.appendingPathComponent(ProjectGenerator.manifestFileName)
        )

        #expect(throws: ProjectGenerationError.fingerprintCollision(generated.directoryURL.path)) {
            try generator.generate(
                inspection: fixture.inspection(for: ipa, appName: "Demo"),
                fingerprint: fingerprint,
                patchedBundleIdentifier: "com.example.demo"
            )
        }
    }

    private var fileManager: FileManager { .default }

    private func symbolicDestination(_ url: URL) throws -> String {
        try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
    }
}

private struct ProjectRepositoryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAPatchProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeDirectory("IPAPatch.xcodeproj")
        try Data("// project".utf8).write(
            to: root.appendingPathComponent("IPAPatch.xcodeproj/project.pbxproj")
        )
        for path in [
            "IPAPatch",
            "IPAPatch-DummyApp",
            "IPAPatch-MacDummyApp",
            "IPAPatchFrameworkMac",
            "Sources",
            "Tools",
            "Assets/Dylibs",
            "Assets/Frameworks",
            "Assets/macapp.app",
            "Assets/Resources",
        ] {
            try makeDirectory(path)
        }
        try Data("plist".utf8).write(
            to: root.appendingPathComponent("Assets/Resources/config.plist")
        )
    }

    func makeIPA(named name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func inspection(for ipaURL: URL, appName: String) -> IPAInspection {
        IPAInspection(
            ipaURL: ipaURL,
            appName: appName,
            executableName: "Demo",
            bundleIdentifier: "com.example.demo",
            platform: .device,
            architectures: ["arm64"],
            encryptionIDs: [0]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true
        )
    }
}
