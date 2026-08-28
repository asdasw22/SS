import SwiftUI

struct SettingsView: View {
    @AppStorage("debugMode") private var debugMode = false
    @AppStorage("multipleAnswersWrong") private var multipleAnswersWrong = true
    @AppStorage("autoCapture") private var autoCapture = true
    var body: some View { NavigationStack { Form { Section("Scanning") { Toggle("Auto capture", isOn: $autoCapture); Toggle("Multiple answers are wrong", isOn: $multipleAnswersWrong) }; Section("Developer") { Toggle("OMR debug overlay", isOn: $debugMode); Text("Debug mode shows bubble boxes, fill ratios, thresholds, confidence, and alignment diagnostics on supported review screens.").font(.footnote).foregroundStyle(.secondary) }; Section { Label("All image analysis runs on-device by default.", systemImage: "lock.shield.fill"); Text("SmartGrade does not upload answer sheets or student data.").font(.footnote).foregroundStyle(.secondary) } }.navigationTitle("Settings") } }
}