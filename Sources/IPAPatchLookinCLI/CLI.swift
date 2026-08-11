import Foundation
import IPAPatchLookinCore
import IPAPatchLookinProject

struct CLIError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? {
        message
    }
}

private struct ParsedArguments {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ arguments: [String]) throws {
        let valueOptions: Set<String> = [
            "--team",
            "--bundle-id",
            "--bundle-id-prefix",
            "--device",
            "--simulator",
            "--derived-data",
        ]
        let flagOptions: Set<String> = [
            "--build-only",
            "--no-launch",
        ]

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if let separator = argument.firstIndex(of: "="), argument.hasPrefix("--") {
                let key = String(argument[..<separator])
                let value = String(argument[argument.index(after: separator)...])
                guard valueOptions.contains(key), !value.isEmpty else {
                    throw CLIError("Unknown or invalid option: \(argument)")
                }
                values[key] = value
            } else if valueOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw CLIError("Missing value for \(argument)")
                }
                index += 1
                values[argument] = arguments[index]
            } else if flagOptions.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("-") {
                throw CLIError("Unknown option: \(argument)")
            } else {
                positionals.append(argument)
            }
            index += 1
        }
    }
}

enum CLI {
    static let version = "0.4.2"

    static func run(arguments: [String]) throws {
        let context = try ProjectContext.locate()
        let invocation = CLIInvocation(arguments: arguments)
        let command = invocation.command
        let remaining = invocation.remaining

        switch command {
        case "help", "--help", "-h":
            print(help)
        case "version", "--version":
            print(version)
        case "inspect":
            let parsed = try ParsedArguments(remaining)
            guard parsed.positionals.count == 1,
                  parsed.values.isEmpty,
                  parsed.flags.isEmpty,
                  let input = parsed.positionals.first else {
                throw CLIError("usage: ./ipapatch-lookin inspect /path/to/app.ipa")
            }
            let url = URL(
                fileURLWithPath: NSString(string: input).expandingTildeInPath
            ).standardizedFileURL
            PatchWorkflow.printInspection(try IPAInspector.inspect(ipaURL: url))
        case "devices":
            guard remaining.isEmpty else {
                throw CLIError("usage: ./ipapatch-lookin devices")
            }
            let devices = try DestinationDiscovery.physicalDevices()
            print(devices.isEmpty
                ? "No paired iPhone or iPad was found."
                : DestinationDiscovery.physicalDeviceList(devices))
        case "simulators":
            guard remaining.isEmpty else {
                throw CLIError("usage: ./ipapatch-lookin simulators")
            }
            let simulators = try DestinationDiscovery.simulators()
            print(simulators.isEmpty
                ? "No iOS Simulator was found."
                : DestinationDiscovery.simulatorList(simulators))
        case "projects":
            guard remaining.isEmpty else {
                throw CLIError("usage: ./ipapatch-lookin projects")
            }
            let projects = try context.projectGenerator.projects()
            if projects.isEmpty {
                print("No generated IPA projects were found.")
            } else {
                for project in projects {
                    print("""
                    \(project.manifest.appName)
                      source bundle id: \(project.manifest.originalBundleIdentifier)
                      patched bundle id: \(project.manifest.patchedBundleIdentifier)
                      project: \(project.projectURL.path)
                    """)
                }
            }
        case "setup":
            try setup(arguments: remaining, context: context)
        case "run":
            let parsed = try ParsedArguments(remaining)
            guard parsed.positionals.count <= 1,
                  parsed.values.isEmpty,
                  parsed.flags.isEmpty else {
                throw CLIError("usage: ./ipapatch-lookin run [/path/to/app.ipa]")
            }
            try PatchWorkflow.prepare(
                input: parsed.positionals.first,
                context: context
            )
        case "deploy":
            let parsed = try ParsedArguments(remaining)
            guard parsed.positionals.count <= 1 else {
                throw CLIError("deploy accepts at most one IPA path")
            }
            try PatchWorkflow.deploy(
                options: RunOptions(
                    input: parsed.positionals.first,
                    teamID: parsed.values["--team"],
                    bundleIdentifier: parsed.values["--bundle-id"],
                    bundleIDPrefix: parsed.values["--bundle-id-prefix"],
                    device: parsed.values["--device"],
                    simulator: parsed.values["--simulator"],
                    buildOnly: parsed.flags.contains("--build-only"),
                    noLaunch: parsed.flags.contains("--no-launch"),
                    derivedDataPath: parsed.values["--derived-data"]
                ),
                context: context
            )
        default:
            throw CLIError("Unknown command: \(command)\n\n\(help)")
        }
    }

