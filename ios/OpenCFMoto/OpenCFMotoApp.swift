import SwiftUI

@main
struct OpenCFMotoApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(model)
                .task {
                    model.start()
                }
        }
    }
}
