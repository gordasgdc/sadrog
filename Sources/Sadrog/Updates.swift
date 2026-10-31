// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AppKit
import SwiftUI
import SadrogCore

/// Updates: a quiet check at launch (a found version → one pop-up per version + the sidebar line; a failure only in the log) and a manual
/// check with three distinct results (new version / up to date / could not check + reason). „Actualizează acum” never opens a browser.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()
    enum Status: Equatable { case idle, checking, upToDate, available(UpdateManifest), failed(String) }
    @Published private(set) var status: Status = .idle
    private let dismissedKey = "sadrog.dismissedUpdateVersion"
    private let log = DiagnosticLog("update")

    func checkAtLaunch() {
        Task {
            switch await fetch() {
            case .failure(let e): log.warning("Verificarea actualizărilor a eșuat: \(e.localizedDescription)"); status = .idle
            case .success(let m):
                guard m.isNewer(than: AppInfo.version) else { log.info("La zi: publicat \(m.version), instalat \(AppInfo.version)"); status = .idle; return }
                status = .available(m)
                if m.mandatory || UserDefaults.standard.string(forKey: dismissedKey) != m.version { present(m) }
            }
        }
    }

    func checkManually() {
        guard status != .checking else { return }
        Task {
            switch await fetch() {
            case .failure(let e):
                log.warning("Verificare manuală eșuată: \(e.localizedDescription)")
                status = .failed(e.localizedDescription)
                alert(T("Nu am putut verifica actualizările"), e.localizedDescription + "\n\n" + T("Verifică conexiunea la internet și încearcă din nou."))
            case .success(let m):
                if m.isNewer(than: AppInfo.version) { status = .available(m); present(m) }
                else { status = .upToDate; alert(T("Ești la zi"), L10n.f("Rulezi cea mai recentă versiune (%@).", AppInfo.version)) }
            }
        }
    }

    func present(_ m: UpdateManifest) {
        let a = NSAlert()
        a.messageText = L10n.f("Versiune nouă disponibilă: %@", m.version)
        let notes = m.notes(); a.informativeText = (notes.isEmpty ? "" : notes + "\n\n") + L10n.f("Instalată: %@. „Actualizează acum” descarcă, verifică și instalează versiunea nouă, apoi repornește SADROG. Proiectele și înregistrările nu se ating.", AppInfo.version)
        a.addButton(withTitle: T("Actualizează acum"))
        if !m.mandatory { a.addButton(withTitle: T("Mai târziu")) }
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { Task { await SelfUpdater.install(m) } }
        else if !m.mandatory { UserDefaults.standard.set(m.version, forKey: dismissedKey); log.info("Actualizarea \(m.version) amânată") }
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text; a.addButton(withTitle: "OK"); NSApp.activate(); a.runModal()
    }

    private func fetch() async -> Result<UpdateManifest, Error> {
        status = .checking
        var c = URLComponents(url: UpdateManifest.url, resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var r = URLRequest(url: c.url!); r.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData; r.timeoutInterval = 15
        do {
            let (data, resp) = try await URLSession.shared.data(for: r)
            if let h = resp as? HTTPURLResponse, !(200...299).contains(h.statusCode) { return .failure(SelfUpdater.Failure(L10n.f("Serverul a răspuns cu status %d.", h.statusCode))) }
            do { return .success(try JSONDecoder().decode(UpdateManifest.self, from: data)) }
            catch { return .failure(SelfUpdater.Failure(T("Răspunsul serverului nu este un update.json valid."))) }
        } catch { return .failure(error) }
    }
}

