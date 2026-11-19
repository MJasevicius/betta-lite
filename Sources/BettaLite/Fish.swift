// The fish: scene() / bodies() / frame() from betta_fish.py, made endless. It draws itself from
// nothing as in the original; after that, instead of the original's 20 s run, it swims from one
// spot to another for as long as it is left to (Motion below), and the colours keep changing, a
// little slower than in the original. The particles of the original (plankton, glints off the tail, fireworks) are left out:
// only the bubbles in the water and from its mouth stay.
//
// Where the Python evaluates something per point that only depends on one axis of a fin's sheet
// (the travelling wave, the pleats, the flare of each ray), this computes it once per row or column
// and combines with sin(a+b) = sin a cos b + cos a sin b. How the fish holds itself at a time is
// tabulated once a frame and interpolated. Only the points that end up in front, one per cell, get
// lit: the rest are only placed. Time is kept in Double, so it still moves smoothly after days;
// everything per point is Float.

import Foundation
import simd

typealias R = Float
typealias V3 = SIMD3<Float>
typealias Time = Double
typealias Span = (Time, Time)

// MARK: - timeline: the build-up, as in the original

let TAU: R = 2 * .pi
let TAU_D = 2 * Double.pi
let PERIOD: Time = 2.0
let BEAT0: Time = 0.2
let T_BODY: Span = (0.0, 2.0)
let T_TAIL: Span = (2.0, 4.4)
let T_SAILS: Span = (2.6, 4.9)
let T_RIBBONS: Span = (3.2, 5.4)
let T_OARS: Span = (3.6, 4.6)
let T_SCALES: Span = (5.0, 6.8)
let T_LIGHT: Time = 6.2                         // the colours start changing
let T_SWIM: Time = 6.6                          // and from here on it swims wherever it likes
let FLASH: Time = 0.6

let BODY: Int8 = 0, TAIL: Int8 = 1, BACK: Int8 = 2, BELLY: Int8 = 3, RIB0: Int8 = 4, OAR0: Int8 = 6, MARK: Int8 = 8

@inline(__always) func C(_ s: Unicode.Scalar) -> Int16 { Int16(s.value) - 32 }

/// the fill letters of a set (see LETTER_SETS), 12 to a level of brightness
func fillLetters(_ pools: [String]) -> [Int16] {
    pools.flatMap { p -> [Int16] in
        let s = Array(p.unicodeScalars)
        return (0..<12).map { C(s[$0 % s.count]) }
    }
}
let SLOPE: [Int16] = [C("-"), C("/"), C("|"), C("\\"), C("-")]

// MARK: - colours

let WHITE = V3(1.00, 0.98, 0.94)
let GOLD = V3(1.00, 0.82, 0.38)
let PALETTES: [[V3]] = [
    [V3(0.10, 0.36, 1.00), V3(0.30, 0.86, 1.00), V3(0.40, 0.30, 1.00), V3(0.90, 0.26, 0.92), V3(1.00, 0.30, 0.55)],   // blue; violet to rose
    [V3(0.95, 0.10, 0.16), V3(1.00, 0.55, 0.35), V3(0.90, 0.08, 0.14), V3(1.00, 0.30, 0.08), V3(1.00, 0.58, 0.10)],   // fire
    [V3(0.04, 0.66, 0.74), V3(0.60, 1.00, 0.90), V3(0.08, 0.72, 0.70), V3(0.98, 0.84, 0.14), V3(1.00, 0.96, 0.58)],   // mustard
    [V3(0.14, 0.84, 0.36), V3(0.76, 1.00, 0.62), V3(1.00, 0.86, 0.92), V3(1.00, 0.44, 0.66), V3(0.96, 0.14, 0.42)],   // lotus
    [V3(0.20, 0.85, 1.00), V3(0.90, 0.98, 1.00), V3(0.30, 0.74, 1.00), V3(0.65, 0.90, 1.00), V3(0.95, 0.98, 1.00)],   // ice
    [V3(1.00, 0.50, 0.10), V3(1.00, 0.90, 0.70), V3(0.12, 0.30, 1.00), V3(0.20, 0.66, 1.00), V3(0.60, 0.94, 1.00)],   // koi
    [V3(0.30, 0.24, 1.00), V3(0.66, 0.60, 1.00), V3(0.18, 1.00, 0.52), V3(0.18, 0.86, 1.00), V3(0.72, 0.48, 1.00)],   // aurora
    [V3(0.94, 0.96, 1.00), GOLD, V3(1.00, 0.86, 0.50), V3(1.00, 0.70, 0.40), V3(1.00, 0.95, 0.80)],                   // pearl and gold
]
let WAVE_SPEED: Time = 1.25                     // how fast a wave of colour runs out, at a new set every beat;
                                                // slower in proportion when they come further apart
