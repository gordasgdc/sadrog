// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
// App icon from the approved vector mark (LogoData): the mark in light graphite on a macOS-shaped graphite tile with a soft top light.
// Usage: MakeIcon <out.png> (1024×1024). The build turns it into AppIcon.icns with sips + iconutil.
import AppKit
import SwiftUI

@MainActor func render() -> NSImage? {
    let view = ZStack {
        RoundedRectangle(cornerRadius: 1024 * 0.2237, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.21, blue: 0.23), Color(red: 0.10, green: 0.105, blue: 0.115)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 1024 * 0.2237, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.03)], startPoint: .top, endPoint: .bottom), lineWidth: 6))
            .frame(width: 824, height: 824)
        LogoMark().foregroundStyle(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.78)], startPoint: .top, endPoint: .bottom))
            .frame(width: 560, height: 318)
    }.frame(width: 1024, height: 1024)
    let r = ImageRenderer(content: view); r.scale = 1
    return r.nsImage
}
let out = CommandLine.arguments[1]
MainActor.assumeIsolated {
    guard let img = render(), let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: out))
}
