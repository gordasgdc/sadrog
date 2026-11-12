// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// What an export will really produce, computed once and used by the sheet's summary, details and fields — never a second guess.
/// The size rule is the one AVFoundation's size presets follow (measured on landscape, portrait, 4:3, square, UHD and small sources in
/// `ExportPlanTests`): the LONG side is limited to `longSideCap`, the aspect is kept, nothing is enlarged, sizes are even.
public struct ExportPlan: Equatable, Sendable {
    public enum Delivery: Equatable, Sendable { case reencode, passthrough, audio, archive }
    public var delivery: Delivery
    public var width: Int, height: Int
    public var duration: Double
    public var range: ClosedRange<Double>?
    public var codec: String
    public var container: String
    public var fileExtension: String
    /// What the result is, in the user's terms — never "lossless" unless the pixels really are the processed frames.
    public enum Loss: String, Equatable, Sendable { case none, lossy, highQuality, lossless }
    public var loss: Loss = .lossy
    public var fps: Double = 0
    public var audio: String = ""
    /// Compressed video only: true = this Mac's hardware encoder is required for the export; false = software encoding (slower). nil = not applicable.
    public var hardware: Bool?
    /// Honest notes about the result (enlargement, different proportions, hidden cost), already in the interface language.
    public var notes: [String] = []

    public static func scaled(width w: Int, height h: Int, longSideCap cap: Int?) -> (w: Int, h: Int) {
        guard let cap, max(w, h) > cap else { return (w, h) }
        let k = Double(cap) / Double(max(w, h))
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        return w >= h ? (cap, even(Double(h) * k)) : (even(Double(w) * k), cap)
    }
    /// - Parameters: `renderSize` = the document's picture size; `onlyRange` = the In–Out range is requested; `passthrough` = "fast" is really possible.
    public static func video(_ p: SadrogProject, renderSize: CGSize, longSideCap: Int?, passthrough: Bool, onlyRange: Bool) -> ExportPlan {
        let r = onlyRange ? p.exportRange : nil
        let size = passthrough ? (Int(renderSize.width), Int(renderSize.height)) : scaled(width: Int(renderSize.width), height: Int(renderSize.height), longSideCap: longSideCap)
        return ExportPlan(delivery: passthrough ? .passthrough : .reencode, width: size.0, height: size.1, duration: r.map { $0.upperBound - $0.lowerBound } ?? p.timelineEnd,
                          range: r, codec: passthrough ? "" : "H.264", container: "QuickTime (.mov)", fileExtension: "mov")
    }
    /// The plan for the explicit settings (size, rate, mode, codec). `copyPossible` = the project can be copied without processing; when it cannot, `.copy` is refused by the
    /// exporter (it never turns into a lossy export silently) and the plan says so in `notes`.
    public static func video(_ p: SadrogProject, documentSize: CGSize, documentFPS: Double, settings s: ExportSettings, copyPossible: Bool) -> ExportPlan {
        let r = s.onlyRange ? p.exportRange : nil, dur = r.map { $0.upperBound - $0.lowerBound } ?? p.timelineEnd
        var pl = ExportPlan(delivery: .reencode, width: Int(documentSize.width), height: Int(documentSize.height), duration: dur, range: r, codec: "", container: "QuickTime (.mov)", fileExtension: "mov")
        pl.fps = documentFPS
        if s.mode == .copy {
            pl.delivery = .passthrough; pl.loss = .none; pl.audio = T("copiat din sursă"); pl.codec = ""
            if !copyPossible { pl.notes.append(T("Copierea fără procesare nu se poate pentru acest proiect.")) }
            return pl
        }
        let o = s.outputSize(document: documentSize)
        pl.width = o.w; pl.height = o.h; pl.fps = s.outputFPS(document: documentFPS)
        switch s.mode {
        case .copy: break
        case .compressed:
            pl.codec = s.codec == .h264 ? "H.264" : "HEVC (H.265)"; pl.loss = .lossy; pl.audio = "AAC"
            if s.container == .mp4 { pl.container = "MPEG-4 (.mp4)"; pl.fileExtension = "mp4" }
            pl.hardware = HardwareEncoder.available(s.codec, width: o.w, height: o.h)
            if s.audioMono { pl.audio = "AAC mono" }
        case .master:
            pl.codec = s.proRes == .p422 ? "Apple ProRes 422" : "Apple ProRes 4444"; pl.loss = .highQuality; pl.audio = T("PCM necomprimat")
            pl.notes.append(T("ProRes este un master de calitate foarte înaltă, dar tot comprimat: nu este lossless."))
        case .lossless:
            pl.codec = T("PNG fără pierderi, RGB 8 biți"); pl.container = T("Folder: secvență PNG + audio WAV"); pl.fileExtension = ""; pl.loss = .lossless; pl.audio = T("WAV PCM întreg, 32 biți")
            pl.notes.append(T("Rezultatul este un folder: cadre PNG, audio.wav și sequence.json (cadență, dimensiuni, număr de cadre, interval, relația cu sunetul)."))
            pl.notes.append(T("Fără pierderi față de cadrele procesate RGB pe 8 biți și mixul proiectului (după scalare și efecte), nu față de sursa originală."))
        }
        let doc = (Int(documentSize.width), Int(documentSize.height))
        if s.mode == .compressed {
            switch s.videoRate(duration: dur) {
            case .bitrate(let m):
                pl.notes.append(L10n.f("Rată video medie țintă: %@ Mb/s; encoderul o poate depăși sau subdepăși pe scene foarte simple sau foarte complexe.", m.formatted(.number.precision(.fractionLength(0...1)))))
                if s.targetMB != nil && s.videoMbps == nil { pl.notes.append(T("Mărime țintă: encoderul lucrează într-o singură trecere, deci mărimea finală este apropiată de țintă, nu garantată.")) }
            case .quality: pl.notes.append(T("Calitate constantă: mărimea depinde de conținut (imagine statică = fișier mic, mișcare multă = fișier mai mare)."))
            }
        }
        if o.w * o.h > doc.0 * doc.1 { pl.notes.append(T("Mărire: imaginea este interpolată; nu apare detaliu nou.")) }
        let da = documentSize.width / max(documentSize.height, 1), oa = Double(o.w) / Double(max(o.h, 1))
        if abs(da - oa) > 0.01 { pl.notes.append(T("Altă proporție decât documentul: imaginea se încadrează întreagă, cu margini; pozițiile relative ale elementelor se păstrează.")) }
        if abs(pl.fps - documentFPS) > 0.01 { pl.notes.append(L10n.f("Cadență schimbată: %@ → %@ cadre/s (cadre repetate sau omise, fără interpolare).", "\(documentFPS.formatted(.number.precision(.fractionLength(0...2))))", "\(pl.fps.formatted(.number.precision(.fractionLength(0...2))))")) }
        return pl
    }
    public static func audio(_ p: SadrogProject) -> ExportPlan {
        ExportPlan(delivery: .audio, width: 0, height: 0, duration: p.timelineEnd, range: nil, codec: "AAC", container: "MPEG-4 audio (.m4a)", fileExtension: "m4a")
    }
    public static func archive(_ p: SadrogProject) -> ExportPlan {
        ExportPlan(delivery: .archive, width: 0, height: 0, duration: p.timelineEnd, range: nil, codec: "", container: "SADROG (.sadrogproj)", fileExtension: "sadrogproj")
    }
}
