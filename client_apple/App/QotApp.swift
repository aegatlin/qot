import BackgroundTasks
import QotKit
import SwiftUI

@main
struct QotApp: App {
    @State private var model = AppModel.onDevice()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            NotesView(model: model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.becameActive()
            case .background:
                model.becameInactive()
                BackgroundSync.schedule()
            default: break
            }
        }
        .backgroundTask(.appRefresh(BackgroundSync.id)) {
            BackgroundSync.schedule()
            await BackgroundSync.run()
        }
    }
}

/// Notes taken elsewhere should be here by the time the app opens: iOS wakes
/// the app now and then to sync (`BGAppRefreshTask`; when is up to iOS).
enum BackgroundSync {
    static let id = "llc.abstractsyntax.qot.sync"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: id)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run() async {
        guard let store = try? AppGroup.store() else { return }
        let syncer = Syncer(store: store, credentials: AppGroup.credentials()) { base in
            ServerAPI(baseURL: base, transport: URLSession.shared, userAgent: UserAgent.value)
        }
        _ = try? await syncer.sync()
    }
}
