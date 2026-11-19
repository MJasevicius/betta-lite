// Where a fish goes, and what it does on the way. A chain of legs (rest, turn round, swim, and
// the habits of a real betta: flaring its fins, darting up for air, blowing a bubble nest; begging
// at the glass when it is hungry) drawn at random as time runs on. Something can cut in (a pellet,
// the mouse, a tap on the glass): the chain is then cut at that moment and goes on from where the
// fish is, at the speed it has, so it never jerks.
//
// The water is one or more areas, one per screen: a fish may roam from one screen to the next.

import Foundation
import simd

typealias P2 = SIMD2<Double>

/// what the fish is in the mood for: from the settings and the clock
struct Mood {
    var pace = 1                    // 0 lively, 1 calm, 2 very calm
    var night = 0.0                 // 0 day ... 1 deep in the night
    var habits = true
    var hungry = false
}

/// one screen's worth of water, in the water's units
struct Area {
    var xs: ClosedRange<Double>, ys: ClosedRange<Double>   // where the middle of a fish may go
    var left = 0.0, right = 0.0, bottom = 0.0, top = 0.0   // the screen
    var surface = 0.0                                      // where the water ends (the top, or the drawn surface)
    var gulpY = 0.0                                        // where the middle of a fish goes for a gulp of air
    var floor = 0.0                                        // where pellets come to rest
}

final class Motion {
    enum Kind { case rest, turn, swim, flare, gulp, nest, look }
    enum Purpose { case roam, gulp, nest, chase, approach, dart, flee, beg, inspect }
    struct Leg {
        let kind: Kind
        var purpose: Purpose = .roam
        let t0: Time, t1: Time
        let p0: P2, p1: P2
        var v0: P2 = .zero                  // the speed it sets off with
        var v1: P2 = .zero                  // and the speed it ends with (only a turn in a fright goes straight on)
        var tilt0 = 0.0                     // the tip of its nose it was cut off with, which it eases out of
        let yaw0: Double, yaw1: Double
        var bend = 0.0                      // how far a swim curves off the straight line
    }
    static let turnTime: Time = 2.2

    private(set) var areas: [Area]
    var mood = Mood()
    var nest: P2?                           // where it goes to blow bubbles into its nest, once it has one
    var others: [P2] = []                   // where the other fish are: it picks somewhere away from them
    private var legs: [Leg]
    private var rng: SplitMix

    static func yaw(_ facing: Double) -> Double { facing > 0 ? FACING : .pi - FACING }
    static func facing(_ yaw: Double) -> Double { yaw < .pi / 2 ? 1 : -1 }

    init(seed: UInt64, areas: [Area], start: P2 = .zero) {
        self.areas = areas
        rng = SplitMix(seed, 1)
        legs = [Leg(kind: .rest, t0: -1e9, t1: T_SWIM, p0: start, p1: start, yaw0: FACING, yaw1: FACING)]
    }

    /// where it may go from now on (it finishes what it is doing first)
    func bound(_ areas: [Area]) {
        self.areas = areas
        if let n = nest {                                   // its nest stays on its screen, just under the water's top
            let a = self.areas[area(n)]
            nest = a.left <= n.x && n.x <= a.right ? P2(min(max(n.x, a.xs.lowerBound), a.xs.upperBound), a.ys.upperBound) : nil
        }
    }

    /// the area p is in (or the nearest)
    func area(_ p: P2) -> Int {
        var best = 0, bestD = Double.infinity
        for (i, a) in areas.enumerated() {
            if p.x >= a.left && p.x <= a.right && p.y >= a.bottom && p.y <= a.top { return i }
            let dx = max(a.xs.lowerBound - p.x, 0, p.x - a.xs.upperBound)
            let dy = max(a.ys.lowerBound - p.y, 0, p.y - a.ys.upperBound)
            if dx * dx + dy * dy < bestD { bestD = dx * dx + dy * dy; best = i }
        }
        return best
    }

    /// p moved to where a fish's middle may be (up to where it gulps air, with `lift`)
    func clamp(_ p: P2, lift: Bool = false) -> P2 {
        let a = areas[area(p)]
        return P2(min(max(p.x, a.xs.lowerBound), a.xs.upperBound),
                  min(max(p.y, a.ys.lowerBound), lift ? max(a.gulpY, a.ys.upperBound) : a.ys.upperBound))
    }

