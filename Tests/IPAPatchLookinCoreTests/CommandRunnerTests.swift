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

    @Test
    func includesCapturedOutputAndErrorWhenACommandFails() {
        do {
            _ = try CommandRunner.run(
                "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'standard output'; printf 'standard error' >&2; exit 7",
                ]
            )
            Issue.record("Expected the command to fail")
        } catch let failure as CommandFailure {
            #expect(failure.exitCode == 7)
            #expect(failure.standardOutput == "standard output")
            #expect(failure.standardError == "standard error")
            #expect(failure.errorDescription?.contains("standard output") == true)
            #expect(failure.errorDescription?.contains("standard error") == true)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
