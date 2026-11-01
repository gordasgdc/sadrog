// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// Development-only comparison board (launch with `--components`): the real styles and views, each state forced.
struct ComponentsBoard: View {
    private let states: [(String, ControlState)] = [("Normal", .normal), ("Hover", .hover), ("Apăsat", .pressed), ("Focus", .focus), ("Dezactivat", .disabled)]
    private let media = ProcessInfo.processInfo.environment["SADROG_BOARD_MEDIA"] ?? ""
    @State private var pick = 1
    private let peaks: [Float] = (0..<900).map { i in Float(0.18 + 0.7 * abs(sin(Double(i) * 0.21) * sin(Double(i) * 0.035))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            board("1 · Bară de unelte și transport") {
                ForEach(states, id: \.0) { n, st in
                    HStack(spacing: 14) {
                        label(n)
                        ControlGroup2 {
                            Button {} label: { Image(systemName: "cursorarrow") }.buttonStyle(ToolButtonStyle(active: true))
                            Button {} label: { Image(systemName: "scissors") }.buttonStyle(ToolButtonStyle())
                        }
                        HStack(spacing: 4) {
                            IconButton(symbol: "backward.frame.fill", label: T("Un cadru înapoi")) {}
                            Button {} label: { Image(systemName: "play.fill").font(Theme.F.iconLarge).frame(width: 34, height: 24) }.buttonStyle(.gloss(.secondary, compact: true))
                            IconButton(symbol: "forward.frame.fill", label: T("Un cadru înainte")) {}
                        }
                        Button {} label: { Label(T("Exportă"), systemImage: "square.and.arrow.up") }.buttonStyle(.gloss(.primary))
                        Button {} label: { Label(T("Taie la cursor"), systemImage: "scissors") }.buttonStyle(.gloss(.secondary, compact: true))
                        Text("00:00:12:18").font(Theme.F.mono).padding(.horizontal, 8).frame(width: 104, height: 24).fieldSurface(focused: st == .focus)
                    }.environment(\.forcedState, st).disabled(st == .disabled)
                }
            }
            board("2 · Selector, meniu, câmp") {
                HStack(spacing: 14) {
                    label("Normal")
                    Picker(T("Calitate"), selection: $pick) { Text(T("Rapid (fără recodare)")).tag(0); Text(T("Înalt (HEVC)")).tag(1) }.labelsHidden().frame(width: 190)
                    label("Dezactivat")
                    Picker(T("Calitate"), selection: $pick) { Text(T("Rapid (fără recodare)")).tag(0); Text(T("Înalt (HEVC)")).tag(1) }.labelsHidden().frame(width: 190).disabled(true)
                    HStack(spacing: 6) { Image(systemName: "magnifyingglass").font(Theme.F.small).foregroundStyle(Theme.C.textFaint); Text(T("Caută materiale…")).font(Theme.F.body).foregroundStyle(Theme.C.textFaint); Spacer() }
                        .padding(.horizontal, 8).frame(width: 190, height: 26).fieldSurface()
                    Text(T("Meniu deschis: nativ macOS (vezi captura din aplicație).")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
                }
            }
            board("3 · Rând de inspector") {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 2) { ValueRow(label: T("Început"), value: "00:00:08:03"); ValueRow(label: T("Durată"), value: "00:00:09:02"); ValueRow(label: T("Fișier"), value: "capture.mov") }.frame(width: 250)
                    VStack(alignment: .leading, spacing: 2) { ValueRow(label: T("Sfârșit"), value: "00:00:17:06").opacity(0.4); Text(T("dezactivat")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }.frame(width: 250)
                    InspectorGroup(T("Grup de inspector")) { ValueRow(label: T("Cadre/s"), value: "30") }.frame(width: 250)
                }
            }
            board("5 · Butonul Record, toate stările") {
                let phases: [(String, RecPhase, ControlState)] = [("Disponibil", .idle, .normal), ("Hover", .idle, .hover), ("Apăsat", .idle, .pressed), ("Dezactivat", .idle, .disabled), ("Pregătire", .preparing, .normal), ("Numărătoare", .countdown(3), .normal), ("Pornește", .starting, .normal), ("Înregistrare", .recording, .normal), ("Pauză", .paused, .normal), ("Oprire", .stopping, .normal)]
                HStack(spacing: 16) {
                    ForEach(phases, id: \.0) { n, p, st in
                        VStack(spacing: 6) { RecordFace(phase: p, state: st); Text(n).font(Theme.F.caption).foregroundStyle(Theme.C.textDim) }
                    }
                }.padding(.vertical, 6)
            }
            board("6 · Panou de captură: materialul din machetă, fiecare stare din stilurile reale") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(states, id: \.0) { n, st in
                        HStack(spacing: 14) {
                            label(n)
                            Button {} label: { Label(T("Previzualizare"), systemImage: "eye").lineLimit(1) }.buttonStyle(CMButtonStyle(width: CM.previewW))
                            ZStack { CMFace(state: st); HStack(spacing: 6) { Text(T("Canale")); Image(systemName: "chevron.down").font(Theme.F.glyph) }.font(CM.button) }.frame(width: CM.configW, height: CM.buttonHeight)
                            ZStack { CMFace(radius: CM.addRadius, state: st); HStack(spacing: 10) { Image(systemName: "plus.circle"); Text(T("Adaugă sursă")).font(.system(size: 19, weight: .semibold)) } }.frame(width: 250, height: CM.addH)
                            RecordPillFace(phase: .idle, state: st, label: Text(T("Începe înregistrarea")))
                        }.environment(\.forcedState, st).disabled(st == .disabled)
                    }
                }.padding(.vertical, 6)
            }
            board("7 · Indicator de nivel: oprit, normal, ridicat, aproape de limită, clipping") {
                LazyVGrid(columns: [GridItem(.fixed(460)), GridItem(.fixed(460))], alignment: .leading, spacing: 18) {
                    ForEach([("Oprit", Float(0), false), ("−30 dBFS", Float(0.0316), true), ("−12 dBFS", Float(0.251), true), ("−2 dBFS", Float(0.794), true), ("0 dBFS · clipping", Float(1.0), true)], id: \.0) { n, pk, live in
                        let r: MeterReading = { var m = MeterReading(); m.update(peak: pk); return m }()
                        VStack(alignment: .leading, spacing: 6) { Text(n).font(Theme.F.caption).foregroundStyle(Theme.C.textDim); LevelReadout(reading: r, live: live) }.frame(width: 440, alignment: .leading)
                    }
                }
            }
            board("8 · Previzualizare cameră: stările reale ale casetei (nicio imagine ilustrativă)") {
                HStack(alignment: .top, spacing: 14) {
                    ForEach([("Se încarcă", CameraPreviewState.loading), ("Acces refuzat", .denied), ("Restricționat", .restricted), ("Cameră lipsă", .absent), ("Eroare", .failed("Camera este folosită de altă aplicație."))], id: \.0) { n, st in
                        VStack(alignment: .leading, spacing: 4) { Text(n).font(Theme.F.caption).foregroundStyle(Theme.C.textDim); CameraPreviewBox(state: st, session: nil) }
                    }
                }
            }
            board("4 · Clipuri") {
                let cases: [(String, Bool, Bool, Bool)] = [("Neales", false, false, false), ("Hover", false, true, false), ("Ales", true, false, false), ("Margine în editare", true, false, true)]
                HStack(alignment: .top, spacing: 18) {
                    ForEach(cases, id: \.0) { n, sel, hov, ed in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(n).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
                            VideoClipFace(media: media, sourceStart: 6, duration: 6, w: 232, h: 72, pps: 38.7, selected: sel, hover: hov, editing: ed)
                            AudioClipFace(peaks: peaks, from: 6, to: 12, w: 232, h: 54, selected: sel, hover: hov, editing: ed)
                        }
                    }
                }
            }
        }.padding(20).frame(width: 1240).background(Theme.C.bg1).foregroundStyle(Theme.C.text)
    }
    private func label(_ t: String) -> some View { Text(t).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).frame(width: 66, alignment: .leading) }
    private func board<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) { SectionLabel(title); c() }.padding(.bottom, 14)
    }
}
