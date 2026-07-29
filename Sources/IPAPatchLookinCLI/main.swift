import Foundation
import Darwin

do {
    setbuf(stdout, nil)
    setbuf(stderr, nil)
    try CLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
} catch {
    let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}
