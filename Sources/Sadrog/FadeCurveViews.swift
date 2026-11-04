// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// Fade ramps drawn over an audio clip with the curve that is really applied (`FadeCurve.gain`): the shaded part is what is taken away.
struct FadeOverlay: View {
    let fadeIn: CGFloat, fadeOut: CGFloat
    var inCurve = FadeCurve.linear, outCurve = FadeCurve.linear
    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            if fadeIn > 0.5 { ramp(x0: 0, w: min(fadeIn, W), H: H, curve: inCurve, mirrored: false) }
            if fadeOut > 0.5 { ramp(x0: max(0, W - fadeOut), w: min(fadeOut, W), H: H, curve: outCurve, mirrored: true) }
        }.allowsHitTesting(false)
    }
    @ViewBuilder private func ramp(x0: CGFloat, w: CGFloat, H: CGFloat, curve: FadeCurve, mirrored: Bool) -> some View {
        let n = max(6, min(40, Int(w / 3)))
        let pts: [CGPoint] = (0...n).map { i in
            let u = Double(i) / Double(n)
            return CGPoint(x: x0 + CGFloat(u) * w, y: H * (1 - CGFloat(curve.gain(mirrored ? 1 - u : u))))
        }
        Path { p in
            p.move(to: CGPoint(x: x0, y: 0)); p.addLine(to: CGPoint(x: x0 + w, y: 0))
            for q in pts.reversed() { p.addLine(to: q) }
            p.closeSubpath()
        }.fill(.black.opacity(0.38))
        Path { p in p.move(to: pts[0]); for q in pts.dropFirst() { p.addLine(to: q) } }.stroke(Theme.C.text.opacity(0.85), lineWidth: 1)
    }
}

/// Handles of a sound item’s fades, shown on hover/selection: a square at the end of each fade for its DURATION and a round handle on the curve for its CURVATURE.
/// Each gesture is one undo step; Esc cancels it (the project is untouched); double-click on a curvature handle straightens it; the context menu picks a shape.
struct FadeHandles: View {
    @ObservedObject var m: EditorModel
    let id: UUID, duration: Double, pps: CGFloat, width: CGFloat, height: CGFloat
    @State private var start: AudioEdit?
    @State private var cancelled = false
    @State private var esc = KeyMonitorBox()
    private func armEsc() {
        guard esc.token == nil else { return }
        esc.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53, let b = start else { return e }
            cancelled = true; m.liveAudioEdit(id, b); m.liveAudio[id] = nil; return nil
        }
    }
    private func finish(_ commit: Bool) { defer { start = nil; cancelled = false; esc.stop() }; if commit, !cancelled, start != nil { m.commitAudio(id) } }
    var body: some View {
        let e = m.audioEdit(id), f = e.effectiveFades(duration: duration)
        ZStack(alignment: .topLeading) {
            handle(x: CGFloat(f.fadeIn) * pps, help: T("Fade-in: trage spre dreapta pentru durată"), isIn: true)
            handle(x: width - CGFloat(f.fadeOut) * pps, help: T("Fade-out: trage spre stânga pentru durată"), isIn: false)
            // curvature handles need room: below ~30 pt of fade they would overlap the duration handle, so the Inspector row is the way there
            if f.fadeIn * Double(pps) >= 30 { curveHandle(isIn: true, fade: f.fadeIn, curve: e.fadeInCurve) }
            if f.fadeOut * Double(pps) >= 30 { curveHandle(isIn: false, fade: f.fadeOut, curve: e.fadeOutCurve) }
        }.frame(width: width, height: height, alignment: .topLeading)
        .onDisappear { esc.stop() }
    }
    private func handle(x: CGFloat, help: String, isIn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Theme.C.text).frame(width: 7, height: 7).overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Theme.C.bg0, lineWidth: 1))
            .frame(width: 18, height: 16).contentShape(Rectangle())             // comfortable hit area around a fine mark
            .offset(x: max(-4, min(width - 14, x - 9)), y: -3)
            .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { v in
                if cancelled { return }
                let b = start ?? m.audioEdit(id); start = b; armEsc()
                var n = b; let dt = Double(v.translation.width / pps)
                if !isIn { n.fadeOut = max(0, min(duration - b.fadeIn, ((b.fadeOut - dt) * 100).rounded() / 100)) }
                if isIn { n.fadeIn = max(0, min(duration - b.fadeOut, ((b.fadeIn + dt) * 100).rounded() / 100)) }
                m.liveAudioEdit(id, n)
            }.onEnded { _ in finish(true) })
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .help(help).accessibilityLabel(isIn ? T("Mâner fade-in") : T("Mâner fade-out"))
    }
    private func curveHandle(isIn: Bool, fade: Double, curve: FadeCurve) -> some View {
        let fw = CGFloat(fade) * pps
        let cx = isIn ? fw / 2 : width - fw / 2, cy = height * (1 - CGFloat(curve.midGain))
        func set(_ c: FadeCurve) { m.apply(reload: false) { $0.setFadeCurves(id, fadeIn: isIn ? c : nil, fadeOut: isIn ? nil : c) } }
        return Circle().fill(Theme.C.sel).frame(width: 8, height: 8).overlay(Circle().strokeBorder(Theme.C.bg0, lineWidth: 1))
            .frame(width: 18, height: 18).contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { v in
                if cancelled { return }
                let b = start ?? m.audioEdit(id); start = b; armEsc()
                let c0 = isIn ? b.fadeInCurve : b.fadeOutCurve
                let fineK: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                let g = c0.midGain - Double(v.translation.height * fineK / max(1, height))
                var n = b; let c = FadeCurve.fitting(midGain: g, from: c0)
                if isIn { n.fadeInCurve = c } else { n.fadeOutCurve = c }
                m.liveAudioEdit(id, n)
            }.onEnded { _ in finish(true) })
            .onTapGesture(count: 2) { set(.linear) }
            .contextMenu {
                Button(T("Liniar")) { set(.linear) }
                Button(T("Intrare lentă")) { set(FadeCurve(shape: .easeIn, bend: curve.bend)) }
                Button(T("Ieșire lentă")) { set(FadeCurve(shape: .easeOut, bend: curve.bend)) }
                Button(T("Curbă S")) { set(FadeCurve(shape: .sCurve, bend: curve.bend)) }
                Divider()
                Button(T("Resetează curba")) { set(.linear) }.disabled(curve == .linear)
            }
            .help(T("Curbura fade-ului: trage în sus/jos (⇧ fin, Esc anulează); dublu-clic o îndreaptă; clic dreapta alege forma"))
            .accessibilityLabel(isIn ? T("Curbură fade-in") : T("Curbură fade-out")).accessibilityValue(String(format: "%.0f %%", curve.midGain * 100))
            .accessibilityAction(named: Text(T("Resetează curba"))) { set(.linear) }
            .position(x: cx, y: max(6, min(height - 6, cy)))   // LAST: gestures attached after .position() answer over the whole container
    }
}

