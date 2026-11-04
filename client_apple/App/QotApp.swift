import QotKit
import SwiftUI

@main
struct QotApp: App {
    var body: some Scene {
        WindowGroup {
            NotesView(model: NotesModel.onDevice())
        }
    }
}
