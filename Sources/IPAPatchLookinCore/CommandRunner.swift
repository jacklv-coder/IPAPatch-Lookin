import Foundation

private final class CapturedData: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func store(_ data: Data) {
        lock.lock()
        storage = data
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String
}

public struct CommandFailure: LocalizedError, Sendable {
    public let executable: String
    public let arguments: [String]
    public let exitCode: Int32
    public let standardError: String

    public var errorDescription: String? {
        let command = ([executable] + arguments).joined(separator: " ")
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "Command failed with exit code \(exitCode): \(command)"
        }
        return "Command failed with exit code \(exitCode): \(command)\n\(detail)"
    }
}

public enum CommandRunner {
    @discardableResult
    public static func run(
        _ executable: String,
        arguments: [String] = [],
        currentDirectory: URL? = nil,
        environment: [String: String] = [:],
        captureOutput: Bool = true
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory

        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(
                environment,
                uniquingKeysWith: { _, new in new }
            )
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        if captureOutput {
            process.standardOutput = outputPipe
            process.standardError = errorPipe
        } else {
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
        }
        process.standardInput = FileHandle.standardInput

        try process.run()

        let readGroup = DispatchGroup()
        let capturedOutput = CapturedData()
        let capturedError = CapturedData()
        if captureOutput {
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readGroup.leave() }
                capturedOutput.store(
                    outputPipe.fileHandleForReading.readDataToEndOfFile()
                )
            }
            readGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { readGroup.leave() }
                capturedError.store(
                    errorPipe.fileHandleForReading.readDataToEndOfFile()
                )
            }
        }
        process.waitUntilExit()
        readGroup.wait()

        let outputData = captureOutput
            ? capturedOutput.value()
            : Data()
        let errorData = captureOutput
            ? capturedError.value()
            : Data()
        let result = CommandResult(
            exitCode: process.terminationStatus,
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? ""
        )

        guard result.exitCode == 0 else {
            throw CommandFailure(
                executable: executable,
                arguments: arguments,
                exitCode: result.exitCode,
                standardError: result.standardError
            )
        }
        return result
    }
}
