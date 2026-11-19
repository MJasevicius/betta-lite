// One betta in the tank: scene() and the lighting from betta_fish.py, plus what it does. Each frame:
// what it does (pellets to chase, the mouse, a tap on the glass, its habits), then it is placed (its
// points go into the tank's lists, where only those in front of each cell get lit), then its own
// lights in the water: its breath, its bubble nest, its flares.
//
// Every fish keeps its own clock, from when it began drawing itself, so no two beat in step.

import Foundation
import simd

/// the water's scale: how the fish's units land on the grid of letters
enum Water {
    static let zoom: R = 7.4
    static let scaleX = zoom * 0.5 * 113                    // cells per unit (over depth), as in the 113 x 103 original
    static let scaleY = zoom * 0.5 * (791.0 / 1030.0) * 103
    static let cellAspect: R = 10.0 / 7.0                  // a cell is 7 wide and 10 tall
    static let depth = (0.25 * 0.25 + 36.0).squareRoot()   // how far the camera is from the water the fish swims in
    /// how far the fish's middle must keep from the edges (units): it reaches about this far, veils and all
    static let marginX = 1.0, marginUp = 0.92, marginDown = 0.86
    /// how far above its middle its mouth is when it takes a gulp of air, nose up
    static let mouthRise = 0.47
}

/// what every fish is made of, and the camera they are seen through: worked out once
final class Shape {
    static let shared = Shape()
    let bodyU: [R], bodyAt: [[V3]], scales: [R], bodyInk: [[V3]], bodyWay: [R]
    let eyes: [V3], gills: [V3], scaleAt: [V3], scaleT0: [Time]
    let sheets: [Sheet]                         // tail, back, belly, ribbons, oars
    // the camera, a long way back, level with the fish; each fish is drawn as if the camera were in
    // front of wherever it is, and that view is moved across the screen to where it is
    let right: V3, up: V3, fwd: V3, eyeCam: V3
    let view: V3, key: V3, half: V3

