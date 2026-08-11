import Foundation
import IPAPatchLookinCore
import IPAPatchLookinProject

struct ProjectContext {
    let root: URL

    var projectURL: URL {
        root.appendingPathComponent("IPAPatch.xcodeproj", isDirectory: true)
    }

    var inputDirectory: URL {
        root.appendingPathComponent("Input", isDirectory: true)
    }

    var configurationStore: ConfigurationStore {
        ConfigurationStore(url: root.appendingPathComponent(".ipapatch-lookin.json"))
    }

    var projectGenerator: ProjectGenerator {
        ProjectGenerator(repositoryRoot: root)
    }

    static func locate() throws -> ProjectContext {
        if let explicitRoot = ProcessInfo.processInfo.environment["IPAPATCH_PROJECT_ROOT"],
           !explicitRoot.isEmpty {
            let root = URL(fileURLWithPath: explicitRoot).standardizedFileURL
            return try validated(root)
        }

        var candidate = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        while candidate.path != "/" {
            if FileManager.default.fileExists(
                atPath: candidate.appendingPathComponent("IPAPatch.xcodeproj").path
            ) {
                return ProjectContext(root: candidate)
            }
            candidate.deleteLastPathComponent()
        }
        throw CLIError(
            "Could not locate IPAPatch.xcodeproj. Run the repository’s ./ipapatch-lookin wrapper."
        )
    }

    private static func validated(_ root: URL) throws -> ProjectContext {
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("IPAPatch.xcodeproj").path
        ) else {
            throw CLIError("Invalid IPAPATCH_PROJECT_ROOT: \(root.path)")
        }
        return ProjectContext(root: root)
    }
}

struct RunOptions {
    let input: String?
    let teamID: String?
    let bundleIdentifier: String?
    let bundleIDPrefix: String?
    let device: String?
    let simulator: String?
    let buildOnly: Bool
    let noLaunch: Bool
    let derivedDataPath: String?
}

