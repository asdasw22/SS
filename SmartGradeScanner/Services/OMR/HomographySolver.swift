import CoreGraphics
import Foundation

struct ProjectiveTransform: Sendable, Equatable {
  let h11: Double
  let h12: Double
  let h13: Double
  let h21: Double
  let h22: Double
  let h23: Double
  let h31: Double
  let h32: Double

  func apply(_ point: CGPoint) -> CGPoint {
    let x = Double(point.x)
    let y = Double(point.y)
    let denominator = h31 * x + h32 * y + 1
    guard abs(denominator) > 1e-10 else { return CGPoint(x: -10, y: -10) }
    return CGPoint(
      x: (h11 * x + h12 * y + h13) / denominator,
      y: (h21 * x + h22 * y + h23) / denominator)
  }
}

struct HomographySolver: Sendable {
  /// Least-squares projective mapping from `source` to `destination`.
  /// Four point pairs are sufficient; additional pairs make the estimate more robust.
  func solve(source: [CGPoint], destination: [CGPoint]) -> ProjectiveTransform? {
    guard source.count == destination.count, source.count >= 4 else { return nil }

    var ata = Array(repeating: Array(repeating: 0.0, count: 8), count: 8)
    var atb = Array(repeating: 0.0, count: 8)

    for (p, q) in zip(source, destination) {
      let x = Double(p.x)
      let y = Double(p.y)
      let u = Double(q.x)
      let v = Double(q.y)
      let rows = [
        ([x, y, 1, 0, 0, 0, -u * x, -u * y], u),
        ([0, 0, 0, x, y, 1, -v * x, -v * y], v),
      ]
      for (row, value) in rows {
        for i in 0..<8 {
          atb[i] += row[i] * value
          for j in 0..<8 { ata[i][j] += row[i] * row[j] }
        }
      }
    }

    // Tiny regularization avoids singularity for nearly-affine views.
    for i in 0..<8 { ata[i][i] += 1e-9 }
    guard let h = solveLinearSystem(ata, atb), h.count == 8 else { return nil }
    let transform = ProjectiveTransform(
      h11: h[0], h12: h[1], h13: h[2],
      h21: h[3], h22: h[4], h23: h[5],
      h31: h[6], h32: h[7])

    let error = reprojectionError(transform: transform, source: source, destination: destination)
    guard error.isFinite, error < 0.20 else { return nil }
    return transform
  }

  func reprojectionError(
    transform: ProjectiveTransform,
    source: [CGPoint],
    destination: [CGPoint]
  ) -> Double {
    guard source.count == destination.count, !source.isEmpty else { return .greatestFiniteMagnitude }
    return zip(source, destination).reduce(0) {
      $0 + distance(transform.apply($1.0), $1.1)
    } / Double(source.count)
  }

  func reprojectionError(source: [CGPoint], destination: [CGPoint]) -> Double {
    guard source.count == destination.count, !source.isEmpty else { return .greatestFiniteMagnitude }
    return zip(source, destination).reduce(0) { $0 + distance($1.0, $1.1) }
      / Double(source.count)
  }

  func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
    hypot(Double(a.x - b.x), Double(a.y - b.y))
  }

  private func solveLinearSystem(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
    let n = vector.count
    guard matrix.count == n, matrix.allSatisfy({ $0.count == n }) else { return nil }
    var augmented = (0..<n).map { matrix[$0] + [vector[$0]] }

    for pivot in 0..<n {
      var bestRow = pivot
      for row in pivot..<n where abs(augmented[row][pivot]) > abs(augmented[bestRow][pivot]) {
        bestRow = row
      }
      guard abs(augmented[bestRow][pivot]) > 1e-12 else { return nil }
      if bestRow != pivot { augmented.swapAt(bestRow, pivot) }

      let divisor = augmented[pivot][pivot]
      for column in pivot...n { augmented[pivot][column] /= divisor }

      for row in 0..<n where row != pivot {
        let factor = augmented[row][pivot]
        if abs(factor) < 1e-15 { continue }
        for column in pivot...n {
          augmented[row][column] -= factor * augmented[pivot][column]
        }
      }
    }
    return (0..<n).map { augmented[$0][n] }
  }
}