let BUBBLE = V3(0.50, 0.74, 1.00)

@inline(__always) func pale(_ rgb: V3, _ k: R) -> V3 { rgb + (WHITE - rgb) * k }
@inline(__always) func clamp(_ x: R, _ lo: R, _ hi: R) -> R { min(max(x, lo), hi) }
@inline(__always) func smooth(_ x: R) -> R { let x = clamp(x, 0, 1); return x * x * (3 - 2 * x) }
@inline(__always) func unit(_ v: V3) -> V3 { v / max(simd_length(v), 1e-12) }
@inline(__always) func sgn(_ x: R) -> R { x > 0 ? 1 : (x < 0 ? -1 : 0) }
@inline(__always) func pow16(_ x: R) -> R { let x2 = x * x, x4 = x2 * x2, x8 = x4 * x4; return x8 * x8 }

@inline(__always) func clampD(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(max(x, lo), hi) }
@inline(__always) func smoothD(_ x: Double) -> Double { let x = clampD(x, 0, 1); return x * x * (3 - 2 * x) }
@inline(__always) func fracD(_ x: Double) -> Double { x - floor(x) }               // Python's x % 1.0
@inline(__always) func span(_ t: Time, _ s: Span) -> Double { smoothD((t - s.0) / (s.1 - s.0)) }
@inline(__always) func flash(_ t: Time, _ at: Time) -> R { t >= at ? R(pow(clampD(1 - (t - at) / FLASH, 0, 1), 2)) : 0 }

@inline(__always) func slopeChar(_ dx: R, _ dy: R) -> Int16 {
    // screen direction (y up) -> the ASCII stroke that looks most like it
    var ang = atan2(dy, dx) * (180 / .pi)
    ang -= 180 * floor(ang / 180)
    return SLOPE[ang < 25 ? 0 : ang < 72 ? 1 : ang < 108 ? 2 : ang < 155 ? 3 : 4]
}

@inline(__always) func outlineLetter(_ gx: Int, _ gy: Int) -> Int16 {
    let ax = abs(gx), ay = abs(gy)
    if ax + ay == 0 { return C("+") }
    if ax > 2 * ay { return C("|") }
    if ay > 2 * ax { return gy > 0 ? C("_") : C("-") }
    return gx * gy > 0 ? C("/") : C("\\")
}

