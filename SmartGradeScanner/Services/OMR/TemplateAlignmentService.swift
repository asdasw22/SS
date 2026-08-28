import CoreGraphics
import Foundation

struct AlignmentTransform: Sendable, Equatable {
  var a: Double
  var b: Double
  var c: Double
  var d: Double
  var e: Double
  var f: Double

  static let identity = AlignmentTransform(a: 1, b: 0, c: 0, d: 0, e: 1, f: 0)

  var scaleX: Double { hypot(a, d) }
  var scaleY: Double { hypot(b, e) }
  var determinant: Double { a * e - b * d }
  var shear: Double {
    let sx = max(scaleX, 0.0001)
    let sy = max(scaleY, 0.0001)
    return (a * b + d * e) / (sx * sy)
  }
  var rotationDegrees: Double { atan2(d, a) * 180 / .pi }

  func apply(_ point: CGPoint) -> CGPoint {
    let x = Double(point.x)
    let y = Double(point.y)
    return CGPoint(
      x: a * x + b * y + c,
      y: d * x + e * y + f)
  }

  func apply(_ rect: NormalizedRect) -> CGRect {
    let points = [
      CGPoint(x: rect.x, y: rect.y),
      CGPoint(x: rect.x + rect.width, y: rect.y),
      CGPoint(x: rect.x + rect.width, y: rect.y + rect.height),
      CGPoint(x: rect.x, y: rect.y + rect.height),
    ].map(apply)
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
      return .null
    }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  func maximumUnitSquareDrift() -> Double {
    let corners = [
      CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
      CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1), CGPoint(x: 0.5, y: 0.5),
    ]
    return corners.map { point in
      let mapped = apply(point)
      return hypot(Double(mapped.x - point.x), Double(mapped.y - point.y))
    }.max() ?? 0
  }
}

struct TemplateAlignmentReport: Sendable {
  let matchedMarkers: Int
  let confidence: Double
  let isCompatible: Bool
  let transform: AlignmentTransform
  let reprojectionError: Double
  let coverage: Double
  let scaleX: Double
  let scaleY: Double
  let rotationDegrees: Double
  let shear: Double
  let maximumDrift: Double
  let geometryIsSane: Bool
}

struct TemplateAlignmentService: Sendable {
  func validate(markers: [DetectedMarker], template: TemplateDefinition) -> TemplateAlignmentReport
  {
    guard !template.markers.isEmpty else {
      return report(
        matched: 0,
        confidence: template.strictRegistration == true ? 0 : 1,
        compatible: template.strictRegistration != true,
        transform: .identity,
        error: 0,
        coverage: 1,
        sane: template.strictRegistration != true)
    }

    let required = min(
      template.markers.count,
      max(template.calibration.minimumMarkerCount, 3))

    guard markers.count >= 3, let initial = fitAffine(markers) else {
      return report(
        matched: markers.count,
        confidence: 0,
        compatible: false,
        transform: .identity,
        error: .greatestFiniteMagnitude,
        coverage: markerCoverage(markers),
        sane: false)
    }

    let initialResiduals = markers.map { residual(marker: $0, transform: initial) }
    let medianResidual = median(initialResiduals)
    let rejectionLimit = max(
      template.calibration.markerReprojectionTolerance * 1.7,
      max(0.010, medianResidual * 2.4))
    let inliers = zip(markers, initialResiduals).compactMap { marker, error in
      error <= rejectionLimit ? marker : nil
    }
    let transform = (inliers.count >= 3 ? fitAffine(inliers) : nil) ?? initial
    let usedMarkers = inliers.count >= 3 ? inliers : markers
    let errors = usedMarkers.map { residual(marker: $0, transform: transform) }
    let reprojectionError = errors.reduce(0, +) / Double(max(errors.count, 1))
    let coverage = markerCoverage(usedMarkers)
    let markerConfidence =
      usedMarkers.map(\.confidence).reduce(0, +) / Double(max(usedMarkers.count, 1))
    let errorScore = max(
      0, 1 - reprojectionError / max(template.calibration.markerReprojectionTolerance * 2.0, 0.02))
    let coverageScore = min(1, coverage / 0.28)
    let confidence = min(
      1, max(0, markerConfidence * 0.56 + errorScore * 0.29 + coverageScore * 0.15))

    let xs = usedMarkers.map { $0.expectedCenter.x }
    let ys = usedMarkers.map { $0.expectedCenter.y }
    let widthSpan = Double((xs.max() ?? 0) - (xs.min() ?? 0))
    let heightSpan = Double((ys.max() ?? 0) - (ys.min() ?? 0))
    let minimumWidthSpan = template.strictRegistration == true ? 0.42 : 0.30
    let minimumHeightSpan = template.strictRegistration == true ? 0.56 : 0.28
    let distributed = widthSpan >= minimumWidthSpan && heightSpan >= minimumHeightSpan
    let sane = geometryIsSane(transform, template: template)

    let compatible =
      usedMarkers.count >= required
      && distributed
      && markerConfidence >= (template.strictRegistration == true ? 0.62 : 0.57)
      && reprojectionError <= max(template.calibration.markerReprojectionTolerance * 1.40, 0.030)
      && confidence >= 0.60
      && sane

    return report(
      matched: usedMarkers.count,
      confidence: confidence,
      compatible: compatible,
      transform: transform,
      error: reprojectionError,
      coverage: coverage,
      sane: sane)
  }

