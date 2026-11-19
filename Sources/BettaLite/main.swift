// Betta Lite, in Swift and Metal. Adapted from betta_fish.py by @dwcminh.ascii.
//
//   swift run -c release                         the wallpaper (everything else: the fish in the menu bar)
//   ./make-app.sh                                the same as an app, in ~/Applications
//   .build/release/BettaLite --bench             how long the CPU takes per frame
//   ... --snap 300,900 --out DIR [--seed N]      render those frames (30 a second) to PNGs, offscreen
//   ... --path MINUTES [--seed N] [--fish N]     swim that long without drawing; check they stay on screen
//   ... --dump SECONDS FILE                      the raw 113 x 103 grid of one frame (to compare with the Python)
//   ... --icon FILE                              the app's icon, drawn by the fish, 1024 x 1024

import AppKit
import Darwin
import MetalKit

let ROWS = 128                                  // rows of letters on a screen (the menu's Medium)

func cpuSeconds() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

func threadSeconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

/// as many columns as fit beside `rows` rows on a screen this shape, the cells kept 7 wide to 10 tall
func columns(for rows: Int, width: Double, height: Double) -> Int {
    Int((Double(rows) * width / height * Double(CELL_H) / Double(CELL_W)).rounded())
}

// MARK: - tools for checking

let args = CommandLine.arguments
func arg(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
let toolSeed = UInt64(arg("--seed") ?? "1") ?? 1
let toolRows = Int(arg("--rows") ?? "") ?? ROWS
let toolCols = Int(arg("--cols") ?? "") ?? columns(for: toolRows, width: 3456, height: 2234)   // a 16-inch MacBook Pro's screen
let toolFish = Int(arg("--fish") ?? "1") ?? 1

/// the tank the tools look at: a laptop's screen, or with --two, with a bigger one beside it and a little higher
func toolTank(bubbles: Bool = true) -> Tank {
    let layout = flag("--here")
        ? Layout(screens: NSScreen.screens.map(\.frame), fishRows: toolRows)
        : flag("--two")
        ? Layout(screens: [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: 1728, y: 100, width: 2560, height: 1440)],
                 fishRows: toolRows)
        : Layout.single(cols: toolCols, rows: toolRows)
    let tank = Tank(layout: layout, seed: toolSeed, fish: toolFish, bubbles: bubbles)
    tank.seabed = flag("--seabed")
    tank.surface = flag("--surface")
    tank.company = flag("--company")
    return tank
}

func bench() {
    let tank = toolTank()
    for i in 0..<420 { tank.frame(Time(i) / 30) }                   // the build-up (every fish's), and warm
    let start = threadSeconds()
    let frames = 900
    for i in 420..<(420 + frames) { tank.frame(Time(i) / 30) }      // 30 s of swimming
    let per = (threadSeconds() - start) / Double(frames)
    print(String(format: "%d fish, %d x %d: %.2f ms of CPU per frame -> %.1f%% of one core at 30 fps",
                 tank.bettas.count, tank.cols, tank.rows, per * 1000, per * 30 * 100))
}