/// a few random numbers that are always the same for the same seed and keys
struct SplitMix {
    var s: UInt64
    init(_ seed: UInt64, _ a: UInt64 = 0, _ b: UInt64 = 0) {
        s = seed &* 0x9E37_79B9_7F4A_7C15 ^ a &* 0xBF58_476D_1CE4_E5B9 ^ b &* 0x94D0_49BB_1331_11EB
    }
    mutating func next() -> UInt64 {
        s &+= 0x9E37_79B9_7F4A_7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

// MARK: - the beat: on every one it spreads its fins and strikes harder with its tail

@inline(__always) func beat(_ t: Time) -> Double {
    let ph = fracD((t - BEAT0) / PERIOD)
    return ph < 0.22 ? smoothD(ph / 0.22) : 1 - smoothD((ph - 0.22) / 0.78)
}
@inline(__always) func flare(_ t: Time) -> Double { beat(t) * (0.35 + 0.65 * smoothD((t - T_RIBBONS.1 + 0.3) / 0.5)) }

// MARK: - how it holds itself in the water

let NOSE: R = 0.42, LENGTH: R = 0.80
let TAIL_X: R = NOSE - 0.97 * LENGTH
let PIVOT_X: R = -0.26, PIVOT_Y: R = -0.06      // the middle of the whole fish, veils and all
let HOME_Y: Double = 0.02
let TIP: Double = 0.22, STEEP: Double = 1.7     // how far it hangs nose-up, and how much more per unit a second it climbs
let FACING: Double = 0.60, WEAVE: Double = 0.22 // how far it is turned towards us, and how far it weaves either way
let BODY_LAG: R = 0.32, FIN_LAG: R = 0.85       // how late the tail root runs (s), and a fin, per unit of its length
let MOVE_BODY: R = 0.25, MOVE_FIN: R = 0.55     // how much of that delay its way across the water has: the veils trail
let SWIM: Double = 0.050
let TAIL_BEAT: R = TAU / R(PERIOD)
let TAIL_BEAT_D: Double = TAU_D / PERIOD
let ALONG_BODY: R = 5.0, ALONG_FIN: R = 2.6
let EFFORT: Double = 1.4                        // how much harder the tail works, per unit a second it swims


@inline(__always) func bob(_ t: Time) -> Double { 0.05 * sin(0.9 * t) }

/// Everything about the pose that depends only on the (delayed) time, in one vector so it
/// interpolates in one go: cos/sin of the tip, cos/sin of the heading, sideways drift, height of
/// the bob, and where it is in the water across and up.
typealias Pose = SIMD8<Float>

func pose(_ td: Time, _ motion: Motion) -> Pose {
    let m = motion.at(td)
    // it tips up as it climbs (and down as it dives), over the last and next moment so that it eases
    // into it; going fast, by the slope of its way rather than its speed, or a dash up or down would
    // stand it on its nose
    let a0 = motion.at(td - 0.15).p, a1 = motion.at(td + 0.15).p
    let fast = max(1, simd_length(a1 - a0) / 0.3 / 0.3)
    let climb = (a1.y - a0.y) / 0.3 / fast + (bob(td + 0.05) - bob(td - 0.05)) / 0.1
    let tip = clampD(TIP + m.tilt + 0.05 * sin(0.7 * td + 1.0) + STEEP * climb, -0.5, 0.8)
    let yaw = m.yaw + WEAVE * sin(TAU_D * td / 9.0 + 0.4) + 0.06 * sin(1.1 * td)
    return Pose(R(cos(tip)), R(sin(tip)), R(cos(yaw)), R(sin(yaw)), R(0.05 * sin(0.45 * td + 0.4)), R(HOME_Y + bob(td)),
                R(m.p.x), R(m.p.y))
}

/// how hard it strikes with its tail: on the beat, and harder the faster it goes
func stroke(_ t: Time, _ motion: Motion) -> Double { (0.70 + 0.50 * flare(t)) * (1 + EFFORT * motion.speed(t)) }

/// carry(): from the fish's own space into the water at time t. Each point runs late by how far it
/// is from the head (and out along a fin), so the body bends into every turn and the veils sweep
/// after it. With a table it covers every delay a point can have (up to about a second).
struct Carrier {
    let t: Time
    private let motion: Motion
    private let swimK: Double, phase: Double
    private var table: [Pose] = []
    private var swims: [R] = []                     // the sideways swing at each point along the body, 0...1
    static let reach: R = 1.1
    static let samples = 600
    static let swimSamples = 1024
    private static let perSecond = R(samples - 1) / reach

    init(_ t: Time, _ motion: Motion, tabulate: Bool = false) {
        self.t = t
        self.motion = motion
        swimK = SWIM * stroke(t, motion) / 0.65
        phase = (TAIL_BEAT_D * t).truncatingRemainder(dividingBy: TAU_D)
        if tabulate {
            let step = Double(Carrier.reach) / Double(Carrier.samples - 1), lo = t - Double(Carrier.reach)
            table = (0..<Carrier.samples).map { pose(lo + Double($0) * step, motion) }
            swims = (0...Carrier.swimSamples).map { R(swing(Double($0) / Double(Carrier.swimSamples))) }
        }
    }

    private func swing(_ behind: Double) -> Double {
        let b = behind - 0.25
        return b > 0 ? swimK * b * b.squareRoot() * sin(Double(ALONG_BODY) * behind - phase) : 0
    }

    /// the pose `back` seconds ago
    @inline(__always) func poseAt(_ back: R) -> Pose {
        if table.isEmpty { return pose(t - Double(back), motion) }
        let x = (Carrier.reach - back) * Carrier.perSecond
        if !(x >= 0 && x <= R(table.count - 1)) { return pose(t - Double(back), motion) }
        let i = min(Int(x), table.count - 2)
        let a = table[i]
        return a + (table[i + 1] - a) * (x - R(i))
    }

    @inline(__always) func callAsFunction(_ p: V3, _ lag: R = 0) -> V3 {
        let behind = clamp((NOSE - p.x) / LENGTH, 0, 1)
        var z = p.z
        if swims.isEmpty {
            z += R(swing(Double(behind)))
        } else if behind > 0.25 {
            let x = behind * R(Carrier.swimSamples)
            let i = min(Int(x), Carrier.swimSamples - 1)
            z += swims[i] + (swims[i + 1] - swims[i]) * (x - R(i))
        }
        let ps = poseAt(BODY_LAG * behind + lag)                     // how it holds itself, as late as this point runs
        let mv = poseAt(MOVE_BODY * BODY_LAG * behind + MOVE_FIN * lag)  // where it is: the veils trail a little
        let x = p.x - PIVOT_X, y = p.y - PIVOT_Y
        let x2 = x * ps[0] - y * ps[1]
        let y2 = x * ps[1] + y * ps[0]
        return V3(x2 * ps[2] - z * ps[3] + ps[4] + mv[6], y2 + ps[5] + mv[7], x2 * ps[3] + z * ps[2])
    }
}

// MARK: - the body

private func interp(_ x: Double, _ xp: [Double], _ fp: [Double]) -> Double {
    if x <= xp[0] { return fp[0] }
    if x >= xp[xp.count - 1] { return fp[fp.count - 1] }
    var lo = 0, hi = xp.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if xp[mid] <= x { lo = mid } else { hi = mid } }
    return fp[lo] + (fp[hi] - fp[lo]) * (x - xp[lo]) / (xp[hi] - xp[lo])
}

/// half the body's height, nose (0) to tail root (1), at 400 steps, smoothed with a Hann window
let H_D: [Double] = {
    let ku: [Double] = [0, 0.03, 0.09, 0.18, 0.32, 0.48, 0.66, 0.84, 1.0]
    let kh: [Double] = [0.004, 0.026, 0.058, 0.094, 0.128, 0.128, 0.102, 0.068, 0.047]
    let h = (0..<400).map { interp(Double($0) / 399, ku, kh) }
    let w = (0..<21).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 20) }
    let total = w.reduce(0, +)
    let padded = Array(repeating: h[0], count: 10) + h + Array(repeating: h[399], count: 10)
    return (0..<400).map { i in (0..<21).reduce(0.0) { $0 + padded[i + $1] * w[$1] } / total }
}()
let H_F: [R] = H_D.map { R($0) }

