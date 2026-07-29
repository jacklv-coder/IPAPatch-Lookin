import Foundation

public enum ByteOrder: Sendable {
    case littleEndian
    case bigEndian
}

public enum AppleBinaryPlatform: Int, Codable, Sendable {
    case macOS = 1
    case iOS = 2
    case tvOS = 3
    case watchOS = 4
    case bridgeOS = 5
    case macCatalyst = 6
    case iOSSimulator = 7
    case tvOSSimulator = 8
    case watchOSSimulator = 9
    case driverKit = 10
    case visionOS = 11
    case visionOSSimulator = 12

    public var displayName: String {
        switch self {
        case .macOS: "macOS"
        case .iOS: "iPhoneOS"
        case .tvOS: "AppleTVOS"
        case .watchOS: "WatchOS"
        case .bridgeOS: "BridgeOS"
        case .macCatalyst: "Mac Catalyst"
        case .iOSSimulator: "iPhoneSimulator"
        case .tvOSSimulator: "AppleTVSimulator"
        case .watchOSSimulator: "WatchSimulator"
        case .driverKit: "DriverKit"
        case .visionOS: "XROS"
        case .visionOSSimulator: "XRSimulator"
        }
    }
}

public struct MachOSliceInspection: Equatable, Sendable {
    public let architecture: String
    public let platform: AppleBinaryPlatform?
    public let encryptionID: UInt32?
}

public struct MachOInspection: Equatable, Sendable {
    public let slices: [MachOSliceInspection]

    public var architectures: [String] {
        slices.map(\.architecture)
    }

    public var platforms: [AppleBinaryPlatform] {
        Array(Set(slices.compactMap(\.platform))).sorted { $0.rawValue < $1.rawValue }
    }

    public var isDecrypted: Bool {
        slices.allSatisfy { ($0.encryptionID ?? 0) == 0 }
    }
}

public enum MachOError: LocalizedError, Equatable {
    case truncated(offset: Int)
    case unsupportedMagic(offset: Int)
    case emptyUniversalBinary
    case invalidUniversalSlice(index: Int)
    case invalidLoadCommandTable
    case invalidLoadCommand
    case invalidDylibCommand
    case expectedSingleLoadCommand(path: String, slice: Int, count: Int)

    public var errorDescription: String? {
        switch self {
        case let .truncated(offset):
            "Truncated Mach-O data at file offset \(offset)"
        case let .unsupportedMagic(offset):
            "Unsupported Mach-O magic at file offset \(offset)"
        case .emptyUniversalBinary:
            "Universal Mach-O contains no slices"
        case let .invalidUniversalSlice(index):
            "Invalid universal Mach-O slice \(index)"
        case .invalidLoadCommandTable:
            "Invalid Mach-O load-command table"
        case .invalidLoadCommand:
            "Invalid Mach-O load command"
        case .invalidDylibCommand:
            "Invalid Mach-O dylib load command"
        case let .expectedSingleLoadCommand(path, slice, count):
            "Expected exactly one load command for \(path) in slice \(slice), found \(count)"
        }
    }
}

public enum MachOFile {
    private static let lcLoadDylib: UInt32 = 0x0000_000c
    private static let lcLoadUpwardDylib: UInt32 = 0x8000_0023
    private static let lcBuildVersion: UInt32 = 0x0000_0032
    private static let lcEncryptionInfo: UInt32 = 0x0000_0021
    private static let lcEncryptionInfo64: UInt32 = 0x0000_002c
    private static let lcVersionMinIPhoneOS: UInt32 = 0x0000_0025

    private struct ThinFormat {
        let byteOrder: ByteOrder
        let headerSize: Int
    }

    private struct SliceDescriptor {
        let offset: Int
        let size: Int
    }

    private struct LoadCommandMatch {
        let offset: Int
        let byteOrder: ByteOrder
        let command: UInt32
    }

