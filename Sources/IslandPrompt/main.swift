// island-prompt.swift — a Dynamic Island-style approve/disapprove prompt at the MacBook notch.
//
// Usage:   island-prompt "Bash: rm -rf /tmp/build"   [--timeout 30]
// Prints:  "Approve" | "Disapprove"  to stdout, or nothing on timeout/dismiss.
// Build:   swiftc -O -o island-prompt island-prompt.swift -framework SwiftUI -framework AppKit
//
// Faceless GUI (no Dock icon). Renders a black pill hanging under the notch,
// springs open with the request + two buttons, returns the click, exits.

import SwiftUI
import AppKit
import SudoorCore

// MARK: - Args
let rawArgs = Array(CommandLine.arguments.dropFirst())
var message = "Claude wants to run a tool"
var source = ""                 // which terminal is asking: "Terminal · project · ttys003"
var timeout: Double = 30
do {
    var i = 0
    var msgParts: [String] = []
    while i < rawArgs.count {
        let a = rawArgs[i]
        if a == "--timeout", i + 1 < rawArgs.count { timeout = clampTimeout(Double(rawArgs[i + 1]) ?? 30); i += 2; continue }
        if a == "--source",  i + 1 < rawArgs.count { source = rawArgs[i + 1]; i += 2; continue }
        msgParts.append(a); i += 1
    }
    if !msgParts.isEmpty { message = msgParts.joined(separator: " ") }
}
timeout = clampTimeout(timeout)

// MARK: - Decision plumbing
let decisionGate = DecisionGate()

func decide(_ value: String?) -> Never {
    decisionGate.runOnce {
        if let v = value { FileHandle.standardOutput.write(Data((v + "\n").utf8)) }
    }
    NSApplication.shared.terminate(nil)
    exit(0)
}

// MARK: - Island shape
// Flush, square top edge so it merges seamlessly with the notch above;
// only the bottom corners round off, so the pill hangs out of the notch.
struct IslandShape: Shape {
    var bottomRadius: CGFloat = 30
    func path(in rect: CGRect) -> Path {
        let br = min(bottomRadius, rect.width / 2, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))            // top-left (square)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))         // top edge → top-right (square)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))    // right side
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br),
                 radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)   // bottom-right
        p.addLine(to: CGPoint(x: rect.minX + br, y: rect.maxY))    // bottom edge
        p.addArc(center: CGPoint(x: rect.minX + br, y: rect.maxY - br),
                 radius: br, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false) // bottom-left
        p.closeSubpath()
        return p
    }
}

// MARK: - Island view
struct IslandView: View {
    let title: String
    let detail: String
    let source: String
    let timeout: Double
    let onDecision: (String?) -> Void   // "Approve" | "Disapprove" | nil(timeout)

    // Genie state: scale is anchored at the notch (top). We animate width and
    // height independently — thin tall "stream" out of the notch, then widen.
    @State private var scaleX: CGFloat = 0.12
    @State private var scaleY: CGFloat = 0.02
    @State private var opacity: Double = 0
    @State private var streaming = true     // blur on while pouring out
    @State private var dismissing = false
    @State private var hoverApprove = false
    @State private var hoverDeny = false

    // Genie OUT: pull narrow, then suck back up into the notch, then decide.
    func genieDismiss(_ value: String?) {
        guard !dismissing else { return }
        dismissing = true
        streaming = true
        withAnimation(.easeIn(duration: 0.16)) { scaleX = 0.18; scaleY = 1.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            withAnimation(.easeIn(duration: 0.20)) { scaleX = 0.10; scaleY = 0.0; opacity = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { onDecision(value) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The pill hugs the notch from the top, drapes downward.
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }

                // Which terminal window is asking — the prominent identifier.
                if !source.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(source)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.13))
                    .clipShape(Capsule())
                }

                // The actual command / file being requested.
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button(action: { genieDismiss("Disapprove") }) {
                        Text("Disapprove")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(hoverDeny ? 0.16 : 0.10))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverDeny = $0 }

                    Button(action: { genieDismiss("Approve") }) {
                        Text("Approve")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Color.white.opacity(hoverApprove ? 1.0 : 0.92))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverApprove = $0 }
                }
            }
            .padding(.horizontal, 34)
            .padding(.top, 26)
            .padding(.bottom, 28)
            .frame(width: 400)
            .background(Color.black)
            .clipShape(IslandShape())
            .overlay(
                IslandShape().stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
            .blur(radius: streaming ? 4 : 0)
            .scaleEffect(CGSize(width: scaleX, height: scaleY), anchor: .top)
            .opacity(opacity)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // Genie IN: thin tall stream out of the notch …
            withAnimation(.easeOut(duration: 0.18)) {
                scaleX = 0.18; scaleY = 1.06; opacity = 1
            }
            // … then widen and settle with a soft bounce.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                streaming = false
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    scaleX = 1; scaleY = 1
                }
            }
            // Timeout → genie back into the notch, then defer to CLI.
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                genieDismiss(nil)
            }
        }
    }
}

// MARK: - App / window
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Prefer the notched (built-in) screen.
        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main!
        let f = screen.frame

        let title = "Claude needs permission"
        let detail = message

        let host = NSHostingView(rootView: IslandView(
            title: title, detail: detail, source: source, timeout: timeout,
            onDecision: { decide($0) }
        ))

        let w: CGFloat = 400, h: CGFloat = 240
        // Centered horizontally; top edge flush with the very top of the screen
        // so the pill appears to hang out of the notch.
        let x = f.midX - w / 2
        let y = f.maxY - h
        let rect = NSRect(x: x, y: y, width: w, height: h)

        window = NSWindow(contentRect: rect, styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        // Above the menu bar / notch so the pill is never clipped.
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.contentView = host
        window.setFrame(rect, display: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Make the helper active so the buttons are clickable on the first click.
        NSApp.activate(ignoringOtherApps: true)
        // (Timeout is owned by the view so it can play the genie-out animation.)

        // Backstop: if our parent (the permission hook) goes away — e.g. Claude
        // resolved the request in the terminal and tore the hook down — there's
        // nothing left to approve. Self-dismiss instead of hanging at the notch
        // until the timeout. (A follow-up same-session request also kills us via
        // the hook; this covers the orphaned-with-no-follow-up case.)
        let bornPPID = getppid()
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { t in
            if getppid() != bornPPID {   // reparented → parent hook is gone
                t.invalidate()
                decide(nil)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
