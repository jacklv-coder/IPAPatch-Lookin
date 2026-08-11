import Testing
@testable import IPAPatchLookinCLI

struct CLIInvocationTests {
    @Test
    func routesDirectIPAPathToRun() {
        let invocation = CLIInvocation(arguments: ["~/Downloads/Demo.IPA"])

        #expect(invocation.command == "run")
        #expect(invocation.remaining == ["~/Downloads/Demo.IPA"])
    }

    @Test
    func preservesExplicitCommandsAndHelpDefault() {
        let run = CLIInvocation(arguments: ["run", "Demo.ipa"])
        let inspect = CLIInvocation(arguments: ["inspect", "Demo.ipa"])
        let help = CLIInvocation(arguments: [])

        #expect(run.command == "run")
        #expect(run.remaining == ["Demo.ipa"])
        #expect(inspect.command == "inspect")
        #expect(inspect.remaining == ["Demo.ipa"])
        #expect(help.command == "help")
        #expect(help.remaining.isEmpty)
    }
}
