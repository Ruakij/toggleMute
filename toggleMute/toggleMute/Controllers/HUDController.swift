// Author: Sascha Petrik

import Cocoa

/// A small always-on-top overlay, similar in spirit to the system volume/
/// brightness HUD, that briefly shows whether the mic just got muted or
/// unmuted. Purely visual — never intercepts clicks (ignoresMouseEvents).
final class HUDController {

    static let shared = HUDController()

    private var panel: NSPanel?
    private var imageView: NSImageView?
    private var dismissWorkItem: DispatchWorkItem?

    private let size = NSSize(width: 64, height: 64)
    private let displayDuration: TimeInterval = 1.0
    private let fadeDuration: TimeInterval = 0.25
    private let screenMarginTop: CGFloat = 10
    private let screenMarginRight: CGFloat = 16

    private init() {}


    /// - Parameter sticky: When true, the HUD is shown but no auto-dismiss
    ///   timer is armed — used while push-to-talk is being held down, so it
    ///   stays on screen for as long as the key/icon is pressed. A later
    ///   non-sticky call (the PTT release) re-arms the normal fade-out.
    /// - Parameter red: When true (and muted), tints the icon
    ///   MuteController.redColor instead of white — mirrors the optional red
    ///   menu bar icon.
    func show(muted: Bool, sticky: Bool = false, red: Bool = false) {

        DispatchQueue.main.async { [weak self] in
            self?.present(muted: muted, sticky: sticky, red: red)
        }

    }


    /// Fades the HUD out immediately, regardless of whether it's currently
    /// sticky. Used when "Always show HUD" gets turned off while the
    /// permanent HUD is on screen — otherwise it would just sit there until
    /// the next mute/unmute event happened to re-arm the fade timer.
    func hide() {

        DispatchQueue.main.async { [weak self] in
            self?.dismissWorkItem?.cancel()
            self?.dismissWorkItem = nil
            self?.fadeOutAndHide()
        }

    }


    private func present(muted: Bool, sticky: Bool, red: Bool) {

        dismissWorkItem?.cancel()
        dismissWorkItem = nil

        let panel = panelInstance()
        positionTopRight(panel)

        imageView?.image = symbolImage(muted: muted)
        imageView?.contentTintColor = (muted && red) ? MuteController.redColor : .white

        panel.alphaValue = 1
        panel.orderFrontRegardless()

        guard !sticky else { return }

        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOutAndHide()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + displayDuration, execute: workItem)

    }


    private func panelInstance() -> NSPanel {

        if let panel = panel {
            return panel
        }

        let newPanel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .statusBar
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        newPanel.isReleasedWhenClosed = false

        let newImageView = NSImageView(frame: NSRect(x: 16, y: 16, width: 32, height: 32))
        newImageView.imageScaling = .scaleProportionallyUpOrDown
        // The rendered image is a template (see symbolImage(muted:)); this
        // tint is what actually makes it white/red — see present(muted:sticky:red:).
        newImageView.contentTintColor = .white

        let effectView = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 24
        effectView.layer?.masksToBounds = true

        effectView.addSubview(newImageView)
        newPanel.contentView = effectView

        panel = newPanel
        imageView = newImageView

        return newPanel

    }


    private func symbolImage(muted: Bool) -> NSImage? {

        // Always draw the same "mic" glyph — mic vs mic.slash are two
        // metrics, which visibly shifted the icon between states. Drawing a
        // fixed diagonal strike-through ourselves on mute keeps the mic body
        // pixel-identical between both states; only the line is added.
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .medium)

        guard let mic = NSImage(systemSymbolName: "mic", accessibilityDescription: muted ? "Muted" : "Unmuted")?
            .withSymbolConfiguration(config) else { return nil }

        let canvasSize = NSSize(width: 48, height: 48)
        let canvas = NSImage(size: canvasSize)

        canvas.lockFocus()

        let micSize = mic.size
        let micOrigin = NSPoint(
            x: (canvasSize.width - micSize.width) / 2,
            y: (canvasSize.height - micSize.height) / 2
        )
        mic.draw(at: micOrigin, from: .zero, operation: .sourceOver, fraction: 1.0)

        if muted {
            let line = NSBezierPath()
            line.lineWidth = 2
            line.lineCapStyle = .round
            line.move(to: NSPoint(x: 32, y: 18))
            line.line(to: NSPoint(x: canvasSize.width - 31, y: canvasSize.height - 16))
            NSColor.black.setStroke()
            line.stroke()
        }

        canvas.unlockFocus()

        // Re-mark as a template so contentTintColor (set on the image view)
        // tints the whole thing uniformly — lockFocus drawing bakes in flat
        // pixels and clears this flag, which is why the icon rendered black
        // instead of adapting like the other HUDs.
        canvas.isTemplate = true

        return canvas

    }


    private func positionTopRight(_ panel: NSPanel) {

        // NSScreen.main can transiently be nil very early in a background
        // (LSUIElement) app's lifecycle — before the window server has
        // fully registered it, since there's no window to anchor to yet.
        // This is most likely to bite on the very first HUD trigger right
        // after a cold launch. Falling back to the first available screen
        // (rather than silently skipping positioning, which left the panel
        // shown at its default near-origin position) keeps the HUD visible
        // and correctly placed even in that race.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let x = screen.visibleFrame.maxX - size.width - screenMarginRight
        let y = screen.visibleFrame.maxY - size.height - screenMarginTop

        panel.setFrameOrigin(NSPoint(x: x, y: y))

    }


    private func fadeOutAndHide() {

        guard let panel = panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fadeDuration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })

    }

}
