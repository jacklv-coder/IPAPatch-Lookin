import Foundation
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

struct ProjectReadyMessageTests {
    @Test
    func describesCreatedDeviceProject() {
        let message = ProjectReadyMessage.text(
            appName: "ChatGPT",
            projectURL: URL(fileURLWithPath: "/tmp/Projects/ChatGPT/IPAPatch.xcodeproj"),
            wasCreated: true,
            platform: .device,
            architectures: ["arm64"]
        )

        #expect(message.contains("Created Xcode project for ChatGPT:"))
        #expect(message.contains("Select your Apple Development Team"))
        #expect(message.contains("Select a connected iPhone or iPad."))
        #expect(message.contains("No device is required while generating the project."))
        #expect(message.contains("Select the IPAPatch-DummyApp scheme."))
    }

    @Test
    func describesReusedSimulatorProject() {
        let message = ProjectReadyMessage.text(
            appName: "Demo",
            projectURL: URL(fileURLWithPath: "/tmp/Projects/Demo/IPAPatch.xcodeproj"),
            wasCreated: false,
            platform: .simulator,
            architectures: ["arm64", "x86_64"]
        )

        #expect(message.contains("Reused existing Xcode project for Demo:"))
        #expect(message.contains("Select the IPAPatch-DummyApp scheme."))
        #expect(message.contains("Select an iOS Simulator matching arm64, x86_64."))
        #expect(!message.contains("Apple Development Team"))
    }
}
