// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreImage
import CoreVideo
import Vision

/// What happens to the background behind a person in a camera picture. Computed locally (Vision person segmentation) at EDIT time:
/// the recording itself is never changed, so the effect can be switched off, and it is the same in preview and export.
public enum PersonBackground: String, Codable, Sendable, CaseIterable { case off, blur, remove }

/// Per-item picture adjustments (format 19): simple colour controls and the person-background effect. Neutral values draw the source untouched.
/// Stored values are the CoreImage ones; the inspector shows them as −100…100 (brightness) and percent (contrast, saturation).
public struct PictureAdjust: Codable, Equatable, Sendable {
    public var brightness = 0.0          // −0.5…0.5 (added to the picture); 0 = neutral
    public var contrast = 1.0            // 0.5…1.5; 1 = neutral
    public var saturation = 1.0          // 0…2; 1 = neutral, 0 = black and white
    public var background = PersonBackground.off
    public var blur = 0.5                // background blur strength 0…1 (radius = blur × 4 % of the picture height)
    public init() {}
    public static let brightnessRange = -0.5...0.5, contrastRange = 0.5...1.5, saturationRange = 0.0...2.0
    public var colorIsNeutral: Bool { abs(brightness) < 1e-6 && abs(contrast - 1) < 1e-6 && abs(saturation - 1) < 1e-6 }
    public var isNeutral: Bool { colorIsNeutral && background == .off }
    public mutating func normalize() {
        func cl(_ v: Double, _ r: ClosedRange<Double>) -> Double { v.isFinite ? min(r.upperBound, max(r.lowerBound, v)) : (r.lowerBound + r.upperBound) / 2 }
        brightness = cl(brightness, Self.brightnessRange); contrast = cl(contrast, Self.contrastRange); saturation = cl(saturation, Self.saturationRange); blur = cl(blur, 0...1)
    }
    enum CodingKeys: String, CodingKey { case brightness, contrast, saturation, background, blur }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 1
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 1
        background = (try c.decodeIfPresent(String.self, forKey: .background)).flatMap(PersonBackground.init(rawValue:)) ?? .off
        blur = try c.decodeIfPresent(Double.self, forKey: .blur) ?? 0.5
        normalize()
    }

    /// Colour controls on a source picture (CoreImage, extent kept). Same code for preview and export.
    public func applyColor(to img: CIImage) -> CIImage {
        guard !colorIsNeutral else { return img }
        return img.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation]).cropped(to: img.extent)
    }

    /// The person-background effect on a source frame. `buffer` is the frame the mask is computed from (the full, uncropped source);
    /// `img` is that same frame as an image with its origin at (0,0). Returns `img` untouched when no mask can be made (the failure is never silent
    /// in the editor: `PersonMask.lastFailure` is shown by the inspector).
    public func applyBackground(to img: CIImage, buffer: CVPixelBuffer) -> CIImage {
        guard background != .off, let mask = PersonMask.make(for: buffer) else { return img }
        let rect = img.extent
        let m = mask.transformed(by: CGAffineTransform(scaleX: rect.width / max(1, mask.extent.width), y: rect.height / max(1, mask.extent.height)))
        switch background {
        case .off: return img
        case .blur:
            let back = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: max(0.5, blur * 0.04 * rect.height)]).cropped(to: rect)
            return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: back, kCIInputMaskImageKey: m]).cropped(to: rect)
        case .remove:
            let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0)).cropped(to: rect)
            return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: clear, kCIInputMaskImageKey: m]).cropped(to: rect)
        }
    }
}

/// Person segmentation mask (white = person) for one frame, made on this Mac by the Vision framework. No network, no model download.
public enum PersonMask {
    /// Reason of the last failure (nil = the last request worked). Read by the inspector; written from the compositor's queue.
    public static var lastFailure: String? { lock.lock(); defer { lock.unlock() }; return failure }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failure: String?
    private static func note(_ s: String?) { lock.lock(); failure = s; lock.unlock() }

    public static func make(for buffer: CVPixelBuffer, quality: VNGeneratePersonSegmentationRequest.QualityLevel = .balanced) -> CIImage? {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = quality; req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer, options: [:]).perform([req])
            guard let pb = req.results?.first?.pixelBuffer else { note("no mask"); return nil }
            note(nil)
            return CIImage(cvPixelBuffer: pb)
        } catch { note(error.localizedDescription); return nil }
    }
}