    private init() {
        let eye = SIMD3<Double>(0, -0.25, 6)
        let f = simd_normalize(-eye)
        let rgt = simd_normalize(simd_cross(f, SIMD3<Double>(0, 1, 0)))
        let u = simd_cross(rgt, f)
        right = V3(rgt); up = V3(u); fwd = V3(f)
        eyeCam = V3(R(simd_dot(rgt, eye)), R(simd_dot(u, eye)), R(simd_dot(f, eye)))
        view = V3(simd_normalize(eye))
        let k = simd_normalize(SIMD3<Double>(-0.50, 0.62, 0.60))
        key = V3(k)
        half = V3(simd_normalize(k + simd_normalize(eye)))

        // body points, spread evenly over the skin: a golden-angle spiral from the nose back
        let n = 8000, golden = Double.pi * (3 - 5.0.squareRoot())
        let grid = (0..<2000).map { lin($0, 2000) }
        var area = [Double](), run = 0.0
        for gu in grid { run += tallD(gu) + 0.01; area.append(run) }
        let areaN = area.map { $0 / run }
        let us = (0..<n).map { interpD(Double($0) + 0.5, n, areaN, grid) }
        let ths = (0..<n).map { (Double($0) * golden).truncatingRemainder(dividingBy: 2 * Double.pi) }
        let nudge = 2e-3
        bodyU = us.map { R($0) }
        bodyAt = [
            (0..<n).map { bodyD(us[$0], ths[$0]) },
            (0..<n).map { bodyD(us[$0] + nudge, ths[$0]) },
            (0..<n).map { bodyD(us[$0], ths[$0] + nudge) },
        ]
        let sc = (0..<n).map { 0.5 + 0.5 * cos(us[$0] * 170 + ths[$0] * 8) * cos(us[$0] * 170 - ths[$0] * 8) }
        scales = sc.map { R($0) }
        let pales = (0..<n).map { min(max(max(smoothD((0.2 - us[$0]) / 0.12), smoothD((-sin(ths[$0]) - 0.2) / 0.6)), 0), 1) }
        bodyInk = PALETTES.map { p in
            (0..<n).map { i in
                let mix = 0.75 * pales[i] + 0.40 * (sc[i] > 0.78 ? 1 : 0) * (us[i] > 0.2 ? 1 : 0)
                return p[0] + (p[1] - p[0]) * R(mix)
            }
        }
        bodyWay = us.map { R(abs($0 - 0.22)) * LENGTH }                     // from the gills (GILL = 0.22)

        eyes = [bodyD(0.085, 0.42) + V3(0, 0, 0.012), bodyD(0.085, Double.pi - 0.42) + V3(0, 0, -0.012)]
        let gs = (0..<16).map { -0.95 + 1.9 * lin($0, 16) }
        gills = gs.map { bodyD(0.225 + 0.035 * cos($0 * 1.4), $0) + V3(0, 0, 0.006) }
            + gs.map { bodyD(0.225 + 0.035 * cos($0 * 1.4), Double.pi - $0) - V3(0, 0, 0.006) }
        scaleAt = (0..<12).map { i in
            let even = i % 2 == 0
            let th = (even ? 1.0 : -1.0) * 0.18 * cos(Double(i) * 2.1) + Double.pi * Double(i % 2)
            return bodyD(0.30 + 0.52 * Double((i * 5) % 12) / 11, th) + V3(0, 0, even ? 0.01 : -0.01)
        }
        scaleT0 = (0..<12).map { T_SCALES.0 + (T_SCALES.1 - T_SCALES.0) * Double($0) / 11 }

        func glitter(_ at: [Int], _ speed: [R], _ phase: [R]) -> (at: [Int], speed: [R], phase: [R]) { (at, speed, phase) }
        sheets = [
            Sheet(nk: 1, na: 172, nr: 66, a: { _, i, _ in lin(i, 172) }, r: { _, _, j in lin(j, 66) }, part: { _ in TAIL },
                  ink: veilInk, rays: Double(TAIL_RAYS), slopeAlongA: false, way: (0.60, TAIL_LEN), done: T_TAIL.1,
                  glitter: glitter(TAIL_GLITTER_AT, TAIL_GLITTER_SPEED, TAIL_GLITTER_PHASE),
                  flareAt: [20, 86, 150].map { $0 * 66 + 65 }),
            Sheet(nk: 1, na: 92, nr: 48, a: { _, i, _ in lin(i, 92) }, r: { _, _, j in lin(j, 48) }, part: { _ in BACK },
                  ink: veilInk, rays: Double(BACK_RAYS), slopeAlongA: false, way: (0.36, 0.50), done: T_SAILS.1,
                  glitter: glitter(BACK_GLITTER_AT, BACK_GLITTER_SPEED, BACK_GLITTER_PHASE),
                  flareAt: [30, 70].map { $0 * 48 + 47 }),
            Sheet(nk: 1, na: 106, nr: 48, a: { _, i, _ in lin(i, 106) }, r: { _, _, j in lin(j, 48) }, part: { _ in BELLY },
                  ink: veilInk, rays: Double(BELLY_RAYS), slopeAlongA: false, way: (0.34, 0.58), done: T_SAILS.1,
                  glitter: glitter(BELLY_GLITTER_AT, BELLY_GLITTER_SPEED, BELLY_GLITTER_PHASE),
                  flareAt: [36, 82].map { $0 * 48 + 47 }),
            Sheet(nk: 2, na: 150, nr: 13, a: { _, i, _ in lin(i, 150) }, r: { _, i, _ in lin(i, 150) }, part: { RIB0 + Int8($0) },
                  ink: veilInk, rays: 0, slopeAlongA: true, way: (0.12, RIBBON_LEN), done: T_RIBBONS.1,
                  flareAt: [0, 1].map { ($0 * 150 + 149) * 13 + 6 }),
            Sheet(nk: 2, na: 40, nr: 26, a: { _, i, _ in lin(i, 40) }, r: { _, _, j in lin(j, 26) }, part: { OAR0 + Int8($0) },
                  ink: { pal, _ in pale(PALETTES[pal][3], 0.20) },
                  rays: Double(OAR_RAYS), slopeAlongA: true, way: (0.05, OAR_LEN), done: T_OARS.1),
        ]
    }
}

/// the tank's lists of every point placed this frame, which each fish appends to
final class Points {
    let SX = Buf<R>(0, capacity: 1 << 17), SY = Buf<R>(0, capacity: 1 << 17), Z = Buf<R>(0, capacity: 1 << 17)
    let PRT = Buf<Int8>(0, capacity: 1 << 17), AREA = Buf<R>(0, capacity: 1 << 17), SRC = Buf<Int32>(0, capacity: 1 << 17)
    var count: Int { SX.count }
    func removeAll() { SX.removeAll(); SY.removeAll(); Z.removeAll(); PRT.removeAll(); AREA.removeAll(); SRC.removeAll() }
}

/// how many kinds of part a fish has (BODY ... MARK): a fish's parts are numbered from index * PARTS
let PARTS: Int8 = 9

final class Betta {
    let index: Int
    let seed: UInt64
    let motion: Motion
    let born: Time                                      // when it starts drawing itself, on the tank's clock
    /// which sets of colours it may wear next (the menu decides)
    var allowedPalettes: () -> [Int] = { Array(0..<PALETTES.count) }
    private let S = Shape.shared
    private let pts: Points
    private let zBias: R                                // each fish swims a little further back than the one before
    private let partBase: Int8, srcBase: Int32