    // MARK: planning

    private var speedScale: Double { [1.35, 1.0, 0.7][min(max(mood.pace, 0), 2)] * (1 - 0.4 * mood.night) }
    private func restTime() -> Time {
        let (a, b) = [(0.6, 2.5), (1.0, 4.5), (3.0, 8.0)][min(max(mood.pace, 0), 2)]
        return rng.range(a, b) * (1 + 0.8 * mood.night)
    }

    private func add(_ leg: Leg) { legs.append(leg) }
    private func stay(_ kind: Kind, _ purpose: Purpose = .roam, at p: P2, yaw: Double, from t0: Time, for time: Time) {
        add(Leg(kind: kind, purpose: purpose, t0: t0, t1: t0 + time, p0: p, p1: p, yaw0: yaw, yaw1: yaw))
    }

    /// go to `target` from `p` (facing as `yaw`, moving at `v`), from time `t0`: turning round first if
    /// it is behind
    private func go(from p: P2, yaw: Double, v: P2, at t0: Time, to target: P2, speed: Double, purpose: Purpose,
                    bend: Double = 0, tilt: Double = 0) {
        var from = p, start = t0, v0 = v, yaw0 = yaw, tilt0 = tilt
        let dx = target.x - p.x
        let facing = Motion.facing(yaw)
        let way: Double = abs(dx) < 0.08 ? facing : (dx > 0 ? 1 : -1)
        let want = Motion.yaw(way)
        if abs(want - yaw) > 0.15 {
            let time: Time, end: P2, v1: P2
            if purpose == .flee {
                // in a fright, all in one: it whips round and is already shooting off as it comes out of
                // the turn, straight on into the dash
                time = max(0.3, 0.55 * abs(want - yaw) / (.pi - 2 * FACING))
                let d = target - p, dir = simd_length(d) > 1e-6 ? d / simd_length(d) : P2(way, 0)
                v1 = dir * min(speed * 0.8, simd_length(d) / 0.8)
                end = clamp(p + (v * 0.25 + v1 * 0.35) * time, lift: true)
            } else {
                // turn round, gliding on with whatever speed it had (or a little, if it had none)
                time = max(0.8, Motion.turnTime * abs(want - yaw) / (.pi - 2 * FACING))
                let glide = simd_length(v) < 0.05 ? P2(0.12 * facing, 0) : v * (time / 3)
                end = clamp(p + glide, lift: true)
                v1 = .zero
            }
            add(Leg(kind: .turn, purpose: purpose, t0: t0, t1: t0 + time, p0: p, p1: end, v0: v, v1: v1, tilt0: tilt0,
                    yaw0: yaw, yaw1: want))
            from = end; start = t0 + time; v0 = v1; yaw0 = want; tilt0 = 0
        }
        let dist = simd_length(target - from)
        let least: Time = purpose == .flee ? 1.3 : purpose == .dart ? 1.2 : 2.2
        var time = max(least, dist / speed)
        // setting off fast towards somewhere near, it gets there sooner, rather than shooting past and
        // coming back
        let along = dist > 1e-6 ? simd_dot(v0, target - from) / dist : 0
        if along * time > 2.5 * dist { time = max(dist / speed, 2.5 * dist / along) }
        add(Leg(kind: .swim, purpose: purpose, t0: start, t1: start + time, p0: from, p1: target, v0: v0, tilt0: tilt0,
                yaw0: yaw0, yaw1: yaw0, bend: bend))
    }

