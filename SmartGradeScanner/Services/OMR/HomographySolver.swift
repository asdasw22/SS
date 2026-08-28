import Foundation
import CoreGraphics

struct HomographySolver: Sendable {
    func reprojectionError(source: [CGPoint], destination: [CGPoint]) -> Double {
        guard source.count == destination.count, !source.isEmpty else { return .greatestFiniteMagnitude }
        return zip(source, destination).reduce(0) { $0 + hypot(Double($1.0.x - $1.1.x), Double($1.0.y - $1.1.y)) } / Double(source.count)
    }
}