    // this frame
    private(set) var lt: Time = -1                      // its own clock (negative: not born yet)
    private var hidden = false                          // only on screens covered by windows: not drawn this frame
    private(set) var pointsFrom = 0, pointsTo = 0       // its points in the tank's lists
    private var eyeHere = V3.zero
    private(set) var centreX: R = 0, centreY: R = 0
    private var car: Carrier
    private var flares = [Flare]()
    private var markL = [R](), markRGB = [V3](), markG = [Int16]()     // eyes, gills, scales: lit as they are placed
    private let bodyP = Buf<V3>(.zero)
    private var bodyWhole: R = 0, bodyEdge: R = 0, bodyGrowing = false
    private final class Laid { let wp = Buf<V3>(.zero); var base = 0, g: R = 0, whole: R = 0 }    // base: its first point
    private let laid = (0..<5).map { _ in Laid() }                    // each fin as it lies this frame

    // the colours: which set it wears after each wave, and when the waves set off
    private var waveAt: R = -9, old = 0, new = 0
    private var wardrobe: [Int]
    private var colourEvery: Time
    private var colourT0: Time = T_LIGHT, colourBase = 0

    // what it has been doing (on its own clock, but for `check`: the tank's)
    private struct Puff { var p0: V3; var t0: Time; var wobble: Double; var size: Double }
    private struct NestBubble { var from: V3; var spot: P2; var born: Time; var life: Double; var size: Double }
    private var puffs = [Puff](), nest = [NestBubble]()
    private var rng: SplitMix
    private(set) var lastMouth = V3.zero
    private var lastAnchor = P2.zero
    private var chaseAt: Time = -1e9, calmUntil: Time = -1e9, lastGulp: Time = -1e9, lastNestPuff: Time = -1e9
    private var check: (at: Time, spot: P2)?
    /// what it has done so far (for checking)
    private(set) var done = ["eaten": 0, "gulps": 0, "nest bubbles": 0, "frights": 0, "looks at a tap": 0]

    init(index: Int, seed: UInt64, motion: Motion, born: Time, points: Points, colourEvery: Time) {
        self.index = index; self.seed = seed; self.motion = motion; self.born = born
        self.colourEvery = colourEvery
        pts = points
        zBias = R(index) * 0.8
        partBase = Int8(index) * PARTS
        srcBase = Int32(index) << 27
        car = Carrier(0, motion)
        rng = SplitMix(seed, 5)
        var first = SplitMix(seed, 6)
        wardrobe = [index == 0 ? 0 : Int(first.next() % UInt64(PALETTES.count))]
    }

    var alive: Bool { lt >= 0 }
    var swimming: Bool { lt > T_SWIM }
    /// where its middle is now
    var anchor: P2 { motion.at(max(lt, 0)).p }

    // MARK: projection

    @inline(__always) func project(_ p: V3) -> (R, R, R) {
        let c = V3(simd_dot(S.right, p), simd_dot(S.up, p), simd_dot(S.fwd, p)) - eyeHere
        let zz = max(c.z, 0.2)
        return (centreX + c.x / zz * Water.scaleX, centreY - c.y / zz * Water.scaleY, c.z + zBias)
    }

    @inline(__always) private func toCam(_ p: V3) -> V3 {
        V3(simd_dot(S.right, p), simd_dot(S.up, p), simd_dot(S.fwd, p)) - eyeHere
    }

    // MARK: colour

    private func currentChange(_ t: Time) -> Int {
        t < colourT0 ? colourBase - 1 : colourBase + Int(floor((t - colourT0) / colourEvery))
    }

    private func wears(_ n: Int) -> Int {
        // the set it wears after the n-th wave: a new one each time, never the one before
        while wardrobe.count <= n {
            let allowed = allowedPalettes()
            var choices = allowed.filter { $0 != wardrobe.last! }
            if choices.isEmpty { choices = allowed.isEmpty ? [wardrobe.last!] : allowed }
            wardrobe.append(choices[Int(rng.next() % UInt64(choices.count))])
        }
        return wardrobe[n]
    }

    /// the menu changed which colours it may wear: the next wave brings them
    func recolour() {
        let keep = max(currentChange(max(lt, 0)) + 2, 1)
        if wardrobe.count > keep { wardrobe.removeLast(wardrobe.count - keep) }
    }

    /// new sets of colours come this often from now on
    func setColourEvery(_ every: Time) {
        guard every != colourEvery else { return }
        if lt >= T_LIGHT {
            colourBase = currentChange(lt) + 1
            colourT0 = lt
        }
        colourEvery = every
    }

    @inline(__always) private func lit(_ way: R, _ inkOld: V3, _ inkNew: V3, _ lum: R) -> (V3, R) {
        // behind the wave the fish wears the next palette, ahead of it the old one; the front is white-hot
        let d = waveAt - way
        let on = smooth(d / 0.2)
        let band: R = abs(d) < 0.4 && old != new ? 0.85 * exp(-(d / 0.06) * (d / 0.06)) : 0
        var rgb = inkOld + (inkNew - inkOld) * on
        rgb += (WHITE - rgb) * (min(band, 1) * 0.65)
        return (rgb, lum + 0.45 * band)
    }