func tallD(_ u: Double) -> Double {
    let x = min(max(u, 0), 1) * 399
    let i = min(Int(x), 398)
    return H_D[i] + (H_D[i + 1] - H_D[i]) * (x - Double(i))
}
@inline(__always) func tall(_ u: R) -> R {
    let x = clamp(u, 0, 1) * 399
    let i = min(Int(x), 398)
    return H_F[i] + (H_F[i + 1] - H_F[i]) * (x - R(i))
}
func archD(_ u: Double) -> Double {
    let c = min(max(1 - u / 0.2, 0), 1)
    return 0.012 * sin(Double.pi * min(max(u, 0), 1)) - 0.010 * c * c
}
@inline(__always) func arch(_ u: R) -> R { let c = clamp(1 - u / 0.2, 0, 1); return 0.012 * sin(.pi * clamp(u, 0, 1)) - 0.010 * c * c }
@inline(__always) func backAt(_ x: R) -> R { let u = (NOSE - x) / LENGTH; return arch(u) + tall(u) }
@inline(__always) func bellyAt(_ x: R) -> R { let u = (NOSE - x) / LENGTH; return arch(u) - tall(u) }

func bodyD(_ u: Double, _ th: Double) -> V3 {
    let h = tallD(u), nose = Double(NOSE), length = Double(LENGTH)
    return V3(R(nose - length * u), R(archD(u) + h * sin(th)), R(h * (0.56 - 0.22 * u) * cos(th)))
}
@inline(__always) func body(_ u: R, _ th: R) -> V3 {
    let h = tall(u)
    return V3(NOSE - LENGTH * u, arch(u) + h * sin(th), h * (0.56 - 0.22 * u) * cos(th))
}