/// The “X” of a crossfade over the start of the incoming sound: both gain curves as really applied (`CrossfadeShape.gains`), with a handle on the incoming curve
/// to bend them. One undo step per drag, Esc cancels, double-click straightens, the context menu switches equal gain / equal power.
struct CrossfadeX: View {
    @ObservedObject var m: EditorModel
    let id: UUID, shape: CrossfadeShape, width: CGFloat, height: CGFloat
    @State private var live: CrossfadeShape?
    @State private var cancelled = false
    @State private var esc = KeyMonitorBox()
    var body: some View {
        let sh = live ?? shape, w = max(2, width)
        ZStack(alignment: .topLeading) {
            Canvas { ctx, size in
                let n = max(8, min(48, Int(size.width / 3)))
                var a = Path(), b = Path()
                for i in 0...n {
                    let u = Double(i) / Double(n), g = sh.gains(u), x = CGFloat(u) * size.width
                    let pa = CGPoint(x: x, y: size.height * (1 - CGFloat(g.incoming))), pb = CGPoint(x: x, y: size.height * (1 - CGFloat(g.outgoing)))
                    if i == 0 { a.move(to: pa); b.move(to: pb) } else { a.addLine(to: pa); b.addLine(to: pb) }
                }
                ctx.stroke(a, with: .color(Theme.C.accentInk.opacity(0.9)), lineWidth: 1.3); ctx.stroke(b, with: .color(Theme.C.accentInk.opacity(0.6)), lineWidth: 1.3)
            }.allowsHitTesting(false).accessibilityHidden(true)
            if w >= 30 {
                Circle().fill(Theme.C.sel).frame(width: 8, height: 8).overlay(Circle().strokeBorder(Theme.C.bg0, lineWidth: 1))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
                    .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { v in
                        if cancelled { return }
                        if esc.token == nil { esc.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in guard e.keyCode == 53 else { return e }; cancelled = true; live = nil; return nil } }
                        let fineK: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                        live = shape.fitting(midIncoming: shape.midIncoming - Double(v.translation.height * fineK / max(1, height)))
                    }.onEnded { _ in
                        defer { live = nil; cancelled = false; esc.stop() }
                        if !cancelled, let s = live, s != shape { m.apply(reload: false) { $0.setCrossfadeShape(incoming: id, s) } }
                    })
                    .onTapGesture(count: 2) { var s = shape; s.curve = .linear; m.apply(reload: false) { $0.setCrossfadeShape(incoming: id, s) } }
                    .contextMenu {
                        Button(T("Câștig egal")) { var s = shape; s.mode = .equalGain; m.apply(reload: false) { $0.setCrossfadeShape(incoming: id, s) } }
                        Button(T("Putere egală")) { var s = shape; s.mode = .equalPower; m.apply(reload: false) { $0.setCrossfadeShape(incoming: id, s) } }
                        Divider()
                        Button(T("Resetează curba")) { var s = shape; s.curve = .linear; m.apply(reload: false) { $0.setCrossfadeShape(incoming: id, s) } }.disabled(shape.curve == .linear)
                    }
                    .help(T("Curba încrucișării: trage în sus/jos (⇧ fin, Esc anulează); dublu-clic o îndreaptă; clic dreapta alege tipul"))
                    .accessibilityLabel(T("Curbura încrucișării")).accessibilityValue(String(format: "%.0f %%", sh.midIncoming * 100))
                    .position(x: w / 2, y: max(6, min(height - 6, height * (1 - CGFloat(sh.midIncoming)))))   // LAST, see curveHandle
            }
        }.frame(width: w, height: height, alignment: .topLeading).onDisappear { esc.stop() }
    }
}
