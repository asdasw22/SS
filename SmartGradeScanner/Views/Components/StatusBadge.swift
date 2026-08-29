import SwiftUI

struct StatusBadge: View {
    let status: ResponseStatus
    var body: some View {
        Label(label, systemImage: icon).font(.caption.bold()).foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.12), in: Capsule())
    }
    private var label: String {
        switch status { case .selected: return "Detected"; case .empty: return "Blank"; case .multiple: return "Multiple"; case .weak: return "Weak mark"; case .uncertain: return "Needs review"; case .invalidRegion: return "Invalid" }
    }
    private var icon: String { switch status { case .selected: return "checkmark.circle.fill"; case .empty: return "minus.circle"; case .multiple: return "exclamationmark.triangle.fill"; default: return "questionmark.circle.fill" } }
    private var color: Color { switch status { case .selected: return .green; case .empty: return .secondary; case .multiple: return .red; default: return .orange } }
}