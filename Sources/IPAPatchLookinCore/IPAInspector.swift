import Foundation

public enum IPAPlatform: String, Codable, Sendable {
    case device
    case simulator

    public var displayName: String {
        switch self {
        case .device: "iPhoneOS"
        case .simulator: "iPhoneSimulator"
        }
    }
}

public struct IPAInspection: Equatable, Sendable {
    public let ipaURL: URL
    public let appName: String
    public let executableName: String
    public let bundleIdentifier: String
    public let platform: IPAPlatform
    public let architectures: [String]
    public let encryptionIDs: [UInt32?]

    public var isDecrypted: Bool {
        encryptionIDs.allSatisfy { ($0 ?? 0) == 0 }
    }
}

public enum IPAInspectionError: LocalizedError, Equatable {
    case missingIPA(String)
    case emptyIPA(String)
    case invalidPayload(appCount: Int)
    case missingInfoPlist
    case invalidInfoPlist
    case missingInfoValue(String)
    case unsupportedPlatform(String)
    case missingExecutable(String)
    case encrypted([UInt32])

    public var errorDescription: String? {
        switch self {
        case let .missingIPA(path):
            "IPA does not exist: \(path)"
        case let .emptyIPA(path):
            "IPA is empty: \(path)"
        case let .invalidPayload(appCount):
            "Expected exactly one Payload/*.app in the IPA, found \(appCount)"
        case .missingInfoPlist:
            "The app bundle does not contain Info.plist"
        case .invalidInfoPlist:
            "The app bundle contains an invalid Info.plist"
        case let .missingInfoValue(key):
            "Info.plist is missing \(key)"
        case let .unsupportedPlatform(platform):
            "Unsupported app platform: \(platform)"
        case let .missingExecutable(name):
            "The app executable is missing: \(name)"
        case let .encrypted(ids):
            "The IPA is still encrypted (cryptid: \(ids.map(String.init).joined(separator: ", ")))"
        }
    }
}

public enum IPAInspector {
    public static func inspect(ipaURL: URL) throws -> IPAInspection {
        let standardized = ipaURL.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: standardized.path,
            isDirectory: &isDirectory
        ), !isDirectory.boolValue else {
            throw IPAInspectionError.missingIPA(standardized.path)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: standardized.path)
        guard (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw IPAInspectionError.emptyIPA(standardized.path)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAPatchLookin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        try CommandRunner.run(
            "/usr/bin/unzip",
            arguments: ["-oqq", standardized.path, "-d", directory.path]
        )
        return try inspectExtractedApp(in: directory, ipaURL: standardized)
    }

    public static func inspectApp(
        at appURL: URL,
        ipaURL: URL? = nil
    ) throws -> IPAInspection {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoURL.path) else {
            throw IPAInspectionError.missingInfoPlist
        }
        let plistData = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization.propertyList(
            from: plistData,
            options: [],
            format: nil
        ) as? [String: Any] else {
            throw IPAInspectionError.invalidInfoPlist
        }

        guard let executable = plist["CFBundleExecutable"] as? String,
              !executable.isEmpty else {
            throw IPAInspectionError.missingInfoValue("CFBundleExecutable")
        }
        guard let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              !bundleIdentifier.isEmpty else {
            throw IPAInspectionError.missingInfoValue("CFBundleIdentifier")
        }

        let executableURL = appURL.appendingPathComponent(executable)
        guard FileManager.default.fileExists(atPath: executableURL.path) else {
            throw IPAInspectionError.missingExecutable(executable)
        }
        let machO = try MachOFile.inspect(at: executableURL)
        let declaredPlatform = (plist["CFBundleSupportedPlatforms"] as? [String])?.first
        let platform = try resolvePlatform(
            declaredPlatform: declaredPlatform,
            machOPlatforms: machO.platforms
        )
        let encryptionIDs = machO.slices.map(\.encryptionID)
        let nonzeroEncryptionIDs = encryptionIDs.compactMap { $0 }.filter { $0 != 0 }
        if !nonzeroEncryptionIDs.isEmpty {
            throw IPAInspectionError.encrypted(nonzeroEncryptionIDs)
        }

        return IPAInspection(
            ipaURL: ipaURL ?? appURL,
            appName: appURL.deletingPathExtension().lastPathComponent,
            executableName: executable,
            bundleIdentifier: bundleIdentifier,
            platform: platform,
            architectures: machO.architectures,
            encryptionIDs: encryptionIDs
        )
    }

    private static func inspectExtractedApp(
        in directory: URL,
        ipaURL: URL
    ) throws -> IPAInspection {
        let payload = directory.appendingPathComponent("Payload", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: payload,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let apps = contents.filter { url in
            guard url.pathExtension.lowercased() == "app" else {
                return false
            }
            return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        guard apps.count == 1, let app = apps.first else {
            throw IPAInspectionError.invalidPayload(appCount: apps.count)
        }
        return try inspectApp(at: app, ipaURL: ipaURL)
    }

    private static func resolvePlatform(
        declaredPlatform: String?,
        machOPlatforms: [AppleBinaryPlatform]
    ) throws -> IPAPlatform {
        let declared: IPAPlatform?
        if let declaredPlatform {
            switch declaredPlatform {
            case "iPhoneOS":
                declared = .device
            case "iPhoneSimulator":
                declared = .simulator
            default:
                throw IPAInspectionError.unsupportedPlatform(declaredPlatform)
            }
        } else {
            declared = nil
        }

        let binary: IPAPlatform?
        if machOPlatforms.isEmpty {
            binary = nil
        } else if machOPlatforms.allSatisfy({ $0 == .iOS }) {
            binary = .device
        } else if machOPlatforms.allSatisfy({ $0 == .iOSSimulator }) {
            binary = .simulator
        } else {
            let names = machOPlatforms.map(\.displayName).joined(separator: ", ")
            throw IPAInspectionError.unsupportedPlatform(
                names.isEmpty ? "unknown" : names
            )
        }

        if let declared, let binary, declared != binary {
            throw IPAInspectionError.unsupportedPlatform(
                "Info.plist declares \(declared.displayName), but Mach-O contains \(binary.displayName)"
            )
        }
        if let declared {
            return declared
        }
        if let binary {
            return binary
        }
        throw IPAInspectionError.unsupportedPlatform("unknown")
    }
}
