import SwiftUI
import EzeestiUI

@main
struct EzeestiApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 720)
    }
}
