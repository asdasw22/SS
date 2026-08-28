import SwiftUI
import SwiftData

struct HomeView: View {
    @Query private var students: [Student]
    @Query private var exams: [Exam]
    @StateObject private var viewModel = HomeViewModel()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 4) { Text("SmartGrade").font(.largeTitle.bold()); Text("Scan. Grade. Done.").foregroundStyle(.secondary) }
                    NavigationLink(destination: ScannerView()) { Label("Scan Answer Sheet", systemImage: "camera.viewfinder").font(.headline).frame(maxWidth: .infinity).padding().background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(.white) }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        MetricCard(title: "Students", value: "\(students.count)", systemImage: "person.3.fill", tint: .blue)
                        MetricCard(title: "Exams", value: "\(exams.count)", systemImage: "doc.text.fill", tint: .purple)
                        MetricCard(title: "Scanned papers", value: "\(viewModel.totalScans(exams))", systemImage: "checkmark.seal.fill", tint: .green)
                        NavigationLink(destination: StatisticsView()) { MetricCard(title: "Analytics", value: "View", systemImage: "chart.bar.fill", tint: .orange) }.buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Quick actions").font(.title3.bold())
                        NavigationLink(destination: CreateExamView()) { Label("Create New Exam", systemImage: "plus.circle.fill") }.buttonStyle(.bordered)
                        NavigationLink(destination: ClassroomListView()) { Label("Manage Classes", systemImage: "person.2.fill") }.buttonStyle(.bordered)
                        NavigationLink(destination: HistoryView()) { Label("Scan History", systemImage: "clock.arrow.circlepath") }.buttonStyle(.bordered)
                    }
                }.padding()
            }.navigationTitle("Home")
        }
    }
}