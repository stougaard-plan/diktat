import AppKit
import SwiftUI

/// Synlig markering under optagelse: rød prik i menulinjen med tid, og et sort panel i bunden
/// med to niveaumålere og stopknap. Kan ikke skjules, mens der optages.
@MainActor
final class MeetingIndicator {
    static let shared = MeetingIndicator()

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var timer: Timer?

    func show() {
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let menu = NSMenu()
            let stop = NSMenuItem(title: "Stop mødeoptagelse", action: #selector(stopFromMenu), keyEquivalent: "")
            stop.target = self
            menu.addItem(stop)
            item.menu = menu
            statusItem = item
        }
        if panel == nil { panel = makePanel() }
        panel?.orderFrontRegardless()
        updateStatusTitle()
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateStatusTitle() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        playSound("Tink")
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        playSound("Pop")
    }

    @objc private func stopFromMenu() { MeetingRecorder.shared.stop() }

    private func updateStatusTitle() {
        let recorder = MeetingRecorder.shared
        let text = Self.format(recorder.elapsed)
        let hasProblem = !recorder.problems.isEmpty
        let attributed = NSMutableAttributedString(
            string: hasProblem ? "⚠ " : "● ",
            attributes: [.foregroundColor: hasProblem ? NSColor.systemOrange : NSColor.systemRed])
        attributed.append(
            NSAttributedString(
                string: text, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)]))
        statusItem?.button?.attributedTitle = attributed
        resizePanel(problemLines: min(3, recorder.problems.count))
    }

    /// Panelet vokser nedad fra bunden, når der er problemer, så fejlteksten altid kan læses.
    private func resizePanel(problemLines: Int) {
        guard let panel else { return }
        let height = Self.panelHeight(problemLines: problemLines)
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    static func panelHeight(problemLines: Int) -> CGFloat { 64 + CGFloat(problemLines) * 30 }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 360, height: 64)
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.sharingType = .none  // ikke synlig ved skærmdeling
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: MeetingPanelView())
        if let screen = RecorderScreenResolver.resolve() {
            let x = screen.frame.midX - size.width / 2
            let y = screen.frame.minY + 48
            p.setFrameOrigin(NSPoint(x: x, y: y))
        }
        return p
    }
}

struct MeetingLevelBar: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(Color.white)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, level * 6))))
                }
            }
            .frame(height: 4)
        }
    }
}

struct MeetingPanelView: View {
    @ObservedObject private var recorder = MeetingRecorder.shared

    var body: some View {
        let problems = recorder.problems
        VStack(spacing: 6) {
        HStack(spacing: 14) {
            Circle().fill(problems.isEmpty ? Color.red : Color.orange).frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 5) {
                Text("Optager møde  \(MeetingIndicator.format(recorder.elapsed))")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                MeetingLevelBar(label: "Mikrofon", level: recorder.micLevel)
                MeetingLevelBar(label: "Computer", level: recorder.computerLevel)
            }
            Button {
                recorder.stop()
            } label: {
                Image(systemName: "stop.fill").font(.system(size: 12)).foregroundStyle(.white)
                    .frame(width: 30, height: 30).background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(.plain)
            .help("Stop mødeoptagelse")
        }
        .frame(height: 64 - 12)
        ForEach(Array(problems.prefix(3).enumerated()), id: \.offset) { _, text in
            Text("⚠ " + text)
                .font(.system(size: 11)).foregroundStyle(Color.orange)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        }
        .padding(.horizontal, 16)
        .frame(width: 360, height: MeetingIndicator.panelHeight(problemLines: min(3, problems.count)), alignment: .top)
        .padding(.top, 0)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(red: 0.06, green: 0.06, blue: 0.06)))
    }

}

/// Lyd afspilles uden for hovedtråden. Et hængende lydkort må aldrig stoppe optagelsen.
private func playSound(_ name: String) {
    DispatchQueue.global(qos: .utility).async { NSSound(named: name)?.play() }
}
