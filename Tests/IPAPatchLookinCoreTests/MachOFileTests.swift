import Foundation
import Testing
@testable import IPAPatchLookinCore

struct MachOFileTests {
    private let loadPath = "@executable_path/Dylibs/IPAPatchFramework"

    @Test
    func normalizesThinMachO() throws {
        let fixture = try TemporaryFixture(data: thinMachO(command: 0x8000_0023))
        defer { fixture.remove() }

        let changed = try MachOFile.normalizeLoadCommand(
            at: fixture.url,
            loadPath: loadPath
        )
        #expect(changed == 1)
        #expect(try commandTypes(in: Data(contentsOf: fixture.url)) == [0x0000_000c])
    }

    @Test
    func normalizesEveryUniversalSlice() throws {
        let fixture = try TemporaryFixture(data: fatMachO(
            thinMachO(command: 0x8000_0023),
            thinMachO(command: 0x8000_0023)
        ))
        defer { fixture.remove() }

        let changed = try MachOFile.normalizeLoadCommand(
            at: fixture.url,
            loadPath: loadPath
        )
        #expect(changed == 2)
        #expect(
            try commandTypes(in: Data(contentsOf: fixture.url))
                == [0x0000_000c, 0x0000_000c]
        )
    }

    @Test
    func validatesBeforeMutatingEverySlice() throws {
        var missingPathSlice = thinMachO(command: 0x0000_000c)
        let replacement = Data(
            "@rpath/OtherLibrary"
                .padding(toLength: loadPath.utf8.count, withPad: "_", startingAt: 0)
                .utf8
        )
        let pathData = Data(loadPath.utf8)
        let pathRange = try #require(missingPathSlice.range(of: pathData))
        missingPathSlice.replaceSubrange(pathRange, with: replacement)

        let original = fatMachO(
            thinMachO(command: 0x8000_0023),
            missingPathSlice
        )
        let fixture = try TemporaryFixture(data: original)
        defer { fixture.remove() }

        #expect(throws: MachOError.expectedSingleLoadCommand(
            path: loadPath,
            slice: 1,
            count: 0
        )) {
            try MachOFile.normalizeLoadCommand(at: fixture.url, loadPath: loadPath)
        }
        #expect(try Data(contentsOf: fixture.url) == original)
    }

    @Test
    func inspectsDevicePlatformAndEncryption() throws {
        let fixture = try TemporaryFixture(data: thinMachO(
            command: 0x0000_000c,
            platform: 2,
            cryptID: 0
        ))
        defer { fixture.remove() }

        let inspection = try MachOFile.inspect(at: fixture.url)
        #expect(inspection.architectures == ["arm64"])
        #expect(inspection.platforms == [.iOS])
        #expect(inspection.isDecrypted)
    }

    @Test
    func inspectsSimulatorPlatform() throws {
        let fixture = try TemporaryFixture(data: thinMachO(
            command: 0x0000_000c,
            cpuType: 0x0100_0007,
            platform: 7,
            cryptID: nil
        ))
        defer { fixture.remove() }

        let inspection = try MachOFile.inspect(at: fixture.url)
        #expect(inspection.architectures == ["x86_64"])
        #expect(inspection.platforms == [.iOSSimulator])
        #expect(inspection.isDecrypted)
    }

    @Test
    func rejectsEncryptedApp() throws {
        let fixture = try TemporaryAppFixture(
            binary: thinMachO(
                command: 0x0000_000c,
                platform: 2,
                cryptID: 1
            ),
            declaredPlatform: "iPhoneOS"
        )
        defer { fixture.remove() }

        #expect(throws: IPAInspectionError.encrypted([1])) {
            try IPAInspector.inspectApp(at: fixture.appURL)
        }
    }

    @Test
    func rejectsInfoPlistAndMachOPlatformMismatch() throws {
        let fixture = try TemporaryAppFixture(
            binary: thinMachO(
                command: 0x0000_000c,
                cpuType: 0x0100_0007,
                platform: 7,
                cryptID: nil
            ),
            declaredPlatform: "iPhoneOS"
        )
        defer { fixture.remove() }

        #expect(throws: IPAInspectionError.unsupportedPlatform(
            "Info.plist declares iPhoneOS, but Mach-O contains iPhoneSimulator"
        )) {
            try IPAInspector.inspectApp(at: fixture.appURL)
        }
    }

    private func thinMachO(
        command: UInt32,
        cpuType: UInt32 = 0x0100_000c,
        platform: UInt32 = 2,
        cryptID: UInt32? = 0
    ) -> Data {
        let commandSize = aligned(24 + loadPath.utf8.count + 1, to: 8)
        var dylib = Data()
        dylib.appendLittleEndian(command)
        dylib.appendLittleEndian(UInt32(commandSize))
        dylib.appendLittleEndian(24)
        dylib.appendLittleEndian(0)
        dylib.appendLittleEndian(0)
        dylib.appendLittleEndian(0)
        dylib.append(contentsOf: loadPath.utf8)
        dylib.append(0)
        dylib.append(Data(repeating: 0, count: commandSize - dylib.count))

        var buildVersion = Data()
        buildVersion.appendLittleEndian(0x0000_0032)
        buildVersion.appendLittleEndian(24)
        buildVersion.appendLittleEndian(platform)
        buildVersion.appendLittleEndian(0)
        buildVersion.appendLittleEndian(0)
        buildVersion.appendLittleEndian(0)

        var commands = buildVersion + dylib
        var commandCount: UInt32 = 2
        if let cryptID {
            var encryption = Data()
            encryption.appendLittleEndian(0x0000_002c)
            encryption.appendLittleEndian(24)
            encryption.appendLittleEndian(0)
            encryption.appendLittleEndian(0)
            encryption.appendLittleEndian(cryptID)
            encryption.appendLittleEndian(0)
            commands.append(encryption)
            commandCount += 1
        }

        var header = Data()
        header.append(contentsOf: [0xcf, 0xfa, 0xed, 0xfe])
        header.appendLittleEndian(cpuType)
        header.appendLittleEndian(0)
        header.appendLittleEndian(2)
        header.appendLittleEndian(commandCount)
        header.appendLittleEndian(UInt32(commands.count))
        header.appendLittleEndian(0)
        header.appendLittleEndian(0)
        return header + commands
    }

    private func fatMachO(_ slices: Data...) -> Data {
        let tableSize = 8 + (20 * slices.count)
        var nextOffset = 0x1000
        var header = Data()
        header.appendBigEndian(0xcafe_babe)
        header.appendBigEndian(UInt32(slices.count))

        for (index, slice) in slices.enumerated() {
            header.appendBigEndian(0x0100_000c)
            header.appendBigEndian(UInt32(index))
            header.appendBigEndian(UInt32(nextOffset))
            header.appendBigEndian(UInt32(slice.count))
            header.appendBigEndian(12)
            nextOffset += aligned(slice.count, to: 0x1000)
        }
        header.append(Data(repeating: 0, count: tableSize - header.count))

        var result = header
        for slice in slices {
            let offset = aligned(result.count, to: 0x1000)
            result.append(Data(repeating: 0, count: offset - result.count))
            result.append(slice)
        }
        return result
    }

    private func commandTypes(in data: Data) throws -> [UInt32] {
        var results: [UInt32] = []
        let pathData = Data(loadPath.utf8)
        var searchRange = data.startIndex..<data.endIndex
        while let range = data.range(of: pathData, in: searchRange) {
            let commandOffset = range.lowerBound - 24
            let value = data[commandOffset..<(commandOffset + 4)]
                .enumerated()
                .reduce(UInt32(0)) {
                    $0 | (UInt32($1.element) << UInt32($1.offset * 8))
                }
            results.append(value)
            searchRange = range.upperBound..<data.endIndex
        }
        return results
    }

    private func aligned(_ value: Int, to alignment: Int) -> Int {
        ((value + alignment - 1) / alignment) * alignment
    }
}

private struct TemporaryAppFixture {
    let directory: URL
    let appURL: URL

    init(binary: Data, declaredPlatform: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAPatchLookinAppTests-\(UUID().uuidString)")
        appURL = directory.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: appURL,
            withIntermediateDirectories: true
        )
        let plist: [String: Any] = [
            "CFBundleExecutable": "Fixture",
            "CFBundleIdentifier": "com.example.fixture",
            "CFBundleSupportedPlatforms": [declaredPlatform],
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )
        try plistData.write(to: appURL.appendingPathComponent("Info.plist"))
        try binary.write(to: appURL.appendingPathComponent("Fixture"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct TemporaryFixture {
    let directory: URL
    let url: URL

    init(data: Data) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("IPAPatchLookinTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("AppBinary")
        try data.write(to: url)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }

    mutating func appendBigEndian(_ value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }
}
