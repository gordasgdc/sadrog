// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import CoreGraphics
import CoreImage
import Foundation

/// „Prezentator în cerc”: a video clip shown as a perfect circle. This is a CROP of the clip's own picture — not a callout (a callout is a
/// region effect on the frame). The circle's place and size on the canvas are the item's `Transform` (move, resize, align, animate as before);
/// what is seen INSIDE the circle (zoom and framing of the picture) is set here, separately. Removing it gives the full rectangle back.
public struct CircleCrop: Codable, Equatable, Sendable {
    /// ≥ 1: how much the picture is enlarged inside the circle (1 = the largest square the picture allows).
    public var zoom: Double = 1
    /// −1…1: where the square window sits inside the picture, as a fraction of the free travel (0 = centred; +x right, +y down).
    public var offsetX: Double = 0
    public var offsetY: Double = 0
    public var border: CircleBorder?
    public static let zoomRange: ClosedRange<Double> = 1...4
    public init(zoom: Double = 1, offsetX: Double = 0, offsetY: Double = 0, border: CircleBorder? = nil) {
        self.zoom = zoom; self.offsetX = offsetX; self.offsetY = offsetY; self.border = border
    }
    public mutating func normalize() {
        zoom = min(Self.zoomRange.upperBound, max(Self.zoomRange.lowerBound, zoom))
        offsetX = min(1, max(-1, offsetX)); offsetY = min(1, max(-1, offsetY))
        if var b = border { b.normalize(); border = b }
    }
    /// The square of the source picture shown in the circle, in TOP-LEFT pixel coordinates of a source of size `n`. Never distorts:
    /// a square of the shorter side divided by `zoom`, moved inside the picture by the offsets.
    /// Moves the picture by `d` SOURCE pixels (right/down) while the circle stays: the window travels the opposite way, always inside the picture (no gaps).
    public mutating func pan(imageBy d: CGSize, in n: CGSize) {
        let w = window(in: n); setWindowOrigin(CGPoint(x: w.minX - d.width, y: w.minY - d.height), in: n)
    }
    /// Places the window (top-left source pixels), clamped inside the source; converts back to the −1…1 offsets.
    public mutating func setWindowOrigin(_ o: CGPoint, in n: CGSize) {
        let side = min(n.width, n.height) / CGFloat(max(1, zoom)), fx = n.width - side, fy = n.height - side
        offsetX = fx > 0.5 ? Double(min(max(o.x, 0), fx) / (fx / 2) - 1) : 0
        offsetY = fy > 0.5 ? Double(min(max(o.y, 0), fy) / (fy / 2) - 1) : 0
        normalize()
    }
    /// New magnification, keeping the point of the picture that is at the circle's centre where it is (clamped: never a gap in the circle).
    public mutating func setZoom(_ z: Double, keepingCentreIn n: CGSize) {
        let w = window(in: n), cx = w.midX, cy = w.midY
        zoom = z; normalize()
        let side = min(n.width, n.height) / CGFloat(zoom)
        setWindowOrigin(CGPoint(x: cx - side / 2, y: cy - side / 2), in: n)
    }
    /// Centres the picture in the circle (offsets 0), keeping the magnification.
    public mutating func recentre() { offsetX = 0; offsetY = 0 }
    public func window(in n: CGSize) -> CGRect {
        let side = min(n.width, n.height) / CGFloat(max(1, zoom))
        let fx = n.width - side, fy = n.height - side
        return CGRect(x: fx / 2 * (1 + CGFloat(offsetX)), y: fy / 2 * (1 + CGFloat(offsetY)), width: side, height: side)
    }
}

public enum CircleBorderStyle: String, Codable, Sendable, CaseIterable { case simple, glossy }

/// Optional outline drawn INSIDE the circle edge (it never grows the circle). `width` is a fraction of the diameter.
public struct CircleBorder: Codable, Equatable, Sendable {
    public var style: CircleBorderStyle = .glossy
    public var width: Double = 0.02
    public var color: TextColor = .white
    public var opacity: Double = 1
    public static let widthRange: ClosedRange<Double> = 0.005...0.08
    public init(style: CircleBorderStyle = .glossy, width: Double = 0.02, color: TextColor = .white, opacity: Double = 1) {
        self.style = style; self.width = width; self.color = color; self.opacity = opacity
    }
    public mutating func normalize() { width = min(Self.widthRange.upperBound, max(Self.widthRange.lowerBound, width)); opacity = min(1, max(0, opacity)) }
}

/// What the compositor needs for one cropped item, prepared once per build (not per frame): the window, the circle mask and the outline image,
/// all at the window's pixel size. Preview and export use the same objects.
public struct CircleCropRender: @unchecked Sendable {
    public let window: CGRect          // top-left source pixels
    public let side: CGFloat
    let mask: CIImage                  // white = picture; antialiased edge
    let ring: CIImage?                 // outline (premultiplied), drawn over the picture