/// Real self-update: downloads the versioned DMG, checks size + SHA-256 against the manifest, mounts it, checks the app inside
/// (bundle ID, version = manifest, codesign strict, Developer ID with the GDC Team ID), replaces the installed app (native administrator
/// prompt only when its folder is not writable) and relaunches after this process exits.
@MainActor
enum SelfUpdater {
    struct Failure: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }
    nonisolated static let teamID = "8AR6XP8MG7"
    private static let log = DiagnosticLog("update")

    static func install(_ m: UpdateManifest) async {
        let progress = UpdateProgressWindow()
        progress.show(L10n.f("Se descarcă SADROG %@…", m.version))
        do {
            let dmg = try await download(m)
            progress.update(T("Se verifică versiunea nouă…"))
            let staged = try await Task.detached { try stage(dmg: dmg, version: m.version) }.value
            progress.update(T("Se instalează…"))
            let target = installedLocation()
            try await Task.detached { try replace(target, with: staged) }.value
            log.info("Actualizare instalată: \(m.version) în \(target.path); repornire")
            progress.update(T("Gata. SADROG repornește…"))
            relaunchAfterExit(target)
            NSApp.terminate(nil)
        } catch {
            progress.close()
            log.error("Actualizare eșuată (\(m.version)): \(error.localizedDescription)")
            let a = NSAlert(); a.alertStyle = .warning; a.messageText = T("Actualizarea nu s-a putut instala")
            a.informativeText = error.localizedDescription + "\n\n" + T("Versiunea instalată a rămas neschimbată."); a.addButton(withTitle: "OK"); a.runModal()
        }
    }

    private static func download(_ m: UpdateManifest) async throws -> URL {
        let (tmp, resp) = try await URLSession.shared.download(from: m.downloadURL)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 { throw Failure(L10n.f("Serverul a răspuns cu status %d.", h.statusCode)) }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("SADROG/Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("SADROG-\(m.version).dmg")
        try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: tmp, to: dest)
        if let s = m.size, let real = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64), real != s {
            throw Failure(T("Fișierul descărcat nu are mărimea anunțată."))
        }
        guard try UpdateManifest.sha256(of: dest) == m.sha256 else { try? FileManager.default.removeItem(at: dest); throw Failure(T("Fișierul descărcat nu corespunde amprentei SHA-256 anunțate.")) }
        log.info("Descărcat și verificat \(dest.lastPathComponent)")
        return dest
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else { throw Failure("\((tool as NSString).lastPathComponent): \(out.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return out
    }

    nonisolated private static func stage(dmg: URL, version: String) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("SADROG-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"]) }
        let apps = (try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil)) ?? []
        guard let app = apps.first(where: { $0.pathExtension == "app" && (NSDictionary(contentsOf: $0.appendingPathComponent("Contents/Info.plist"))?["CFBundleIdentifier"] as? String) == AppInfo.bundleID }),
              let found = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String else {
            throw Failure(T("Imaginea descărcată nu conține SADROG."))
        }
        guard found == version else { throw Failure(L10n.f("Imaginea descărcată conține %@, nu %@.", found, version)) }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let details = try run("/usr/bin/codesign", ["-dvv", app.path])
        guard details.contains("TeamIdentifier=\(teamID)"), details.contains("Authority=Developer ID Application") else { throw Failure(T("Semnătura versiunii noi nu este a GDC.")) }
        let staged = dmg.deletingLastPathComponent().appendingPathComponent("SADROG \(version).app")
        try? FileManager.default.removeItem(at: staged)
        try run("/usr/bin/ditto", [app.path, staged.path])
        return staged
    }

    private static func installedLocation() -> URL {
        let cur = Bundle.main.bundleURL
        if cur.path.contains("/AppTranslocation/") { return URL(fileURLWithPath: "/Applications/SADROG.app") }
        return cur.deletingLastPathComponent().appendingPathComponent("SADROG.app")
    }

    nonisolated private static func replace(_ target: URL, with staged: URL) throws {
        let fm = FileManager.default, parent = target.deletingLastPathComponent()
        if fm.isWritableFile(atPath: parent.path), !fm.fileExists(atPath: target.path) || fm.isWritableFile(atPath: target.path) {
            let old = parent.appendingPathComponent(".\(target.lastPathComponent).old")
            try? fm.removeItem(at: old)
            if fm.fileExists(atPath: target.path) { try fm.moveItem(at: target, to: old) }
            do { try fm.moveItem(at: staged, to: target) } catch { if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: target) }; throw error }
            try? fm.removeItem(at: old); return
        }
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let cmd = "/bin/rm -rf \(q(target.path)).old; if [ -e \(q(target.path)) ]; then /bin/mv \(q(target.path)) \(q(target.path)).old; fi; "
            + "/usr/bin/ditto \(q(staged.path)) \(q(target.path)) && /bin/rm -rf \(q(target.path)).old "
            + "|| { [ -e \(q(target.path)).old ] && /bin/mv \(q(target.path)).old \(q(target.path)); exit 1; }"
        let esc = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        try run("/usr/bin/osascript", ["-e", "do shell script \"\(esc)\" with administrator privileges"])
        try? fm.removeItem(at: staged)
    }

    private static func relaunchAfterExit(_ app: URL) {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
        try? p.run()
    }
}

/// Minimal progress window, so the app never looks frozen during an update.
@MainActor
final class UpdateProgressWindow {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90), styleMask: [.titled], backing: .buffered, defer: false)
    private let label = NSTextField(labelWithString: "")
    init() {
        panel.title = "SADROG"
        let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.startAnimation(nil)
        label.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [spinner, label]); stack.spacing = 14; stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = stack
    }
    func show(_ t: String) { label.stringValue = t; panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate() }
    func update(_ t: String) { label.stringValue = t }
    func close() { panel.orderOut(nil) }
}