enum PatchWorkflow {
    static func prepare(input: String?, context: ProjectContext) throws {
        let ipaURL = try resolveInput(input, in: context)

        print("Inspecting \(ipaURL.path)")
        let inspection = try IPAInspector.inspect(ipaURL: ipaURL)
        printInspection(inspection)
        try validateArchitecture(inspection)

        let configuration = try context.configurationStore.load()
        let prefix = try ConfigurationSupport.validateBundleIdentifier(
            configuration.bundleIDPrefix
                ?? ConfigurationSupport.defaultBundleIDPrefix()
        )
        let fingerprint = try ProjectGenerator.fingerprint(of: ipaURL)
        let bundleIdentifier = try ConfigurationSupport.validateBundleIdentifier(
            derivedBundleIdentifier(
                prefix: prefix,
                original: inspection.bundleIdentifier,
                discriminator: fingerprint
            )
        )
        let generatedProject = try context.configurationStore.withPreparationLock {
            try context.projectGenerator.generate(
                inspection: inspection,
                fingerprint: fingerprint,
                patchedBundleIdentifier: bundleIdentifier
            )
        }

        print(generatedProject.wasCreated
            ? "Created independent project for this IPA"
            : "Reusing existing project for this IPA")
        print("Resolving LookinServer Swift Package")
        try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "-resolvePackageDependencies",
                "-project",
                generatedProject.projectURL.path,
                "-scheme",
                "IPAPatch-DummyApp",
            ],
            currentDirectory: generatedProject.directoryURL,
            captureOutput: false
        )

        let destinationInstruction: String
        switch inspection.platform {
        case .device:
            destinationInstruction = "a connected physical iPhone or iPad"
        case .simulator:
            destinationInstruction =
                "an iOS Simulator matching \(inspection.architectures.joined(separator: ", "))"
        }

        print("""
        Xcode project ready:
          \(generatedProject.projectURL.path)

        Open it, select the IPAPatch-DummyApp scheme and
        \(destinationInstruction), then press Cmd-R.
        """)
    }

    static func deploy(options: RunOptions, context: ProjectContext) throws {
        let configuration = try context.configurationStore.load()
        let ipaURL = try resolveInput(options.input, in: context)

        print("Inspecting \(ipaURL.path)")
        let inspection = try IPAInspector.inspect(ipaURL: ipaURL)
        printInspection(inspection)
        try validateArchitecture(inspection)

        let prefix = try ConfigurationSupport.validateBundleIdentifier(
            options.bundleIDPrefix
                ?? configuration.bundleIDPrefix
                ?? ConfigurationSupport.defaultBundleIDPrefix()
        )
        let bundleIdentifier = try ConfigurationSupport.validateBundleIdentifier(
            options.bundleIdentifier
                ?? derivedBundleIdentifier(
                    prefix: prefix,
                    original: inspection.bundleIdentifier,
                    discriminator: nil
                )
        )
        let derivedData = try resolveDerivedData(
            explicitPath: options.derivedDataPath,
            bundleIdentifier: bundleIdentifier
        )

        switch inspection.platform {
        case .device:
            try runOnDevice(
                inspection: inspection,
                bundleIdentifier: bundleIdentifier,
                teamID: options.teamID ?? configuration.teamID,
                deviceSelector: options.device ?? configuration.device,
                buildOnly: options.buildOnly,
                noLaunch: options.noLaunch,
                derivedData: derivedData,
                context: context
            )
        case .simulator:
            try runOnSimulator(
                inspection: inspection,
                bundleIdentifier: bundleIdentifier,
                simulatorSelector: options.simulator ?? configuration.simulator,
                buildOnly: options.buildOnly,
                noLaunch: options.noLaunch,
                derivedData: derivedData,
                context: context
            )
        }
    }

    static func printInspection(_ inspection: IPAInspection) {
        let cryptIDs = inspection.encryptionIDs.compactMap { $0 }
        let cryptDescription = cryptIDs.isEmpty
            ? "not present"
            : cryptIDs.map(String.init).joined(separator: ", ")
        print("""
          app: \(inspection.appName)
          bundle id: \(inspection.bundleIdentifier)
          platform: \(inspection.platform.displayName)
          architectures: \(inspection.architectures.joined(separator: ", "))
          cryptid: \(cryptDescription)
        """)
    }

    private static func validateArchitecture(_ inspection: IPAInspection) throws {
        switch inspection.platform {
        case .device:
            guard inspection.architectures.contains(where: {
                $0 == "arm64" || $0 == "arm64e"
            }) else {
                throw CLIError(
                    "The iPhoneOS IPA does not contain a supported 64-bit ARM architecture."
                )
            }
        case .simulator:
            let hostArchitecture = try CommandRunner.run(
                "/usr/bin/uname",
                arguments: ["-m"]
            ).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard inspection.architectures.contains(hostArchitecture) else {
                throw CLIError(
                    "The Simulator IPA contains \(inspection.architectures.joined(separator: ", ")), "
                        + "but this Mac requires a \(hostArchitecture) iPhoneSimulator slice."
                )
            }
        }
    }

    private static func runOnDevice(
        inspection: IPAInspection,
        bundleIdentifier: String,
        teamID: String?,
        deviceSelector: String?,
        buildOnly: Bool,
        noLaunch: Bool,
        derivedData: URL,
        context: ProjectContext
    ) throws {
        if buildOnly {
            let app = try build(
                inspection: inspection,
                bundleIdentifier: bundleIdentifier,
                teamID: nil,
                destination: "generic/platform=iOS",
                productDirectory: "Debug-iphoneos",
                derivedData: derivedData,
                unsigned: true,
                context: context
            )
            try verify(app: app, context: context)
            print("Unsigned patched app: \(app.path)")
            return
        }

        let teams = ConfigurationSupport.inferredDevelopmentTeams()
        let resolvedTeam: String
        if let teamID {
            resolvedTeam = try ConfigurationSupport.validateTeamID(teamID)
        } else if teams.count == 1, let team = teams.first {
            resolvedTeam = team
            print("Using detected Apple development team: \(team)")
        } else {
            throw CLIError(
                "A development team is required for an iPhoneOS IPA. Run setup --team <TEAM_ID> or pass --team."
            )
        }

        let devices = try DestinationDiscovery.physicalDevices()
        let device = try DestinationDiscovery.selectPhysicalDevice(
            selector: deviceSelector,
            from: devices
        )
        print("Destination: \(device.name) (\(device.udid))")

        let app = try build(
            inspection: inspection,
            bundleIdentifier: bundleIdentifier,
            teamID: resolvedTeam,
            destination: "platform=iOS,id=\(device.udid)",
            productDirectory: "Debug-iphoneos",
            derivedData: derivedData,
            unsigned: false,
            context: context
        )
        try verify(app: app, context: context)
        if buildOnly {
            print("Signed patched app: \(app.path)")
            return
        }

        print("Installing \(bundleIdentifier)")
        try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl",
                "device",
                "install",
                "app",
                "--device",
                device.udid,
                app.path,
            ],
            captureOutput: false
        )
        if !noLaunch {
            print("Launching \(bundleIdentifier)")
            try CommandRunner.run(
                "/usr/bin/xcrun",
                arguments: [
                    "devicectl",
                    "device",
                    "process",
                    "launch",
                    "--terminate-existing",
                    "--device",
                    device.udid,
                    bundleIdentifier,
                ],
                captureOutput: false
            )
        }
        print("Done. Open Lookin on the Mac and select the running app.")
    }

    private static func runOnSimulator(
        inspection: IPAInspection,
        bundleIdentifier: String,
        simulatorSelector: String?,
        buildOnly: Bool,
        noLaunch: Bool,
        derivedData: URL,
        context: ProjectContext
    ) throws {
        let simulators = try DestinationDiscovery.simulators()
        let simulator = try DestinationDiscovery.selectSimulator(
            selector: simulatorSelector,
            from: simulators
        )
        print("Destination: \(simulator.name) (\(simulator.udid))")

        if !simulator.isBooted {
            print("Booting \(simulator.name)")
            try CommandRunner.run(
                "/usr/bin/xcrun",
                arguments: ["simctl", "boot", simulator.udid]
            )
            try CommandRunner.run(
                "/usr/bin/xcrun",
                arguments: ["simctl", "bootstatus", simulator.udid, "-b"],
                captureOutput: false
            )
        }

        let app = try build(
            inspection: inspection,
            bundleIdentifier: bundleIdentifier,
            teamID: nil,
            destination: "platform=iOS Simulator,id=\(simulator.udid)",
            productDirectory: "Debug-iphonesimulator",
            derivedData: derivedData,
            unsigned: false,
            context: context
        )
        try verify(app: app, context: context)
        if buildOnly {
            print("Patched Simulator app: \(app.path)")
            return
        }

        print("Installing \(bundleIdentifier)")
        try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "install", simulator.udid, app.path],
            captureOutput: false
        )
        if !noLaunch {
            print("Launching \(bundleIdentifier)")
            try CommandRunner.run(
                "/usr/bin/xcrun",
                arguments: [
                    "simctl",
                    "launch",
                    "--terminate-running-process",
                    simulator.udid,
                    bundleIdentifier,
                ],
                captureOutput: false
            )
        }
        print("Done. Open Lookin on the Mac and select the running app.")
    }

    private static func build(
        inspection: IPAInspection,
        bundleIdentifier: String,
        teamID: String?,
        destination: String,
        productDirectory: String,
        derivedData: URL,
        unsigned: Bool,
        context: ProjectContext
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: derivedData,
            withIntermediateDirectories: true
        )
        var arguments = [
            "xcodebuild",
            "-quiet",
            "-project", context.projectURL.path,
            "-scheme", "IPAPatch-DummyApp",
            "-configuration", "Debug",
            "-destination", destination,
            "-derivedDataPath", derivedData.path,
            "IPAPATCH_INPUT_IPA=\(inspection.ipaURL.path)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(bundleIdentifier)",
        ]
        if unsigned {
            arguments.append("CODE_SIGNING_ALLOWED=NO")
        } else if let teamID {
            arguments.insert(contentsOf: ["-allowProvisioningUpdates"], at: 1)
            arguments.append("DEVELOPMENT_TEAM=\(teamID)")
        }
        arguments.append("build")

        print("Building and injecting LookinServer")
        try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: arguments,
            currentDirectory: context.root,
            captureOutput: false
        )
        let app = derivedData
            .appendingPathComponent("Build/Products")
            .appendingPathComponent(productDirectory)
            .appendingPathComponent("IPAPatch-DummyApp.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw CLIError("Xcode build succeeded but the patched app was not found at \(app.path)")
        }
        return app
    }

    private static func verify(app: URL, context: ProjectContext) throws {
        try CommandRunner.run(
            context.root.appendingPathComponent("Tools/verify_patch.sh").path,
            arguments: [app.path],
            currentDirectory: context.root,
            captureOutput: false
        )
    }

    private static func resolveInput(
        _ suppliedPath: String?,
        in context: ProjectContext
    ) throws -> URL {
        if let suppliedPath {
            let expanded = NSString(string: suppliedPath).expandingTildeInPath
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        let candidates = ((try? FileManager.default.contentsOfDirectory(
            at: context.inputDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []).filter { $0.pathExtension.caseInsensitiveCompare("ipa") == .orderedSame }
        guard candidates.count == 1, let ipa = candidates.first else {
            if candidates.isEmpty {
                throw CLIError(
                    "No IPA was provided. Drag one after `./ipapatch-lookin run` "
                        + "or place exactly one .ipa in \(context.inputDirectory.path)."
                )
            }
            throw CLIError(
                "Input contains multiple IPA files. Pass the desired IPA path explicitly."
            )
        }
        return ipa.standardizedFileURL
    }

    private static func resolveDerivedData(
        explicitPath: String?,
        bundleIdentifier: String
    ) throws -> URL {
        if let explicitPath {
            return URL(
                fileURLWithPath: NSString(string: explicitPath).expandingTildeInPath,
                isDirectory: true
            ).standardizedFileURL
        }
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return caches
            .appendingPathComponent("IPAPatch-Lookin", isDirectory: true)
            .appendingPathComponent(shortHash(bundleIdentifier), isDirectory: true)
            .appendingPathComponent("DerivedData", isDirectory: true)
    }

    private static func derivedBundleIdentifier(
        prefix: String,
        original: String,
        discriminator: String?
    ) -> String {
        let slug = original.split(separator: ".").last.map(String.init) ?? "app"
        let safeSlug = slug.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let base = "\(prefix).\(String(safeSlug)).\(shortHash(original))"
        if let discriminator {
            return "\(base).\(discriminator)"
        }
        return base
    }

    private static func shortHash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%012llx", hash & 0x0000_ffff_ffff_ffff)
    }
}