    @inline(__always) private func place(_ p: V3, _ part: Int8, _ area: R, _ src: Int32) {
        let (x, y, z) = project(p)
        pts.SX.append(x); pts.SY.append(y); pts.Z.append(z); pts.PRT.append(part + partBase); pts.AREA.append(area)
        pts.SRC.append(src | srcBase)
    }

    @inline(__always) private func add(_ p: V3, _ lum: R, _ rgb: V3, _ part: Int8, _ glyph: Int16) {
        place(p, part, 1, Int32(markL.count))
        markL.append(lum); markRGB.append(rgb); markG.append(glyph)
    }

    /// light one of its points that ended up in front in a cell: (brightness, colour, own glyph or -1)
    @inline(__always) func shade(_ kind: Int, _ i: Int) -> (R, V3, Int16) {
        switch kind {
        case 0: return (markL[i], markRGB[i], markG[i])
        case 1: return shadeBody(i)
        default: return shadeFin(kind - 2, i)
        }
    }

    // MARK: what it does (t: the tank's clock)

    private func puff(_ at: V3, _ t0: Time, count: Int) {
        for i in 0..<count {
            puffs.append(Puff(p0: at, t0: t0 + 0.12 * Double(i), wobble: rng.unit(), size: rng.unit()))
        }
    }

    /// the glass was tapped near it: it shoots off, away from the tap
    func startle(from tap: P2) {
        guard swimming else { return }
        let here = anchor
        var away = here - tap
        if simd_length(away) < 0.05 { away = P2(rng.range(-1, 1), rng.range(-0.3, 0.3)) }
        away = simd_normalize(away)
        // straight away from it, or as near that as the walls let it get far
        let far = rng.range(1.0, 1.5)
        var target = here, best = -Double.infinity
        for turn in [0.0, 0.4, -0.4, 0.8, -0.8, 1.2, -1.2] {
            let d = P2(away.x * cos(turn) - away.y * sin(turn), away.x * sin(turn) + away.y * cos(turn))
            let q = motion.clamp(here + d * far)
            let score = simd_dot(q - here, away) + 0.5 * simd_length(q - here) - 0.15 * abs(turn)
            if score > best { best = score; target = q }
        }
        motion.redirect(lt, to: target, speed: 1.5, purpose: .flee)
        calmUntil = lt + 5
        chaseAt = -1e9
        puff(lastMouth, lt, count: 3)
        done["frights", default: 0] += 1
    }

    /// come back later (at `t`, on the tank's clock) to look at where the glass was tapped
    func inspect(_ spot: P2, at t: Time) { check = (t, spot) }

    /// where to send its middle so that its mouth gets to `spot`
    private func mouthTo(_ spot: P2, from here: P2) -> P2 {
        var offset = P2(Double(lastMouth.x), Double(lastMouth.y)) - lastAnchor
        if (spot.x > here.x) != (offset.x > 0) { offset.x = -offset.x }
        return spot - offset
    }

    private func behave(_ t: Time, _ s: Surroundings, _ tank: Tank) {
        let here = motion.at(lt).p
        let mouth = P2(Double(lastMouth.x), Double(lastMouth.y))

        // pellets: eaten when its mouth gets there
        var nearest: P2? = nil, nearestD = Double.infinity
        if swimming {
            for i in tank.pellets.indices where !tank.pellets[i].eaten && t >= tank.pellets[i].t0 {
                let at = tank.pelletAt(tank.pellets[i], t), d = simd_length(at - mouth)
                if d < 0.1 {
                    tank.pellets[i].eaten = true
                    done["eaten", default: 0] += 1
                    puff(lastMouth, lt, count: 2)
                    chaseAt = -1e9
                } else if d < nearestD {
                    nearestD = d
                    nearest = tank.pelletAt(tank.pellets[i], t + 0.7)
                }
            }
        }

        if let soon = nearest {
            // food: go for the nearest, aiming its mouth where it will be
            if motion.kind(lt).kind != .turn && lt - chaseAt > 1.0 {
                motion.redirect(lt, to: mouthTo(soon, from: here), speed: 0.55, purpose: .chase)
                chaseAt = lt
            }
        } else if swimming, let c = check, t >= c.at {
            // where the glass was tapped: come and have a look
            check = nil
            motion.redirect(lt, to: mouthTo(c.spot, from: here), speed: 0.3, purpose: .inspect)
            calmUntil = lt + 9
            done["looks at a tap", default: 0] += 1
        } else if swimming, s.reaction != .ignore, let m = s.mouse, s.mouseMoving, lt > calmUntil {
            // the pointer: come and have a look, or keep away from it
            let d = m - here, dist = simd_length(d)
            if s.reaction == .curious && dist > 0.5 && dist < 1.8 {
                motion.redirect(lt, to: m - d / dist * 0.5, speed: 0.32, purpose: .approach)
                calmUntil = lt + 3.5
            } else if s.reaction == .shy && dist < 1.0 {
                motion.redirect(lt, to: here - d / max(dist, 1e-6) * 1.0, speed: 0.8, purpose: .dart)
                calmUntil = lt + 2.5
            }
        }

        // its habits: a gulp of air at the top lets a few bubbles go (and ripples the surface); under its
        // nest it blows more into it
        let now = motion.kind(lt)
        if now.kind == .gulp && now.t0 != lastGulp {
            lastGulp = now.t0
            done["gulps", default: 0] += 1
            puff(lastMouth, lt, count: 4 + Int(rng.unit() * 3))
            tank.ripple(at: Double(lastMouth.x), t)
        }
        if now.kind == .nest && lt - lastNestPuff > 0.35, let n = motion.nest {
            lastNestPuff = lt
            done["nest bubbles", default: 0] += 1
            let top = motion.areas[motion.area(n)].surface
            let spread = (rng.unit() + rng.unit() + rng.unit() - 1.5) * 0.3
            nest.append(NestBubble(from: lastMouth, spot: P2(n.x + spread, top - 0.02 - rng.unit() * 0.05 * (1 - abs(spread))),
                                   born: lt, life: rng.range(150, 360), size: rng.unit()))
            if nest.count > 90 { nest.removeFirst() }
        }
        nest.removeAll { lt - $0.born > $0.life }
        puffs.removeAll { lt - $0.t0 > 2.8 }
    }

