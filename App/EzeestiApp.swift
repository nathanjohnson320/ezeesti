import SwiftUI
import SwiftData
import EzeestiUI
import EzeestiLearning

@main
struct EzeestiApp: App {
    private let container: ModelContainer

    init() {
        do {
            container = try VocabStore.makeContainer()
        } catch {
            fatalError("SwiftData container failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .modelContainer(container)
        .defaultSize(width: 1100, height: 720)
    }
}