    private func extend() {
        let last = legs.last!
        let p = last.p1, yaw = last.yaw1, t0 = last.t1
        let night = mood.night
        let a = areas[area(p)]
        switch (last.kind, last.purpose) {
        case (.swim, .gulp):
            // at the top: a gulp of air
            stay(.gulp, at: p, yaw: yaw, from: t0, for: 0.9)
        case (.swim, .nest):
            // under its nest: blow bubbles into it for a while
            stay(.nest, at: p, yaw: yaw, from: t0, for: rng.range(4, 8))
        case (.swim, .beg):
            // at the glass, looking out at you
            stay(.look, .beg, at: p, yaw: yaw, from: t0, for: rng.range(3, 6))
        case (.swim, .inspect):
            // where the glass was tapped: what was that?
            stay(.look, .inspect, at: p, yaw: yaw, from: t0, for: rng.range(2.5, 4))
        case (.gulp, _):
            // and back down
            let target = P2(min(max(p.x + rng.range(-0.6, 0.6), a.xs.lowerBound), a.xs.upperBound),
                            rng.range(a.ys.lowerBound, (a.ys.lowerBound + a.ys.upperBound) / 2))
            go(from: p, yaw: yaw, v: .zero, at: t0, to: target, speed: 0.3 * speedScale, purpose: .roam)
        case (.swim, _), (.nest, _):
            if mood.hungry {
                stay(.rest, at: p, yaw: yaw, from: t0, for: rng.range(0.5, 1.2))
            } else if mood.habits && night < 0.5 && rng.unit() < 0.22 {
                // flare: spread every fin at nothing in particular, turned a little towards us
                stay(.flare, at: p, yaw: yaw, from: t0, for: rng.range(3.5, 5))
            } else {
                stay(.rest, at: p, yaw: yaw, from: t0, for: restTime())
            }
        case (.rest, _), (.flare, _), (.turn, _), (.look, _):
            let r = rng.unit()
            if mood.hungry {
                // hungry: up near the top, at the front of the glass, waiting to be fed
                let x = min(max(p.x + rng.range(-0.7, 0.7), a.xs.lowerBound), a.xs.upperBound)
                let y = a.ys.upperBound - (a.ys.upperBound - a.ys.lowerBound) * rng.range(0.03, 0.22)
                go(from: p, yaw: yaw, v: .zero, at: t0, to: P2(x, y), speed: 0.3 * speedScale, purpose: .beg)
            } else if mood.habits && r < 0.12 * (1 - night) {
                // dart up for air
                let x = min(max(p.x + rng.range(-0.4, 0.4), a.xs.lowerBound), a.xs.upperBound)
                go(from: p, yaw: yaw, v: .zero, at: t0, to: P2(x, max(a.gulpY, a.ys.upperBound)), speed: 0.45, purpose: .gulp)
            } else if mood.habits && r < 0.26 * (1 - night) + 0.12 * night {
                // to its bubble nest (starting one on this screen, if it has none)
                let n = nest ?? P2(rng.range(a.xs.lowerBound, a.xs.upperBound), a.ys.upperBound)
                nest = n
                let na = areas[area(n)]
                let x = min(max(n.x + rng.range(-0.1, 0.1), na.xs.lowerBound), na.xs.upperBound)
                go(from: p, yaw: yaw, v: .zero, at: t0, to: P2(x, n.y), speed: 0.24 * speedScale, purpose: .nest)
            } else {
                // somewhere else (on any screen), far enough across to be worth the swim, and as far from
                // the other fish as it can find; low down at night
                var target = p, best = -Double.infinity
                for _ in 0..<12 {
                    let b = areas[pick()]
                    let top = b.ys.lowerBound + (b.ys.upperBound - b.ys.lowerBound) * (1 - 0.65 * night)
                    let q = P2(rng.range(b.xs.lowerBound, b.xs.upperBound), rng.range(b.ys.lowerBound, top))
                    let across = abs(q.x - p.x) >= 0.3 * (b.xs.upperBound - b.xs.lowerBound)
                    let room = others.map { simd_length(($0 - q) * P2(1, 1.6)) }.min() ?? 0
                    let score = (across ? 10 : 0) + min(room, 3)
                    if score > best { best = score; target = q }
                    if others.isEmpty && across { break }
                }
                let dist = simd_length(target - p)
                go(from: p, yaw: yaw, v: .zero, at: t0, to: target, speed: 0.24 * speedScale * rng.range(0.85, 1.2),
                   purpose: .roam, bend: rng.range(-0.18, 0.18) * min(dist, 3))
            }
        }
    }

    /// an area to swim to: a wider screen is likelier
    private func pick() -> Int {
        guard areas.count > 1 else { return 0 }
        let w = areas.map { $0.xs.upperBound - $0.xs.lowerBound + 0.6 }
        var r = rng.unit() * w.reduce(0, +)
        for (i, x) in w.enumerated() { r -= x; if r < 0 { return i } }
        return areas.count - 1
    }

