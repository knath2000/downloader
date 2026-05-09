import XCTest
@testable import VidDL

final class ProfileNarrativeFormatterTests: XCTestCase {
    func testParsesValidMarkdownSections() {
        let text = """
        ## What I Learned About Your Habits

        The profile shows repeated engagement.

        ## Top Performers (with source citations)

        EmilyFox dominates the evidence.
        """

        let sections = ProfileNarrativeFormatter.sections(from: text)

        XCTAssertEqual(sections.map(\.title), [
            "What I Learned About Your Habits",
            "Top Performers (with source citations)"
        ])
        XCTAssertEqual(sections[0].body, "The profile shows repeated engagement.")
        XCTAssertEqual(sections[1].body, "EmilyFox dominates the evidence.")
    }

    func testRepairsFlattenedCachedNarrative() {
        let text = "What I Learned About Your HabitsThe profile shows repeated engagement.Top Performers (with source citations)EmilyFox dominates.Preferred Categories & Themes (with source citations)Latina performer focus is consistent.Studio Preferences (with source citations)No dominant studio preference.Viewing Patterns (duration, quality, frequency)Average duration was 19.4 minutes.How This Profile Was Built (data sources used, counts, gaps/limitations)Built from 232 items."

        let sections = ProfileNarrativeFormatter.sections(from: text)

        XCTAssertEqual(sections.count, 6)
        XCTAssertEqual(sections.map(\.title), [
            "What I Learned About Your Habits",
            "Top Performers (with source citations)",
            "Preferred Categories & Themes (with source citations)",
            "Studio Preferences (with source citations)",
            "Viewing Patterns (duration, quality, frequency)",
            "How This Profile Was Built (data sources used, counts, gaps/limitations)"
        ])
        XCTAssertEqual(sections[0].body, "The profile shows repeated engagement.")
        XCTAssertEqual(sections[1].body, "EmilyFox dominates.")
        XCTAssertEqual(sections[5].body, "Built from 232 items.")
    }

    func testParsesOptionalHeadingSuffixes() {
        let text = """
        ## Top Performers
        Performer evidence.
        ## Preferred Categories
        Category evidence.
        ## How This Profile Was Built
        Source evidence.
        """

        let sections = ProfileNarrativeFormatter.sections(from: text)

        XCTAssertEqual(sections.map(\.title), [
            "Top Performers (with source citations)",
            "Preferred Categories & Themes (with source citations)",
            "How This Profile Was Built (data sources used, counts, gaps/limitations)"
        ])
        XCTAssertEqual(sections.map(\.body), [
            "Performer evidence.",
            "Category evidence.",
            "Source evidence."
        ])
    }

    func testFallsBackToSingleReadableSectionForUnknownText() {
        let text = "A single paragraph without known headings."

        let sections = ProfileNarrativeFormatter.sections(from: text)

        XCTAssertEqual(sections, [
            ProfileNarrativeSection(title: "", body: "A single paragraph without known headings.")
        ])
    }

    func testConvertsLiteralNewlineEscapes() {
        let text = "## What I Learned About Your Habits\\n\\nEscaped newlines are normalized."

        let sections = ProfileNarrativeFormatter.sections(from: text)

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "What I Learned About Your Habits")
        XCTAssertEqual(sections[0].body, "Escaped newlines are normalized.")
    }
}
