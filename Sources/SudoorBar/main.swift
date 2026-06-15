// island-menubar.swift — IslandBar menu bar agent (monochrome rocket).
//
// Shows a 🚀 in the menu bar with a blinking dot when a terminal is waiting on
// a permission prompt, a live "Requesting now" list, recent history, a handled
// counter, a "Show requesting terminal" toggle, and "Start at login".
//
// State lives in ~/.island/config.json (atomic, flock-protected so the hook
// and this app never corrupt it). Built into IslandBar.app — see build-app.sh.

import AppKit
import ServiceManagement
import Darwin

struct Req  { let term: String; let project: String; let tool: String; let detail: String; let time: Double }
struct Hist { let term: String; let project: String; let tool: String; let outcome: String; let time: Double }

final class MenuBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    let islandPath  = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("island-prompt").path ?? ("~/IslandPrompt/island-prompt" as NSString).expandingTildeInPath
    let islandDir   = ("~/.island" as NSString).expandingTildeInPath
    let pendingDir  = ("~/.island/pending" as NSString).expandingTildeInPath
    let historyFile = ("~/.island/history.jsonl" as NSString).expandingTildeInPath
    let configFile  = ("~/.island/config.json" as NSString).expandingTildeInPath
    let lockFile    = ("~/.island/.state.lock" as NSString).expandingTildeInPath
    var blinkOn = false

    // MARK: - Atomic config (shared with the hook)
    func readConfig() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: configFile),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }

    func updateConfig(_ mutate: (inout [String: Any]) -> Void) {
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        let fd = open(lockFile, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var cfg = readConfig()
        mutate(&cfg)
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys]) {
            let tmp = configFile + ".tmp"
            if (try? d.write(to: URL(fileURLWithPath: tmp))) != nil {
                rename(tmp, configFile)   // atomic replace
            }
        }
    }

    var showTerminals: Bool {
        get { (readConfig()["showTerminal"] as? Bool) ?? true }
        set { updateConfig { $0["showTerminal"] = newValue } }
    }
    func readCount() -> Int { (readConfig()["count"] as? NSNumber)?.intValue ?? 0 }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        // Default the toggle on first run.
        if readConfig()["showTerminal"] == nil { updateConfig { $0["showTerminal"] = true } }
        // Persist across reboots via the modern login-item API.
        if #available(macOS 13.0, *), SMAppService.mainApp.status != .enabled {
            try? SMAppService.mainApp.register()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.rocketTemplate()
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.toolTip = "sudoor — Stop babysitting the terminal."
        }
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        updateStatus()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    // MARK: - Data
    func pendingRequests() -> [Req] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: pendingDir) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Req] = []
        for f in files where f.hasSuffix(".json") {
            let path = pendingDir + "/" + f
            guard let data = fm.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let t = (o["time"] as? NSNumber)?.doubleValue ?? 0
            if now - t > 300 { try? fm.removeItem(atPath: path); continue }
            out.append(Req(term: o["term"] as? String ?? "Terminal",
                           project: o["project"] as? String ?? "",
                           tool: o["tool"] as? String ?? "",
                           detail: o["detail"] as? String ?? "",
                           time: t))
        }
        return out.sorted { $0.time < $1.time }
    }

    func recentHistory(_ limit: Int = 5) -> [Hist] {
        guard let s = try? String(contentsOfFile: historyFile, encoding: .utf8) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Hist] = []
        for line in s.split(separator: "\n").suffix(limit).reversed() {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let t = (o["time"] as? NSNumber)?.doubleValue ?? 0
            if now - t > 86400 { continue }
            out.append(Hist(term: o["term"] as? String ?? "Terminal",
                            project: o["project"] as? String ?? "",
                            tool: o["tool"] as? String ?? "",
                            outcome: o["outcome"] as? String ?? "",
                            time: t))
        }
        return out
    }

    func ago(_ t: Double) -> String {
        let s = Int(Date().timeIntervalSince1970 - t)
        if s < 60 { return "\(max(s,0))s ago" }
        if s < 3600 { return "\(s/60)m ago" }
        return "\(s/3600)h ago"
    }

    // MARK: - Menu
    func rebuildMenu() {
        menu.removeAllItems()

        let test = NSMenuItem(title: "Test sudoor prompt", action: #selector(testIsland), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())

        if showTerminals {
            let reqs = pendingRequests()
            let header = NSMenuItem(title: reqs.isEmpty ? "No terminals requesting" : "Requesting now:",
                                    action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in reqs {
                var label = "   \(r.term) · \(r.project) — \(r.tool)"
                if !r.detail.isEmpty { label += ": \(r.detail)" }
                if label.count > 64 { label = String(label.prefix(63)) + "…" }
                let it = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
            }
            let recent = recentHistory()
            if !recent.isEmpty {
                menu.addItem(.separator())
                let rh = NSMenuItem(title: "Recent:", action: nil, keyEquivalent: "")
                rh.isEnabled = false
                menu.addItem(rh)
                for h in recent {
                    let mark = h.outcome == "approved" ? "✓" : h.outcome == "denied" ? "✕" : "·"
                    var label = "   \(mark) \(h.term) · \(h.project) — \(h.tool)  (\(ago(h.time)))"
                    if label.count > 70 { label = String(label.prefix(69)) + "…" }
                    let it = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                    it.isEnabled = false
                    menu.addItem(it)
                }
            }
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Show requesting terminal", action: #selector(toggleShow), keyEquivalent: "")
        toggle.target = self
        toggle.state = showTerminals ? .on : .off
        menu.addItem(toggle)

        let login = NSMenuItem(title: "Start at login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let counter = NSMenuItem(title: "Permissions handled: \(readCount())", action: nil, keyEquivalent: "")
        counter.isEnabled = false
        menu.addItem(counter)

        let status = NSMenuItem(title: hookInstalled() ? "Hook: installed ✓" : "Hook: not installed",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func updateStatus() {
        guard let button = statusItem.button else { return }
        let n = showTerminals ? pendingRequests().count : 0
        let handled = readCount()
        var s = ""
        if n > 0 { blinkOn.toggle(); s += blinkOn ? " ●" : " ○" } else { blinkOn = false }
        if handled > 0 { s += " \(handled)" }
        button.attributedTitle = NSAttributedString(
            string: s,
            attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium),
                         .foregroundColor: NSColor.labelColor])
        button.toolTip = n > 0
            ? "sudoor — \(n) requesting · \(handled) handled"
            : "sudoor — \(handled) handled"
    }

    func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    func hookInstalled() -> Bool {
        let settings = ("~/.claude/settings.json" as NSString).expandingTildeInPath
        guard let s = try? String(contentsOfFile: settings, encoding: .utf8) else { return false }
        return s.contains("claude-permission-hook.sh")
    }

    static func rocketTemplate() -> NSImage {
        // Bundled alien mark, rendered as a template (tints to the menu bar).
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let img = NSImage(contentsOf: url), img.size.height > 0 {
            let h: CGFloat = 18
            img.size = NSSize(width: (h * img.size.width / img.size.height).rounded(), height: h)
            img.isTemplate = true
            return img
        }
        // Fallback: 🚀 emoji silhouette.
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        let glyph = "🚀" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        let g = glyph.size(withAttributes: attrs)
        glyph.draw(at: NSPoint(x: (size.width - g.width) / 2, y: (size.height - g.height) / 2), withAttributes: attrs)
        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: - Actions
    @objc func toggleShow() { showTerminals.toggle(); rebuildMenu() }

    @objc func toggleLogin() {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
                else { try SMAppService.mainApp.register() }
            } catch { NSLog("IslandBar login toggle error: \(error)") }
        }
        rebuildMenu()
    }

    @objc func testIsland() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: islandPath)
        p.arguments = ["Terminal · demo — Bash: rm -rf /tmp/build  (test)", "--timeout", "20"]
        try? p.run()
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = MenuBarDelegate()
app.delegate = delegate
app.run()
