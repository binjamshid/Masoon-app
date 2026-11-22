import Foundation
import MasoonCurriculum
import MasoonDomain
import XCTest

final class SyntheticPlanTests: XCTestCase {
    func testSyntheticFixtureProducesDeterministicTaskStream() throws {
        let fixtures = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        let directory = fixtures.appendingPathComponent("synthetic-plan")
        func read(_ relativePath: String) throws -> [UInt8] {
            [UInt8](try Data(contentsOf: directory.appendingPathComponent(relativePath)))
        }

        let input = try read("input.json")
        let (curriculum, kind, content) = try FixtureInput.referencedPaths(inputBytes: input)
        XCTAssertEqual(kind, "poem")
        let fixture = try FixtureInput(
            inputBytes: input,
            curriculumBytes: read(curriculum),
            contentBytes: read(content)
        )

        let result = try Engine.generate(context: fixture.context, window: fixture.window)
        let task = try XCTUnwrap(result.tasks.first)
        XCTAssertEqual(result.tasks.count, 1)
        XCTAssertEqual(task.originRuleId, "learn")
        XCTAssertEqual(task.content, [CanonicalRange(surah: 1, ayahStart: 1, ayahEnd: 2)!])
        let stream = try fixture.run()
        XCTAssertEqual(stream, StreamSerializer.serialize(result))
        XCTAssertEqual(try fixture.run(), stream)
        XCTAssertTrue(stream.contains("\n#STATE|"))
    }
}