    public static func inspect(at url: URL) throws -> MachOInspection {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let descriptors = try sliceDescriptors(in: data)
        let slices = try descriptors.map { try inspectSlice(in: data, descriptor: $0) }
        return MachOInspection(slices: slices)
    }

    @discardableResult
    public static func normalizeLoadCommand(
        at url: URL,
        loadPath: String
    ) throws -> Int {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let descriptors = try sliceDescriptors(in: data)
        var matches: [LoadCommandMatch] = []

        for (index, descriptor) in descriptors.enumerated() {
            let sliceMatches = try matchingLoadCommands(
                in: data,
                descriptor: descriptor,
                loadPath: loadPath
            )
            guard sliceMatches.count == 1 else {
                throw MachOError.expectedSingleLoadCommand(
                    path: loadPath,
                    slice: index,
                    count: sliceMatches.count
                )
            }
            matches.append(contentsOf: sliceMatches)
        }

        let commandsToChange = matches.filter { $0.command == lcLoadUpwardDylib }
        guard !commandsToChange.isEmpty else {
            return 0
        }

        let file = try FileHandle(forUpdating: url)
        defer {
            try? file.close()
        }
        for match in commandsToChange {
            try file.seek(toOffset: UInt64(match.offset))
            try file.write(contentsOf: encodeUInt32(lcLoadDylib, byteOrder: match.byteOrder))
        }
        return commandsToChange.count
    }

    private static func sliceDescriptors(in data: Data) throws -> [SliceDescriptor] {
        let magic = try bytes(in: data, at: 0, count: 4)
        if thinFormat(for: magic) != nil {
            return [SliceDescriptor(offset: 0, size: data.count)]
        }

        let format: (ByteOrder, Int, Bool)
        switch magic {
        case [0xca, 0xfe, 0xba, 0xbe]:
            format = (.bigEndian, 20, false)
        case [0xca, 0xfe, 0xba, 0xbf]:
            format = (.bigEndian, 32, true)
        case [0xbe, 0xba, 0xfe, 0xca]:
            format = (.littleEndian, 20, false)
        case [0xbf, 0xba, 0xfe, 0xca]:
            format = (.littleEndian, 32, true)
        default:
            throw MachOError.unsupportedMagic(offset: 0)
        }

        let (byteOrder, entrySize, uses64BitOffsets) = format
        let count = Int(try readUInt32(in: data, at: 4, byteOrder: byteOrder))
        guard count > 0 else {
            throw MachOError.emptyUniversalBinary
        }
        let (tableSize, overflow) = count.multipliedReportingOverflow(by: entrySize)
        guard !overflow, 8 + tableSize <= data.count else {
            throw MachOError.truncated(offset: data.count)
        }

        return try (0..<count).map { index in
            let entryOffset = 8 + (index * entrySize)
            let sliceOffset: UInt64
            let sliceSize: UInt64
            if uses64BitOffsets {
                sliceOffset = try readUInt64(
                    in: data,
                    at: entryOffset + 8,
                    byteOrder: byteOrder
                )
                sliceSize = try readUInt64(
                    in: data,
                    at: entryOffset + 16,
                    byteOrder: byteOrder
                )
            } else {
                sliceOffset = UInt64(try readUInt32(
                    in: data,
                    at: entryOffset + 8,
                    byteOrder: byteOrder
                ))
                sliceSize = UInt64(try readUInt32(
                    in: data,
                    at: entryOffset + 12,
                    byteOrder: byteOrder
                ))
            }

            guard sliceSize > 0,
                  sliceOffset <= UInt64(Int.max),
                  sliceSize <= UInt64(Int.max),
                  sliceOffset + sliceSize <= UInt64(data.count)
            else {
                throw MachOError.invalidUniversalSlice(index: index)
            }
            return SliceDescriptor(offset: Int(sliceOffset), size: Int(sliceSize))
        }
    }