let MOUTH = V3(NOSE + 0.01, arch(0) + 0.012, 0)

// MARK: - the fins, in the fish's own space

let PLEATS: R = 4.5
let TAIL_LEN: R = 0.70, TAIL_SPREAD: R = 2.50, TAIL_RAYS: R = 15
let BACK_RAYS: R = 9, BELLY_RAYS: R = 11
let SWEEP: R = 0.60
let RIBBON_LEN: R = 0.60
let OAR_LEN: R = 0.15, OAR_RAYS: R = 5

@inline(__always) func scallop(_ a: R, _ rays: R) -> R { 0.94 + 0.06 * abs(cos(rays * .pi * a)).squareRoot() }
@inline(__always) func sinD(_ x: Double) -> R { R(sin(x)) }

/// A growable buffer of plain values, allocated once and reused every frame. Unlike an Array it has
/// no copy-on-write check on every write, which in the hot loops cost more than the maths.
final class Buf<T> {
    private(set) var p: UnsafeMutablePointer<T>
    private(set) var capacity: Int
    private(set) var count = 0
    private let zero: T

    init(_ zero: T, capacity: Int = 1024) {
        self.zero = zero
        self.capacity = capacity
        p = .allocate(capacity: capacity)
        p.initialize(repeating: zero, count: capacity)
    }
    deinit { p.deallocate() }

    @inline(__always) subscript(i: Int) -> T {
        get { p[i] }
        set { p[i] = newValue }
    }
    @inline(__always) func append(_ x: T) {
        if count == capacity { reserve(capacity * 2) }
        p[count] = x
        count += 1
    }
    func removeAll() { count = 0 }
    /// n values; whatever was there before is left as it was, so a writer must fill them all
    func resize(_ n: Int) {
        reserve(n)
        count = n
    }
    func fill(_ x: T) { p.update(repeating: x, count: count) }
    private func reserve(_ n: Int) {
        guard n > capacity else { return }
        let q = UnsafeMutablePointer<T>.allocate(capacity: n)
        q.moveInitialize(from: p, count: capacity)
        (q + capacity).initialize(repeating: zero, count: n - capacity)
        p.deallocate()
        p = q
        capacity = n
    }
}

/// wave(): the parts of the sideways wave that depend only on r (one per column of a sheet)...
struct WaveR {
    var p13: [R] = [], p12: [R] = [], p4: [R] = [], s1: [R] = [], c1: [R] = [], s2: [R] = [], c2: [R] = []
    init(_ rs: [R]) {
        for r in rs {
            p13.append(pow(r, 1.3)); p12.append(pow(r, 1.2)); p4.append(r * r * r * r)
            s1.append(sin(ALONG_FIN * r)); c1.append(cos(ALONG_FIN * r))
            s2.append(sin(-1.8 * r)); c2.append(cos(-1.8 * r))
        }
    }
}