    // MARK: each frame

    /// what it does, where it is, and its points into the tank's lists
    func place(_ t: Time, _ s: Surroundings, in tank: Tank) {
        lt = t - born
        pointsFrom = pts.count; pointsTo = pts.count
        guard lt >= 0 else { return }
        motion.mood = s.mood
        behave(t, s, tank)
        let here = motion.at(lt).p
        hidden = !tank.shows(here)
        if hidden {
            // nobody can see it: it goes on swimming (that is all in time), but nothing of it is drawn
            lastMouth = Carrier(lt, motion)(MOUTH)
            lastAnchor = here
            return
        }
        let car = Carrier(lt, motion, tabulate: true)
        // the view follows the fish: drawn as from a camera in front of it, moved to where it is on screen
        let a = V3(R(here.x), R(here.y), 0)
        eyeHere = S.eyeCam + V3(simd_dot(S.right, a), simd_dot(S.up, a), simd_dot(S.fwd, a))
        centreX = tank.originX + a.x * Water.scaleX / R(Water.depth)
        centreY = tank.originY - a.y * Water.scaleY / R(Water.depth)
        scene(lt, car)
        pointsTo = pts.count
        lastAnchor = here
    }

    /// its own lights in the water, once every fish has been placed: its breath and its nest...
    func bubbles(in tank: Tank) {
        guard alive, !hidden else { return }
        breath(lt, tank)
        bubbleNest(lt, tank)
    }

    /// ...and, last of all, its flares
    func flare(in tank: Tank) {
        guard alive, !hidden else { return }
        for f in flares {
            let (x, y, z) = project(f.p)
            tank.flare(x, y, z, f)
        }
        lastMouth = car(MOUTH)
    }

    // MARK: scene()

