import SwiftUI
import WidgetKit

/// A complication and Smart Stack widget: one tap opens qot on the Watch,
/// ready to capture.
@main
struct QotWatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "llc.abstractsyntax.qot.watch.capture", provider: Provider()) { _ in
            CaptureComplication()
        }
        .configurationDisplayName("New Note")
        .description("Opens qot to capture a note.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct Entry: TimelineEntry {
    let date = Date.now
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry() }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        completion(Timeline(entries: [Entry()], policy: .never))
    }
}

struct CaptureComplication: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline, .accessoryRectangular:
                Label("New note", systemImage: "square.and.pencil")
            case .accessoryCorner:
                Image(systemName: "square.and.pencil")
                    .widgetLabel("qot")
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "square.and.pencil")
                }
            }
        }
        .widgetURL(URL(string: "qot://capture"))
        .containerBackground(.clear, for: .widget)
    }
}