/// ...and the parts that depend only on a (one per row)
struct WaveA {
    let s1, c1, s2, c2, ruffle: R
    init(a: R, root: R, t: Time, k: R) {
        let th1 = Double(root + 0.9 * (a - 0.5)) - TAIL_BEAT_D * t
        let th2 = Double(PLEATS * TAU * a + k) + 1.3 * sin(0.6 * t + Double(k))
        s1 = sinD(th1); c1 = R(cos(th1)); s2 = sinD(th2); c2 = R(cos(th2))
        ruffle = sinD(Double(19 * a + 2 * k) - 3.4 * t)
    }
    @inline(__always) func at(_ w: WaveR, _ j: Int, _ bigStroke: R) -> R {
        let swing = bigStroke * w.p13[j] * (s1 * w.c1[j] + c1 * w.s1[j])
        let pleat = 0.022 * w.p12[j] * (s2 * w.c2[j] + c2 * w.s2[j])
        return swing + pleat + 0.014 * w.p4[j] * ruffle
    }
}

/// tail(): rows are a (across the fan), columns r (out along the rays)
func tailSheet(_ As: [R], _ Rs: [R], _ t: Time, _ g: R, _ strokeT: R, _ pos: Buf<V3>, _ lag: Buf<R>, display: R = 0) {
    let na = As.count, nr = Rs.count
    pos.resize(na * nr); lag.resize(na * nr)
    let w = WaveR(Rs), bigStroke = 0.17 * strokeT, g08 = pow(g, 0.8), last = R(nr - 1)
    let spread = Rs.map { TAIL_SPREAD * (0.16 + 0.84 * g) * (1 + 0.08 * R(flare(t - 0.25 * Double($0))) + 0.22 * display) }
    for i in 0..<na {
        let a = As[i]
        let long = TAIL_LEN * (0.90 + 0.10 * sin(.pi * a)) * scallop(a, TAIL_RAYS)
        let step = long * g08 / last
        let swirl = 0.07 * sinD(Double(3.2 * a) - 1.3 * t) * g
        let wa = WaveA(a: a, root: ALONG_BODY, t: t, k: 0)
        var x = TAIL_X, y = 0.040 * (2 * a - 1), prev: R = 0
        for j in 0..<nr {
            let r = Rs[j]
            var ang = (a - 0.5) * spread[j] * (1 - 0.22 * r * r) + r * swirl
            ang -= 0.16 * r * r * cos(ang)
            let out = wa.at(w, j, bigStroke) * g
            if j > 0 {
                // a ray does not stretch: pushed out of the plane, it has less left to reach along it
                let rise = out - prev
                let flat = max(step * step - rise * rise, 0.36 * step * step).squareRoot()
                x -= flat * cos(ang); y += flat * sin(ang)
            }
            prev = out
            pos[i * nr + j] = V3(x, y, out)
            lag[i * nr + j] = FIN_LAG * long * R(j) / last
        }
    }
}

