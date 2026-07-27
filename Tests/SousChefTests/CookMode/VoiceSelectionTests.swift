import XCTest
import AVFoundation
@testable import SousChef

/// Apple ships only the compact default voices; the natural-sounding Enhanced and Premium
/// ones are user downloads an app can't install. So the app picks the best voice actually
/// INSTALLED — hardcoding premium would resolve to nothing on most phones and fall back to
/// the robotic default. These tests pin that ladder without needing a device that happens
/// to have the right voices downloaded.
final class VoiceSelectionTests: XCTestCase {

    private struct FakeVoice: RankableVoice {
        let language: String
        let quality: AVSpeechSynthesisVoiceQuality
        let identifier: String
    }

    private func pick(_ voices: [FakeVoice], language: String = "en-US") -> FakeVoice? {
        CookVoiceController.selectVoice(from: voices, preferredLanguage: language)
    }

    // MARK: Quality ladder

    func testPrefersPremiumOverEnhancedOverDefault() {
        let voices = [
            FakeVoice(language: "en-US", quality: .default, identifier: "a"),
            FakeVoice(language: "en-US", quality: .premium, identifier: "b"),
            FakeVoice(language: "en-US", quality: .enhanced, identifier: "c"),
        ]
        XCTAssertEqual(pick(voices)?.identifier, "b")
    }

    func testFallsBackToEnhancedWhenNoPremiumInstalled() {
        let voices = [
            FakeVoice(language: "en-US", quality: .default, identifier: "a"),
            FakeVoice(language: "en-US", quality: .enhanced, identifier: "c"),
        ]
        XCTAssertEqual(pick(voices)?.identifier, "c")
    }

    func testFallsBackToDefaultWhenNothingDownloaded() {
        // The out-of-the-box phone: only compact voices exist.
        let voices = [FakeVoice(language: "en-US", quality: .default, identifier: "a")]
        XCTAssertEqual(pick(voices)?.identifier, "a")
    }

    // MARK: Language beats quality

    func testLanguageMatchOutranksQuality() {
        // A premium French voice must never win on an English device — an unintelligible
        // step read beautifully is worse than a plain one read in the user's language.
        let voices = [
            FakeVoice(language: "fr-FR", quality: .premium, identifier: "fr"),
            FakeVoice(language: "en-US", quality: .default, identifier: "en"),
        ]
        XCTAssertEqual(pick(voices)?.identifier, "en")
    }

    func testExactLocaleBeatsSameLanguageOtherRegion() {
        let voices = [
            FakeVoice(language: "en-GB", quality: .premium, identifier: "gb"),
            FakeVoice(language: "en-US", quality: .premium, identifier: "us"),
        ]
        XCTAssertEqual(pick(voices)?.identifier, "us")
    }

    func testFallsBackToAnyEnglishForAnUnsupportedLocale() {
        // Device set to Japanese with no Japanese voice installed: an English voice still
        // reads the (English) recipe text correctly.
        let voices = [
            FakeVoice(language: "en-GB", quality: .enhanced, identifier: "gb"),
            FakeVoice(language: "de-DE", quality: .premium, identifier: "de"),
        ]
        XCTAssertEqual(pick(voices, language: "ja-JP")?.identifier, "gb")
    }

    func testSameLanguageDifferentRegionBeatsUnrelatedLanguage() {
        let voices = [
            FakeVoice(language: "es-MX", quality: .default, identifier: "mx"),
            FakeVoice(language: "en-US", quality: .premium, identifier: "us"),
        ]
        XCTAssertEqual(pick(voices, language: "es-ES")?.identifier, "mx")
    }

    // MARK: Edge cases

    func testNoUsableVoiceReturnsNil() {
        // Nothing in a language we can use → nil, and the synthesizer falls back to system
        // default rather than reading in a language the cook can't follow.
        let voices = [FakeVoice(language: "de-DE", quality: .premium, identifier: "de")]
        XCTAssertNil(pick(voices, language: "ja-JP"))
        XCTAssertNil(pick([], language: "en-US"))
    }

    func testSelectionIsStableAcrossCalls() {
        // Equal language and quality: the tie-break must be deterministic, or the voice
        // could change between launches.
        let voices = [
            FakeVoice(language: "en-US", quality: .enhanced, identifier: "aaa"),
            FakeVoice(language: "en-US", quality: .enhanced, identifier: "zzz"),
        ]
        let first = pick(voices)?.identifier
        XCTAssertEqual(first, pick(voices)?.identifier)
        XCTAssertEqual(first, pick(voices.reversed())?.identifier, "order of the system list must not matter")
    }
}
