// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// One grouped list of sources: every kind (screen, window, camera, audio) shares the same row anatomy, separated by hairlines.
struct SourceList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(PanelBackground(radius: 9))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

/// Row anatomy: [icon tile] [title + subtitle] … [actions] [details chevron] [on/off]. Details open in place, on request.
struct SourceRow<Title: View, Actions: View, Detail: View>: View {
    let symbol: String
    var enabled: Binding<Bool>? = nil
    var toggleLocked = false
    var dimmed = false
    var subtitle: String = ""
    var subtitleTone: Color = Theme.C.textFaint
    var hasDetail = false
    @State private var open = false
    @ViewBuilder var title: Title
    @ViewBuilder var actions: Actions
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(Theme.F.icon).foregroundStyle(dimmed ? Theme.C.textFaint : Theme.C.textDim).frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.C.bg3.opacity(0.8)))
                VStack(alignment: .leading, spacing: 2) {
                    title
                    if !subtitle.isEmpty { Text(subtitle).font(Theme.F.caption).foregroundStyle(subtitleTone).lineLimit(1).truncationMode(.middle) }
                }.opacity(dimmed ? 0.6 : 1)
                Spacer(minLength: 6)
                actions
                if !hasDetail { Color.clear.frame(width: 22, height: 24) }       // keeps the action columns aligned across rows
                if hasDetail {
                    Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                        Image(systemName: "chevron.right").font(Theme.F.glyph).rotationEffect(.degrees(open ? 90 : 0)).frame(width: 22, height: 24).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Theme.C.textFaint).help(open ? T("Ascunde detaliile") : T("Arată detaliile")).accessibilityLabel(open ? T("Ascunde detaliile") : T("Arată detaliile"))
                }
                if let e = enabled {
                    Toggle("", isOn: e).toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(toggleLocked)
                        .help(e.wrappedValue ? T("Activă: se înregistrează") : T("Inactivă: nu se înregistrează")).accessibilityLabel(T("Activează sursa"))
                }
            }.padding(.horizontal, 12).frame(minHeight: 48)
            if open && hasDetail {
                detail.padding(.leading, 50).padding(.trailing, 12).padding(.bottom, 10).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { HairlineDivider().opacity(0.55) }
    }
}

/// Source name as a quiet menu: reads as text, opens the list of what is available. With `onHover` the list is a popover whose rows report the
/// pointer (id while over a row, nil when it leaves), so the app can show which monitor/window a row is before it is chosen.
struct SourceMenu: View {
    let title: String
    var placeholder = false
    var items: [(id: String, title: String, checked: Bool)]
    var disabled = false
    var onHover: ((String?) -> Void)? = nil
    let onPick: (String) -> Void
    @State private var open = false
    private var label: some View {
        HStack(spacing: 4) {
            Text(title).font(Theme.F.body.weight(.medium)).foregroundStyle(placeholder ? Theme.C.textDim : Theme.C.text).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.up.chevron.down").font(Theme.F.glyph).foregroundStyle(Theme.C.textFaint)
        }
    }
    var body: some View {
        if let onHover {
            Button { open.toggle() } label: { label }.buttonStyle(.plain).fixedSize().disabled(disabled).accessibilityLabel(title)
                .popover(isPresented: $open, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(items, id: \.id) { it in
                            Button { open = false; onHover(nil); onPick(it.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark").font(Theme.F.glyph).opacity(it.checked ? 1 : 0).frame(width: 12)
                                    Text(it.title).font(Theme.F.body).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                            }.buttonStyle(.plain).onHover { inside in onHover(inside ? it.id : nil) }
                                .accessibilityLabel(it.title).accessibilityValue(it.checked ? T("aleasă") : "")
                        }
                    }.padding(4).frame(minWidth: 220, maxWidth: 420)
                        .onDisappear { onHover(nil) }
                }
        } else {
            Menu {
                ForEach(items, id: \.id) { it in
                    Button { onPick(it.id) } label: { if it.checked { Label(it.title, systemImage: "checkmark") } else { Text(it.title) } }
                }
            } label: { label }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().disabled(disabled).accessibilityLabel(title)
        }
    }
}

/// Empty state: one short line, no paragraph.
struct EmptyHint: View {
    let text: String
    var body: some View { Text(text).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11) }
}

/// A single, calm notice with its action (used for activation and permissions).
struct Notice: View {
    let symbol: String; let text: String; var tone: Color = Theme.C.warn; var action: String; let run: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(Theme.F.icon).foregroundStyle(tone)
            Text(text).font(Theme.F.body).foregroundStyle(Theme.C.text.opacity(0.92)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action, action: run).buttonStyle(.gloss(.secondary, compact: true))
        }.padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tone.opacity(0.28), lineWidth: 0.7))
    }
}

/// Per-row "more" menu: the rarely used actions (remove) stay out of the row.
struct RowMenu<Items: View>: View {
    @ViewBuilder var items: Items
    var body: some View {
        Menu { items } label: { Image(systemName: "ellipsis").font(Theme.F.icon).frame(width: 24, height: 24).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Theme.C.textDim).help(T("Mai multe")).accessibilityLabel(T("Mai multe"))
    }
}
