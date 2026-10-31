// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI

/// Minimal SVG path-data parser (M, L, C, Z absolute) for the logo outlines.
func pathFromSVG(_ d: String) -> Path {
    var p = Path(); let t = d.replacingOccurrences(of: "M", with: " M ").replacingOccurrences(of: "L", with: " L ").replacingOccurrences(of: "C", with: " C ").replacingOccurrences(of: "Z", with: " Z ").split(separator: " ").map(String.init)
    var i = 0
    func pt() -> CGPoint { defer { i += 2 }; return CGPoint(x: Double(t[i])!, y: Double(t[i + 1])!) }
    while i < t.count {
        let c = t[i]; i += 1
        switch c {
        case "M": p.move(to: pt())
        case "L": p.addLine(to: pt())
        case "C": let a = pt(), b = pt(), e = pt(); p.addCurve(to: e, control1: a, control2: b)
        case "Z": p.closeSubpath()
        default: break
        }
    }
    return p
}

/// The approved SADROG symbol, drawn from vector outlines; `small` is the optical variant for compact sizes.
struct LogoMark: View {
    var small = false
    var body: some View {
        let parts = small ? LogoData.small : LogoData.large
        let b = LogoData.bounds
        GeometryReader { g in
            let s = min(g.size.width / b.width, g.size.height / b.height)
            ZStack {
                ForEach(parts.indices, id: \.self) { i in
                    pathFromSVG(parts[i].d).fill(style: FillStyle(eoFill: parts[i].evenOdd))
                }
            }
            .frame(width: b.width, height: b.height, alignment: .topLeading)
            .offset(x: -b.minX, y: -b.minY)
            .frame(width: b.width, height: b.height, alignment: .topLeading)
            .scaleEffect(s, anchor: .topLeading)
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .aspectRatio(b.width / b.height, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