    private func scene(_ t: Time, _ car: Carrier) {
        markL.removeAll(keepingCapacity: true); markRGB.removeAll(keepingCapacity: true); markG.removeAll(keepingCapacity: true)
        flares.removeAll(keepingCapacity: true)
        self.car = car

        // the colours: every so often a wave runs from the gills to every hem and leaves new colours behind it
        let change = currentChange(t)
        old = wears(max(change, 0))
        new = wears(max(change + 1, 0))
        let since = t - colourT0 - Double(change - colourBase) * colourEvery
        waveAt = change >= 0 ? R(since * WAVE_SPEED * PERIOD / colourEvery) : -9
        let strokeT = R(stroke(t, motion))
        let display = R(motion.display(t))

        // the body: only as far as it is drawn
        let edge = R(pow(clampD((t - T_BODY.0) / (T_BODY.1 - T_BODY.0), 0, 1), 1.2))
        var m = 0
        do { var lo = 0, hi = S.bodyU.count; while lo < hi { let mid = (lo + hi) / 2; if S.bodyU[mid] < edge { lo = mid + 1 } else { hi = mid } }; m = lo }
        bodyEdge = edge
        bodyGrowing = t < T_BODY.1
        bodyWhole = flash(t, T_BODY.1)
        let whole = bodyWhole
        bodyP.resize(S.bodyU.count)
        let at0 = S.bodyAt[0]
        for i in 0..<m {
            let p = car(at0[i])
            bodyP[i] = p
            place(p, BODY, 1, 1 << 24 | Int32(i))
        }
        if whole > 0.05 {
            for (u, th) in [(0.10, 1.1), (0.52, 1.5), (0.97, 1.2)] as [(R, R)] {
                flares.append(Flare(p: car(body(u, th)), reach: Int(2 + 5 * whole), strength: whole, rgb: WHITE, always: true))
            }
        }

        // the fins
        let pos = Tank.pos, lag = Tank.lag
        var g = R(span(t, T_TAIL))
        if g > 0.01 {
            tailSheet(linspace(172), linspace(66), t, g, strokeT, pos, lag, display: display)
            fin(0, g, t, car)
        }
        g = R(span(t, T_SAILS))
        if g > 0.01 {
            sailSheet(linspace(92), linspace(48), t, g, 1, strokeT, pos, lag, display: display)
            fin(1, g, t, car)
            sailSheet(linspace(106), linspace(48), t, g, -1, strokeT, pos, lag, display: display)
            fin(2, g, t, car)
        }
        g = R(span(t, T_RIBBONS))
        if g > 0.01 {
            ribbonSheet(linspace(150), (0..<13).map { -1 + 2 * R(lin($0, 13)) }, t, g, pos, lag)
            fin(3, g, t, car)
        }
        g = R(span(t, T_OARS))
        if g > 0.01 {
            oarSheet(t, g, pos, lag)
            fin(4, g, t, car)
        }

        // eyes, and the edge of each gill cover
        if edge > 0.12 {
            for e in S.eyes { add(car(e), 1.3, WHITE, MARK, C("@")) }
        }
        if edge > 0.3 {
            let p = S.gills.map { car($0) }
            let c = p.map { toCam($0) }
            let ink = pale(PALETTES[new][1], 0.5)
            for side in 0..<2 {
                for j in 0..<16 {
                    let i = side * 16 + j
                    let i0 = side * 16 + max(j - 1, 0), i1 = side * 16 + min(j + 1, 15)
                    let d: R = (j == 0 || j == 15) ? 1 : 2
                    let dx = (c[i1].x / c[i1].z - c[i0].x / c[i0].z) / d
                    let dy = (c[i1].y / c[i1].z - c[i0].y / c[i0].z) / d
                    add(p[i], 1.0, ink, MARK, slopeChar(dx, dy))
                }
            }
        }

        // scales that catch the light: each pops on white with a flare, then twinkles gold
        for i in 0..<12 where t >= S.scaleT0[i] {
            let p = car(S.scaleAt[i])
            let age = t - S.scaleT0[i]
            let h = flash(t, S.scaleT0[i])
            let tw = R(0.5 + 0.5 * sin(t * 5 + Double(i) * 2.4))
            add(p, 1.05 + 0.3 * tw + 0.3 * h, GOLD + (WHITE - GOLD) * h, MARK, tw > 0.5 ? C("*") : C("o"))
            if age < 0.45 || tw > 0.975 {
                let k = max(h, 0.45)
                flares.append(Flare(p: p, reach: Int(2 + 3 * k), strength: k, rgb: age < 0.45 ? WHITE : GOLD, always: true))
            }
        }

        // the very start: a spark at its nose
        let seedLight = R(clampD(1 - t / 1.0, 0, 1))
        if seedLight > 0.05 {
            flares.append(Flare(p: car(MOUTH), reach: Int(2 + 6 * seedLight), strength: seedLight, rgb: WHITE, always: false))
        }
    }

    /// the body's skin at a point: a lattice of scales, a paler belly and face, the colour wave
    private func shadeBody(_ i: Int) -> (R, V3, Int16) {
        let u = S.bodyU[i], p = bodyP[i]
        let pu = car(S.bodyAt[1][i]), pt = car(S.bodyAt[2][i])
        var n = unit(simd_cross(pu - p, pt - p))
        n *= sgn(simd_dot(n, S.view))                                       // the skin we see faces us
        let nv = simd_dot(n, S.view), hl = clamp(simd_dot(n, S.half), 0, 1)
        var lum = 0.60 + 0.36 * clamp(simd_dot(n, S.key), 0, 1)
        lum += 0.55 * pow16(hl) * (hl * hl) * (hl * hl) + 0.26 * (1 - abs(nv)) * (1 - abs(nv))
        if u > 0.2 { lum += 0.24 * (S.scales[i] - 0.5) }
        var (rgb, l) = lit(S.bodyWay[i], S.bodyInk[old][i], S.bodyInk[new][i], lum)
        rgb += (WHITE - rgb) * clamp(l - 1.0, 0, 0.5)
        var glyph: Int16 = -1
        if bodyGrowing && u > bodyEdge - 0.035 && i % 2 == 0 { glyph = C("*"); l = 1.3; rgb = WHITE }   // the growing edge sparks
        rgb += (WHITE - rgb) * (0.7 * bodyWhole); l += 0.4 * bodyWhole                                 // whole: it flashes white
        return (l, rgb, glyph)
    }

