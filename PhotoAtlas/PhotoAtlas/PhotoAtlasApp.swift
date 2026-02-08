import SwiftUI

@main
struct PhotoAtlasApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            MapScreen()
                .environmentObject(model)
        }
    }
}
