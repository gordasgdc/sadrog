// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// One grouped list of sources: every kind (screen, window, camera, audio) shares the same row anatomy, separated by hairlines.
struct SourceList<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 14) { content }
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
            Text(title).font(CM.title).foregroundStyle(placeholder ? Theme.C.textDim : Theme.C.text).lineLimit(1).truncationMode(.tail)
            Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.C.textDim)
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
        Menu { items } label: { Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Theme.C.textDim).help(T("Mai multe")).accessibilityLabel(T("Mai multe"))
    }
}