    /// Cut in: from time t, head for `target` instead, from where it is and at the speed it has.
    func redirect(_ t: Time, to target: P2, speed: Double, purpose: Purpose) {
        let here = at(t), v = velocity(t)
        legs.removeAll { $0.t0 > t }
        let goal = clamp(target, lift: purpose == .chase)
        go(from: here.p, yaw: here.yaw, v: v, at: t, to: goal, speed: speed, purpose: purpose, tilt: here.tilt)
    }

    // MARK: where it is

    private func leg(_ t: Time) -> Leg {
        while legs.last!.t1 <= t { extend() }
        if legs.count > 400 && legs[200].t1 < t - 60 { legs.removeFirst(200) }   // nothing looks that far back
        if t < legs[0].t0 { return legs[0] }
        var lo = 0, hi = legs.count - 1                     // the last leg to have started by t
        while lo < hi { let mid = (lo + hi + 1) / 2; if legs[mid].t0 <= t { lo = mid } else { hi = mid - 1 } }
        return legs[lo]
    }

    func kind(_ t: Time) -> (kind: Kind, purpose: Purpose, t0: Time) { let l = leg(t); return (l.kind, l.purpose, l.t0) }

    /// how far it is spreading its fins in a flare (0...1)
    func display(_ t: Time) -> Double {
        let l = leg(t)
        guard l.kind == .flare else { return 0 }
        let u = (t - l.t0) / (l.t1 - l.t0)
        return smoothD(u / 0.25) * (1 - smoothD((u - 0.7) / 0.3))
    }

    /// where it is (the middle of the fish), which way it faces, and how much further it tips its nose
    /// up than usual (for a gulp of air), before any weaving and bobbing
    func at(_ t: Time) -> (p: P2, yaw: Double, tilt: Double) {
        let l = leg(t)
        let u = clampD((t - l.t0) / (l.t1 - l.t0), 0, 1)
        let up = 0.38                                       // nose up at the surface
        switch l.kind {
        case .rest, .nest:
            return (l.p0, l.yaw0, 0)
        case .gulp:
            return (l.p0, l.yaw0, up * (1 - smoothD((u - 0.6) / 0.4)))
        case .flare:
            return (l.p0, l.yaw0 + (.pi / 2 - l.yaw0) * 0.4 * display(t), 0)
        case .look:
            let k = smoothD(u / 0.2) * (1 - smoothD((u - 0.8) / 0.2))
            return (l.p0, l.yaw0 + (.pi / 2 - l.yaw0) * 0.55 * k, 0)
        case .turn, .swim:
            // sets off at the speed it had and comes smoothly to a stop, or to the speed it goes on with
            // (quintic Hermite)
            let u2 = u * u, u3 = u2 * u, u4 = u3 * u, u5 = u4 * u
            let h0 = 1 - 10 * u3 + 15 * u4 - 6 * u5, h1 = u - 6 * u3 + 8 * u4 - 3 * u5, h5 = 10 * u3 - 15 * u4 + 6 * u5
            let h4 = -4 * u3 + 7 * u4 - 3 * u5
            var q = l.p0 * h0 + l.p1 * h5 + (l.v0 * h1 + l.v1 * h4) * (l.t1 - l.t0)
            if l.bend != 0 {
                // curving off the line and back, setting off and arriving straight (no sudden swerve)
                let d = l.p1 - l.p0, n = simd_length(d) > 1e-9 ? P2(-d.y, d.x) / simd_length(d) : .zero
                let s = sin(.pi * u)
                q += n * (l.bend * s * s)
            }
            let yaw = l.kind == .turn ? l.yaw0 + (l.yaw1 - l.yaw0) * smoothD(u) : l.yaw0
            var tilt = l.purpose == .gulp && l.kind == .swim ? up * smoothD((u - 0.55) / 0.45) : 0
            if l.tilt0 != 0 { tilt += l.tilt0 * (1 - smoothD((t - l.t0) / 0.5)) }
            return (q, yaw, tilt)
        }
    }

    func velocity(_ t: Time) -> P2 { (at(t + 0.02).p - at(t - 0.02).p) / 0.04 }
    func speed(_ t: Time) -> Double { simd_length(at(t + 0.05).p - at(t - 0.05).p) / 0.1 }
}