    private static func setup(arguments: [String], context: ProjectContext) throws {
        let parsed = try ParsedArguments(arguments)
        let allowedValues: Set<String> = [
            "--team",
            "--bundle-id-prefix",
            "--device",
            "--simulator",
        ]
        guard parsed.positionals.isEmpty,
              parsed.flags.isEmpty,
              Set(parsed.values.keys).isSubset(of: allowedValues) else {
            throw CLIError("setup received an unsupported argument; run --help for its options")
        }
        let detectedTeams = ConfigurationSupport.inferredDevelopmentTeams()
        try context.configurationStore.update { configuration in
            if let team = parsed.values["--team"] {
                configuration.teamID = try ConfigurationSupport.validateTeamID(team)
            } else if configuration.teamID == nil, detectedTeams.count == 1 {
                configuration.teamID = detectedTeams.first
                print("Using detected Apple development team: \(detectedTeams[0])")
            }

            let prefixCandidate = parsed.values["--bundle-id-prefix"]
                ?? configuration.bundleIDPrefix
                ?? ConfigurationSupport.defaultBundleIDPrefix()
            configuration.bundleIDPrefix =
                try ConfigurationSupport.validateBundleIdentifier(prefixCandidate)

            if let device = parsed.values["--device"] {
                configuration.device = device
            }
            if let simulator = parsed.values["--simulator"] {
                configuration.simulator = simulator
            }
        }

        print("Saved local configuration to \(context.configurationStore.url.path)")
        print("Resolving LookinServer Swift Package")
        try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: [
                "xcodebuild",
                "-resolvePackageDependencies",
                "-project",
                context.projectURL.path,
                "-scheme",
                "IPAPatch-DummyApp",
            ],
            currentDirectory: context.root,
            captureOutput: false
        )
        print("Setup complete.")
    }

    private static let help = """
    IPAPatch-Lookin \(version)

    Usage:
      ./ipapatch-lookin /path/to/app.ipa
      ./ipapatch-lookin setup [options]
      ./ipapatch-lookin inspect /path/to/app.ipa
      ./ipapatch-lookin run [/path/to/app.ipa]
      ./ipapatch-lookin deploy [/path/to/app.ipa] [options]
      ./ipapatch-lookin projects
      ./ipapatch-lookin devices
      ./ipapatch-lookin simulators

    Setup options:
      --team TEAM_ID                Apple development team for physical devices
      --bundle-id-prefix PREFIX     Prefix used for generated patched bundle IDs
      --device NAME_OR_UDID         Default physical device
      --simulator NAME_OR_UDID      Default Simulator

    Deploy options:
      --team TEAM_ID
      --bundle-id BUNDLE_ID         Exact patched bundle identifier
      --bundle-id-prefix PREFIX
      --device NAME_OR_UDID
      --simulator NAME_OR_UDID
      --derived-data PATH
      --build-only                  Build and verify without installing
      --no-launch                   Install without launching

    Passing an IPA directly is shorthand for `run` and creates or reuses its Xcode project.
    `deploy` builds, installs, and launches from the command line.
    With no IPA path, `run` and `deploy` use the only .ipa file in Input/.
    Only decrypted IPAs you own or are authorized to inspect are supported.
    """
}

struct CLIInvocation: Equatable {
    let command: String
    let remaining: [String]

    init(arguments: [String]) {
        guard let first = arguments.first else {
            command = "help"
            remaining = []
            return
        }

        let expanded = NSString(string: first).expandingTildeInPath as NSString
        if !first.hasPrefix("-"),
           expanded.pathExtension.caseInsensitiveCompare("ipa") == .orderedSame {
            command = "run"
            remaining = arguments
        } else {
            command = first
            remaining = Array(arguments.dropFirst())
        }
    }
}
