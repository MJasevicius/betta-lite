// The app: one tank across the main screen (or every screen), a wallpaper on each, and the fish in
// the menu bar with everything you can change. It keeps the tank's clock, tells the fish what is
// going on around them (the time of day, the mouse, whether they are hungry, a tap on the glass),
// and pauses when told to, on battery or in Low Power Mode if asked.

import AppKit
import IOKit.ps
import MetalKit

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var device: MTLDevice!
    private var tank: Tank!
    private var walls: [Wallpaper] = []
    private var shape: [CGRect] = [], shapeRows = 0      // the screens and fish size the tank was laid out for
    private var status: NSStatusItem!
    private let settings = Settings.shared
    private var t: Time = 0, lastFrame = CACurrentMediaTime()
    private var lastMouse = NSPoint(x: -1, y: -1), mouseMovedAt = 0.0
    private var light = (night: 0.0, dawn: 0.0), hungry = false, clockCheckedAt = -1e9
    private var timer: Timer?, tapMonitor: Any?
    var printStats = true
    private var statFrames = 0, statFish = 0.0, statWall = CACurrentMediaTime(), statCPU = cpuSeconds()

    func applicationDidFinishLaunching(_ note: Notification) {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
        self.device = device
        settings.start()
        arrange()

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let fish = NSImage(systemSymbolName: "fish", accessibilityDescription: "Betta Lite") {
            fish.isTemplate = true
            status.button?.image = fish
        } else {
            status.button?.title = "🐟"
        }
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu

        settings.onChange = { [weak self] key in self?.changed(key) }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.arrange() }
        NotificationCenter.default.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil,
                                               queue: .main) { [weak self] _ in self?.checkPower() }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.checkPower() }
        timer?.tolerance = 5
        checkPower()
        // a click on the desktop is a tap on the glass
        tapMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in self?.tapped() }
        if printStats { print("Betta Lite · quit from the fish in the menu bar") }
    }

    // MARK: screens

    /// one tank over the screens it should be on, and a wallpaper on each
    private func arrange() {
        let wanted = settings.allScreens ? NSScreen.screens : Array(NSScreen.screens.prefix(1))
        guard !wanted.isEmpty else { return }
        let frames = wanted.map(\.frame), rows = settings.rows
        if tank == nil {
            tank = Tank(layout: Layout(screens: frames, fishRows: rows), seed: UInt64.random(in: 1...UInt64(UInt32.max)),
                        fish: settings.fishCount)
            if printStats { print("seed \(tank.seed)") }
        } else if frames != shape || rows != shapeRows {
            tank.relayout(Layout(screens: frames, fishRows: rows))
        }
        shape = frames; shapeRows = rows
        if printStats {
            let f = tank.layout.fish
            print("\(wanted.count) screen(s): \(f.regions.map { "\($0.cols) x \($0.rows)" }.joined(separator: ", ")) letters")
        }

        let ids = wanted.map(\.displayID)
        for w in walls where !ids.contains(w.screenID) { w.close() }
        walls.removeAll { !ids.contains($0.screenID) }
        for (i, screen) in wanted.enumerated() {
            if let w = walls.first(where: { $0.screenID == screen.displayID }) {
                w.renderer.screen = i
                w.fit()
            } else {
                let w = Wallpaper(screen: screen, device: device, tank: tank, index: i)
                w.onTick = { [weak self] in self?.tick() }
                walls.append(w)
            }
        }
        apply()
        checkPower()
    }

    /// take on the settings that need nothing rebuilt
    private func apply() {
        let s = settings
        tank.allowedPalettes = { s.allowedPalettes() }
        tank.fill = fillLetters(LETTER_SETS[min(max(s.letters, 0), LETTER_SETS.count - 1)].pools)
        tank.colourEvery = s.colourEvery
        tank.seabed = s.seabed
        tank.surface = s.surface
        tank.company = s.company
        tank.setCount(s.fishCount)
        for w in walls {
            let r = w.renderer
            r.glow = Float(s.glow)
            r.trail = Float(s.trail)
            r.font = s.font
            r.rays = Float(s.rays)
            r.caustics = Float(s.caustics)
            r.vignette = s.vignette
        }
    }

    private func changed(_ key: String) {
        switch key {
        case "allScreens", "rows": arrange()
        case "paused", "pauseOnBattery", "pauseLowPower": checkPower()
        case "colourMode", "favourites", "fixedSet": apply(); tank.bettas.forEach { $0.recolour() }
        case "dayNight", "sunrise", "sunset", "hunger", "lastFed": clockCheckedAt = -1e9
        default: apply()
        }
    }

    // MARK: the tank's clock

    /// bring the tank up to the present: once for all the screens, however many ask
    private func tick() {
        let now = CACurrentMediaTime()
        guard now - lastFrame > 1.0 / 45 else { return }
        t += min(now - lastFrame, 1.0 / 15)
        lastFrame = now
        surround(now)
        tank.seen = (0..<tank.layout.screens.count).map { i in walls.first { $0.renderer.screen == i }?.visible ?? false }
        let c0 = threadSeconds()
        tank.frame(t)
        statFish += threadSeconds() - c0
        for w in walls {
            w.renderer.time = Float(t.truncatingRemainder(dividingBy: 10_000))
            w.renderer.brightness = Float(1 - 0.45 * light.night)
            w.renderer.dawn = Float(light.dawn)
        }

        statFrames += 1
        let wall = now - statWall
        if wall >= 5 {
            let cpu = cpuSeconds()
            if printStats {
                print(String(format: "%.0f fps · fish %.2f ms/frame · whole app %.1f%% of one CPU core",
                             Double(statFrames) / wall, statFish / Double(max(statFrames, 1)) * 1000, (cpu - statCPU) / wall * 100))
            }
            statFrames = 0; statFish = 0; statWall = now; statCPU = cpu
        }
    }

    /// what is going on around the fish
    private func surround(_ now: Double) {
        if now - clockCheckedAt > 30 {
            light = settings.light()
            hungry = settings.hungry() && light.night < 0.5             // asleep, it does not beg
            clockCheckedAt = now
        }
        let mouse = NSEvent.mouseLocation
        if mouse != lastMouse { lastMouse = mouse; mouseMovedAt = now }
        var s = Surroundings()
        s.mood = Mood(pace: settings.pace, night: light.night, habits: settings.habits, hungry: hungry)
        s.mouse = tank.water(at: mouse)?.p
        s.mouseMoving = now - mouseMovedAt < 1.5
        s.reaction = settings.mouse
        tank.surroundings = s
    }

    // MARK: a tap on the glass

    private func tapped() {
        guard settings.tapGlass, let tank, walls.contains(where: { !$0.held && $0.visible }) else { return }
        let p = NSEvent.mouseLocation
        guard let at = tank.water(at: p), onDesktop(p) else { return }
        tank.tap(at: at.p, screen: at.screen)
    }

    /// whether a point of the screens is bare desktop: not in the menu bar or the Dock, nor on any window
    /// or widget (desktop icons are fine: they are on the glass)
    private func onDesktop(_ p: NSPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(p) }), screen.visibleFrame.contains(p) else {
            return false
        }
        let q = CGPoint(x: p.x, y: NSScreen.screens[0].frame.maxY - p.y)            // the window list's corner is top left
        let me = Int(getpid())
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < 20,         // the Dock, menus and overlays are higher
                  (w[kCGWindowOwnerPID as String] as? Int) != me,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            if r.contains(q) { return false }
        }
        return true
    }

    // MARK: power

    private func checkPower() {
        var hold = settings.paused
        if settings.pauseLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { hold = true }
        if settings.pauseOnBattery && onBattery() { hold = true }
        walls.forEach { $0.held = hold }
    }

    private func onBattery() -> Bool {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        guard let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPMBatteryPowerKey
    }

    // MARK: open at login

    private var agent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/io.github.mjasevicius.betta-lite.plist")
    }
    private var opensAtLogin: Bool { FileManager.default.fileExists(atPath: agent.path) }

    private func setOpensAtLogin(_ on: Bool) {
        if on {
            let me = Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": "io.github.mjasevicius.betta-lite",
                "ProgramArguments": [me],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "LimitLoadToSessionType": "Aqua",
            ]
            try? FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: agent, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: agent)
        }
    }

    // MARK: the menu

    private final class Action: NSMenuItem {
        var run: () -> Void = {}
        @objc func fire() { run() }
    }

    private func item(_ title: String, on: Bool = false, _ run: @escaping () -> Void) -> NSMenuItem {
        let i = Action(title: title, action: #selector(Action.fire), keyEquivalent: "")
        i.target = i
        i.run = run
        i.state = on ? .on : .off
        return i
    }

    private func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu()
        items.forEach { m.addItem($0) }
        i.submenu = m
        return i
    }

    private func choose<T: Equatable>(_ title: String, _ options: [(String, T)], _ current: T, _ set: @escaping (T) -> Void) -> NSMenuItem {
        sub(title, options.map { o in item(o.0, on: o.1 == current) { set(o.1) } })
    }

    private func header(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func hour(_ h: Double) -> String { String(format: "%d:00", Int(h) % 24) }

    private func ago(_ date: Date) -> String {
        let m = Int(Date().timeIntervalSince(date) / 60)
        if m < 1 { return "just now" }
        if m < 60 { return "\(m) minute\(m == 1 ? "" : "s") ago" }
        let h = m / 60
        if h < 48 { return "\(h) hour\(h == 1 ? "" : "s") ago" }
        return "\(h / 24) days ago"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let s = settings
        menu.removeAllItems()
        menu.addItem(header("Betta Lite"))
        menu.addItem(item(s.paused ? "Resume" : "Pause") { s.paused.toggle() })
        let starving = s.hungry()
        menu.addItem(item(starving ? (s.fishCount > 1 ? "Feed (They're Hungry)" : "Feed (It's Hungry)") : "Feed") { [weak self] in
            self?.tank.feed()
            s.lastFed = Date()
        })

        menu.addItem(.separator())
        menu.addItem(header("Look"))
        menu.addItem(choose("Fish Size", [("Small", 160), ("Medium", 128), ("Large", 104)], s.rows) { s.rows = $0 })
        let sets = PALETTE_NAMES.enumerated()
        menu.addItem(sub("Colours", [
            item("Change Through All Sets", on: s.colourMode == .all) { s.colourMode = .all },
            item("Change Through Favourites", on: s.colourMode == .favourites) { s.colourMode = .favourites },
            item("Follow the Time of Day", on: s.colourMode == .timeOfDay) { s.colourMode = .timeOfDay },
            sub("Keep One Set", sets.map { i, name in
                item(name, on: s.colourMode == .fixed && s.fixedSet == i) { s.fixedSet = i; s.colourMode = .fixed }
            }),
            .separator(),
            sub("Favourites", sets.map { i, name in
                item(name, on: s.favourites.contains(i)) {
                    var f = s.favourites
                    if f.contains(i) { f.remove(i) } else { f.insert(i) }
                    s.favourites = f
                }
            }),
            choose("New Colours Every", [("2 Seconds (Original)", 2.0), ("8 Seconds", 8.0), ("30 Seconds", 30.0),
                                         ("2 Minutes", 120.0)], s.colourEvery) { s.colourEvery = $0 },
        ]))
        menu.addItem(choose("Glow", [("Off", 0.0), ("Soft", 0.5), ("Normal", 1.0), ("Strong", 1.6)], s.glow) { s.glow = $0 })
        menu.addItem(choose("Trail", [("Off", 0.0), ("Short", 0.3), ("Normal", 0.5), ("Long", 0.75)], s.trail) { s.trail = $0 })
        menu.addItem(sub("Letters", [header("Font")] + FONTS.map { f in item(f, on: s.font == f) { s.font = f } }
                         + [.separator(), header("Fill")]
                         + LETTER_SETS.enumerated().map { i, set in item(set.name, on: s.letters == i) { s.letters = i } }))
        menu.addItem(sub("Water", [
            choose("Light Rays", [("Off", 0.0), ("Faint", 0.5), ("Normal", 1.0), ("Strong", 1.8), ("Very Strong", 3.0)], s.rays) {
                s.rays = $0
            },
            choose("Caustics", [("Off", 0.0), ("Soft", 0.5), ("Normal", 1.0), ("Strong", 1.8)], s.caustics) { s.caustics = $0 },
            .separator(),
            item("Water Surface", on: s.surface) { s.surface.toggle() },
            item("Sand and Plants", on: s.seabed) { s.seabed.toggle() },
            item("Darker Edges", on: s.vignette) { s.vignette.toggle() },
        ]))

        menu.addItem(.separator())
        menu.addItem(header("Behaviour"))
        menu.addItem(choose("Number of Fish", (1...MAX_FISH).map { ("\($0)", $0) }, s.fishCount) { s.fishCount = $0 })
        menu.addItem(item("Betta Habits (Bubble Nest, Air, Flaring)", on: s.habits) { s.habits.toggle() })
        menu.addItem(choose("Pace", [("Lively", 0), ("Calm", 1), ("Very Calm", 2)], s.pace) { s.pace = $0 })
        menu.addItem(choose("Mouse", [("Ignore It", Reaction.ignore), ("Curious", .curious), ("Shy", .shy)], s.mouse) { s.mouse = $0 })
        menu.addItem(item("Tap the Glass (Click the Desktop)", on: s.tapGlass) { s.tapGlass.toggle() })
        menu.addItem(sub("Gets Hungry", [
            item("Never", on: s.hunger == 0) { s.hunger = 0 },
            item("After 6 Hours Without Food", on: s.hunger == 6) { s.hunger = 6 },
            item("After 12 Hours Without Food", on: s.hunger == 12) { s.hunger = 12 },
            item("After a Day Without Food", on: s.hunger == 24) { s.hunger = 24 },
            .separator(),
            header("Last fed \(ago(s.lastFed))"),
        ]))
        menu.addItem(sub("Day and Night", [
            item("Sunrise and Sunset", on: s.dayNight) { s.dayNight.toggle() },
            header("Golden light as the lights come up and go down; dim and sleepy at night"),
            .separator(),
            choose("Sunrise", (5...9).map { (hour(Double($0)), Double($0)) }, s.sunrise) { s.sunrise = $0 },
            choose("Sunset", (20...24).map { (hour(Double($0)), Double($0)) }, s.sunset) { s.sunset = $0 },
        ]))
        menu.addItem(item("Tank Mates (Neon Tetras)", on: s.company) { s.company.toggle() })

        menu.addItem(.separator())
        menu.addItem(item("One Tank Across All Screens", on: s.allScreens) { s.allScreens.toggle() })
        menu.addItem(item("Pause on Battery", on: s.pauseOnBattery) { s.pauseOnBattery.toggle() })
        menu.addItem(item("Pause in Low Power Mode", on: s.pauseLowPower) { s.pauseLowPower.toggle() })
        menu.addItem(item("Open at Login", on: opensAtLogin) { [weak self] in
            guard let self else { return }
            self.setOpensAtLogin(!self.opensAtLogin)
        })

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Betta Lite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }
}
