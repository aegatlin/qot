import AppIntents
import QotKit
import SwiftUI
import WidgetKit

@main
struct QotWidgets: WidgetBundle {
    var body: some Widget {
        CaptureControl()
        CaptureWidget()
        LatestNotesWidget()
    }
}

/// Control Center (and the Lock Screen's control slots, and the Action
/// button): one tap opens qot ready to type.
struct CaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "llc.abstractsyntax.qot.capture-control") {
            ControlWidgetButton(action: OpenCaptureIntent()) {
                Label("New Note", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Note")
        .description("Opens qot ready to type a note.")
    }
}

// MARK: - Lock Screen

struct EmptyEntry: TimelineEntry {
    let date = Date.now
}

struct EmptyProvider: TimelineProvider {
    func placeholder(in context: Context) -> EmptyEntry { EmptyEntry() }
    func getSnapshot(in context: Context, completion: @escaping (EmptyEntry) -> Void) {
        completion(EmptyEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<EmptyEntry>) -> Void) {
        completion(Timeline(entries: [EmptyEntry()], policy: .never))
    }
}

/// A Lock Screen button that opens qot ready to type.
struct CaptureWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "llc.abstractsyntax.qot.capture", provider: EmptyProvider()) { _ in
            CaptureWidgetView()
        }
        .configurationDisplayName("New Note")
        .description("Opens qot ready to type a note.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

struct CaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Label("New note", systemImage: "square.and.pencil")
            case .accessoryRectangular:
                Label("New note", systemImage: "square.and.pencil")
                    .font(.headline)
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .accessibilityLabel("New note")
                }
            }
        }
        .widgetURL(OpenCaptureIntent.url)
        .containerBackground(.clear, for: .widget)
    }
}

// MARK: - Home Screen

struct NotesEntry: TimelineEntry {
    let date: Date
    let notes: [NoteItem]
    let problem: String?
}

/// Reads the shared store. The app reloads widgets whenever notes change,
/// so the timeline never refreshes on its own.
struct NotesProvider: TimelineProvider {
    func placeholder(in context: Context) -> NotesEntry {
        NotesEntry(
            date: .now,
            notes: [NoteItem(id: "1", content: "get milk", createdAt: .now)],
            problem: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NotesEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NotesEntry>) -> Void) {
        completion(Timeline(entries: [entry()], policy: .never))
    }

    private func entry() -> NotesEntry {
        do {
            return NotesEntry(date: .now, notes: try AppGroup.store().latest(6), problem: nil)
        } catch {
            return NotesEntry(date: .now, notes: [], problem: error.localizedDescription)
        }
    }
}

struct LatestNotesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "llc.abstractsyntax.qot.latest", provider: NotesProvider()) { entry in
            LatestNotesView(entry: entry)
        }
        .configurationDisplayName("Latest Notes")
        .description("Your most recently edited notes. Tap to write one.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct LatestNotesView: View {
    let entry: NotesEntry
    @Environment(\.widgetFamily) private var family

    private var shown: [NoteItem] {
        Array(entry.notes.prefix(family == .systemLarge ? 6 : family == .systemMedium ? 3 : 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("qot").font(.headline)
                Spacer()
                Image(systemName: "square.and.pencil").foregroundStyle(.tint)
            }
            if let problem = entry.problem {
                Text(problem).font(.caption).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("No notes yet.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(shown) { note in
                Text(note.content)
                    .font(.subheadline)
                    .lineLimit(family == .systemSmall ? 2 : 1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(OpenCaptureIntent.url)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}
