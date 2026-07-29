import Foundation

@main
struct MachONormalizerMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            fail("usage: ipapatch-macho-normalizer <Mach-O> <load-path>", code: 64)
        }

        let binaryURL = URL(fileURLWithPath: arguments[0])
        let loadPath = arguments[1]
        do {
            let inspection = try MachOFile.inspect(at: binaryURL)
            let changed = try MachOFile.normalizeLoadCommand(
                at: binaryURL,
                loadPath: loadPath
            )
            if changed > 0 {
                print(
                    "Normalized \(changed) load command(s) to LC_LOAD_DYLIB: \(loadPath)"
                )
            } else {
                print(
                    "All \(inspection.slices.count) slice(s) already use LC_LOAD_DYLIB: \(loadPath)"
                )
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }
}
