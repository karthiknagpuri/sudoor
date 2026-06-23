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
import WebKit
import SudoorCore

struct Req  { let term: String; let project: String; let cwd: String; let tool: String; let detail: String; let risk: String; let time: Double }
struct Hist { let agent: String; let term: String; let project: String; let cwd: String; let tool: String; let detail: String; let outcome: String; let risk: String; let ruleId: String; let gitBase: String; let time: Double }
struct DailyStats { let handled: Int; let denied: Int; let auto: Int; let critical: Int }
struct Workspace { let name: String; let path: String; let lastSeen: Double }
struct Bookmark { let name: String; let url: String }

// A single bookmark icon in the horizontal strip. Clicking opens it; hovering
// reveals a red minus badge (top-right) to remove it.
final class BookmarkCell: NSView {
    private let onOpen: () -> Void
    private let onRemove: () -> Void
    private let removable: Bool
    private let removeButton = NSButton()

    init(frame: NSRect, icon: NSImage?, name: String, removable: Bool = true,
         onOpen: @escaping () -> Void, onRemove: @escaping () -> Void = {}) {
        self.onOpen = onOpen
        self.onRemove = onRemove
        self.removable = removable
        super.init(frame: frame)

        let iconButton = NSButton(frame: bounds)
        iconButton.isBordered = false
        iconButton.bezelStyle = .shadowlessSquare
        iconButton.imageScaling = .scaleProportionallyDown
        iconButton.image = icon
        iconButton.toolTip = name
        iconButton.target = self
        iconButton.action = #selector(openTapped)
        iconButton.autoresizingMask = [.width, .height]
        addSubview(iconButton)

        guard removable else { return }   // the "+" add cell has no remove badge
        let d: CGFloat = 15
        removeButton.frame = NSRect(x: bounds.maxX - d, y: bounds.maxY - d, width: d, height: d)
        removeButton.isBordered = false
        removeButton.bezelStyle = .shadowlessSquare
        removeButton.image = BookmarkCell.minusBadge(d)
        removeButton.toolTip = "Remove \(name)"
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.isHidden = true
        addSubview(removeButton)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setRemoveVisible(_ visible: Bool) {
        guard removable else { return }
        if removeButton.isHidden == visible { removeButton.isHidden = !visible }
    }

    @objc private func openTapped() { onOpen() }
    @objc private func removeTapped() { onRemove() }

    private static func minusBadge(_ d: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: d, height: d))
        img.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: d, height: d)).fill()
        let bar = NSBezierPath()
        bar.lineWidth = 1.6
        bar.move(to: NSPoint(x: d * 0.28, y: d * 0.5))
        bar.line(to: NSPoint(x: d * 0.72, y: d * 0.5))
        NSColor.white.setStroke()
        bar.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}

// Horizontal container for bookmark cells. Polls the mouse while the menu is open
// to toggle each cell's remove badge — NSTrackingArea events don't fire during a
// menu's event-tracking run-loop mode, so a .common-mode timer is used instead.
final class BookmarkBarView: NSView {
    var cells: [BookmarkCell] = []
    private var timer: Timer?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pollHover() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    private func pollHover() {
        guard let window = window else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        for cell in cells { cell.setRemoveVisible(cell.frame.contains(local)) }
    }

    deinit { timer?.invalidate() }
}
struct ReviewRow { let oldNumber: Int?; let newNumber: Int?; let oldText: String?; let newText: String?; let kind: String }
struct ReviewHunk { let header: String; let rows: [ReviewRow] }
struct ReviewFile { let path: String; let additions: Int; let deletions: Int; let hunks: [ReviewHunk] }

final class MenuDashboardView: NSView {
    private let width: CGFloat = 320
    private let height: CGFloat = 78

    init(threat: String, agentStatus: String, stats: DailyStats, queueCount: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        let title = label("Sudoor", size: 18, weight: .bold, color: .labelColor)
        title.frame = NSRect(x: 14, y: 48, width: 120, height: 22)
        addSubview(title)

        let pill = pillLabel(threat, color: color(forThreat: threat), foreground: .labelColor)
        pill.frame = NSRect(x: width - 88, y: 49, width: 74, height: 20)
        addSubview(pill)

        let subtitle = label("Agent approval control", size: 11, weight: .semibold, color: .secondaryLabelColor)
        subtitle.frame = NSRect(x: 14, y: 30, width: 170, height: 15)
        addSubview(subtitle)

        let queue = queueCount == 0 ? "Queue clear" : "\(queueCount) pending"
        let status = label("\(agentStatus)  |  \(queue)", size: 10, weight: .medium, color: .secondaryLabelColor)
        status.alignment = .right
        status.frame = NSRect(x: 150, y: 31, width: 156, height: 14)
        addSubview(status)

        let summary = label("\(stats.handled) handled today  |  \(stats.denied) denied  |  \(stats.auto) policy", size: 11, weight: .medium, color: .labelColor)
        summary.frame = NSRect(x: 14, y: 10, width: 292, height: 15)
        addSubview(summary)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 6), xRadius: 9, yRadius: 9)
        NSColor.controlBackgroundColor.withAlphaComponent(0.32).setFill()
        bg.fill()
        NSColor.separatorColor.withAlphaComponent(0.28).setStroke()
        bg.lineWidth = 1
        bg.stroke()
    }

    private func color(forThreat threat: String) -> NSColor {
        switch threat {
        case "Critical", "High Risk": return .systemRed.withAlphaComponent(0.18)
        case "Watching": return .systemOrange.withAlphaComponent(0.18)
        default: return .quaternaryLabelColor
        }
    }
}

final class MenuActivityView: NSView {
    init(title: String, subtitle: String, badge: String, badgeColor: NSColor, time: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 32))
        wantsLayer = true

        let badgeView = pillLabel(badge, color: badgeColor, foreground: .labelColor)
        badgeView.frame = NSRect(x: 14, y: 8, width: 42, height: 18)
        addSubview(badgeView)

        let titleLabel = label(title, size: 12, weight: .semibold, color: .labelColor)
        titleLabel.frame = NSRect(x: 68, y: 16, width: 168, height: 14)
        addSubview(titleLabel)

        let subtitleLabel = label(subtitle, size: 10, weight: .medium, color: .secondaryLabelColor)
        subtitleLabel.frame = NSRect(x: 68, y: 3, width: 182, height: 12)
        addSubview(subtitleLabel)

        let timeLabel = label(time, size: 10, weight: .semibold, color: .secondaryLabelColor)
        timeLabel.alignment = .right
        timeLabel.frame = NSRect(x: 252, y: 9, width: 54, height: 14)
        addSubview(timeLabel)
    }

    required init?(coder: NSCoder) { nil }
}

final class MenuSectionView: NSView {
    init(_ title: String, detail: String? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        let titleLabel = label(title, size: 12, weight: .bold, color: .labelColor)
        titleLabel.frame = NSRect(x: 14, y: 4, width: 180, height: 16)
        addSubview(titleLabel)
        if let detail {
            let detailLabel = label(detail, size: 11, weight: .semibold, color: .secondaryLabelColor)
            detailLabel.alignment = .right
            detailLabel.frame = NSRect(x: 200, y: 4, width: 106, height: 16)
            addSubview(detailLabel)
        }
    }

    required init?(coder: NSCoder) { nil }
}

func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
    let field = NSTextField(labelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    return field
}

func pillLabel(_ text: String, color: NSColor, foreground: NSColor) -> NSTextField {
    let field = label(text, size: 9, weight: .bold, color: foreground)
    field.alignment = .center
    field.wantsLayer = true
    field.layer?.cornerRadius = 6
    field.layer?.backgroundColor = color.cgColor
    return field
}

/// Extracts the <title> of each <entry> from an arXiv Atom feed (skips the
/// feed-level title, which is the query echo, not a paper).
final class ArxivTitleParser: NSObject, XMLParserDelegate {
    private(set) var titles: [String] = []
    private var inEntry = false, inTitle = false, buf = ""
    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName q: String?, attributes: [String: String]) {
        if el == "entry" { inEntry = true }
        else if el == "title", inEntry { inTitle = true; buf = "" }
    }
    func parser(_ p: XMLParser, foundCharacters s: String) { if inTitle { buf += s } }
    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName q: String?) {
        if el == "title", inTitle {
            let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if !t.isEmpty { titles.append(t) }
            inTitle = false
        } else if el == "entry" { inEntry = false }
    }
}

/// Minimal SVG path data → NSBezierPath. Supports M/m L/l H/h V/v C/c A/a Z/z —
/// enough to render bundled-free vector glyphs (e.g. the GitHub octocat mark).
final class SVGPathParser {
    private let t: [Character]; private var i = 0
    private var cur = NSPoint.zero; private var start = NSPoint.zero
    private let path = NSBezierPath()
    init(_ d: String) { t = Array(d) }

    private func skipSep() { while i < t.count, " ,\n\t".contains(t[i]) { i += 1 } }
    private func num() -> CGFloat {
        skipSep(); var s = ""
        if i < t.count, t[i] == "-" || t[i] == "+" { s.append(t[i]); i += 1 }
        var dot = false
        while i < t.count {
            let c = t[i]
            if c.isNumber { s.append(c); i += 1 }
            else if c == "." && !dot { dot = true; s.append(c); i += 1 }
            else { break }
        }
        return CGFloat(Double(s) ?? 0)
    }
    private func flag() -> Bool { skipSep(); let f = i < t.count && t[i] == "1"; if i < t.count { i += 1 }; return f }

    func build() -> NSBezierPath {
        var cmd: Character = " "
        while i < t.count {
            skipSep(); if i >= t.count { break }
            if t[i].isLetter { cmd = t[i]; i += 1 }
            switch cmd {
            case "M": cur = NSPoint(x: num(), y: num()); path.move(to: cur); start = cur; cmd = "L"
            case "m": cur = NSPoint(x: cur.x + num(), y: cur.y + num()); path.move(to: cur); start = cur; cmd = "l"
            case "L": cur = NSPoint(x: num(), y: num()); path.line(to: cur)
            case "l": cur = NSPoint(x: cur.x + num(), y: cur.y + num()); path.line(to: cur)
            case "H": cur = NSPoint(x: num(), y: cur.y); path.line(to: cur)
            case "h": cur = NSPoint(x: cur.x + num(), y: cur.y); path.line(to: cur)
            case "V": cur = NSPoint(x: cur.x, y: num()); path.line(to: cur)
            case "v": cur = NSPoint(x: cur.x, y: cur.y + num()); path.line(to: cur)
            case "C":
                let c1 = NSPoint(x: num(), y: num()), c2 = NSPoint(x: num(), y: num())
                cur = NSPoint(x: num(), y: num()); path.curve(to: cur, controlPoint1: c1, controlPoint2: c2)
            case "c":
                let c1 = NSPoint(x: cur.x + num(), y: cur.y + num()), c2 = NSPoint(x: cur.x + num(), y: cur.y + num())
                let e = NSPoint(x: cur.x + num(), y: cur.y + num()); path.curve(to: e, controlPoint1: c1, controlPoint2: c2); cur = e
            case "A", "a":
                let rx = num(), ry = num(); _ = num(); let large = flag(), sweep = flag()
                let end = cmd == "A" ? NSPoint(x: num(), y: num()) : NSPoint(x: cur.x + num(), y: cur.y + num())
                arc(to: end, rx: rx, ry: ry, large: large, sweep: sweep); cur = end
            case "Z", "z": path.close(); cur = start
            default: i += 1
            }
        }
        return path
    }

