import Foundation

/// How the notes list reads, as in Apple Notes: a note's first line is its
/// title, the rest its preview, and notes are grouped by when they were last
/// edited, newest first. Pure, so the app's views stay thin.
public enum NoteList {
    public struct Section: Equatable, Sendable {
        public let title: String
        public let notes: [NoteItem]
    }

    /// The first line with text, or "New Note" for a blank note.
    public static func title(of content: String) -> String {
        lines(content).first ?? "New Note"
    }

    /// The text after the title, on one line.
    public static func preview(of content: String) -> String {
        lines(content).dropFirst().joined(separator: " ")
    }

    /// Notes newest edit first (ties: the newer id, which is UUIDv7, first),
    /// in Notes' sections: Today, Yesterday, Previous 7 Days, Previous 30
    /// Days, then each earlier month of this year, then each earlier year.
    public static func sections(_ notes: [NoteItem], now: Date, calendar: Calendar) -> [Section] {
        let sorted = notes.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        var result: [Section] = []
        for note in sorted {
            let title = sectionTitle(for: note.updatedAt, now: now, calendar: calendar)
            if let last = result.last, last.title == title {
                result[result.count - 1] = Section(title: title, notes: last.notes + [note])
            } else {
                result.append(Section(title: title, notes: [note]))
            }
        }
        return result
    }

    /// Notes whose text contains the query, ignoring case and accents. A
    /// blank query matches every note.
    public static func search(_ notes: [NoteItem], for query: String) -> [NoteItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.content.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func lines(_ content: String) -> [String] {
        content.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func sectionTitle(for date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        switch days {
        case ...0: return "Today"
        case 1: return "Yesterday"
        case 2..<7: return "Previous 7 Days"
        case 7..<30: return "Previous 30 Days"
        default:
            if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
                let month = calendar.component(.month, from: date)
                return calendar.standaloneMonthSymbols[month - 1]
            }
            return String(calendar.component(.year, from: date))
        }
    }
}
