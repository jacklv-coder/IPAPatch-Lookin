import Foundation
import IPAPatchLookinCore

struct PhysicalDevice: Sendable {
    let name: String
    let identifier: String
    let udid: String
    let model: String
    let available: Bool

    func matches(_ selector: String) -> Bool {
        name.caseInsensitiveCompare(selector) == .orderedSame
            || identifier.caseInsensitiveCompare(selector) == .orderedSame
            || udid.caseInsensitiveCompare(selector) == .orderedSame
    }
}

struct SimulatorDevice: Sendable {
    let name: String
    let udid: String
    let state: String
    let runtime: String

    var isBooted: Bool {
        state == "Booted"
    }

    func matches(_ selector: String) -> Bool {
        name.caseInsensitiveCompare(selector) == .orderedSame
            || udid.caseInsensitiveCompare(selector) == .orderedSame
    }
}

enum DestinationDiscovery {
    static func physicalDevices() throws -> [PhysicalDevice] {
        let jsonURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipapatch-devices-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: jsonURL)
        }

        try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: [
                "devicectl",
                "list",
                "devices",
                "--json-output",
                jsonURL.path,
                "--quiet",
            ]
        )
        let response = try JSONDecoder().decode(
            CoreDeviceResponse.self,
            from: Data(contentsOf: jsonURL)
        )
        return response.result.devices.compactMap { item in
            guard item.hardwareProperties.reality == "physical",
                  item.hardwareProperties.platform == "iOS" else {
                return nil
            }
            let udid = item.hardwareProperties.udid ?? item.identifier
            let tunnelAvailable = item.connectionProperties.tunnelState == "connected"
            let available = item.deviceProperties.ddiServicesAvailable || tunnelAvailable
            return PhysicalDevice(
                name: item.deviceProperties.name,
                identifier: item.identifier,
                udid: udid,
                model: item.hardwareProperties.marketingName ?? item.hardwareProperties.productType,
                available: available
            )
        }.sorted {
            if $0.available != $1.available {
                return $0.available && !$1.available
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func simulators() throws -> [SimulatorDevice] {
        let result = try CommandRunner.run(
            "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "available", "--json"]
        )
        let response = try JSONDecoder().decode(
            SimulatorResponse.self,
            from: Data(result.standardOutput.utf8)
        )
        return response.devices.flatMap { runtime, devices in
            guard runtime.contains("SimRuntime.iOS-") else {
                return [SimulatorDevice]()
            }
            return devices.compactMap { device in
                guard device.isAvailable else {
                    return nil
                }
                return SimulatorDevice(
                    name: device.name,
                    udid: device.udid,
                    state: device.state,
                    runtime: runtime
                )
            }
        }.sorted {
            if $0.isBooted != $1.isBooted {
                return $0.isBooted && !$1.isBooted
            }
            if $0.runtime != $1.runtime {
                return $0.runtime > $1.runtime
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func selectPhysicalDevice(
        selector: String?,
        from devices: [PhysicalDevice]
    ) throws -> PhysicalDevice {
        if let selector {
            let matches = devices.filter { $0.matches(selector) }
            guard matches.count == 1, let device = matches.first else {
                throw CLIError(destinationMatchMessage(
                    kind: "physical device",
                    selector: selector,
                    matchCount: matches.count
                ))
            }
            guard device.available else {
                throw CLIError(
                    "Physical device “\(device.name)” is unavailable. Connect and unlock it, then try again."
                )
            }
            return device
        }

        let available = devices.filter(\.available)
        if available.count == 1, let device = available.first {
            return device
        }
        if available.isEmpty {
            throw CLIError(
                "No available iPhone or iPad was found. Connect and unlock a device with Developer Mode enabled."
            )
        }
        throw CLIError(
            "Multiple physical devices are available. Pass --device <name-or-UDID> or save one with setup.\n"
                + physicalDeviceList(available)
        )
    }

    static func selectSimulator(
        selector: String?,
        from simulators: [SimulatorDevice]
    ) throws -> SimulatorDevice {
        if let selector {
            let matches = simulators.filter { $0.matches(selector) }
            guard matches.count == 1, let simulator = matches.first else {
                throw CLIError(destinationMatchMessage(
                    kind: "simulator",
                    selector: selector,
                    matchCount: matches.count
                ))
            }
            return simulator
        }

        let booted = simulators.filter(\.isBooted)
        if booted.count == 1, let simulator = booted.first {
            return simulator
        }
        if booted.count > 1 {
            throw CLIError(
                "Multiple iOS Simulators are booted. Pass --simulator <name-or-UDID> or save one with setup.\n"
                    + simulatorList(booted)
            )
        }
        guard let simulator = simulators.first else {
            throw CLIError(
                "No available iOS Simulator was found. Install an iOS Simulator runtime in Xcode."
            )
        }
        return simulator
    }

    static func physicalDeviceList(_ devices: [PhysicalDevice]) -> String {
        devices.map {
            "  \($0.available ? "✓" : "–") \($0.name) (\($0.model)) \($0.udid)"
        }.joined(separator: "\n")
    }

    static func simulatorList(_ simulators: [SimulatorDevice]) -> String {
        simulators.map {
            "  \($0.isBooted ? "✓" : "–") \($0.name) [\($0.state)] \($0.udid)"
        }.joined(separator: "\n")
    }

    private static func destinationMatchMessage(
        kind: String,
        selector: String,
        matchCount: Int
    ) -> String {
        if matchCount == 0 {
            return "No \(kind) matches “\(selector)”."
        }
        return "More than one \(kind) matches “\(selector)”; use its UDID instead."
    }
}

private struct CoreDeviceResponse: Decodable {
    let result: CoreDeviceResult
}

private struct CoreDeviceResult: Decodable {
    let devices: [CoreDevice]
}

private struct CoreDevice: Decodable {
    let identifier: String
    let connectionProperties: CoreDeviceConnection
    let deviceProperties: CoreDeviceProperties
    let hardwareProperties: CoreDeviceHardware
}

private struct CoreDeviceConnection: Decodable {
    let tunnelState: String
}

private struct CoreDeviceProperties: Decodable {
    let name: String
    let ddiServicesAvailable: Bool
}

private struct CoreDeviceHardware: Decodable {
    let marketingName: String?
    let platform: String
    let productType: String
    let reality: String
    let udid: String?
}

private struct SimulatorResponse: Decodable {
    let devices: [String: [SimulatorItem]]
}

private struct SimulatorItem: Decodable {
    let isAvailable: Bool
    let name: String
    let state: String
    let udid: String
}
