// FixtureRunner — `swift run FixtureRunner <fixture-dir>` (ENGINE_PARITY §5).
// Reads <fixture-dir>/input.json, resolves the fixture's relative
// curriculum/content-ref paths (ENGINE_PARITY §4.3: `quran_ref` or
// `corpus_ref`), and prints the normalized task stream to stdout — nothing
// else. All engine work is pure; only this shim touches the filesystem.

import Foundation
import MasoonCurriculum
import MasoonDomain

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("FixtureRunner: " + message + "\n").utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: FixtureRunner <fixture-dir>")
}

let fixtureDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
let inputURL = fixtureDir.appendingPathComponent("input.json")

func readBytes(_ url: URL) -> [UInt8] {
    guard let data = try? Data(contentsOf: url) else {
        fail("cannot read \(url.path)")
    }
    return [UInt8](data)
}

let inputBytes = readBytes(inputURL)

/// Resolves a fixture-relative path against the directory containing input.json.
func resolve(_ relative: String) -> URL {
    URL(fileURLWithPath: relative, relativeTo: fixtureDir).standardizedFileURL
}

do {
    let (curriculumRel, _, contentRel) = try FixtureInput.referencedPaths(inputBytes: inputBytes)
    let curriculumURL = resolve(curriculumRel)
    let contentURL = resolve(contentRel)
    let fixture = try FixtureInput(
        inputBytes: inputBytes,
        curriculumBytes: readBytes(curriculumURL),
        contentBytes: readBytes(contentURL))
    let stream = try fixture.run()
    FileHandle.standardOutput.write(Data(stream.utf8))
} catch {
    fail("\(error)")
}
