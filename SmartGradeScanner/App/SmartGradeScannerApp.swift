import SwiftUI
import SwiftData

@main
struct SmartGradeScannerApp: App {

    let container: ModelContainer

    init() {
        do {
            container = try ModelContainerFactory.make()
        } catch {
            fatalError("Unable to create SmartGrade storage: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .modelContainer(container)
        }
    }
}