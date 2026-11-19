// One screen's wallpaper: a window on the desktop itself (above the picture, below the icons and
// every window, on every Space, out of the way of the mouse) with that screen's part of the tank
// drawn into it.

import AppKit
import MetalKit

final class Wallpaper: NSObject, MTKViewDelegate {
    let screenID: CGDirectDisplayID
    private let window: NSWindow
    private let view: MTKView
    let renderer: Renderer
    private var ticker: CADisplayLink?
    private(set) var visible = true
    var held = false { didSet { updatePause() } }       // paused from the menu, or for the battery
    var onTick: (() -> Void)?                           // asked to bring the tank up to date before each frame

    var screen: NSScreen? { NSScreen.screens.first { $0.displayID == screenID } }

    init(screen: NSScreen, device: MTLDevice, tank: Tank, index: Int) {
        screenID = screen.displayID
        // made where the screen is, at its size, from the start: a Metal view first made with no size, or
        // off every screen, shows nothing. (Given a screen, NSWindow takes the rect as relative to that
        // screen; without one, as in global coordinates, which is what screen.frame is.)
        let frame = screen.frame
        window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.ignoresMouseEvents = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.title = "Betta Lite"
        view = MTKView(frame: NSRect(origin: .zero, size: frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        view.isPaused = true                                          // we say when to draw: see tick()
        view.enableSetNeedsDisplay = false
        do {
            renderer = try Renderer(device: device, targetFormat: view.colorPixelFormat, tank: tank, screen: index)
        } catch {
            fatalError("could not build the shaders: \(error)")
        }
        super.init()
        view.delegate = self
        window.contentView = view
        fit()
        window.orderFront(nil)

        // nothing to draw while windows cover all of it, or the screen is asleep or locked
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                               queue: .main) { [weak self] _ in
            guard let self else { return }
            self.visible = self.window.occlusionState.contains(.visible)
            self.updatePause()
        }
        // 30 frames a second, asked of the display itself, so nothing wakes up for the frames in between
        let link = view.displayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        ticker = link
    }

    func close() {
        ticker?.invalidate()
        window.orderOut(nil)
    }

    private func updatePause() { ticker?.isPaused = held || !visible }

    /// cover the screen again (it may have moved or changed size)
    func fit() {
        guard let screen else { return }
        window.setFrame(screen.frame, display: false)
        view.frame = NSRect(origin: .zero, size: screen.frame.size)
        renderer.resize(Int(view.drawableSize.width), Int(view.drawableSize.height))
    }

    @objc private func tick() {
        onTick?()
        view.draw()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer.resize(Int(size.width), Int(size.height))
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cmd = renderer.queue.makeCommandBuffer() else { return }
        renderer.draw(into: drawable.texture, cmd)
        cmd.present(drawable)
        cmd.commit()
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