  private func report(
    matched: Int,
    confidence: Double,
    compatible: Bool,
    transform: AlignmentTransform,
    error: Double,
    coverage: Double,
    sane: Bool
  ) -> TemplateAlignmentReport {
    TemplateAlignmentReport(
      matchedMarkers: matched,
      confidence: confidence,
      isCompatible: compatible,
      transform: transform,
      reprojectionError: error,
      coverage: coverage,
      scaleX: transform.scaleX,
      scaleY: transform.scaleY,
      rotationDegrees: transform.rotationDegrees,
      shear: transform.shear,
      maximumDrift: transform.maximumUnitSquareDrift(),
      geometryIsSane: sane)
  }

  private func geometryIsSane(_ transform: AlignmentTransform, template: TemplateDefinition) -> Bool
  {
    let maxDrift =
      template.maximumAlignmentDrift ?? (template.strictRegistration == true ? 0.075 : 0.12)
    let scaleTolerance = template.strictRegistration == true ? 0.12 : 0.18
    let rotationLimit = template.strictRegistration == true ? 7.0 : 11.0
    let shearLimit = template.strictRegistration == true ? 0.13 : 0.20

    guard transform.determinant > 0,
      abs(transform.scaleX - 1) <= scaleTolerance,
      abs(transform.scaleY - 1) <= scaleTolerance,
      abs(transform.rotationDegrees) <= rotationLimit,
      abs(transform.shear) <= shearLimit,
      transform.maximumUnitSquareDrift() <= maxDrift
    else { return false }
    return true
  }

  private func fitAffine(_ markers: [DetectedMarker]) -> AlignmentTransform? {
    guard markers.count >= 3 else { return nil }
    var xx = 0.0
    var xy = 0.0
    var yy = 0.0
    var xSum = 0.0
    var ySum = 0.0
    var xu = 0.0
    var yu = 0.0
    var uSum = 0.0
    var xv = 0.0
    var yv = 0.0
    var vSum = 0.0

    for marker in markers {
      let x = Double(marker.expectedCenter.x)
      let y = Double(marker.expectedCenter.y)
      let u = Double(marker.center.x)
      let v = Double(marker.center.y)
      xx += x * x
      xy += x * y
      yy += y * y
      xSum += x
      ySum += y
      xu += x * u
      yu += y * u
      uSum += u
      xv += x * v
      yv += y * v
      vSum += v
    }

    let n = Double(markers.count)
    let matrix = [
      [xx, xy, xSum],
      [xy, yy, ySum],
      [xSum, ySum, n],
    ]
    guard let xCoefficients = solve3x3(matrix, [xu, yu, uSum]),
      let yCoefficients = solve3x3(matrix, [xv, yv, vSum])
    else { return nil }

    return AlignmentTransform(
      a: xCoefficients[0],
      b: xCoefficients[1],
      c: xCoefficients[2],
      d: yCoefficients[0],
      e: yCoefficients[1],
      f: yCoefficients[2])
  }

  private func solve3x3(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
    guard matrix.count == 3, matrix.allSatisfy({ $0.count == 3 }), vector.count == 3 else {
      return nil
    }
    var augmented = (0..<3).map { matrix[$0] + [vector[$0]] }

    for pivot in 0..<3 {
      var bestRow = pivot
      for row in pivot..<3 where abs(augmented[row][pivot]) > abs(augmented[bestRow][pivot]) {
        bestRow = row
      }
      guard abs(augmented[bestRow][pivot]) > 1e-10 else { return nil }
      if bestRow != pivot { augmented.swapAt(bestRow, pivot) }

      let divisor = augmented[pivot][pivot]
      for column in pivot..<4 { augmented[pivot][column] /= divisor }

      for row in 0..<3 where row != pivot {
        let factor = augmented[row][pivot]
        for column in pivot..<4 {
          augmented[row][column] -= factor * augmented[pivot][column]
        }
      }
    }
    return [augmented[0][3], augmented[1][3], augmented[2][3]]
  }

  private func residual(marker: DetectedMarker, transform: AlignmentTransform) -> Double {
    let projected = transform.apply(marker.expectedCenter)
    return hypot(Double(projected.x - marker.center.x), Double(projected.y - marker.center.y))
  }

  private func markerCoverage(_ markers: [DetectedMarker]) -> Double {
    guard markers.count >= 2 else { return 0 }
    let xs = markers.map { Double($0.expectedCenter.x) }
    let ys = markers.map { Double($0.expectedCenter.y) }
    guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
      return 0
    }
    return max(0, maxX - minX) * max(0, maxY - minY)
  }

  private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }
}