    /// fin(): one sheet of points, carried into the water and placed on screen
    private func fin(_ k: Int, _ g: R, _ t: Time, _ car: Carrier) {
        let s = S.sheets[k], f = laid[k]
        let n = s.count, na = s.na, nr = s.nr
        let wp = f.wp
        wp.resize(n)
        var whole = flash(t, s.done)
        if whole <= 0.05 { whole = 0 }                                      // a fin flashes only above 0.05
        f.g = g; f.whole = whole
        // its points go straight into the frame's lists, from base on
        let base = pts.count
        f.base = base
        for b in [pts.SX, pts.SY, pts.Z, pts.AREA] { b.resize(base + n) }
        pts.PRT.resize(base + n); pts.SRC.resize(base + n)
        let sx = pts.SX.p + base, sy = pts.SY.p + base, sz = pts.Z.p + base, area = pts.AREA.p + base
        let part = pts.PRT.p + base, src = pts.SRC.p + base
        let w = wp.p, at = Tank.pos.p, late = Tank.lag.p
        for i in 0..<n {
            let p = car(at[i], late[i])
            w[i] = p
            (sx[i], sy[i], sz[i]) = project(p)
        }
        let ray = s.ray, tip = s.tip, parts = s.part, opening = g < 1
        let kind = Int32(2 + k) << 24 | srcBase, pb = partBase
        for kk in 0..<s.nk {
            for ia in 0..<na {
                let a0 = ia == 0 ? 0 : -nr, a1 = ia == na - 1 ? 0 : nr, da: R = (ia == 0 || ia == na - 1) ? 1 : 2
                for ir in 0..<nr {
                    let i = (kk * na + ia) * nr + ir
                    let b0 = ir == 0 ? 0 : -1, b1 = ir == nr - 1 ? 0 : 1, db: R = (ir == 0 || ir == nr - 1) ? 1 : 2
                    // how much of a cell this point stands for: its patch of the sheet as it lies on screen
                    let patch = abs((sx[i + a1] - sx[i + a0]) / da * (sy[i + b1] - sy[i + b0]) / db
                                    - (sx[i + b1] - sx[i + b0]) / db * (sy[i + a1] - sy[i + a0]) / da)
                    area[i] = ray[i] || (opening && tip[i]) ? 1 : 1.6 * patch + 0.02     // a letter of its own fills its cell
                    part[i] = parts[i] + pb
                    src[i] = kind | Int32(i)
                }
            }
        }
        if let gl = s.glitter, g >= 1 {
            for i in gl.at where s.sparkles(i, g, t) { area[i] = 1 }
        }
        if whole > 0 {
            for i in s.flareAt {
                flares.append(Flare(p: wp[i], reach: Int(2 + 5 * whole), strength: whole, rgb: WHITE, always: true))
            }
        }
    }

    /// a point of a fin, lit across its folds: a fold facing the light shines, one turned away is dark;
    /// the rays are strokes along their own direction on screen
    private func shadeFin(_ k: Int, _ i: Int) -> (R, V3, Int16) {
        let s = S.sheets[k], f = laid[k], na = s.na, nr = s.nr, g = f.g
        let ia = (i / nr) % na, ir = i % nr
        let a0 = ia == 0 ? 0 : -nr, a1 = ia == na - 1 ? 0 : nr, da: R = (ia == 0 || ia == na - 1) ? 1 : 2
        let b0 = ir == 0 ? 0 : -1, b1 = ir == nr - 1 ? 0 : 1, db: R = (ir == 0 || ir == nr - 1) ? 1 : 2
        let gA = (f.wp[i + a1] - f.wp[i + a0]) / da, gB = (f.wp[i + b1] - f.wp[i + b0]) / db
        var nrm = unit(simd_cross(gA, gB))
        nrm *= sgn(simd_dot(nrm, S.view))
        let r = s.r[i]
        let kd = clamp(simd_dot(nrm, S.key), 0, 1)
        var lum = 0.30 + 0.78 * (kd > 0 ? pow(kd, 0.8) : 0) + 0.40 * pow16(clamp(simd_dot(nrm, S.half), 0, 1))
        lum += 0.22 * smooth((r - 0.86) / 0.12)
        var (rgb, l) = lit(s.wayA + s.wayB * g * r, s.inks[old][i], s.inks[new][i], lum)
        rgb += (WHITE - rgb) * clamp((l - 0.95) * 0.9, 0, 0.55)            // the crest of a fold shines
        var glyph: Int16 = -1
        if s.ray[i] {
            let (o0, o1, d) = s.slopeAlongA ? (a0, a1, da) : (b0, b1, db)
            let sx = pts.SX.p + f.base, sy = pts.SY.p + f.base
            glyph = slopeChar((sx[i + o1] - sx[i + o0]) / d, -(sy[i + o1] - sy[i + o0]) / d * Water.cellAspect)
            l = 0.62 + 0.55 * l
            rgb = pale(rgb, 0.40)
        }
        if s.sparkles(i, g, lt) { glyph = C("*"); l = 1.35; rgb = WHITE }
        if g < 1 && s.tip[i] { glyph = C("*"); l = 1.3; rgb = WHITE }          // sparks along the hem while it opens
        if f.whole > 0 { rgb += (WHITE - rgb) * (0.6 * f.whole); l += 0.35 * f.whole }
        return (l, rgb, glyph)
    }

