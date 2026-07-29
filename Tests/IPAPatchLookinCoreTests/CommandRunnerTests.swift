import Testing
@testable import IPAPatchLookinCore

struct CommandRunnerTests {
    @Test
    func drainsLargeCapturedOutputWithoutBlocking() throws {
        let result = try CommandRunner.run(
            "/usr/bin/jot",
            arguments: ["-b", "abcdefghij", "20000"]
        )

        #expect(result.exitCode == 0)
        #expect(result.standardOutput.split(separator: "\n").count == 20_000)
        #expect(result.standardError.isEmpty)
    }
}