    private static func inspectSlice(
        in data: Data,
        descriptor: SliceDescriptor
    ) throws -> MachOSliceInspection {
        let magic = try bytes(in: data, at: descriptor.offset, count: 4)
        guard let format = thinFormat(for: magic) else {
            throw MachOError.unsupportedMagic(offset: descriptor.offset)
        }

        let cpuType = try readUInt32(
            in: data,
            at: descriptor.offset + 4,
            byteOrder: format.byteOrder
        )
        let cpuSubtype = try readUInt32(
            in: data,
            at: descriptor.offset + 8,
            byteOrder: format.byteOrder
        )
        var platform: AppleBinaryPlatform?
        var encryptionID: UInt32?

        try forEachLoadCommand(in: data, descriptor: descriptor, format: format) {
            command, offset, size in
            switch command {
            case lcBuildVersion where size >= 24:
                let rawPlatform = try readUInt32(
                    in: data,
                    at: offset + 8,
                    byteOrder: format.byteOrder
                )
                platform = AppleBinaryPlatform(rawValue: Int(rawPlatform))
            case lcVersionMinIPhoneOS where size >= 16:
                platform = inferredLegacyIOSPlatform(cpuType: cpuType)
            case lcEncryptionInfo where size >= 20,
                 lcEncryptionInfo64 where size >= 20:
                encryptionID = try readUInt32(
                    in: data,
                    at: offset + 16,
                    byteOrder: format.byteOrder
                )
            default:
                break
            }
        }

        return MachOSliceInspection(
            architecture: architectureName(cpuType: cpuType, cpuSubtype: cpuSubtype),
            platform: platform,
            encryptionID: encryptionID
        )
    }

    private static func matchingLoadCommands(
        in data: Data,
        descriptor: SliceDescriptor,
        loadPath: String
    ) throws -> [LoadCommandMatch] {
        let magic = try bytes(in: data, at: descriptor.offset, count: 4)
        guard let format = thinFormat(for: magic) else {
            throw MachOError.unsupportedMagic(offset: descriptor.offset)
        }
        var matches: [LoadCommandMatch] = []

        try forEachLoadCommand(in: data, descriptor: descriptor, format: format) {
            command, offset, size in
            guard command == lcLoadDylib || command == lcLoadUpwardDylib else {
                return
            }
            guard size >= 24 else {
                throw MachOError.invalidDylibCommand
            }
            let nameOffset = Int(try readUInt32(
                in: data,
                at: offset + 8,
                byteOrder: format.byteOrder
            ))
            guard nameOffset >= 24, nameOffset < size else {
                throw MachOError.invalidDylibCommand
            }

            let nameBytes = try bytes(
                in: data,
                at: offset + nameOffset,
                count: size - nameOffset
            )
            let terminated = nameBytes.prefix { $0 != 0 }
            guard let name = String(bytes: terminated, encoding: .utf8) else {
                return
            }
            if name == loadPath {
                matches.append(
                    LoadCommandMatch(
                        offset: offset,
                        byteOrder: format.byteOrder,
                        command: command
                    )
                )
            }
        }
        return matches
    }

    private static func forEachLoadCommand(
        in data: Data,
        descriptor: SliceDescriptor,
        format: ThinFormat,
        body: (_ command: UInt32, _ offset: Int, _ size: Int) throws -> Void
    ) throws {
        let commandCount = Int(try readUInt32(
            in: data,
            at: descriptor.offset + 16,
            byteOrder: format.byteOrder
        ))
        let commandsSize = Int(try readUInt32(
            in: data,
            at: descriptor.offset + 20,
            byteOrder: format.byteOrder
        ))
        var commandOffset = descriptor.offset + format.headerSize
        let commandsEnd = commandOffset + commandsSize
        let sliceEnd = descriptor.offset + descriptor.size
        guard commandsEnd <= sliceEnd, commandsEnd <= data.count else {
            throw MachOError.invalidLoadCommandTable
        }

        for _ in 0..<commandCount {
            guard commandOffset + 8 <= commandsEnd else {
                throw MachOError.invalidLoadCommand
            }
            let command = try readUInt32(
                in: data,
                at: commandOffset,
                byteOrder: format.byteOrder
            )
            let size = Int(try readUInt32(
                in: data,
                at: commandOffset + 4,
                byteOrder: format.byteOrder
            ))
            guard size >= 8, commandOffset + size <= commandsEnd else {
                throw MachOError.invalidLoadCommand
            }
            try body(command, commandOffset, size)
            commandOffset += size
        }
        guard commandOffset <= commandsEnd else {
            throw MachOError.invalidLoadCommandTable
        }
    }