    // Endpoint-parameterized arc → small line segments (ample at icon scale).
    private func arc(to end: NSPoint, rx: CGFloat, ry: CGFloat, large: Bool, sweep: Bool) {
        guard rx > 0, ry > 0 else { path.line(to: end); return }
        let x1 = cur.x, y1 = cur.y
        let px = (x1 - end.x) / 2, py = (y1 - end.y) / 2
        var rxa = abs(rx), rya = abs(ry)
        let l = (px*px)/(rxa*rxa) + (py*py)/(rya*rya)
        if l > 1 { let s = sqrt(l); rxa *= s; rya *= s }
        let sign: CGFloat = (large != sweep) ? 1 : -1
        let numr = max(0, rxa*rxa*rya*rya - rxa*rxa*py*py - rya*rya*px*px)
        let den = rxa*rxa*py*py + rya*rya*px*px
        let co = sign * sqrt(numr / max(den, 1e-9))
        let cxp = co * rxa * py / rya, cyp = -co * rya * px / rxa
        let cx = cxp + (x1 + end.x)/2, cy = cyp + (y1 + end.y)/2
        func ang(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dd = sqrt((ux*ux+uy*uy)*(vx*vx+vy*vy))
            var a = acos(max(-1, min(1, (ux*vx+uy*vy)/dd)))
            if ux*vy - uy*vx < 0 { a = -a }; return a
        }
        let theta1 = ang(1, 0, (px-cxp)/rxa, (py-cyp)/rya)
        var dtheta = ang((px-cxp)/rxa, (py-cyp)/rya, (-px-cxp)/rxa, (-py-cyp)/rya)
        if !sweep && dtheta > 0 { dtheta -= 2 * .pi }
        if sweep && dtheta < 0 { dtheta += 2 * .pi }
        let steps = max(8, Int(abs(dtheta) / (.pi/16)))
        for s in 1...steps {
            let th = theta1 + dtheta * CGFloat(s)/CGFloat(steps)
            path.line(to: NSPoint(x: cx + rxa*cos(th), y: cy + rya*sin(th)))
        }
    }
}

/// The "Workspaces" menu row with inline quick-action buttons (＋ add, GitHub
/// clone) and a disclosure chevron beside the label. The native submenu (the
/// workspace list) still opens on hover. Polls `isHighlighted` to mirror the
/// system's blue selection, since tracking-area events don't fire in menu mode.
final class WorkspacesRowView: NSView {
    private let titleField = NSTextField(labelWithString: "Workspaces")
    private let folderView = NSImageView()
    private let chevron = NSImageView()
    private let addButton = NSButton()
    private let cloneButton = NSButton()
    private let onAdd: () -> Void
    private let onClone: () -> Void
    private var timer: Timer?
    private var highlighted = false

    init(width: CGFloat, folder: NSImage?, add: NSImage?, github: NSImage, chevron chevronImg: NSImage?,
         onAdd: @escaping () -> Void, onClone: @escaping () -> Void) {
        self.onAdd = onAdd; self.onClone = onClone
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))

        folderView.image = folder
        folderView.imageScaling = .scaleProportionallyDown
        folderView.frame = NSRect(x: 14, y: 5, width: 16, height: 16)
        addSubview(folderView)

        titleField.font = .systemFont(ofSize: 14, weight: .regular)
        titleField.frame = NSRect(x: 36, y: 4, width: 150, height: 18)
        addSubview(titleField)

        chevron.image = chevronImg
        chevron.imageScaling = .scaleProportionallyDown
        chevron.frame = NSRect(x: width - 22, y: 6, width: 12, height: 14)
        addSubview(chevron)

        configure(cloneButton, image: github, x: width - 24 - 28, action: #selector(cloneTapped), tip: "Clone Repository…")
        configure(addButton, image: add, x: width - 24 - 28 - 28, action: #selector(addTapped), tip: "Add Workspace…")
        applyColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func configure(_ b: NSButton, image: NSImage?, x: CGFloat, action: Selector, tip: String) {
        b.image = image; b.isBordered = false; b.bezelStyle = .shadowlessSquare
        b.imagePosition = .imageOnly; b.imageScaling = .scaleProportionallyDown
        b.frame = NSRect(x: x, y: 4, width: 20, height: 18)
        b.target = self; b.action = action; b.toolTip = tip
        addSubview(b)
    }

    @objc private func addTapped() { onAdd() }
    @objc private func cloneTapped() { onClone() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate(); timer = nil
        guard window != nil else { return }
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.refreshHighlight() }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }
    deinit { timer?.invalidate() }

    private func refreshHighlight() {
        let h = enclosingMenuItem?.isHighlighted ?? false
        if h != highlighted { highlighted = h; applyColors(); needsDisplay = true }
    }

    private func applyColors() {
        let fg: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        titleField.textColor = fg
        let dim: NSColor = highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        if #available(macOS 10.14, *) {
            folderView.contentTintColor = fg
            chevron.contentTintColor = highlighted ? .selectedMenuItemTextColor : .tertiaryLabelColor
            addButton.contentTintColor = dim
            cloneButton.contentTintColor = dim
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        super.draw(dirtyRect)
    }
}