/// sail(): the fin along the back (up = 1) or the belly (up = -1)
func sailSheet(_ As: [R], _ Rs: [R], _ t: Time, _ g: R, _ up: R, _ strokeT: R, _ pos: Buf<V3>, _ lag: Buf<R>,
               display: R = 0) {
    let na = As.count, nr = Rs.count
    pos.resize(na * nr); lag.resize(na * nr)
    let w = WaveR(Rs), g08 = pow(g, 0.8), last = R(nr - 1)
    let bigStroke = (0.13 + (up < 0 ? 0.03 : 0)) * strokeT, k = 1.7 + up
    let rays = up > 0 ? BACK_RAYS : BELLY_RAYS
    let flares = Rs.map { R(flare(t - 0.25 * Double($0))) + 4.5 * display }       // flaring, the fins stand up
    for i in 0..<na {
        let a = As[i]
        let x0: R, lean0: R, longBase: R, y0: R
        if up > 0 {
            x0 = 0.00 - 0.24 * a
            lean0 = 0.10 + 0.30 * a
            longBase = (0.32 + 0.28 * a) * sin(.pi * clamp(0.14 + 0.72 * a, 0, 1)).squareRoot()
            y0 = backAt(x0) - 0.012
        } else {
            x0 = 0.04 - 0.30 * a
            lean0 = 0.08 + 0.26 * a
            longBase = (0.26 + 0.42 * a) * sin(.pi * clamp(0.12 + 0.74 * a, 0, 1)).squareRoot()
            y0 = bellyAt(x0) + 0.012
        }
        let long = longBase * scallop(a, rays)
        let step = long * g08 / last
        let swirl = 0.07 * sinD(Double(3.0 * a + up) - 1.3 * t) * g
        let wa = WaveA(a: a, root: ALONG_BODY * (NOSE - x0) / LENGTH, t: t, k: k)
        var x = x0, y = y0, prev: R = 0
        for j in 0..<nr {
            let r = Rs[j]
            let lean = 1.50 + (lean0 + SWEEP * r - 0.10 * flares[j] - 1.50) * g + r * swirl
            let out = wa.at(w, j, bigStroke) * g
            if j > 0 {
                let rise = out - prev
                let flat = max(step * step - rise * rise, 0.36 * step * step).squareRoot()
                x -= flat * sin(lean); y += flat * up * cos(lean)
            }
            prev = out
            pos[i * nr + j] = V3(x, y, 0.012 + 0.010 * r + out)
            lag[i * nr + j] = FIN_LAG * long * R(j) / last
        }
    }
}

/// ribbon(): the two long fins under its chest; per ribbon, s down its length, then w across it
func ribbonSheet(_ Ss: [R], _ Ws: [R], _ t: Time, _ g: R, _ pos: Buf<V3>, _ lag: Buf<R>) {
    let ns = Ss.count, nw = Ws.count
    pos.resize(2 * ns * nw); lag.resize(2 * ns * nw)
    let yb = bellyAt(0.13) + 0.012
    for k in 0..<2 {
        let side = R(2 * k - 1)
        for si in 0..<ns {
            let s = Ss[si]
            let reach = RIBBON_LEN * g * s
            let wide = 0.036 * pow(sin(.pi * pow(clamp(s, 0, 1), 0.55)), 0.8) * (0.4 + 0.6 * g)
            let bx = 0.13 - RIBBON_LEN * g * (0.22 * s + 0.30 * s * s)
            let by = yb - RIBBON_LEN * g * (0.96 * s - 0.20 * s * s)
            let bz = side * (0.030 + 0.07 * s) + 0.11 * pow(s, 1.3) * sinD(Double(1.4 + 3.4 * s + 2.4 * R(k)) - TAIL_BEAT_D * t)
            let sway = 0.012 * sinD(Double(9 * s) - 3 * t)
            for wi in 0..<nw {
                let w = Ws[wi], i = (k * ns + si) * nw + wi
                pos[i] = V3(bx + w * wide, by + 0.3 * w * wide, bz + w * sway)
                lag[i] = FIN_LAG * reach
            }
        }
    }
}

/// oar(): the little fins behind the gills; two sheets of 40 x 26
func oarSheet(_ t: Time, _ g: R, _ pos: Buf<V3>, _ lag: Buf<R>) {
    let na = 40, nr = 26
    pos.resize(2 * na * nr); lag.resize(2 * na * nr)
    lag.fill(0)                                         // the oars follow the body without delay
    let flank = tall(0.27) * 0.5 + 0.004
    for k in 0..<2 {
        let side = R(2 * k - 1)
        let swings = (0..<nr).map { j -> (R, R) in
            let s = 0.80 + 0.55 * sin(7.5 * t + .pi * Double(k) - 1.2 * Double(j) / Double(nr - 1))
            return (R(cos(s)), R(sin(s)))
        }
        for ia in 0..<na {
            let ang = (R(ia) / R(na - 1) - 0.5) * 1.9 * (0.3 + 0.7 * g)
            let ca = cos(ang), sa = sin(ang)
            for j in 0..<nr {
                let reach = OAR_LEN * g * R(j) / R(nr - 1)
                pos[(k * na + ia) * nr + j] = V3(0.205 - ca * swings[j].0 * reach, -0.025 + sa * reach,
                                                 side * (flank + ca * swings[j].1 * reach))
            }
        }
    }
}