    public init(_ c: CircleCrop, source n: CGSize) {
        let w = c.window(in: n); window = w; side = w.width
        let px = max(2, Int(w.width.rounded()))
        mask = Self.image(px, gray: true) { ctx, r in ctx.setFillColor(gray: 1, alpha: 1); ctx.fillEllipse(in: r) } ?? CIImage(color: .white)
        ring = c.border.flatMap { b in Self.image(px, gray: false) { ctx, r in Self.drawRing(b, ctx, r) } }
    }

    static func image(_ px: Int, gray: Bool, _ draw: (CGContext, CGRect) -> Void) -> CIImage? {
        let cs = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true); ctx.setShouldAntialias(true)
        if gray { ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: px, height: px)) }
        draw(ctx, CGRect(x: 0, y: 0, width: px, height: px))
        return ctx.makeImage().map { CIImage(cgImage: $0) }
    }

    /// Simple: an even ring. Glossy: the same ring lit from above — a lighter top, a slightly deeper bottom and one thin specular arc on its inner
    /// edge. Everything stays inside the ring, so the face is never covered and the outline never becomes a heavy frame.
    static func drawRing(_ b: CircleBorder, _ ctx: CGContext, _ r: CGRect) {
        let side = r.width, lw = max(1, CGFloat(b.width) * side), a = CGFloat(b.opacity)
        let c = b.color
        let ringRect = r.insetBy(dx: lw / 2, dy: lw / 2)
        ctx.setLineWidth(lw)
        ctx.setStrokeColor(CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: a * c.a))
        ctx.strokeEllipse(in: ringRect)
        guard b.style == .glossy else { return }
        ctx.saveGState()
        ctx.addEllipse(in: ringRect); ctx.replacePathWithStrokedPath(); ctx.clip()
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        // CG is y-up: the top of the picture is at maxY
        if let light = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55 * a), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(light, start: CGPoint(x: 0, y: r.maxY), end: CGPoint(x: 0, y: r.maxY - side * 0.5), options: [])
        }
        if let shade = CGGradient(colorsSpace: cs, colors: [CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.22 * a)] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(shade, start: CGPoint(x: 0, y: r.minY + side * 0.45), end: CGPoint(x: 0, y: r.minY), options: [])
        }
        ctx.restoreGState()
        // fine specular arc on the inner edge of the ring, upper left → upper right
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(1, lw * 0.18))
        ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.7 * a))
        ctx.addArc(center: CGPoint(x: r.midX, y: r.midY), radius: side / 2 - lw * 0.78, startAngle: .pi * 0.62, endAngle: .pi * 0.38, clockwise: true)
        ctx.strokePath()
    }

    /// The picture of a source frame `src` (CoreImage, y-up, origin 0) cut to the circle, with its outline. Result: origin 0, size `side`×`side`.
    public func apply(to src: CIImage, source n: CGSize) -> CIImage {
        let ciY = n.height - window.maxY                                   // top-left window → CoreImage (y-up)
        let sq = src.cropped(to: CGRect(x: window.minX, y: ciY, width: side, height: side))
            .transformed(by: CGAffineTransform(translationX: -window.minX, y: -ciY))
        let px = mask.extent.width, k = side / max(px, 1)
        let m = mask.transformed(by: CGAffineTransform(scaleX: k, y: k))
        var out = sq.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: sq.extent), kCIInputMaskImageKey: m])
        if let ring { out = ring.transformed(by: CGAffineTransform(scaleX: k, y: k)).composited(over: out) }
        return out.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }
}

public extension TextColor {
    static let presenterRed = TextColor(r: 0.93, g: 0.20, b: 0.22, a: 1)
}

/// The four quick places of a presenter circle.
public enum PresenterCorner: CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    public var id: Self { self }
}

/// Where and how a presenter circle is placed — one formula for the editor's buttons and for a recording opened with its camera.
public enum PresenterPlacement {
    public static let margin = 0.04                  // of the canvas height
    public static let scale = 0.34                   // a new circle: about a third of the canvas height
    public static var defaultCrop: CircleCrop { CircleCrop(border: CircleBorder(style: .glossy, width: 0.02, color: .white)) }
    /// `t` moved so a circle of its size (diameter = shorter canvas side × scale) sits in `corner` with the margin; rotation/opacity kept.
    public static func transform(_ t: Transform, corner: PresenterCorner, render R: CGSize) -> Transform {
        let W = Double(R.width), H = Double(R.height), D = min(W, H) * t.scale, mg = margin * H
        let left = corner == .topLeft || corner == .bottomLeft, top = corner == .topLeft || corner == .topRight
        let cx = left ? mg + D / 2 : W - mg - D / 2, cy = top ? mg + D / 2 : H - mg - D / 2
        var o = t; o.x = (cx - W / 2) / W; o.y = (cy - H / 2) / H; return o
    }
}