final class MenuBarDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var timer: Timer?
    let islandPath  = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("island-prompt").path ?? ("~/IslandPrompt/island-prompt" as NSString).expandingTildeInPath
    let islandDir   = ("~/.island" as NSString).expandingTildeInPath
    let pendingDir  = ("~/.island/pending" as NSString).expandingTildeInPath
    let historyFile = ("~/.island/history.jsonl" as NSString).expandingTildeInPath
    let workspacesFile = ("~/.island/workspaces.json" as NSString).expandingTildeInPath
    let bookmarksFile  = ("~/.island/bookmarks.json" as NSString).expandingTildeInPath
    let bookmarkIconsDir = ("~/.island/bookmark-icons" as NSString).expandingTildeInPath
    var fetchingIcons = Set<String>()   // hosts with an in-flight favicon download
    let contributionsFile = ("~/.island/contributions.json" as NSString).expandingTildeInPath
    var fetchingContrib = false
    let twitterFile = ("~/.island/twitter.json" as NSString).expandingTildeInPath
    var fetchingTwitter = false
    let claudeSettingsFile = ("~/.claude/settings.json" as NSString).expandingTildeInPath
    var fetchingResearch = false
    let dinoBannerFile = ("~/.island/dino-banner.sh" as NSString).expandingTildeInPath
    let usageFile = ("~/.island/usage.json" as NSString).expandingTildeInPath
    var computingUsage = false
    let configFile  = ("~/.island/config.json" as NSString).expandingTildeInPath
    let lockFile    = ("~/.island/.state.lock" as NSString).expandingTildeInPath
    let policyFile  = ("~/.island/policy.json" as NSString).expandingTildeInPath
    var blinkOn = false
    var changesWindow: NSWindow?
    var animTimer: Timer?          // drives the menu bar dino's gentle bob
    var animPhase: CGFloat = 0
    var dinoBase: NSImage?         // cached base icon, redrawn each animation frame

    // MARK: - Atomic config (shared with the hook)
    func readConfigUnlocked() -> [String: Any] {
        guard let d = FileManager.default.contents(atPath: configFile),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }

    func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        let fd = open(lockFile, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        return try body()
    }

    func readConfig() -> [String: Any] {
        withStateLock { readConfigUnlocked() }
    }

    func writeAtomicData(at path: String, data: Data) {
        let tmp = path + ".tmp"
        if (try? data.write(to: URL(fileURLWithPath: tmp))) != nil {
            if FileManager.default.fileExists(atPath: path) {
                _ = try? FileManager.default.replaceItemAt(URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try? FileManager.default.moveItem(atPath: tmp, toPath: path)
            }
        }
    }

    func writeAtomicJSON(at path: String, object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        withStateLock { writeAtomicData(at: path, data: data) }
    }

    func updateConfig(_ mutate: (inout [String: Any]) -> Void) {
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        let fd = open(lockFile, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 { flock(fd, LOCK_EX) }
        defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
        var cfg = readConfigUnlocked()
        mutate(&cfg)
        if let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys]) {
            writeAtomicData(at: configFile, data: d)
        }
    }

    var showTerminals: Bool {
        get { (readConfig()["showTerminal"] as? Bool) ?? true }
        set { updateConfig { $0["showTerminal"] = newValue } }
    }
    var usageTipsEnabled: Bool {
        get { (readConfig()["usageTips"] as? Bool) ?? true }
        set { updateConfig { $0["usageTips"] = newValue } }
    }
    func readCount() -> Int { (readConfig()["count"] as? NSNumber)?.intValue ?? 0 }

    private static let twitterBearerAccount = "twitterBearer"

    func twitterBearerToken() -> String? {
        KeychainStore.load(account: Self.twitterBearerAccount)
    }

    /// Move legacy plaintext bearer tokens from config.json into the Keychain.
    func migrateTwitterBearerFromConfig() {
        updateConfig { cfg in
            guard let legacy = cfg["twitterBearer"] as? String, !legacy.isEmpty else { return }
            KeychainStore.save(legacy, account: Self.twitterBearerAccount)
            cfg.removeValue(forKey: "twitterBearer")
        }
    }

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        // Default the toggle on first run.
        if readConfig()["showTerminal"] == nil { updateConfig { $0["showTerminal"] = true } }
        migrateTwitterBearerFromConfig()

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
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.animateIcon()
        }
        refreshResearchTips()   // refresh arXiv spinner tips if keywords are set (6h throttle)
        syncSpinnerTips()       // push current per-project usage into Claude Code's spinner tips
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }

    // MARK: - Data
    func pendingRequests() -> [Req] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: pendingDir) else { return [] }
        let now = Date().timeIntervalSince1970
        var out: [Req] = []
        for f in files where f.hasSuffix(".json") && !f.contains("/") && f != ".." && !f.contains("..") {
            let path = (pendingDir as NSString).appendingPathComponent(f)
            guard let data = fm.contents(atPath: path),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let t = (o["time"] as? NSNumber)?.doubleValue ?? 0
            if now - t > 300 { try? fm.removeItem(atPath: path); continue }
            out.append(Req(term: o["term"] as? String ?? "Terminal",
                           project: o["project"] as? String ?? "",
                           cwd: o["cwd"] as? String ?? "",
                           tool: o["tool"] as? String ?? "",
                           detail: o["detail"] as? String ?? "",
                           risk: o["risk"] as? String ?? "low",
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
            out.append(Hist(agent: o["agent"] as? String ?? "claude-code",
                            term: o["term"] as? String ?? "Terminal",
                            project: o["project"] as? String ?? "",
                            cwd: o["cwd"] as? String ?? "",
                            tool: o["tool"] as? String ?? "",
                            detail: o["detail"] as? String ?? "",
                            outcome: o["outcome"] as? String ?? "",
                            risk: o["risk"] as? String ?? "low",
                            ruleId: o["ruleId"] as? String ?? "",
                            gitBase: o["gitBase"] as? String ?? "",
                            time: t))
        }
        return out
    }

    func workspaceRegistry() -> [Workspace] {
        guard let data = FileManager.default.contents(atPath: workspacesFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["workspaces"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let path = item["path"] as? String, !path.isEmpty else { return nil }
            let name = (item["name"] as? String) ?? URL(fileURLWithPath: path).lastPathComponent
            let lastSeen = (item["lastSeen"] as? NSNumber)?.doubleValue ?? 0
            return Workspace(name: name, path: path, lastSeen: lastSeen)
        }
    }

    func workspaces(reqs: [Req], history: [Hist]) -> [Workspace] {
        var byPath: [String: Workspace] = [:]
        for workspace in workspaceRegistry() {
            byPath[workspace.path] = workspace
        }
        for r in reqs where !r.cwd.isEmpty {
            byPath[r.cwd] = Workspace(name: r.project.isEmpty ? URL(fileURLWithPath: r.cwd).lastPathComponent : r.project, path: r.cwd, lastSeen: r.time)
        }
        for h in history where !h.cwd.isEmpty {
            let name = h.project.isEmpty ? URL(fileURLWithPath: h.cwd).lastPathComponent : h.project
            if let existing = byPath[h.cwd], existing.lastSeen >= h.time { continue }
            byPath[h.cwd] = Workspace(name: name, path: h.cwd, lastSeen: h.time)
        }
        return byPath.values
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    func todayStats() -> DailyStats {
        guard let s = try? String(contentsOfFile: historyFile, encoding: .utf8) else {
            return DailyStats(handled: readCount(), denied: 0, auto: 0, critical: 0)
        }
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var handled = 0, denied = 0, auto = 0, critical = 0
        for line in s.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            let t = (o["time"] as? NSNumber)?.doubleValue ?? 0
            guard t >= start else { continue }
            let outcome = o["outcome"] as? String ?? ""
            let risk = o["risk"] as? String ?? "low"
            if outcome != "deferred" { handled += 1 }
            if outcome.contains("denied") { denied += 1 }
            if outcome.hasPrefix("auto_") { auto += 1 }
            if risk == "critical" { critical += 1 }
        }
        return DailyStats(handled: handled, denied: denied, auto: auto, critical: critical)
    }

    func threatLevel(pending: [Req], stats: DailyStats) -> String {
        if pending.contains(where: { $0.risk == "critical" }) { return "Critical" }
        if pending.contains(where: { $0.risk == "high" }) || stats.critical > 0 { return "High Risk" }
        if !pending.isEmpty { return "Watching" }
        return "Quiet"
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

        let reqs = pendingRequests()
        let recent = recentHistory(12)
        let workspaceItems = workspaces(reqs: reqs, history: recent)

        let appTitle = disabledItem("Sudoor")
        appTitle.attributedTitle = NSAttributedString(
            string: "Sudoor",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        menu.addItem(appTitle)
        menu.addItem(.separator())

        // Workspaces — sits right under the header, above the usage meter.
        menu.addItem(workspacesMenuItem(workspaceItems: workspaceItems, recent: recent))
        menu.addItem(.separator())

        // Session usage — a gamified context meter plus cost / 5h / 7d spend,
        // computed from this session's Claude Code transcript.
        if let u = cachedUsage() {
            menu.addItem(customItem(contextMeter(pct: u.pct, ctx: u.ctx, win: u.win, runningSec: u.runningSec)))
            menu.addItem(disabledItem(u.costLine))

            // Per-project breakdown — context %, tokens, cost, and time per project.
            let projects = cachedProjects()
            if !projects.isEmpty {
                let projItem = NSMenuItem(title: "Per-Project Usage", action: nil, keyEquivalent: "")
                let projMenu = NSMenu()
                for p in projects {
                    let head = clipped("\(p.name) — \(p.pct)% · \(shortTokens(p.ctx))/\(shortTokens(p.win)) tokens", limit: 56)
                    projMenu.addItem(disabledItem(head))
                    projMenu.addItem(disabledItem("    session \(money(p.sessCost)) · 7d \(money(p.cost7d)) · \(fmtDuration(p.runningSec))"))
                }
                projItem.submenu = projMenu
                menu.addItem(projItem)
            }

            if Date().timeIntervalSince1970 - u.computedAt > 30 { computeUsage() }
        } else {
            computeUsage()
        }
        menu.addItem(.separator())

        // GitHub contributions — a compact heatmap right below the header.
        if let contrib = contributionsBar() {
            menu.addItem(customItem(contrib))
            menu.addItem(.separator())
        }

        // X (Twitter) followers — a small stat. Click to set/change the handle.
        let twItem = NSMenuItem(title: twitterDisplay() ?? "Set 𝕏 (Twitter) Handle…",
                                action: #selector(setTwitterHandle), keyEquivalent: "")
        twItem.target = self
        menu.addItem(twItem)
        menu.addItem(.separator())

        // Research Papers — manage keywords; recent arXiv papers feed Claude Code's
        // spinner tips (replacing the default news headlines).
        let researchItem = NSMenuItem(title: "Research Papers", action: nil, keyEquivalent: "")
        let researchMenu = NSMenu()
        let addKw = NSMenuItem(title: "Add Keyword…", action: #selector(addResearchKeyword), keyEquivalent: "")
        addKw.target = self
        researchMenu.addItem(addKw)
        let kws = researchKeywords()
        let refreshKw = NSMenuItem(title: "Refresh Now", action: #selector(refreshResearchNow), keyEquivalent: "")
        refreshKw.target = self
        refreshKw.isEnabled = !kws.isEmpty
        researchMenu.addItem(refreshKw)
        researchMenu.addItem(.separator())
        if kws.isEmpty {
            researchMenu.addItem(disabledItem("No keywords yet"))
        } else {
            researchMenu.addItem(disabledItem("Keywords (recent arXiv → tips)"))
            for kw in kws {
                let item = NSMenuItem(title: clipped(kw, limit: 44), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                let rm = NSMenuItem(title: "Remove", action: #selector(removeResearchKeyword(_:)), keyEquivalent: "")
                rm.target = self
                rm.representedObject = kw
                sub.addItem(rm)
                item.submenu = sub
                researchMenu.addItem(item)
            }
        }
        researchItem.submenu = researchMenu
        menu.addItem(researchItem)
        menu.addItem(.separator())

        // Bookmarks — a horizontal quick-launch strip of dev-tool favicons, right
        // below the Sudoor header. Hover an icon to reveal a minus badge to remove it.
        let bookmarks = bookmarkRegistry()
        menu.addItem(customItem(makeBookmarkBar(bookmarks)))
        menu.addItem(.separator())

        let terminalItem = NSMenuItem(title: "Terminal", action: #selector(openTerminalPanel), keyEquivalent: "")
        terminalItem.target = self
        menu.addItem(terminalItem)
        menu.addItem(.separator())

        let test = NSMenuItem(title: "Test Sudoor Prompt", action: #selector(testIsland), keyEquivalent: "t")
        test.target = self
        menu.addItem(test)
        menu.addItem(.separator())

        if reqs.isEmpty {
            menu.addItem(disabledItem("Permission Queue: Clear"))
        } else {
            let queueItem = NSMenuItem(title: "Permission Queue", action: nil, keyEquivalent: "")
            let queueMenu = NSMenu()
            for r in reqs {
                let title = clipped("\(riskBadge(r.risk))  \(r.project) - \(r.tool)", limit: 54)
                let detail = clipped(r.detail.isEmpty ? r.term : "\(r.term) - \(r.detail)", limit: 58)
                queueMenu.addItem(disabledItem(title))
                queueMenu.addItem(disabledItem("    \(detail)"))
            }
            queueItem.submenu = queueMenu
            menu.addItem(queueItem)
        }
        menu.addItem(.separator())

        let visibleRecent = Array(recent.prefix(4))
        if !visibleRecent.isEmpty {
            let recentItem = NSMenuItem(title: "Last Encounters", action: nil, keyEquivalent: "")
            let recentMenu = NSMenu()
            for h in visibleRecent {
                let rule = h.ruleId.isEmpty ? "" : " · \(h.ruleId)"
                let title = clipped("\(outcomeMark(h.outcome))  \(h.project) - \(h.tool)", limit: 54)
                let detail = clipped("    \(h.agent)\(rule) - \(ago(h.time))", limit: 58)
                recentMenu.addItem(disabledItem(title))
                recentMenu.addItem(disabledItem(detail))
            }
            recentItem.submenu = recentMenu
            menu.addItem(recentItem)
            menu.addItem(.separator())
        }

        let toggle = NSMenuItem(title: "Show Requesting Terminal", action: #selector(toggleShow), keyEquivalent: "")
        toggle.target = self
        toggle.state = showTerminals ? .on : .off
        toggle.toolTip = "Raise and minimize the requesting terminal window. The permission queue and blink dot always stay visible."
        menu.addItem(toggle)

        let usageTip = NSMenuItem(title: "Show Usage in Terminal", action: #selector(toggleUsageTips), keyEquivalent: "")
        usageTip.target = self
        usageTip.state = usageTipsEnabled ? .on : .off
        usageTip.toolTip = "Show per-project token usage as a Claude Code spinner tip, like the Research Papers tips."
        menu.addItem(usageTip)

        let login = NSMenuItem(title: "Start at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = loginEnabled() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let export = NSMenuItem(title: "Export Audit Log", action: #selector(exportAudit), keyEquivalent: "e")
        export.target = self
        menu.addItem(export)

        let policy = NSMenuItem(title: "Open Policy File", action: #selector(openPolicy), keyEquivalent: "p")
        policy.target = self
        menu.addItem(policy)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Sudoor", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// The "Workspaces" row: inline ＋ (add) and GitHub (clone) buttons plus a
    /// chevron; its submenu is the recent-workspace list.
    func workspacesMenuItem(workspaceItems: [Workspace], recent: [Hist]) -> NSMenuItem {
        let workspacesItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        workspacesItem.view = WorkspacesRowView(
            width: 320,
            folder: symbolIcon("folder"),
            add: symbolIcon("plus"),
            github: MenuBarDelegate.githubMark,
            chevron: symbolIcon("chevron.right"),
            onAdd: { [weak self] in self?.menu.cancelTracking(); DispatchQueue.main.async { self?.addWorkspace() } },
            onClone: { [weak self] in self?.menu.cancelTracking(); DispatchQueue.main.async { self?.cloneRepository() } }
        )
        let workspacesMenu = NSMenu()
        if workspaceItems.isEmpty {
            workspacesMenu.addItem(disabledItem("No recent workspaces"))
        } else {
            for workspace in workspaceItems.prefix(8) {
                let item = NSMenuItem(title: clipped(workspace.name, limit: 44), action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                let openTerminal = NSMenuItem(title: "Open in Terminal", action: #selector(openWorkspaceTerminal(_:)), keyEquivalent: "")
                openTerminal.target = self
                openTerminal.representedObject = workspace.path
                submenu.addItem(openTerminal)

                let runProject = NSMenuItem(title: "Run Project", action: #selector(runWorkspaceProject(_:)), keyEquivalent: "")
                runProject.target = self
                runProject.representedObject = workspace.path
                submenu.addItem(runProject)

                let openFolder = NSMenuItem(title: "Reveal in Finder", action: #selector(openWorkspaceFolder(_:)), keyEquivalent: "")
                openFolder.target = self
                openFolder.representedObject = workspace.path
                submenu.addItem(openFolder)

                if let encounter = recent.first(where: { $0.cwd == workspace.path && !$0.gitBase.isEmpty }) {
                    let review = NSMenuItem(title: "Review Changes", action: #selector(reviewChanges(_:)), keyEquivalent: "")
                    review.target = self
                    review.representedObject = [
                        "path": workspace.path,
                        "base": encounter.gitBase,
                        "project": workspace.name,
                        "request": encounter.detail.isEmpty ? encounter.tool : encounter.detail
                    ]
                    submenu.addItem(review)
                }

                submenu.addItem(.separator())

                let copyPath = NSMenuItem(title: "Copy Path", action: #selector(copyWorkspacePath(_:)), keyEquivalent: "")
                copyPath.target = self
                copyPath.representedObject = workspace.path
                submenu.addItem(copyPath)

                let remove = NSMenuItem(title: "Remove from Workspaces", action: #selector(removeWorkspace(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = workspace.path
                submenu.addItem(remove)

                item.submenu = submenu
                workspacesMenu.addItem(item)
            }
        }
        workspacesItem.submenu = workspacesMenu
        return workspacesItem
    }

    func updateStatus() {
        guard let button = statusItem.button else { return }
        let n = pendingRequests().count
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

    // MARK: - Menu item icons

    /// The GitHub octocat mark, rendered once from vector path data as a template
    /// image (tints to the menu's label color). Bundles no asset.
    static let githubMark: NSImage = {
        let d = "M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.001 8.001 0 0 0 16 8c0-4.42-3.58-8-8-8z"
        let bp = SVGPathParser(d).build()
        let px: CGFloat = 14
        let img = NSImage(size: NSSize(width: px, height: px))
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.translateBy(x: 0, y: px); ctx.scaleBy(x: px / 16, y: -px / 16)   // SVG is y-down
            NSColor.black.setFill(); bp.fill()
        }
        img.unlockFocus()
        img.isTemplate = true
        return img
    }()

    /// A menu-sized SF Symbol image, or nil on macOS < 11 (item shows no icon).
    func symbolIcon(_ name: String) -> NSImage? {
        guard #available(macOS 11.0, *) else { return nil }
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
    }

    func customItem(_ view: NSView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }

    func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    func clipped(_ label: String, limit: Int) -> String {
        label.count > limit ? String(label.prefix(limit - 1)) + "…" : label
    }

    func riskBadge(_ risk: String) -> String {
        switch risk {
        case "critical": return "CRIT"
        case "high": return "HIGH"
        case "medium": return "MED"
        default: return "LOW"
        }
    }

    func colorForRisk(_ risk: String) -> NSColor {
        switch risk {
        case "critical", "high": return .systemRed.withAlphaComponent(0.18)
        case "medium": return .systemOrange.withAlphaComponent(0.14)
        default: return .quaternaryLabelColor
        }
    }

    func outcomeMark(_ outcome: String) -> String {
        if outcome.contains("approved") || outcome.contains("allowed") { return "OK" }
        if outcome.contains("denied") { return "DENY" }
        if outcome == "deferred" { return "WAIT" }
        return "ASK"
    }

    func colorForOutcome(_ outcome: String, risk: String) -> NSColor {
        if outcome.contains("denied") { return .systemRed.withAlphaComponent(0.18) }
        if risk == "critical" || risk == "high" { return .systemOrange.withAlphaComponent(0.16) }
        return .quaternaryLabelColor
    }

    func loginEnabled() -> Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func rocketTemplate() -> NSImage {
        // Bundled alien mark, rendered as a template (tints to the menu bar).
        if let url = Bundle.main.url(forResource: "menubar", withExtension: "png"),
           let img = NSImage(contentsOf: url), img.size.height > 0 {
            let h: CGFloat = 27
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

    /// The dino mark, loaded and sized once, reused for every animation frame.
    func dinoBaseImage() -> NSImage {
        if let d = dinoBase { return d }
        let img = Self.rocketTemplate()
        dinoBase = img
        return img
    }

    /// Gentle vertical "bob" — the dino floats up and down. Lightweight: redraws a
    /// ~27px template image ~12×/sec. The image canvas has margins, so the small
    /// offset never clips the dino.
    @objc func animateIcon() {
        guard let button = statusItem?.button else { return }
        let base = dinoBaseImage()
        animPhase += 0.18
        let dy = sin(animPhase) * 1.5
        let size = base.size
        let frame = NSImage(size: size)
        frame.lockFocus()
        base.draw(in: NSRect(x: 0, y: dy, width: size.width, height: size.height),
                  from: .zero, operation: .sourceOver, fraction: 1)
        frame.unlockFocus()
        frame.isTemplate = true
        button.image = frame
    }

    // MARK: - Actions
    @objc func toggleShow() { showTerminals.toggle(); rebuildMenu() }

    @objc func toggleUsageTips() { usageTipsEnabled.toggle(); rebuildMenu(); syncSpinnerTips() }

    @objc func addWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Add Workspace"
        panel.prompt = "Add"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        upsertWorkspace(path: url.path)
        rebuildMenu()
    }

    @objc func removeWorkspace(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        removeWorkspace(path: path)
        rebuildMenu()
    }

    @objc func cloneRepository() {
        let alert = NSAlert()
        alert.messageText = "Clone Repository"
        alert.informativeText = "Paste or drop a Git repository URL."
        alert.addButton(withTitle: "Clone")
        alert.addButton(withTitle: "Cancel")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        input.placeholderString = "https://github.com/org/repo.git"
        if let pasted = NSPasteboard.general.string(forType: .string), looksLikeGitURL(pasted) {
            input.stringValue = pasted
        }
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let repo = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeGitURL(repo) else {
            NSSound.beep()
            return
        }

        guard let base = chooseCloneDestination() else { return }
        let clonedPath = URL(fileURLWithPath: base, isDirectory: true)
            .appendingPathComponent(repositoryName(from: repo), isDirectory: true)
            .path
        upsertWorkspace(path: clonedPath)
        rebuildMenu()
        runTerminal(command: "mkdir -p \(quotedForShell(base)); cd \(quotedForShell(base)); git clone \(quotedForShell(repo))")
    }

    @objc func openWorkspaceFolder(_ sender: Any) {
        guard let path = path(from: sender), FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }

    // Opens a regular terminal window that plays an animated dino banner, then ~.
    @objc func openTerminalPanel() {
        ensureDinoBanner()
        runTerminal(command: "clear; bash '\(dinoBannerFile)'; cd ~")
    }

    /// Write the animated ASCII-dino banner script (idempotent; overwrites so
    /// updates ship). Quoted heredocs keep the art literal — no bash escaping.
    func ensureDinoBanner() {
        let script = """
        #!/usr/bin/env bash
        # sudoor — animated dino banner shown when opening Terminal from the menu bar.
        show(){ tput cnorm 2>/dev/null; }
        trap show EXIT
        tput civis 2>/dev/null

        fa(){ clear; cat <<'EOF'

              ___
            /(o o)\\        s u d o o r
           /   -   \\
          |  |---|  |   reading papers .
          |  |___|  |
           \\_     _/
            |_| |_|

        EOF
        }
        fb(){ clear; cat <<'EOF'

              ___
            /(- -)\\        s u d o o r
           /   -   \\
          |  |---|  |   reading papers ..
          |  |___|  |
           \\_     _/
            |_| |_|

        EOF
        }
        fc(){ clear; cat <<'EOF'

              ___
            /(o o)\\        s u d o o r
           /   -   \\
          |  |---|  |   reading papers ...
          |  |___|  |
           \\_     _/
            |_| |_|

        EOF
        }
        for i in 1 2 3 4 5; do
          fa; sleep 0.16
          fc; sleep 0.16
          fb; sleep 0.16
        done
        clear
        cat <<'EOF'
          🦖  sudoor — happy hacking

        EOF
        show
        """
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        try? script.write(toFile: dinoBannerFile, atomically: true, encoding: .utf8)
        chmod(dinoBannerFile, 0o755)
    }

    @objc func openWorkspaceTerminal(_ sender: Any) {
        guard let path = path(from: sender), FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        runTerminal(command: "cd \(quotedForShell(path)); clear")
    }

    func runTerminal(command: String) {
        let script = """
        on run argv
            set commandText to item 1 of argv
            tell application "Terminal"
                activate
                do script commandText
            end tell
        end run
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script, command]
        try? process.run()
    }

    @objc func runWorkspaceProject(_ sender: Any) {
        guard let path = path(from: sender),
              FileManager.default.fileExists(atPath: path) else {
            NSSound.beep()
            return
        }
        guard let command = detectRunCommand(in: path) else {
            // No known dev command — drop the user into a shell so they can run it manually.
            runTerminal(command: "cd \(quotedForShell(path)); clear; echo 'No run command detected — start your dev server manually.'")
            return
        }
        // Print a clickable local-URL header before launching, when we can infer
        // the port — OSC 8 hyperlinks are single-click in Terminal.app and iTerm2.
        let name = URL(fileURLWithPath: path).lastPathComponent
        var prefix = "cd \(quotedForShell(path)); clear; "
        if let url = localURL(forCommand: command, in: path) {
            prefix += clickableHeader(name: name, url: url) + "; "
        }
        runTerminal(command: prefix + command)
    }

    /// A shell `printf` that renders a bold, single-click OSC 8 hyperlink header.
    func clickableHeader(name: String, url: String) -> String {
        // ESC[1m … ESC[0m = bold; ESC]8;;URL BEL text ESC]8;; BEL = OSC 8 hyperlink.
        let fmt = "printf '\\033[1m▶ %s\\033[0m  →  \\033]8;;%s\\007%s\\033]8;;\\007\\n\\n' "
        return fmt + quotedForShell(name) + " " + quotedForShell(url) + " " + quotedForShell(url)
    }

    /// Best-effort local URL a project's dev command will serve, or nil if unknown.
    func localURL(forCommand cmd: String, in dir: String) -> String? {
        // Explicit port baked into the command (e.g. `python3 -m http.server 8000`).
        if let r = cmd.range(of: "http\\.server\\s+(\\d+)", options: .regularExpression) {
            let port = cmd[r].split(separator: " ").last.map(String.init) ?? "8000"
            return "http://localhost:\(port)"
        }
        if cmd.contains("manage.py runserver") { return "http://localhost:8000" }
        if cmd.contains("rails server") { return "http://localhost:3000" }
        if cmd.hasPrefix("npm run") || cmd.hasPrefix("pnpm") || cmd.hasPrefix("yarn") || cmd.hasPrefix("bun run") {
            // Vite defaults to 5173; Next/CRA and most others to 3000.
            return dependsOnVite(in: dir) ? "http://localhost:5173" : "http://localhost:3000"
        }
        return nil
    }

    /// Whether a Node project lists `vite` as a (dev)dependency.
    func dependsOnVite(in dir: String) -> Bool {
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("package.json"))
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        for key in ["dependencies", "devDependencies"] {
            if let deps = json[key] as? [String: Any], deps.keys.contains("vite") { return true }
        }
        return false
    }

    /// Best-effort detection of a project's dev/run command from manifest files.
    func detectRunCommand(in dir: String) -> String? {
        let fm = FileManager.default
        func has(_ name: String) -> Bool { fm.fileExists(atPath: (dir as NSString).appendingPathComponent(name)) }

        // Node — pick a script (dev > start > serve) and the matching package manager.
        if has("package.json") {
            let scripts = packageScripts(in: dir)
            let script = ["dev", "start", "serve"].compactMap { safeRunToken($0) }.first { scripts.contains($0) }
            if let script = script {
                let pm: String
                if has("bun.lockb") { pm = "bun run" }
                else if has("pnpm-lock.yaml") { pm = "pnpm" }
                else if has("yarn.lock") { pm = "yarn" }
                else { pm = "npm run" }
                return "\(pm) \(script)"
            }
        }
        if has("Cargo.toml") { return "cargo run" }
        if has("go.mod") { return "go run ." }
        if has("manage.py") { return "python3 manage.py runserver" }
        if has("Gemfile") && has("bin/rails") { return "bin/rails server" }
        if has("Makefile") {
            let targets = makeTargets(in: dir)
            if let target = ["dev", "run", "serve"].compactMap({ safeRunToken($0) }).first(where: { targets.contains($0) }) {
                return "make \(target)"
            }
        }
        if has("pyproject.toml") || has("requirements.txt") {
            for entry in ["main.py", "app.py", "run.py"] where has(entry) {
                guard safeRunToken(entry) != nil else { continue }
                return "python3 \(entry)"
            }
        }
        if has("index.html") { return "python3 -m http.server 8000" }
        return nil
    }

    /// Names of scripts declared in a package.json (empty on any failure).
    func packageScripts(in dir: String) -> Set<String> {
        let url = URL(fileURLWithPath: (dir as NSString).appendingPathComponent("package.json"))
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        return Set(scripts.keys.compactMap { safeRunToken($0) })
    }

    /// Phony/explicit target names parsed from a Makefile's `target:` lines.
    func makeTargets(in dir: String) -> Set<String> {
        let path = (dir as NSString).appendingPathComponent("Makefile")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var targets = Set<String>()
        for line in text.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(" ") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            if let safe = safeRunToken(name), !name.hasPrefix(".") { targets.insert(safe) }
        }
        return targets
    }

    @objc func copyWorkspacePath(_ sender: Any) {
        guard let path = path(from: sender) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func path(from sender: Any) -> String? {
        if let item = sender as? NSMenuItem { return item.representedObject as? String }
        return nil
    }

    func quotedForShell(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func looksLikeGitURL(_ value: String) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("https://") || text.hasPrefix("http://") || text.hasPrefix("git@") || text.hasPrefix("ssh://") {
            return text.contains(".") || text.contains(":")
        }
        return text.hasSuffix(".git")
    }

    func chooseCloneDestination() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose Clone Destination"
        panel.prompt = "Clone Here"
        panel.message = "Select the folder where the repository should be cloned."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: defaultCloneBaseDirectory(), isDirectory: true)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    func defaultCloneBaseDirectory() -> String {
        let codingProjects = (("~/Desktop/Coding Projects" as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: codingProjects) {
            return codingProjects
        }
        return NSHomeDirectory()
    }

    func repositoryName(from repo: String) -> String {
        var value = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/") { value.removeLast() }
        if value.contains(":"), !value.hasPrefix("http://"), !value.hasPrefix("https://"), !value.hasPrefix("ssh://") {
            value = value.split(separator: ":").last.map(String.init) ?? value
        }
        let last = value.split(separator: "/").last.map(String.init) ?? "Repository"
        if last.hasSuffix(".git") {
            return String(last.dropLast(4))
        }
        return last
    }

    func upsertWorkspace(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        writeWorkspaceRegistry { items in
            items.removeAll { $0.path == path }
            items.insert(Workspace(name: name, path: path, lastSeen: Date().timeIntervalSince1970), at: 0)
        }
    }

    func removeWorkspace(path: String) {
        writeWorkspaceRegistry { items in
            items.removeAll { $0.path == path }
        }
    }

    // MARK: - Bookmarks

    /// Saved bookmarks, or a seeded default set written on first run.
    func bookmarkRegistry() -> [Bookmark] {
        guard FileManager.default.fileExists(atPath: bookmarksFile) else {
            let defaults = [
                Bookmark(name: "GitHub", url: "https://github.com"),
                Bookmark(name: "Vercel", url: "https://vercel.com/dashboard"),
                Bookmark(name: "Supabase", url: "https://supabase.com/dashboard"),
                Bookmark(name: "Slack", url: "https://app.slack.com")
            ]
            writeBookmarkRegistry { $0 = defaults }
            return defaults
        }
        guard let data = FileManager.default.contents(atPath: bookmarksFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["bookmarks"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let url = item["url"] as? String, !url.isEmpty else { return nil }
            let name = (item["name"] as? String) ?? (URL(string: url)?.host ?? url)
            return Bookmark(name: name, url: url)
        }
    }

    func writeBookmarkRegistry(_ mutate: (inout [Bookmark]) -> Void) {
        try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
        var items = (FileManager.default.fileExists(atPath: bookmarksFile)) ? bookmarkRegistry() : []
        mutate(&items)
        var seen = Set<String>()
        let encoded = items.compactMap { b -> [String: Any]? in
            guard !b.url.isEmpty, !seen.contains(b.url) else { return nil }
            seen.insert(b.url)
            return ["name": b.name, "url": b.url]
        }
        let root: [String: Any] = ["bookmarks": Array(encoded.prefix(50))]
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
        let tmp = bookmarksFile + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tmp))
            _ = try FileManager.default.replaceItemAt(URL(fileURLWithPath: bookmarksFile), withItemAt: URL(fileURLWithPath: tmp))
        } catch {
            try? data.write(to: URL(fileURLWithPath: bookmarksFile), options: .atomic)
        }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let url = URL(string: raw) else { NSSound.beep(); return }
        NSWorkspace.shared.open(url)
    }

    @objc func removeBookmark(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else { return }
        writeBookmarkRegistry { $0.removeAll { $0.url == url } }
        rebuildMenu()
    }

    /// Ask before deleting a bookmark — the (−) badge is easy to hit by accident.
    func confirmRemoveBookmark(name: String, url: String) {
        menu.cancelTracking()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(name)”?"
        alert.informativeText = "This bookmark will be removed from Sudoor."
        let remove = alert.addButton(withTitle: "Remove")
        remove.keyEquivalent = ""             // require a deliberate click
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"           // Return defaults to the safe choice
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        writeBookmarkRegistry { $0.removeAll { $0.url == url } }
        rebuildMenu()
    }

    @objc func addBookmark() {
        let alert = NSAlert()
        alert.messageText = "Add Bookmark"
        alert.informativeText = "Name and URL of the tool to bookmark."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        // Fixed-frame accessory: name on top, URL below (y grows upward).
        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 54))
        let nameField = NSTextField(frame: NSRect(x: 0, y: 30, width: 320, height: 24))
        nameField.placeholderString = "Name (e.g. GitHub)"
        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        urlField.placeholderString = "https://github.com"
        if let pasted = NSPasteboard.general.string(forType: .string),
           pasted.hasPrefix("http://") || pasted.hasPrefix("https://") {
            urlField.stringValue = pasted
        }
        acc.addSubview(nameField)
        acc.addSubview(urlField)
        alert.accessoryView = acc
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.isEmpty, !url.contains("://") { url = "https://" + url }   // tolerate "github.com"
        guard let parsed = URL(string: url), let host = parsed.host, !host.isEmpty else { NSSound.beep(); return }
        var name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = host.replacingOccurrences(of: "www.", with: "") }

        writeBookmarkRegistry { items in
            items.removeAll { $0.url == url }
            items.append(Bookmark(name: name, url: url))
        }
        fetchIcon(forURL: url)   // prime the favicon cache, then refresh
        rebuildMenu()
    }

    /// Horizontal quick-launch strip of bookmark favicons followed by a "+" add
    /// cell. Each bookmark opens its URL on click and reveals a remove (−) badge
    /// on hover; the "+" opens the add dialog.
    func makeBookmarkBar(_ bookmarks: [Bookmark]) -> NSView {
        let h: CGFloat = 44, cell: CGFloat = 30, gap: CGFloat = 10, padX: CGFloat = 18
        let n = bookmarks.count + 1   // +1 for the trailing "+" add cell
        let width = padX * 2 + CGFloat(n) * cell + CGFloat(n - 1) * gap
        let bar = BookmarkBarView(frame: NSRect(x: 0, y: 0, width: max(width, 120), height: h))
        var x = padX
        var cells: [BookmarkCell] = []
        for bookmark in bookmarks {
            let url = bookmark.url
            let name = bookmark.name
            let c = BookmarkCell(
                frame: NSRect(x: x, y: (h - cell) / 2, width: cell, height: cell),
                icon: bookmarkIcon(for: url, size: 24),
                name: bookmark.name,
                onOpen: { [weak self] in
                    self?.menu.cancelTracking()
                    if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                },
                onRemove: { [weak self] in
                    self?.confirmRemoveBookmark(name: name, url: url)
                }
            )
            bar.addSubview(c)
            cells.append(c)
            x += cell + gap
        }
        // Trailing "+" cell — opens the add-bookmark dialog. No remove badge.
        let plus = BookmarkCell(
            frame: NSRect(x: x, y: (h - cell) / 2, width: cell, height: cell),
            icon: plusTile(24),
            name: "Add bookmark",
            removable: false,
            onOpen: { [weak self] in self?.menu.cancelTracking(); self?.addBookmark() }
        )
        bar.addSubview(plus)
        cells.append(plus)
        bar.cells = cells
        return bar
    }

    /// A subtle rounded "+" tile for the add cell, matching the favicon tiles.
    func plusTile(_ size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
        let p = NSBezierPath()
        p.lineWidth = 1.8
        p.lineCapStyle = .round
        p.move(to: NSPoint(x: size * 0.5, y: size * 0.28)); p.line(to: NSPoint(x: size * 0.5, y: size * 0.72))
        p.move(to: NSPoint(x: size * 0.28, y: size * 0.5)); p.line(to: NSPoint(x: size * 0.72, y: size * 0.5))
        NSColor.secondaryLabelColor.setStroke()
        p.stroke()
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - GitHub contributions

    /// A dark panel heatmap of the last ~17 weeks of GitHub contributions, or nil
    /// (and a background fetch) when there's no cached data yet.
    func contributionsBar() -> NSView? {
        guard let cache = cachedContributions() else { fetchContributions(); return nil }
        if Date().timeIntervalSince1970 - cache.fetchedAt > 6 * 3600 { fetchContributions() }
        let img = contributionsImage(levels: cache.levels, firstDate: cache.firstDate)
        let padX: CGFloat = 18
        let container = NSView(frame: NSRect(x: 0, y: 0, width: img.size.width + padX * 2, height: img.size.height + 6))
        let iv = NSImageView(frame: NSRect(x: padX, y: 3, width: img.size.width, height: img.size.height))
        iv.image = img
        iv.imageScaling = .scaleNone
        container.addSubview(iv)
        return container
    }

    func cachedContributions() -> (levels: [Int], firstDate: String, fetchedAt: TimeInterval)? {
        guard let data = FileManager.default.contents(atPath: contributionsFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = root["levels"] as? [Any] else { return nil }
        let levels = raw.compactMap { ($0 as? NSNumber)?.intValue }
        guard !levels.isEmpty else { return nil }
        let firstDate = (root["firstDate"] as? String) ?? ""
        let fetchedAt = (root["fetchedAt"] as? NSNumber)?.doubleValue ?? 0
        return (levels, firstDate, fetchedAt)
    }

    /// Refresh from the public contributions API (no auth). Username comes from the
    /// cache, else the gh CLI on first run.
    func fetchContributions() {
        guard !fetchingContrib else { return }
        fetchingContrib = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.fetchingContrib = false } }
            guard let user = self.cachedGitHubUser() ?? self.detectGitHubUser(),
                  let url = URL(string: "https://github-contributions-api.jogruber.de/v4/\(user)?y=last"),
                  let data = try? Data(contentsOf: url),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let arr = root["contributions"] as? [[String: Any]], !arr.isEmpty else { return }
            let levels = arr.map { ($0["level"] as? Int) ?? 0 }
            let firstDate = (arr.first?["date"] as? String) ?? ""
            let cache: [String: Any] = ["user": user, "fetchedAt": Int(Date().timeIntervalSince1970),
                                        "firstDate": firstDate, "levels": levels]
            self.writeAtomicJSON(at: self.contributionsFile, object: cache)
            DispatchQueue.main.async { self.rebuildMenu() }
        }
    }

    func cachedGitHubUser() -> String? {
        guard let data = FileManager.default.contents(atPath: contributionsFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return root["user"] as? String
    }

    func detectGitHubUser() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["api", "user", "--jq", ".login"]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            if let d = try? pipe.fileHandleForReading.readToEnd(),
               let s = String(data: d, encoding: .utf8) {
                let login = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !login.isEmpty { return login }
            }
        }
        return nil
    }

    /// Render the heatmap: columns = weeks (last 17), rows = weekdays (Sun→Sat).
    func contributionsImage(levels: [Int], firstDate: String) -> NSImage {
        let cols = 17, rows = 7
        let sq: CGFloat = 11, gap: CGFloat = 3, pad: CGFloat = 12, radius: CGFloat = 2.5
        let offset = contribWeekday(firstDate)
        let totalCols = (offset + levels.count + 6) / 7
        let startCol = max(0, totalCols - cols)
        let gridW = CGFloat(cols) * sq + CGFloat(cols - 1) * gap
        let gridH = CGFloat(rows) * sq + CGFloat(rows - 1) * gap
        let w = gridW + pad * 2, h = gridH + pad * 2
        let palette = ["#2d333b", "#0e4429", "#006d32", "#26a641", "#39d353"].map(contribColor)
        func cellRect(_ c: Int, _ r: Int) -> NSRect {
            NSRect(x: pad + CGFloat(c) * (sq + gap),
                   y: h - pad - CGFloat(r + 1) * sq - CGFloat(r) * gap, width: sq, height: sq)
        }
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        contribColor("#1b1f24").setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 10, yRadius: 10).fill()
        for c in 0..<cols { for r in 0..<rows {
            palette[0].setFill()
            NSBezierPath(roundedRect: cellRect(c, r), xRadius: radius, yRadius: radius).fill()
        } }
        for i in 0..<levels.count {
            let g = offset + i, col = g / 7, row = g % 7
            if col < startCol { continue }
            let c = col - startCol
            if c >= cols { break }
            palette[min(max(levels[i], 0), 4)].setFill()
            NSBezierPath(roundedRect: cellRect(c, row), xRadius: radius, yRadius: radius).fill()
        }
        img.unlockFocus()
        return img
    }

    func contribColor(_ s: String) -> NSColor {
        var h = s; if h.hasPrefix("#") { h.removeFirst() }
        let v = UInt32(h, radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }

    func contribWeekday(_ ymd: String) -> Int {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        guard let d = f.date(from: ymd) else { return 0 }
        return cal.component(.weekday, from: d) - 1
    }

    // MARK: - X (Twitter) followers

    /// The menu-row text, or nil when no handle is set yet (→ show "Set Handle…").
    /// Kicks off a background refresh when the cache is missing or older than 6h.
    func twitterDisplay() -> String? {
        let cfg = readConfig()
        guard let raw = cfg["twitterHandle"] as? String, !raw.isEmpty else { return nil }
        let handle = normalizeHandle(raw)
        if let c = cachedTwitter(), c.handle == handle {
            if Date().timeIntervalSince1970 - c.fetchedAt > 6 * 3600 { fetchTwitterFollowers() }
            if let f = c.followers { return "𝕏 @\(handle) · \(groupedNumber(f)) followers" }
            return "𝕏 @\(handle) · followers unavailable"
        }
        fetchTwitterFollowers()
        return "𝕏 @\(handle) · …"
    }

    func cachedTwitter() -> (handle: String, followers: Int?, fetchedAt: TimeInterval)? {
        guard let data = FileManager.default.contents(atPath: twitterFile),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let handle = root["handle"] as? String else { return nil }
        let followers = (root["followers"] as? NSNumber)?.intValue
        let fetchedAt = (root["fetchedAt"] as? NSNumber)?.doubleValue ?? 0
        return (handle, followers, fetchedAt)
    }

    /// Refresh the follower count in the background, caching success or failure
    /// (so we show "unavailable" instead of hammering a blocked endpoint).
    func fetchTwitterFollowers() {
        guard !fetchingTwitter else { return }
        let cfg = readConfig()
        guard let raw = cfg["twitterHandle"] as? String, !raw.isEmpty else { return }
        let handle = normalizeHandle(raw)
        let bearer = twitterBearerToken()
        fetchingTwitter = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.fetchingTwitter = false } }
            let followers = self.fetchFollowerCount(handle: handle, bearer: bearer)
            var cache: [String: Any] = ["handle": handle, "fetchedAt": Int(Date().timeIntervalSince1970)]
            if let f = followers { cache["followers"] = f }
            self.writeAtomicJSON(at: self.twitterFile, object: cache)
            DispatchQueue.main.async { self.rebuildMenu() }
        }
    }

    /// Official X API v2 when a bearer token is configured (reliable), otherwise
    /// a best-effort guest-token fallback (X often blocks this).
    func fetchFollowerCount(handle: String, bearer: String?) -> Int? {
        if let bearer = bearer, !bearer.isEmpty {
            guard let url = URL(string: "https://api.twitter.com/2/users/by/username/\(handle)?user.fields=public_metrics")
            else { return nil }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
            guard let data = syncRequest(req), let root = twJSON(data),
                  let d = root["data"] as? [String: Any],
                  let pm = d["public_metrics"] as? [String: Any],
                  let f = (pm["followers_count"] as? NSNumber)?.intValue else { return nil }
            return f
        }
        return guestFollowerCount(handle: handle)
    }

    /// Public-web guest path: activate a guest token, then read UserByScreenName.
    /// The GraphQL query id / features rotate, so this is best-effort only.
    private func guestFollowerCount(handle: String) -> Int? {
        let webBearer = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
        guard let activate = URL(string: "https://api.twitter.com/1.1/guest/activate.json") else { return nil }
        var areq = URLRequest(url: activate)
        areq.httpMethod = "POST"
        areq.setValue("Bearer \(webBearer)", forHTTPHeaderField: "Authorization")
        guard let ad = syncRequest(areq), let aj = twJSON(ad),
              let guest = aj["guest_token"] as? String else { return nil }

        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let qid = "sLVLhk0bGj3MVFEKTdax1w"   // UserByScreenName (may change over time)
        let vars = "{\"screen_name\":\"\(handle)\"}"
        let features = "{\"hidden_profile_subscriptions_enabled\":true,\"rweb_tipjar_consumption_enabled\":true,\"responsive_web_graphql_exclude_directive_enabled\":true,\"verified_phone_label_enabled\":false,\"subscriptions_verification_info_is_identity_verified_enabled\":true,\"subscriptions_verification_info_verified_since_enabled\":true,\"highlights_tweets_tab_ui_enabled\":true,\"responsive_web_twitter_article_notes_tab_enabled\":true,\"subscriptions_feature_can_gift_premium\":true,\"creator_subscriptions_tweet_preview_api_enabled\":true,\"responsive_web_graphql_skip_user_profile_image_extensions_enabled\":false,\"responsive_web_graphql_timeline_navigation_enabled\":true}"
        guard let url = URL(string: "https://api.twitter.com/graphql/\(qid)/UserByScreenName?variables=\(enc(vars))&features=\(enc(features))")
        else { return nil }
        var greq = URLRequest(url: url)
        greq.setValue("Bearer \(webBearer)", forHTTPHeaderField: "Authorization")
        greq.setValue(guest, forHTTPHeaderField: "x-guest-token")
        guard let gd = syncRequest(greq), let gj = twJSON(gd),
              let d = gj["data"] as? [String: Any],
              let user = d["user"] as? [String: Any],
              let result = user["result"] as? [String: Any],
              let legacy = result["legacy"] as? [String: Any],
              let f = (legacy["followers_count"] as? NSNumber)?.intValue else { return nil }
        return f
    }

    private func twJSON(_ d: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }

    /// Exact integer with thousands separators, e.g. 1375 → "1,375".
    func groupedNumber(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    // MARK: - Research papers → Claude Code spinner tips

    func researchKeywords() -> [String] { (readConfig()["researchKeywords"] as? [String]) ?? [] }

    @objc func addResearchKeyword() {
        let alert = NSAlert()
        alert.messageText = "Add Research Keyword"
        alert.informativeText = "Claude Code's spinner tips will show recent arXiv papers matching your keywords."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        input.placeholderString = "e.g. diffusion models, LLM agents"
        alert.accessoryView = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let kw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        var kws = researchKeywords()
        if !kws.contains(where: { $0.caseInsensitiveCompare(kw) == .orderedSame }) { kws.append(kw) }
        updateConfig { $0["researchKeywords"] = kws }
        rebuildMenu()
        refreshResearchTips(force: true)
    }

    @objc func removeResearchKeyword(_ sender: Any) {
        guard let kw = (sender as? NSMenuItem)?.representedObject as? String else { return }
        var kws = researchKeywords()
        kws.removeAll { $0 == kw }
        updateConfig { $0["researchKeywords"] = kws }
        rebuildMenu()
        if !kws.isEmpty { refreshResearchTips(force: true) }
    }

    @objc func refreshResearchNow() { refreshResearchTips(force: true) }

    /// Fetch recent arXiv papers for the configured keywords and write them into
    /// Claude Code's spinner tips. Throttled to every 6h unless forced.
    func refreshResearchTips(force: Bool = false) {
        guard !fetchingResearch else { return }
        let kws = researchKeywords()
        guard !kws.isEmpty else { return }
        if !force, let last = (readConfig()["researchFetchedAt"] as? NSNumber)?.doubleValue,
           Date().timeIntervalSince1970 - last < 6 * 3600 { return }
        fetchingResearch = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.fetchingResearch = false } }
            var tips: [String] = []
            var seen = Set<String>()
            for kw in kws {
                for title in self.fetchArxivTitles(keyword: kw, max: 8) {
                    if seen.insert(title.lowercased()).inserted { tips.append("🦖 \(title) — arXiv") }
                    if tips.count >= 40 { break }
                }
                if tips.count >= 40 { break }
            }
            guard !tips.isEmpty else { return }
            self.updateConfig {
                $0["researchTips"] = tips
                $0["researchFetchedAt"] = Int(Date().timeIntervalSince1970)
            }
            DispatchQueue.main.async { self.syncSpinnerTips() }
        }
    }

    func fetchArxivTitles(keyword: String, max: Int) -> [String] {
        let q = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        guard let url = URL(string: "https://export.arxiv.org/api/query?search_query=all:\(q)&sortBy=submittedDate&sortOrder=descending&max_results=\(max)")
        else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        guard let data = syncRequest(req) else { return [] }
        let parser = XMLParser(data: data)
        let delegate = ArxivTitleParser()
        parser.delegate = delegate
        parser.parse()
        return delegate.titles
    }

    // MARK: - Usage → Claude Code spinner tips

    /// Per-project token-usage tip lines, mirroring the menu's
    /// "name — pct% · ctx/win tokens" format. Empty when disabled or uncomputed.
    func usageTips() -> [String] {
        guard usageTipsEnabled else { return [] }
        let projects = cachedProjects()
        if !projects.isEmpty {
            return projects.prefix(6).map {
                "📊 \($0.name) — \($0.pct)% · \(shortTokens($0.ctx))/\(shortTokens($0.win)) tokens · \(money($0.sessCost)) session"
            }
        }
        if let u = cachedUsage() {
            return ["📊 \(u.pct)% · \(shortTokens(u.ctx))/\(shortTokens(u.win)) tokens"]
        }
        return []
    }

    /// Most recently fetched arXiv research tips (persisted in config).
    func storedResearchTips() -> [String] { (readConfig()["researchTips"] as? [String]) ?? [] }

    /// Push the combined usage + research tips into Claude Code's spinner. When
    /// both are empty, restore Claude's default spinner tips.
    func syncSpinnerTips() {
        let tips = usageTips() + storedResearchTips()
        if tips.isEmpty { clearClaudeSpinnerTips() } else { updateClaudeSpinnerTips(tips) }
    }

    /// Remove our spinner-tip override so Claude Code's default tips return.
    func clearClaudeSpinnerTips() {
        guard let d = FileManager.default.contents(atPath: claudeSettingsFile),
              var root = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              root["spinnerTipsOverride"] != nil else { return }
        root.removeValue(forKey: "spinnerTipsOverride")
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = claudeSettingsFile + ".tmp"
        if (try? out.write(to: URL(fileURLWithPath: tmp))) != nil { rename(tmp, claudeSettingsFile) }
    }

    /// Read ~/.claude/settings.json, set the spinner tips to `tips`, write atomically.
    func updateClaudeSpinnerTips(_ tips: [String]) {
        var root: [String: Any] = [:]
        if let d = FileManager.default.contents(atPath: claudeSettingsFile),
           let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { root = o }
        // Skip the rewrite when nothing changed — usage refreshes whenever the menu opens.
        if (root["spinnerTipsEnabled"] as? Bool) == true,
           let prev = root["spinnerTipsOverride"] as? [String: Any],
           (prev["tips"] as? [String]) == tips { return }
        root["spinnerTipsEnabled"] = true
        root["spinnerTipsOverride"] = ["excludeDefault": true, "tips": tips]
        guard let out = try? JSONSerialization.data(withJSONObject: root,
                                                    options: [.prettyPrinted, .sortedKeys]) else { return }
        let tmp = claudeSettingsFile + ".tmp"
        if (try? out.write(to: URL(fileURLWithPath: tmp))) != nil { rename(tmp, claudeSettingsFile) }
    }

    /// Synchronous GET/POST (already called from a background queue).
    private func syncRequest(_ req: URLRequest) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) { out = nil }
            else { out = data }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return out
    }

    /// Strip @, URLs, and query strings down to a bare handle.
    func normalizeHandle(_ s: String) -> String {
        var h = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = h.range(of: "(twitter|x)\\.com/", options: [.regularExpression, .caseInsensitive]) {
            h = String(h[r.upperBound...])
        }
        h = h.split(separator: "/").first.map(String.init) ?? h
        h = h.split(separator: "?").first.map(String.init) ?? h
        if h.hasPrefix("@") { h.removeFirst() }
        return h
    }

    @objc func setTwitterHandle() {
        let alert = NSAlert()
        alert.messageText = "X (Twitter) Followers"
        alert.informativeText = "Enter your @handle. Optionally paste an X API bearer token for reliable counts (the free fetch is often blocked by X)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let cfg = readConfig()
        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 58))
        let handleField = NSTextField(frame: NSRect(x: 0, y: 32, width: 420, height: 24))
        handleField.placeholderString = "@yourhandle"
        handleField.stringValue = (cfg["twitterHandle"] as? String) ?? ""
        let tokenField = NSTextField(frame: NSRect(x: 0, y: 2, width: 420, height: 24))
        tokenField.placeholderString = "API bearer token (optional)"
        tokenField.stringValue = twitterBearerToken() ?? ""
        acc.addSubview(handleField)
        acc.addSubview(tokenField)
        alert.accessoryView = acc
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let handle = normalizeHandle(handleField.stringValue)
        let token = tokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updateConfig { $0["twitterHandle"] = handle }
        if token.isEmpty {
            KeychainStore.delete(account: Self.twitterBearerAccount)
        } else {
            KeychainStore.save(token, account: Self.twitterBearerAccount)
        }
        try? FileManager.default.removeItem(atPath: twitterFile)   // clear stale cache
        rebuildMenu()
        if !handle.isEmpty { fetchTwitterFollowers() }
    }

    // MARK: - Session usage (context / time / cost from Claude Code transcripts)

    func cachedUsage() -> (pct: Int, ctx: Int, win: Int, runningSec: Double, costLine: String, computedAt: TimeInterval)? {
        guard let data = FileManager.default.contents(atPath: usageFile),
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double { ((r[k] as? NSNumber)?.doubleValue) ?? 0 }
        let ctx = Int(num("contextTokens")), win = max(Int(num("contextWindow")), 1)
        let pct = min(100, Int((Double(ctx) / Double(win)) * 100))
        let costLine = "Cost \(money(num("sessionCost")))  ·  5h \(money(num("cost5h")))  ·  7d \(money(num("cost7d")))"
        return (pct, ctx, win, num("runningSec"), costLine, num("computedAt"))
    }

    struct ProjectUsage { let name: String; let pct: Int; let ctx: Int; let win: Int
                          let sessCost: Double; let cost7d: Double; let runningSec: Double }

    /// Per-project usage from the cached usage.json (most-recent-active first).
    func cachedProjects() -> [ProjectUsage] {
        guard let data = FileManager.default.contents(atPath: usageFile),
              let r = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let arr = r["projects"] as? [[String: Any]] else { return [] }
        return arr.map { p in
            let ctx = (p["ctx"] as? NSNumber)?.intValue ?? 0
            let win = max((p["win"] as? NSNumber)?.intValue ?? 1, 1)
            return ProjectUsage(
                name: (p["name"] as? String) ?? "?",
                pct: min(100, Int(Double(ctx) / Double(win) * 100)),
                ctx: ctx, win: win,
                sessCost: (p["sessCost"] as? NSNumber)?.doubleValue ?? 0,
                cost7d: (p["cost7d"] as? NSNumber)?.doubleValue ?? 0,
                runningSec: (p["runningSec"] as? NSNumber)?.doubleValue ?? 0)
        }
    }

    /// Compute per-project context/cost/duration. The project's "current" session
    /// is its most-recently-modified non-subagent transcript (context = that
    /// session's latest message tokens); cost7d sums all of the project's transcripts.
    func computeProjectUsage(byProject: [String: [String]], mtimes: [String: TimeInterval],
                             now: TimeInterval) -> [[String: Any]] {
        var out: [(lastActive: TimeInterval, dict: [String: Any])] = []
        for (projDir, files) in byProject {
            let projCur = files.filter { !$0.contains("/subagents/") }.max { (mtimes[$0] ?? 0) < (mtimes[$1] ?? 0) }
            let lastActive = files.compactMap { mtimes[$0] }.max() ?? 0
            var name = "", ctx = 0, curTs = -1.0, sess = 0.0, c7d = 0.0
            var first: TimeInterval?, last: TimeInterval?
            for f in files {
                guard let content = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    if name.isEmpty, let cwd = d["cwd"] as? String, !cwd.isEmpty {
                        name = (cwd as NSString).lastPathComponent
                    }
                    let ts = parseISO(d["timestamp"] as? String)
                    if let msg = d["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                        let c = usageCost(u, model: msg["model"] as? String)
                        c7d += c
                        if f == projCur {
                            sess += c
                            let tsv = ts ?? 0
                            if tsv >= curTs {
                                curTs = tsv
                                ctx = intVal(u["input_tokens"]) + intVal(u["cache_read_input_tokens"]) + intVal(u["cache_creation_input_tokens"])
                            }
                        }
                    }
                    if f == projCur, let ts = ts {
                        first = first.map { Swift.min($0, ts) } ?? ts
                        last = last.map { Swift.max($0, ts) } ?? ts
                    }
                }
            }
            if name.isEmpty { name = decodeProjectDir(projDir) }
            let win = ctx > 200_000 ? 1_000_000 : 200_000
            let running = (first != nil && last != nil) ? (last! - first!) : 0
            out.append((lastActive, ["name": name, "ctx": ctx, "win": win,
                                     "sessCost": sess, "cost7d": c7d, "runningSec": running]))
        }
        return out.sorted { $0.lastActive > $1.lastActive }.prefix(10).map { $0.dict }
    }

    /// Fallback project name from the encoded dir, e.g. "-Users-me-sudoor" → "sudoor".
    func decodeProjectDir(_ s: String) -> String {
        let parts = s.split(separator: "-").map(String.init).filter { !$0.isEmpty }
        return parts.last ?? s
    }

    /// Scan Claude Code transcripts in the background and cache the usage metrics.
    func computeUsage() {
        guard !computingUsage else { return }
        computingUsage = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.computingUsage = false } }
            let fm = FileManager.default
            let base = ("~/.claude/projects" as NSString).expandingTildeInPath
            guard let en = fm.enumerator(atPath: base) else { return }
            let now = Date().timeIntervalSince1970
            var mtimes: [String: TimeInterval] = [:]
            var byProject: [String: [String]] = [:]   // project dir → transcript paths (≤7d)
            for case let rel as String in en where rel.hasSuffix(".jsonl") {
                let full = base + "/" + rel
                if let date = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date,
                   date.timeIntervalSince1970 > now - 7 * 86400 {
                    mtimes[full] = date.timeIntervalSince1970
                    let projDir = rel.split(separator: "/").first.map(String.init) ?? rel
                    byProject[projDir, default: []].append(full)
                }
            }
            // Current session = most-recently-modified non-subagent transcript.
            let cur = mtimes.filter { !$0.key.contains("/subagents/") }.max { $0.value < $1.value }?.key

            var cost5h = 0.0, cost7d = 0.0, sessCost = 0.0
            var first: TimeInterval?, last: TimeInterval?, ctxTokens = 0
            for f in mtimes.keys {
                guard let content = try? String(contentsOfFile: f, encoding: .utf8) else { continue }
                for line in content.split(separator: "\n") {
                    guard let data = line.data(using: .utf8),
                          let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
                    let ts = self.parseISO(d["timestamp"] as? String)
                    if let msg = d["message"] as? [String: Any], let u = msg["usage"] as? [String: Any] {
                        let c = self.usageCost(u, model: msg["model"] as? String)
                        if let ts = ts {
                            if ts > now - 5 * 3600 { cost5h += c }
                            if ts > now - 7 * 86400 { cost7d += c }
                        }
                        if f == cur {
                            sessCost += c
                            ctxTokens = self.intVal(u["input_tokens"]) + self.intVal(u["cache_read_input_tokens"]) + self.intVal(u["cache_creation_input_tokens"])
                        }
                    }
                    if f == cur, let ts = ts {
                        first = first.map { Swift.min($0, ts) } ?? ts
                        last = last.map { Swift.max($0, ts) } ?? ts
                    }
                }
            }
            let window = ctxTokens > 200_000 ? 1_000_000 : 200_000
            let running = (first != nil && last != nil) ? (last! - first!) : 0
            let projects = self.computeProjectUsage(byProject: byProject, mtimes: mtimes, now: now)
            let cache: [String: Any] = [
                "contextTokens": ctxTokens, "contextWindow": window, "runningSec": running,
                "sessionCost": sessCost, "cost5h": cost5h, "cost7d": cost7d,
                "computedAt": Int(now), "projects": projects
            ]
            self.writeAtomicJSON(at: self.usageFile, object: cache)
            DispatchQueue.main.async { self.rebuildMenu(); self.syncSpinnerTips() }
        }
    }

    func usageCost(_ u: [String: Any], model: String?) -> Double {
        let p = pricing(model)
        return (Double(intVal(u["input_tokens"])) * p.0
              + Double(intVal(u["output_tokens"])) * p.1
              + Double(intVal(u["cache_creation_input_tokens"])) * p.2
              + Double(intVal(u["cache_read_input_tokens"])) * p.3) / 1_000_000
    }

    // USD per 1M tokens: (input, output, cache-write, cache-read). Estimates.
    func pricing(_ model: String?) -> (Double, Double, Double, Double) {
        let m = (model ?? "").lowercased()
        if m.contains("opus") { return (15, 75, 18.75, 1.5) }
        if m.contains("sonnet") { return (3, 15, 3.75, 0.3) }
        if m.contains("haiku") { return (0.8, 4, 1.0, 0.08) }
        if m.contains("fable") { return (5, 25, 6.25, 0.5) }
        return (15, 75, 18.75, 1.5)
    }

    func intVal(_ any: Any?) -> Int { (any as? NSNumber)?.intValue ?? 0 }

    func parseISO(_ s: String?) -> TimeInterval? {
        guard let s = s else { return nil }
        return MenuBarDelegate.isoFormatter.date(from: s)?.timeIntervalSince1970
    }
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func shortTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return n % 1_000_000 == 0 ? "\(n / 1_000_000)M" : String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return "\(n / 1_000)K" }
        return "\(n)"
    }

    func fmtDuration(_ secs: Double) -> String {
        let s = Int(secs)
        let h = s / 3600, m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    func money(_ v: Double) -> String {
        if v >= 100 {
            let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
            return "$" + (f.string(from: NSNumber(value: Int(v.rounded()))) ?? "\(Int(v))")
        }
        return String(format: "$%.2f", v)
    }

    /// A gamified context "fuel gauge": a segmented bar that fills and shifts
    /// green → amber → orange → red as the context window fills up.
    func contextMeter(pct: Int, ctx: Int, win: Int, runningSec: Double) -> NSView {
        let img = contextMeterImage(pct: pct, ctx: ctx, win: win, runningSec: runningSec)
        let padX: CGFloat = 18
        let container = NSView(frame: NSRect(x: 0, y: 0, width: img.size.width + padX * 2, height: img.size.height + 6))
        let iv = NSImageView(frame: NSRect(x: padX, y: 3, width: img.size.width, height: img.size.height))
        iv.image = img
        iv.imageScaling = .scaleNone
        container.addSubview(iv)
        return container
    }

    func contextMeterImage(pct: Int, ctx: Int, win: Int, runningSec: Double) -> NSImage {
        let w: CGFloat = 259, pad: CGFloat = 12, barH: CGFloat = 10, row1H: CGFloat = 16, row3H: CGFloat = 13
        let (zone, word): (NSColor, String) = {
            if pct < 50 { return (contribColor("#39d353"), "Fresh") }
            if pct < 75 { return (contribColor("#e3b341"), "Cruising") }
            if pct < 90 { return (contribColor("#db6d28"), "Filling up") }
            return (contribColor("#e5534b"), "Almost full")
        }()
        let h = pad + row1H + 7 + barH + 7 + row3H + pad
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        contribColor("#1b1f24").setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: 10, yRadius: 10).fill()

        func text(_ s: String, x: CGFloat, topY: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor, rightTo: CGFloat? = nil) {
            let str = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
            let sz = str.size()
            let drawX = rightTo != nil ? rightTo! - sz.width : x
            str.draw(at: NSPoint(x: drawX, y: h - topY - sz.height))
        }
        text("🧠 Context", x: pad, topY: pad, size: 12.5, weight: .semibold, color: .white)
        text("\(pct)%  \(word)", x: 0, topY: pad, size: 12.5, weight: .semibold, color: zone, rightTo: w - pad)

        let barY = h - (pad + row1H + 7 + barH)
        let barW = w - pad * 2
        let n = 24, gap: CGFloat = 3
        let cellW = (barW - CGFloat(n - 1) * gap) / CGFloat(n)
        let filled = max(pct > 0 ? 1 : 0, Int((Double(pct) / 100.0 * Double(n)).rounded()))
        for i in 0..<n {
            let cx = pad + CGFloat(i) * (cellW + gap)
            (i < filled ? zone : contribColor("#2d333b")).setFill()
            NSBezierPath(roundedRect: NSRect(x: cx, y: barY, width: cellW, height: barH), xRadius: 2, yRadius: 2).fill()
        }
        text("\(shortTokens(ctx)) / \(shortTokens(win)) tokens  ·  \(fmtDuration(runningSec)) running",
             x: pad, topY: pad + row1H + 7 + barH + 7, size: 10.5, weight: .regular, color: contribColor("#8b949e"))
        img.unlockFocus()
        return img
    }

    /// Cached favicon (on a light tile so dark logos stay visible in dark mode),
    /// or a globe placeholder while it downloads.
    func bookmarkIcon(for urlString: String, size: CGFloat = 16) -> NSImage? {
        guard let host = URL(string: urlString)?.host else { return globePlaceholder(size) }
        let cached = (bookmarkIconsDir as NSString).appendingPathComponent("\(host).png")
        if let fav = NSImage(contentsOfFile: cached) {
            return iconTile(fav, size: size)
        }
        fetchIcon(forURL: urlString)
        return globePlaceholder(size)
    }

    func globePlaceholder(_ size: CGFloat = 16) -> NSImage? {
        let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        globe?.size = NSSize(width: size, height: size)
        return globe   // SF symbol: a template image, tints to the menu's text colour
    }

    /// Composite a favicon onto a white rounded tile. Without this, a solid black
    /// logo (GitHub, Vercel) is invisible against a dark-mode menu.
    func iconTile(_ favicon: NSImage, size: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22).fill()
        favicon.draw(in: rect.insetBy(dx: size * 0.14, dy: size * 0.14), from: .zero, operation: .sourceOver, fraction: 1)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    /// Download a domain's favicon into the cache, then rebuild the menu so the
    /// real icon replaces the placeholder. No-op if cached or already in flight.
    ///
    /// Tries the site's own /favicon.ico first — that yields the correct
    /// per-subdomain icon (e.g. Gmail's "M", not Google's generic "G") — then
    /// falls back to icon services that collapse to the root domain.
    func fetchIcon(forURL urlString: String) {
        guard let host = URL(string: urlString)?.host, !fetchingIcons.contains(host) else { return }
        let cached = (bookmarkIconsDir as NSString).appendingPathComponent("\(host).png")
        if FileManager.default.fileExists(atPath: cached) { return }
        let candidates = [
            "https://\(host)/favicon.ico",
            "https://icons.duckduckgo.com/ip3/\(host).ico",
            "https://www.google.com/s2/favicons?domain=\(host)&sz=64",
        ].compactMap(URL.init)
        fetchingIcons.insert(host)
        try? FileManager.default.createDirectory(atPath: bookmarkIconsDir, withIntermediateDirectories: true)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.fetchingIcons.remove(host) } }
            for src in candidates {
                var req = URLRequest(url: src)
                req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                req.timeoutInterval = 8
                guard let data = self.syncRequest(req), let img = NSImage(data: data),
                      let png = self.pngData(from: img) else { continue }
                try? png.write(to: URL(fileURLWithPath: cached))
                DispatchQueue.main.async { self.rebuildMenu() }
                return
            }
        }
    }

    /// Normalise an NSImage to PNG, picking its largest pixel representation so
    /// multi-resolution .ico files come out crisp.
    private func pngData(from img: NSImage) -> Data? {
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep })
            .max(by: { $0.pixelsWide < $1.pixelsWide }),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        guard let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }

    func writeWorkspaceRegistry(_ mutate: (inout [Workspace]) -> Void) {
        withStateLock {
            var items = workspaceRegistry()
            mutate(&items)
            var seen = Set<String>()
            let encodedItems = items.compactMap { workspace -> [String: Any]? in
                guard !workspace.path.isEmpty, !seen.contains(workspace.path) else { return nil }
                seen.insert(workspace.path)
                return [
                    "name": workspace.name,
                    "path": workspace.path,
                    "lastSeen": Int(workspace.lastSeen)
                ]
            }
            let root: [String: Any] = ["workspaces": Array(encodedItems.prefix(30))]
            guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return }
            writeAtomicData(at: workspacesFile, data: data)
        }
    }

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

    @objc func exportAudit() {
        NSWorkspace.shared.open(URL(fileURLWithPath: historyFile))
    }

    @objc func openPolicy() {
        if !FileManager.default.fileExists(atPath: policyFile) {
            try? FileManager.default.createDirectory(atPath: islandDir, withIntermediateDirectories: true)
            let starter = """
            {
              "version": 1,
              "rules": []
            }
            """
            try? starter.write(toFile: policyFile, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: policyFile))
    }

    @objc func reviewChanges(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: String],
              let path = payload["path"], let base = payload["base"] else { return }

        let project = payload["project"] ?? URL(fileURLWithPath: path).lastPathComponent
        let request = payload["request"] ?? "Agent request"
        var diff = gitOutput(path: path, arguments: ["diff", "--no-ext-diff", "--no-color", "--unified=3", base, "--"])
        diff += untrackedPatch(path: path)
        let files = parseReviewFiles(diff)

        let window = changesWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Changes — \(project)"
        window.minSize = NSSize(width: 800, height: 500)
        window.isReleasedWhenClosed = false

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: window.contentView?.bounds ?? .zero, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.loadHTMLString(reviewHTML(project: project, request: request, files: files), baseURL: nil)
        window.contentView = webView

        if changesWindow == nil { window.center() }
        changesWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func untrackedPatch(path: String) -> String {
        let root = gitOutput(path: path, arguments: ["rev-parse", "--show-toplevel"])
        guard !root.isEmpty else { return "" }
        let names = gitOutput(path: path, arguments: ["ls-files", "--others", "--exclude-standard"])
            .split(separator: "\n").map(String.init)
        var patch = ""
        for name in names.prefix(100) {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
            let fileURL = rootURL.appendingPathComponent(name).standardizedFileURL
            guard fileURL.path.hasPrefix(rootURL.path + "/"),
                  let data = try? Data(contentsOf: fileURL), data.count <= 512_000 else { continue }
            guard let content = String(data: data, encoding: .utf8), !content.contains("\0") else { continue }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
            patch += "\ndiff --git a/\(name) b/\(name)\nnew file mode 100644\n--- /dev/null\n+++ b/\(name)\n@@ -0,0 +1,\(lines.count) @@\n"
            patch += lines.map { "+" + $0 }.joined(separator: "\n") + "\n"
        }
        return patch
    }

    func gitOutput(path: String, arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", path] + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return "Unable to read repository changes: \(error.localizedDescription)"
        }
    }

    func parseReviewFiles(_ patch: String) -> [ReviewFile] {
        let hunkPattern = try? NSRegularExpression(pattern: #"@@ -(\d+)(?:,\d+)? \+(\d+)"#)
        var files: [ReviewFile] = []
        var path = ""
        var additions = 0, deletions = 0
        var hunks: [ReviewHunk] = []
        var header = ""
        var rows: [ReviewRow] = []
        var oldLine = 0, newLine = 0
        var removed: [(Int, String)] = [], added: [(Int, String)] = []

        func flushBlock() {
            let count = max(removed.count, added.count)
            for index in 0..<count {
                let left = index < removed.count ? removed[index] : nil
                let right = index < added.count ? added[index] : nil
                rows.append(ReviewRow(oldNumber: left?.0, newNumber: right?.0, oldText: left?.1, newText: right?.1, kind: left != nil && right != nil ? "changed" : (left != nil ? "removed" : "added")))
            }
            removed.removeAll(); added.removeAll()
        }
        func flushHunk() {
            flushBlock()
            if !header.isEmpty { hunks.append(ReviewHunk(header: header, rows: rows)) }
            header = ""; rows.removeAll()
        }
        func flushFile() {
            flushHunk()
            if !path.isEmpty { files.append(ReviewFile(path: path, additions: additions, deletions: deletions, hunks: hunks)) }
            path = ""; additions = 0; deletions = 0; hunks.removeAll()
        }

        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                flushFile()
                if let range = line.range(of: " b/", options: .backwards) {
                    path = String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                }
            } else if line.hasPrefix("+++ b/") {
                path = String(line.dropFirst(6))
            } else if line.hasPrefix("@@") {
                flushHunk()
                header = line
                let ns = line as NSString
                if let match = hunkPattern?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), match.numberOfRanges >= 3 {
                    oldLine = Int(ns.substring(with: match.range(at: 1))) ?? 0
                    newLine = Int(ns.substring(with: match.range(at: 2))) ?? 0
                }
            } else if !header.isEmpty && line.hasPrefix("-") && !line.hasPrefix("---") {
                removed.append((oldLine, String(line.dropFirst()))); oldLine += 1; deletions += 1
            } else if !header.isEmpty && line.hasPrefix("+") && !line.hasPrefix("+++") {
                added.append((newLine, String(line.dropFirst()))); newLine += 1; additions += 1
            } else if !header.isEmpty && line.hasPrefix(" ") {
                flushBlock()
                let text = String(line.dropFirst())
                rows.append(ReviewRow(oldNumber: oldLine, newNumber: newLine, oldText: text, newText: text, kind: "context"))
                oldLine += 1; newLine += 1
            }
        }
        flushFile()
        return files
    }

    func reviewHTML(project: String, request: String, files: [ReviewFile]) -> String {
        let totalAdditions = files.reduce(0) { $0 + $1.additions }
        let totalDeletions = files.reduce(0) { $0 + $1.deletions }
        let navigation = files.enumerated().map { index, file in
            "<button class=\"file-link\" data-path=\"\(htmlEscape(file.path.lowercased()))\" onclick=\"document.getElementById('file-\(index)').scrollIntoView({behavior:'smooth'})\"><span>\(htmlEscape(file.path))</span><b class=\"adds\">+\(file.additions)</b><b class=\"dels\">−\(file.deletions)</b></button>"
        }.joined()
        let panels = files.enumerated().map { index, file in
            let hunks = file.hunks.map { hunk in
                let body = hunk.rows.map { row in
                    "<tr class=\"\(row.kind)\"><td class=\"ln\">\(row.oldNumber.map(String.init) ?? "")</td><td class=\"code old\">\(htmlEscape(row.oldText ?? ""))</td><td class=\"ln\">\(row.newNumber.map(String.init) ?? "")</td><td class=\"code new\">\(htmlEscape(row.newText ?? ""))</td></tr>"
                }.joined()
                return "<tr class=\"hunk\"><td colspan=\"4\">\(htmlEscape(hunk.header))</td></tr>" + body
            }.joined()
            return "<section class=\"file\" id=\"file-\(index)\"><header><span>⌄ &nbsp; \(htmlEscape(file.path))</span><span><b class=\"adds\">+\(file.additions)</b> <b class=\"dels\">−\(file.deletions)</b></span></header><div class=\"diff-scroll\"><table>\(hunks)</table></div></section>"
        }.joined()
        let empty = files.isEmpty ? "<div class=\"empty\"><h2>No changes found</h2><p>The workspace still matches its state before this request.</p></div>" : ""

        return """
        <!doctype html><html><head><meta charset="utf-8"><style>
        *{box-sizing:border-box}html,body{margin:0;height:100%;background:#0d1117;color:#d7dde5;font:13px -apple-system,BlinkMacSystemFont,sans-serif}body{overflow:hidden}.app{display:grid;grid-template-columns:290px 1fr;height:100%}aside{border-right:1px solid #30363d;background:#0b1016;padding:18px 14px;overflow:auto}.side-title{font-size:17px;font-weight:700;margin:2px 8px 14px}.search{width:100%;background:#111820;border:1px solid #3b4552;border-radius:8px;color:#d7dde5;padding:10px 12px;outline:none}.summary{color:#8b949e;margin:14px 8px 10px}.file-link{width:100%;display:grid;grid-template-columns:1fr auto auto;gap:7px;text-align:left;border:0;background:transparent;color:#c9d1d9;padding:9px 8px;border-radius:7px;cursor:pointer}.file-link:hover{background:#161f29}.file-link span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}main{overflow:auto;padding:0 24px 40px}.top{position:sticky;top:0;z-index:3;background:rgba(13,17,23,.94);backdrop-filter:blur(14px);padding:20px 0 16px;border-bottom:1px solid #21262d}.top h1{font-size:20px;margin:0 0 6px}.top p{color:#8b949e;margin:0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.file{margin-top:22px;border:1px solid #30363d;border-radius:10px;overflow:hidden;background:#0d1117}.file>header{display:flex;justify-content:space-between;padding:13px 16px;background:#111820;border-bottom:1px solid #30363d;font:600 13px ui-monospace,SFMono-Regular,Menlo,monospace}.adds{color:#3fb950}.dels{color:#f85149}.diff-scroll{overflow:auto}table{width:100%;min-width:980px;border-collapse:collapse;table-layout:fixed;font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,monospace}td{vertical-align:top}.ln{width:48px;padding:0 9px;text-align:right;color:#6e7681;background:#0b1016;border-right:1px solid #21262d;user-select:none}.code{width:calc(50% - 48px);padding:0 12px;white-space:pre;border-right:1px solid #30363d}.changed .old,.removed .old{background:#3f1d24}.changed .new,.added .new{background:#173b24}.removed .new,.added .old{background:#090d12}.hunk td{padding:5px 12px;background:#14213a;color:#8ab4f8;border-top:1px solid #23385f;border-bottom:1px solid #23385f}.empty{text-align:center;color:#8b949e;padding:120px 20px}.empty h2{color:#d7dde5}::-webkit-scrollbar{width:10px;height:10px}::-webkit-scrollbar-thumb{background:#30363d;border-radius:8px}
        </style></head><body><div class="app"><aside><div class="side-title">Changes</div><input class="search" placeholder="Search changed files" oninput="var q=this.value.toLowerCase();document.querySelectorAll('.file-link').forEach(function(x){x.style.display=x.dataset.path.includes(q)?'grid':'none'})"><div class="summary">\(files.count) files &nbsp; <b class="adds">+\(totalAdditions)</b> &nbsp; <b class="dels">−\(totalDeletions)</b></div>\(navigation)</aside><main><div class="top"><h1>\(htmlEscape(project))</h1><p>Request: \(htmlEscape(request))</p></div>\(empty)\(panels)</main></div></body></html>
        """
    }

    func htmlEscape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    @objc func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = MenuBarDelegate()
app.delegate = delegate
app.run()
