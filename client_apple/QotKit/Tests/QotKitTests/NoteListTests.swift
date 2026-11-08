import Foundation
import Testing

@testable import QotKit

private func note(_ content: String, edited: Date, id: String = UUID().uuidString) -> NoteItem {
    NoteItem(id: id, content: content, createdAt: edited, updatedAt: edited)
}

@Suite struct NoteListTests {
    // MARK: Title and preview

    @Test func theTitleIsTheFirstLineWithText() {
        #expect(NoteList.title(of: "\n  \nGroceries\nmilk\neggs") == "Groceries")
    }

    @Test func theTitleIsTrimmed() {
        #expect(NoteList.title(of: "   get milk   ") == "get milk")
    }

    @Test func aBlankNoteIsCalledNewNote() {
        #expect(NoteList.title(of: " \n ") == "New Note")
    }

    @Test func thePreviewIsTheTextAfterTheTitleOnOneLine() {
        #expect(NoteList.preview(of: "Groceries\n\nmilk\n  eggs ") == "milk eggs")
    }

    @Test func aOneLineNoteHasNoPreview() {
        #expect(NoteList.preview(of: "get milk") == "")
    }

    // MARK: Order and sections

    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US")
        return c
    }()

    /// Sunday 2026-11-08 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_150_000)

    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func notesAreGroupedByLastEditNewestFirst() {
        let notes = [
            note("older today", edited: now.addingTimeInterval(-3_600)),
            note("last year", edited: daysAgo(400)),
            note("yesterday", edited: daysAgo(1)),
            note("just now", edited: now),
            note("three days", edited: daysAgo(3)),
            note("twenty days", edited: daysAgo(20)),
            note("two months", edited: daysAgo(60)),
        ]
        let sections = NoteList.sections(notes, now: now, calendar: calendar)
        #expect(sections.map(\.title) == [
            "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September", "2025",
        ])
        #expect(sections.map { $0.notes.map(\.content) } == [
            ["just now", "older today"], ["yesterday"], ["three days"], ["twenty days"],
            ["two months"], ["last year"],
        ])
    }

    @Test func notesEditedInTheSameSecondKeepAStableOrder() {
        let notes = [note("b", edited: now, id: "b"), note("a", edited: now, id: "a")]
        let sections = NoteList.sections(notes, now: now, calendar: calendar)
        #expect(sections.flatMap(\.notes).map(\.id) == ["b", "a"])
    }

    @Test func noNotesMeansNoSections() {
        #expect(NoteList.sections([], now: now, calendar: calendar).isEmpty)
    }

    // MARK: Search

    @Test func searchMatchesAnyPartOfTheTextIgnoringCaseAndAccents() {
        let notes = [note("Café list", edited: now), note("milk", edited: now)]
        #expect(NoteList.search(notes, for: "cafe").map(\.content) == ["Café list"])
        #expect(NoteList.search(notes, for: "  ").count == 2)
    }
}
