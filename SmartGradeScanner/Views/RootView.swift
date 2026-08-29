import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        TabView {
            HomeView().tabItem { Label("Home", systemImage: "house.fill") }
            ExamListView().tabItem { Label("Exams", systemImage: "list.clipboard.fill") }
            QuickScanHostView().tabItem { Label("Scan", systemImage: "camera.viewfinder") }.tag(2)
            StudentListView().tabItem { Label("Students", systemImage: "person.3.fill") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .task {
            await MainActor.run {
                SampleDataSeeder.seedIfNeeded(in: modelContext)
            }
        }
    }
}