    // MARK: its lights in the water

    static let breathChance = 0.4                   // on how many beats it lets bubbles go

    private func breath(_ t: Time, _ tank: Tank) {
        // now and then, on a beat, it lets a few bubbles go from its mouth; they wobble up and away
        let glyphs: [Int16] = [C("."), C("o"), C("O")]
        let now = Int(floor((t - BEAT0) / PERIOD))
        let chance = Betta.breathChance * (1 - 0.6 * motion.mood.night)
        var p = [V3](), gl = [Int16](), rgb = [V3](), k = [R]()
        for n in max(2, now - 2)...max(2, now) {
            var r = SplitMix(seed, 4, UInt64(n))
            guard r.unit() < chance else { continue }
            let tb = BEAT0 + Double(n) * PERIOD
            for i in 0..<(2 + Int(r.unit() * 3)) {
                let t0 = tb + 0.10 + 0.16 * Double(i)
                let wobble = r.unit(), size = r.unit()
                let age = t - t0
                guard age > 0 && age < 2.6 else { continue }
                p.append(Carrier(t0, motion)(MOUTH) + rise(age, wobble))
                gl.append(glyphs[Int(clampD(0.4 + 0.5 * age + size, 0, 2.99))])
                rgb.append(pale(BUBBLE, 0.4))
                k.append(R(0.95 * smoothD(age / 0.15) * (1 - smoothD((age - 2.0) / 0.6))))
            }
        }
        // and the bubbles of a gulp of air, a pellet eaten, or a fright
        for b in puffs {
            let age = t - b.t0
            guard age > 0 else { continue }
            p.append(b.p0 + rise(age, b.wobble))
            gl.append(glyphs[Int(clampD(0.4 + 0.5 * age + b.size, 0, 2.99))])
            rgb.append(pale(BUBBLE, 0.4))
            k.append(R(0.95 * smoothD(age / 0.15) * (1 - smoothD((age - 2.0) / 0.6))))
        }
        if !p.isEmpty { tank.dots(p.map(project), gl, rgb, k) }
    }

    private func rise(_ age: Time, _ wobble: Double) -> V3 {
        V3(R(0.05 * sin(4 * age + 9 * wobble) * min(age, 1)), R(0.22 * age + 0.10 * age * age), 0)
    }

    private func bubbleNest(_ t: Time, _ tank: Tank) {
        // bubbles it has blown up to the top: they rise there, cluster, and pop after a few minutes
        guard !nest.isEmpty else { return }
        let glyphs: [Int16] = [C("."), C("o"), C("o"), C("O"), C("0")]
        var p = [V3](), gl = [Int16](), rgb = [V3](), k = [R]()
        for b in nest {
            let age = t - b.born
            let u = smoothD(age / 1.6)
            let wobble = 0.03 * sin(5 * age + 20 * b.size) * (1 - u)
            let x = Double(b.from.x) + (b.spot.x - Double(b.from.x)) * u + wobble
            let y = Double(b.from.y) + (b.spot.y - Double(b.from.y)) * u + 0.004 * sin(0.7 * t + 9 * b.size)
            p.append(V3(R(x), R(y), 0))
            gl.append(glyphs[min(Int(b.size * 5), 4)])
            rgb.append(pale(BUBBLE, 0.55))
            let fade = smoothD(age / 0.3) * (1 - smoothD((age - b.life + 8) / 8))
            k.append(R(0.75 * fade * (0.85 + 0.15 * sin(1.3 * t + 30 * b.size))))
        }
        tank.dots(p.map(project), gl, rgb, k)
    }

    /// how far it reached on screen this frame, in cells from where its middle is drawn
    func reach() -> (left: R, right: R, up: R, down: R) {
        var l: R = 0, r: R = 0, u: R = 0, d: R = 0
        for i in pointsFrom..<pointsTo {
            l = min(l, pts.SX[i] - centreX); r = max(r, pts.SX[i] - centreX)
            u = min(u, pts.SY[i] - centreY); d = max(d, pts.SY[i] - centreY)
        }
        return (-l, r, -u, d)
    }
}

/// np.interp((i + 0.5) / n, xp, fp) for the body's points
private func interpD(_ i: Double, _ n: Int, _ xp: [Double], _ fp: [Double]) -> Double {
    let x = i / Double(n)
    if x <= xp[0] { return fp[0] }
    if x >= xp[xp.count - 1] { return fp[fp.count - 1] }
    var lo = 0, hi = xp.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if xp[mid] <= x { lo = mid } else { hi = mid } }
    return fp[lo] + (fp[hi] - fp[lo]) * (x - xp[lo]) / (xp[hi] - xp[lo])
}
