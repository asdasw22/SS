import SwiftUI

import SwiftData

import Charts

struct StatisticsView: View {

    @Query(sort: \Exam.date, order: .reverse) private var exams: [Exam]

    @State private var selectedExamID: UUID?

    private var selectedExam: Exam? { exams.first { $0.id == selectedExamID } }

    private var statistics: ExamStatistics { StatisticsService().calculate(results: selectedExam?.results ?? [], passingPercentage: selectedExam?.passingPercentage ?? 50) }

    var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 18) { Picker("Exam", selection: $selectedExamID) { Text("Select exam").tag(nil as UUID?); ForEach(exams) { Text($0.name).tag($0.id as UUID?) } }.pickerStyle(.menu); if selectedExam != nil { LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) { MetricCard(title: "Students", value: "\(statistics.studentCount)", systemImage: "person.3.fill", tint: .blue); MetricCard(title: "Average", value: statistics.average.formatted(.number.precision(.fractionLength(1))) + "%", systemImage: "chart.line.uptrend.xyaxis", tint: .green); MetricCard(title: "Highest", value: statistics.highest.formatted(.number.precision(.fractionLength(1))) + "%", systemImage: "trophy.fill", tint: .orange); MetricCard(title: "Pass rate", value: statistics.passRate.formatted(.number.precision(.fractionLength(1))) + "%", systemImage: "checkmark.seal.fill", tint: .purple) }; Text("Question analysis").font(.title2.bold()); Chart(statistics.questions) { item in BarMark(x: .value("Question", "Q\(item.questionNumber)"), y: .value("Correct", item.correctPercentage)).foregroundStyle(item.correctPercentage < 50 ? Color.red : Color.blue) }.frame(height: 260) } else { EmptyStateView(title: "Choose an exam", message: "Select an exam to see class performance and difficult questions.", systemImage: "chart.bar.xaxis") } }.padding() }.navigationTitle("Statistics") }.onAppear { selectedExamID = selectedExamID ?? exams.first?.id } }

}