    private static func thinFormat(for magic: [UInt8]) -> ThinFormat? {
        switch magic {
        case [0xce, 0xfa, 0xed, 0xfe]:
            ThinFormat(byteOrder: .littleEndian, headerSize: 28)
        case [0xcf, 0xfa, 0xed, 0xfe]:
            ThinFormat(byteOrder: .littleEndian, headerSize: 32)
        case [0xfe, 0xed, 0xfa, 0xce]:
            ThinFormat(byteOrder: .bigEndian, headerSize: 28)
        case [0xfe, 0xed, 0xfa, 0xcf]:
            ThinFormat(byteOrder: .bigEndian, headerSize: 32)
        default:
            nil
        }
    }

    private static func inferredLegacyIOSPlatform(cpuType: UInt32) -> AppleBinaryPlatform {
        switch cpuType {
        case 0x0100_0007, 0x0000_0007:
            .iOSSimulator
        default:
            .iOS
        }
    }

    private static func architectureName(cpuType: UInt32, cpuSubtype: UInt32) -> String {
        switch cpuType {
        case 0x0100_000c:
            let subtype = cpuSubtype & 0x00ff_ffff
            return subtype == 2 ? "arm64e" : "arm64"
        case 0x0000_000c:
            return "arm"
        case 0x0100_0007:
            return "x86_64"
        case 0x0000_0007:
            return "i386"
        default:
            return String(format: "cpu-0x%08x", cpuType)
        }
    }

    private static func bytes(in data: Data, at offset: Int, count: Int) throws -> [UInt8] {
        guard offset >= 0, count >= 0, offset + count <= data.count else {
            throw MachOError.truncated(offset: offset)
        }
        return Array(data[offset..<(offset + count)])
    }

    private static func readUInt32(
        in data: Data,
        at offset: Int,
        byteOrder: ByteOrder
    ) throws -> UInt32 {
        let value = try bytes(in: data, at: offset, count: 4)
        switch byteOrder {
        case .littleEndian:
            return UInt32(value[0])
                | (UInt32(value[1]) << 8)
                | (UInt32(value[2]) << 16)
                | (UInt32(value[3]) << 24)
        case .bigEndian:
            return (UInt32(value[0]) << 24)
                | (UInt32(value[1]) << 16)
                | (UInt32(value[2]) << 8)
                | UInt32(value[3])
        }
    }

    private static func readUInt64(
        in data: Data,
        at offset: Int,
        byteOrder: ByteOrder
    ) throws -> UInt64 {
        let value = try bytes(in: data, at: offset, count: 8)
        switch byteOrder {
        case .littleEndian:
            return value.enumerated().reduce(UInt64(0)) { result, item in
                result | (UInt64(item.element) << UInt64(item.offset * 8))
            }
        case .bigEndian:
            return value.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
    }

    private static func encodeUInt32(_ value: UInt32, byteOrder: ByteOrder) -> Data {
        let bytes: [UInt8]
        switch byteOrder {
        case .littleEndian:
            bytes = [
                UInt8(truncatingIfNeeded: value),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 24),
            ]
        case .bigEndian:
            bytes = [
                UInt8(truncatingIfNeeded: value >> 24),
                UInt8(truncatingIfNeeded: value >> 16),
                UInt8(truncatingIfNeeded: value >> 8),
                UInt8(truncatingIfNeeded: value),
            ]
        }
        return Data(bytes)
    }
}