func path(_ minutes: Double) {
    // swim a while, frame by frame, and see how far the fish ever reached towards each edge
    // (with --feed, dropping pellets every minute; --tap, tapping the glass every minute; --night,
    // deep in the night; --hungry, hungry all the time)
    let tank = toolTank()
    var mood = Mood()
    mood.night = flag("--night") ? 1 : 0
    mood.hungry = flag("--hungry")
    tank.surroundings.mood = mood
    var worst: (left: R, right: R, up: R, down: R) = (0, 0, 0, 0)
    var outside = 0, looking = 0, crossings = 0, offWhile = [String: Int]()
    var lastArea = tank.bettas.map { _ in 0 }
    var gulpMouth = [Double](), gulpTop = [Double]()
    let frames = Int(minutes * 60 * 30)
    var tapRng = SplitMix(toolSeed, 9)
    // smoothness: how much its nose tips, and its speed changes, from one frame to the next
    var lastTip = tank.bettas.map { _ in Double.nan }, lastV = tank.bettas.map { _ in P2.zero }
    var tipJumps = [String: Int](), worstTip = 0.0, kicks = [String: Int]()
    var flee = tank.bettas.map { _ in (peak: 0.0, stopped: false, dips: 0) }, fleeDips = 0, flees = 0
    for i in 0..<frames {
        if flag("--feed") && i % 1800 == 600 { tank.feed() }
        if flag("--tap") && i % 1800 == 1200 {
            let a = tank.areas[0]
            tank.tap(at: P2(tapRng.range(a.left, a.right), tapRng.range(a.bottom, a.top)), screen: 0)
        }
        tank.frame(Time(i) / 30)
        for (k, b) in tank.bettas.enumerated() where b.swimming {
            let ps = pose(b.lt, b.motion), tip = atan2(Double(ps[1]), Double(ps[0]))
            let kind0 = b.motion.kind(b.lt), what = "\(kind0.kind)/\(kind0.purpose)"
            if !lastTip[k].isNaN {
                let d = abs(tip - lastTip[k])
                worstTip = max(worstTip, d)
                if d > 0.04 { tipJumps[what, default: 0] += 1 }
            }
            lastTip[k] = tip
            let v = b.motion.velocity(b.lt)
            if simd_length(v - lastV[k]) > 0.08 { kicks[what, default: 0] += 1 }
            lastV[k] = v
            // a flight from a tap: one burst, or does it stop and go again?
            let sp = simd_length(v)
            if kind0.purpose == .flee {
                if flee[k].peak == 0 { flees += 1 }
                flee[k].peak = max(flee[k].peak, sp)
                if flee[k].peak > 0.4 && sp < 0.25 * flee[k].peak { flee[k].stopped = true }
                else if flee[k].stopped && sp > 0.5 * flee[k].peak { flee[k].dips += 1; flee[k].stopped = false; fleeDips += 1 }
            } else { flee[k] = (0, false, 0) }
            let r = b.reach()
            worst = (max(worst.left, r.left), max(worst.right, r.right), max(worst.up, r.up), max(worst.down, r.down))
            let kind = b.motion.kind(b.lt)
            if kind.kind == .look { looking += 1 }
            let a = b.motion.area(b.anchor)
            if a != lastArea[k] { crossings += 1; lastArea[k] = a }
            if kind.kind == .gulp && b.lt - kind.t0 > 0.2 && b.lt - kind.t0 < 0.4 {
                // at the top of a gulp: how its mouth and the highest point of it lie against the surface
                let surface = tank.areas[a].surface
                gulpMouth.append(Double(b.lastMouth.y) - surface)
                var top = R.infinity
                for j in b.pointsFrom..<b.pointsTo { top = min(top, tank.points.SY[j]) }
                gulpTop.append(-(Double(top) - Double(tank.originY)) * Water.depth / Double(Water.scaleY) - surface)
            }
        }
        if tank.offScreen() {
            outside += 1
            for b in tank.bettas where b.alive { offWhile["\(b.motion.kind(b.lt).kind)/\(b.motion.kind(b.lt).purpose)", default: 0] += 1 }
        }
    }
    print(String(format: "%d fish, %.0f min: reached %.0f left, %.0f right, %.0f up, %.0f down (cells from a middle); "
                 + "frames with some fish off every screen: %d of %d", tank.bettas.count, minutes,
                 worst.left, worst.right, worst.up, worst.down, outside, frames))
    var done = [String: Int]()
    for b in tank.bettas { for (k, v) in b.done { done[k, default: 0] += v } }
    print("they did:", done.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
    print(String(format: "time spent looking out of the glass: %.0f%%; crossings between screens: %d",
                 100 * Double(looking) / Double(frames * tank.bettas.count), crossings))
    print("where they are at the end:", tank.bettas.map { b in String(format: "(%.2f, %.2f) born %.1f", b.anchor.x, b.anchor.y, b.born) }.joined(separator: ", "))
    if !offWhile.isEmpty { print("off screen while:", offWhile.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")) }
    print(String(format: "smoothness: worst nose tip change in a frame %.3f rad; frames over 0.04: %@; speed kicks: %@; flights %d, stopping and going again %d",
                 worstTip, tipJumps.description, kicks.description, flees, fleeDips))
    if !gulpMouth.isEmpty {
        print(String(format: "at the top of a gulp, against the surface: mouth %.2f ... %.2f, highest point %.2f ... %.2f (units)",
                     gulpMouth.min()!, gulpMouth.max()!, gulpTop.min()!, gulpTop.max()!))
    }
}

func dump(_ t: Time, _ file: String) {
    let tank = Tank(layout: .single(cols: 113, rows: 103), seed: toolSeed, fish: 1, bubbles: false)
    tank.frame(t)
    var data = Data()
    let n = tank.cols * tank.rows
    data.append(Data(bytes: tank.char.p, count: n * 2))
    let flat = (0..<n).flatMap { [tank.col[$0].x, tank.col[$0].y, tank.col[$0].z] }
    flat.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    try! data.write(to: URL(fileURLWithPath: file))
}

/// render frames 0...last of a tank (30 a second), handing the chosen ones of one screen over as pictures
func render(_ tank: Tank, frames: Set<Int>, scale: Int, screens: [Int] = [0], setup: (Renderer) -> Void = { _ in },
            before: (Int) -> Void = { _ in }, _ each: (Int, Int, CGImage) -> Void) {
    let device = MTLCreateSystemDefaultDevice()!
    let views = screens.map { i -> (Int, Renderer, MTLTexture, Int, Int) in
        let renderer = try! Renderer(device: device, targetFormat: .bgra8Unorm, tank: tank, screen: i)
        let r = tank.layout.fish.regions[i]
        let w = r.cols * CELL_W * scale, h = r.rows * CELL_H * scale
        renderer.resize(w, h)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        setup(renderer)
        return (i, renderer, device.makeTexture(descriptor: d)!, w, h)
    }
    for n in 0...(frames.max() ?? 0) {
        before(n)
        tank.frame(Time(n) / 30)
        for (i, renderer, target, w, h) in views {
            renderer.time = Float(n) / 30
            let cmd = renderer.queue.makeCommandBuffer()!
            renderer.draw(into: target, cmd)
            cmd.commit()
            cmd.waitUntilCompleted()
            guard frames.contains(n) else { continue }
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            target.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            each(n, i, ctx.makeImage()!)
        }
    }
}

func save(_ image: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

/// the tank, how it is drawn, and what happens in it, as the tools' options say
func toolScene() -> (Tank, (Renderer) -> Void, (Int) -> Void) {
    // --seabed, --surface, --company, --vignette as in the menu; --rays K, --caustics K, --dawn K, --night K;
    // --feed N drops pellets at frame N, --tap N taps the glass near the first fish at frame N
    let tank = toolTank()
    var mood = Mood()
    mood.hungry = flag("--hungry")
    mood.night = Double(arg("--night") ?? "0") ?? 0
    tank.surroundings.mood = mood
    let feedAt = arg("--feed").flatMap(Int.init), tapAt = arg("--tap").flatMap(Int.init)
    let setup: (Renderer) -> Void = { r in
        r.rays = Float(arg("--rays") ?? "0") ?? 0
        r.caustics = Float(arg("--caustics") ?? "0") ?? 0
        r.dawn = Float(arg("--dawn") ?? "0") ?? 0
        r.brightness = Float(1 - 0.45 * mood.night)
        r.vignette = flag("--vignette")
    }
    let before: (Int) -> Void = { n in
        if n == feedAt { tank.feed() }
        if n == tapAt, let b = tank.bettas.first { tank.tap(at: b.anchor + P2(0.6, 0.2), screen: 0) }
    }
    return (tank, setup, before)
}

func snap(_ frames: Set<Int>, _ dir: String, scale: Int) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let (tank, setup, before) = toolScene()
    let screens = Array(0..<tank.layout.screens.count)
    render(tank, frames: frames, scale: scale, screens: screens, setup: setup, before: before) { n, i, image in
        let name = screens.count > 1 ? String(format: "swift_%05d_s%d.png", n, i) : String(format: "swift_%05d.png", n)
        let path = URL(fileURLWithPath: dir).appendingPathComponent(name).path
        save(image, path)
        print("wrote \(path)")
    }
}

func icon(_ file: String) {
    // the fish just after it has drawn itself, centred, on a rounded black square
    let tank = Tank(layout: .single(cols: 146, rows: 102), seed: 7)    // 1022 x 1020 pixels: near enough square
    render(tank, frames: [192], scale: 1) { _, _, image in
        let size = 1024
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let inset: CGFloat = 100, box = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(box)
        let zoom: CGFloat = 1.25                                        // closer in on the fish
        let w = CGFloat(image.width) * zoom * box.width / 1024, h = CGFloat(image.height) * zoom * box.height / 1024
        ctx.draw(image, in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
        save(ctx.makeImage()!, file)
        print("wrote \(file)")
    }
}

// MARK: - start

/// only one fish on the desktop at a time: a second launch just leaves
func alreadyRunning() -> Bool {
    let path = NSTemporaryDirectory() + "betta.wallpaper.lock"
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    return fd < 0 || flock(fd, LOCK_EX | LOCK_NB) != 0                  // held for as long as we run
}

setvbuf(stdout, nil, _IOLBF, 0)
if args.contains("--bench") {
    bench()
} else if let m = arg("--path") {
    path(Double(m) ?? 5)
} else if let t = arg("--dump"), let i = args.firstIndex(of: "--dump"), i + 2 < args.count {
    dump(Time(t)!, args[i + 2])
} else if let file = arg("--video") {
    film(file, from: Double(arg("--from") ?? "0") ?? 0, seconds: Double(arg("--seconds") ?? "20") ?? 20, width: Int(arg("--width") ?? "1280") ?? 1280)
} else if let file = arg("--gif") {
    gif(file, from: Double(arg("--from") ?? "0") ?? 0, seconds: Double(arg("--seconds") ?? "8") ?? 8, fps: Int(arg("--fps") ?? "15") ?? 15,
        width: Int(arg("--width") ?? "640") ?? 640)
} else if let list = arg("--snap") {
    snap(Set(list.split(separator: ",").compactMap { Int($0) }), arg("--out") ?? "snaps", scale: Int(arg("--scale") ?? "1") ?? 1)
} else if let file = arg("--icon") {
    icon(file)
} else if alreadyRunning() {
    print("Betta Lite is already on the desktop")
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)                             // no Dock icon, no menu bar of its own
    let delegate = App()
    app.delegate = delegate
    app.run()
}