// MARK: - what stays the same from frame to frame

/// A fin as a sheet of points: nk sheets of na x nr (the Python's last two grid axes).
final class Sheet {
    let nk, na, nr: Int
    let a: [R], r: [R]                  // what the Python calls a and r for each point
    let part: [Int8]
    let inks: [[V3]]                    // [palette][point]
    let ray: [Bool]
    let tip: [Bool]
    let slopeAlongA: Bool               // np.gradient(sx, axis=1): along a for the 3-D grids, r for the 2-D ones
    let wayA: R, wayB: R                // how far from the gills it springs, and how long it is
    let done: Time
    let glitter: (at: [Int], speed: [Double], phase: [Double])?
    let glitterSlot: [Int32]            // which glitter (if any) each point is
    let flareAt: [Int]
    var count: Int { nk * na * nr }

    init(nk: Int, na: Int, nr: Int, a: (Int, Int, Int) -> Double, r: (Int, Int, Int) -> Double, part: (Int) -> Int8,
         ink: (Int, R) -> V3, rays: Double, slopeAlongA: Bool, way: (R, R), done: Time,
         glitter: (at: [Int], speed: [R], phase: [R])? = nil, flareAt: [Int] = []) {
        self.nk = nk; self.na = na; self.nr = nr
        var av = [R](), rv = [R](), pv = [Int8](), rayv = [Bool](), tipv = [Bool]()
        for k in 0..<nk { for i in 0..<na { for j in 0..<nr {
            let ad = a(k, i, j), rd = r(k, i, j)
            av.append(R(ad)); rv.append(R(rd)); pv.append(part(k))
            rayv.append(rays > 0 && cos(rays * 2 * Double.pi * ad) > 0.88 && rd > 0.14)
            tipv.append(rd > 0.98 && (k * na + i) % 3 == 0)
        } } }
        self.a = av; self.r = rv; self.part = pv; self.ray = rayv; self.tip = tipv
        inks = (0..<PALETTES.count).map { pal in rv.map { ink(pal, $0) } }
        self.slopeAlongA = slopeAlongA
        wayA = way.0; wayB = way.1
        self.done = done; self.flareAt = flareAt
        self.glitter = glitter.map { ($0.at, $0.speed.map { Double($0) }, $0.phase.map { Double($0) }) }
        var slot = [Int32](repeating: -1, count: nk * na * nr)
        for (j, i) in (glitter?.at ?? []).enumerated() { slot[i] = Int32(j) }
        glitterSlot = slot
    }

    @inline(__always) func sparkles(_ i: Int, _ g: R, _ t: Time) -> Bool {
        // here and there a point of a whole fin flashes
        guard g >= 1, let gl = glitter else { return false }
        let j = Int(glitterSlot[i])
        return j >= 0 && sin(t * gl.speed[j] + gl.phase[j]) > 0.94
    }
}

func veilInk(_ pal: Int, _ r: R) -> V3 {
    let p = PALETTES[pal], v0 = p[2], v1 = p[3], v2 = p[4]
    let ink = r < 0.5 ? v0 + (v1 - v0) * smooth(r / 0.5) : v1 + (v2 - v1) * smooth((r - 0.5) / 0.45)
    return r > 0.95 ? pale(v2, 0.6) : ink
}

func linspace(_ n: Int) -> [R] { (0..<n).map { R(Double($0) / Double(n - 1)) } }
func lin(_ i: Int, _ n: Int) -> Double { Double(i) / Double(n - 1) }

struct Flare { var p: V3; var reach: Int; var strength: R; var rgb: V3; var always: Bool }

