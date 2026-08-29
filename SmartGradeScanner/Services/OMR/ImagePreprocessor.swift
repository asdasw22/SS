import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO

struct ImagePreprocessor: Sendable {
    func orientedImage(from image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let input = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation.rawValue))
        let translated = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
        return context.createCGImage(translated, from: translated.extent)
    }

    func normalizedImage(from image: CGImage) -> CGImage? {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let input = CIImage(cgImage: image)

        let controls = CIFilter.colorControls()
        controls.inputImage = input
        controls.saturation = 0
        controls.contrast = 1.08
        controls.brightness = 0.01

        guard let controlled = controls.outputImage else { return nil }
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = controlled
        sharpen.sharpness = 0.18
        guard let output = sharpen.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
    }

    /// Warps the detected page (given by its four image-space corners) into the
    /// exact canonical 904×1280 canvas used by the fixed strict template. Every
    /// later bubble/ID ROI is expressed in this canonical coordinate system, so a
    /// raw camera frame is never analyzed directly.
    func canonicalImage(from image: CGImage,
                        corners: [CGPoint],
                        width: Int,
                        height: Int) -> CGImage? {
        guard corners.count == 4, width > 0, height > 0 else { return image }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let input = CIImage(cgImage: image)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = input
        filter.topLeft = corners[0]
        filter.topRight = corners[1]
        filter.bottomRight = corners[2]
        filter.bottomLeft = corners[3]
        guard let corrected = filter.outputImage,
              corrected.extent.width > 1, corrected.extent.height > 1 else { return nil }

        let translated = corrected.transformed(by: CGAffineTransform(
            translationX: -corrected.extent.minX, y: -corrected.extent.minY))

        let targetSize = CGSize(width: width, height: height)
        let scaleX = targetSize.width / max(translated.extent.width, 1)
        let scaleY = targetSize.height / max(translated.extent.height, 1)
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let targetRect = CGRect(origin: .zero,
                                size: CGSize(width: targetSize.width.rounded(),
                                             height: targetSize.height.rounded()))
        return context.createCGImage(scaled, from: targetRect)
    }

    func resizedImage(from image: CGImage, longEdge: CGFloat = 1400) -> CGImage? {
        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let sourceLong = max(sourceWidth, sourceHeight)
        guard sourceLong > 1 else { return nil }
        if sourceLong <= longEdge { return image }
        let scale = longEdge / sourceLong
        let input = CIImage(cgImage: image)
        let scaled = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rect = CGRect(x: 0, y: 0, width: (sourceWidth * scale).rounded(), height: (sourceHeight * scale).rounded())
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(scaled, from: rect)
    }

    func correctedImage(from image: CGImage,
                        corners: [CGPoint],
                        targetAspectRatio: Double,
                        longEdge: CGFloat = 1600) -> CGImage? {
        guard corners.count == 4, targetAspectRatio > 0 else { return image }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let input = CIImage(cgImage: image)

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = input
        filter.topLeft = corners[0]
        filter.topRight = corners[1]
        filter.bottomRight = corners[2]
        filter.bottomLeft = corners[3]
        guard let corrected = filter.outputImage, corrected.extent.width > 1, corrected.extent.height > 1 else { return nil }

        let translated = corrected.transformed(by: CGAffineTransform(translationX: -corrected.extent.minX,
                                                                     y: -corrected.extent.minY))
        // Never upscale a small already-clean scan to several megapixels. OMR only
        // needs enough pixels to measure the bubbles; avoiding unnecessary upscale
        // makes photo-library scans much faster.
        let sourceLongEdge = max(translated.extent.width, translated.extent.height)
        let effectiveLongEdge = max(500, min(longEdge, sourceLongEdge))
        let targetSize: CGSize
        if targetAspectRatio >= 1 {
            targetSize = CGSize(width: effectiveLongEdge, height: effectiveLongEdge / CGFloat(targetAspectRatio))
        } else {
            targetSize = CGSize(width: effectiveLongEdge * CGFloat(targetAspectRatio), height: effectiveLongEdge)
        }

        let scaleX = targetSize.width / max(translated.extent.width, 1)
        let scaleY = targetSize.height / max(translated.extent.height, 1)
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        let targetRect = CGRect(origin: .zero,
                                size: CGSize(width: targetSize.width.rounded(), height: targetSize.height.rounded()))
        return context.createCGImage(scaled, from: targetRect)
    }
}
