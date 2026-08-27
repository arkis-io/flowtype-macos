import XCTest
@testable import FlowType

final class PersonalDictionaryTests: XCTestCase {
    func testParsesVocabularyAndReplacements() {
        let dictionary = PersonalDictionary.parse("""
        # comment
        Arkis
        whisper flow => Wispr Flow
        arkis
        """)

        XCTAssertEqual(dictionary.vocabulary, ["Arkis", "Wispr Flow"])
        XCTAssertEqual(
            dictionary.replacements,
            [.init(source: "whisper flow", destination: "Wispr Flow")]
        )
    }

    func testAppliesCaseInsensitiveWholePhraseReplacements() {
        let dictionary = PersonalDictionary.parse("whisper flow => Wispr Flow")
        XCTAssertEqual(
            dictionary.applyingReplacements(to: "I tried WHISPER FLOW, then whisper flowing."),
            "I tried Wispr Flow, then whisper flowing."
        )
    }
}
