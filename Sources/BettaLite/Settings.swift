// Everything you can change from the fish in the menu bar, remembered between launches.

import Foundation

let PALETTE_NAMES = ["Blue", "Fire", "Mustard", "Lotus", "Ice", "Koi", "Aurora", "Pearl"]

/// the letters that fill the fish, from its darkest folds to its brightest
let LETTER_SETS: [(name: String, pools: [String])] = [
    ("Classic", ["1il!;:", "rtfjcvxz=+", "aeoun0{}[]<>", "08B$#&%Q"]),
    ("Dense", [":;!il1", "tfjxz=+*", "aeounO0{}[]", "08B$#&%Q@M"]),
    ("Blocky", [".:", "+=*", "#%&", "@MW#"]),
    ("Minimal", [".", ":", "-=", "+*"]),
]

let FONTS = ["Courier", "Menlo", "Monaco", "SF Mono"]

enum ColourMode: Int { case all, favourites, timeOfDay, fixed }
enum Reaction: Int { case ignore, curious, shy }

final class Settings {
    static let shared = Settings()
    private let store = UserDefaults(suiteName: "io.github.mjasevicius.betta-lite") ?? .standard
    var onChange: ((String) -> Void)?                // told which setting changed

    private func get<T>(_ key: String, _ fallback: T) -> T { store.object(forKey: key) as? T ?? fallback }
    private func has(_ key: String) -> Bool { store.object(forKey: key) != nil }
    private func set(_ key: String, _ value: Any) {
        store.set(value, forKey: key)
        onChange?(key)
    }

    // how it looks
    /// rows of letters on a screen: more rows, a smaller fish with more room
    var rows: Int { get { get("rows", 128) } set { set("rows", newValue) } }
    var colourMode: ColourMode {
        get { ColourMode(rawValue: get("colourMode", 0)) ?? .all }
        set { set("colourMode", newValue.rawValue) }
    }
    var favourites: Set<Int> {
        get { Set(get("favourites", Array(0..<PALETTE_NAMES.count))) }
        set { set("favourites", Array(newValue).sorted()) }
    }
    var fixedSet: Int { get { get("fixedSet", 0) } set { set("fixedSet", newValue) } }
    /// seconds between new sets of colours (the original: 2)
    var colourEvery: Double { get { get("colourEvery", 8.0) } set { set("colourEvery", newValue) } }
    var glow: Double { get { get("glow", 1.0) } set { set("glow", newValue) } }
    /// how much of the last frame stays behind
    var trail: Double { get { get("trail", 0.5) } set { set("trail", newValue) } }
    var font: String { get { get("font", "Courier") } set { set("font", newValue) } }
    var letters: Int { get { get("letters", 0) } set { set("letters", newValue) } }
    /// light rays coming down through the water: 0 none, 1 normal (once a switch: on was 1)
    var rays: Double {
        get { has("rays") ? get("rays", 0.0) : (get("lightRays", false) ? 1 : 0) }
        set { set("rays", newValue) }
    }
    /// light playing over the fish, the sand and the plants: 0 none, 1 normal
    var caustics: Double { get { get("caustics", 0.0) } set { set("caustics", newValue) } }
    var surface: Bool { get { get("surface", false) } set { set("surface", newValue) } }
    var seabed: Bool { get { get("seabed", false) } set { set("seabed", newValue) } }
    var vignette: Bool { get { get("vignette", false) } set { set("vignette", newValue) } }

    // how it behaves
    var fishCount: Int { get { min(max(get("fishCount", 1), 1), MAX_FISH) } set { set("fishCount", newValue) } }
    var habits: Bool { get { get("habits", true) } set { set("habits", newValue) } }
    /// 0 lively, 1 calm, 2 very calm
    var pace: Int { get { get("pace", 1) } set { set("pace", newValue) } }
    /// lights that come up at sunrise and go down at sunset, and a sleepy fish at night (once "sleepyAtNight")
    var dayNight: Bool {
        get { has("dayNight") ? get("dayNight", false) : get("sleepyAtNight", false) }
        set { set("dayNight", newValue) }
    }
    var sunrise: Double { get { get("sunrise", 7.0) } set { set("sunrise", newValue) } }     // hours
    var sunset: Double { get { get("sunset", 22.0) } set { set("sunset", newValue) } }       // up to 24 (midnight)
    /// hours without food before it is hungry (0: never)
    var hunger: Double { get { get("hunger", 24.0) } set { set("hunger", newValue) } }
    var lastFed: Date {
        get { Date(timeIntervalSince1970: get("lastFed", Date().timeIntervalSince1970)) }
        set { set("lastFed", newValue.timeIntervalSince1970) }
    }
    var tapGlass: Bool { get { get("tapGlass", true) } set { set("tapGlass", newValue) } }
    var mouse: Reaction {
        get { Reaction(rawValue: get("mouse", 0)) ?? .ignore }
        set { set("mouse", newValue.rawValue) }
    }
    var company: Bool { get { get("company", false) } set { set("company", newValue) } }

    // practical
    var allScreens: Bool { get { get("allScreens", false) } set { set("allScreens", newValue) } }
    var pauseOnBattery: Bool { get { get("pauseOnBattery", false) } set { set("pauseOnBattery", newValue) } }
    var pauseLowPower: Bool { get { get("pauseLowPower", true) } set { set("pauseLowPower", newValue) } }
    /// not remembered: a paused fish wakes up again with the next launch
    var paused = false { didSet { onChange?("paused") } }

    /// the first time it runs, it has just been fed
    func start() {
        // the first time: the settings it had before it had this name (as ASCII Betta Fish)
        if !has("adopted"), let old = UserDefaults.standard.persistentDomain(forName: "local.bettafish") {
            for (k, v) in old where store.object(forKey: k) == nil { store.set(v, forKey: k) }
        }
        store.set(true, forKey: "adopted")
        if !has("lastFed") { store.set(Date().timeIntervalSince1970, forKey: "lastFed") }
    }

    /// how deep into the night it is by the clock (0 day, 1 night, fading over an hour around sunset
    /// and sunrise), and how golden the light is (most at sunrise and sunset themselves); both always 0
    /// unless the lights follow the clock
    func light(at date: Date = Date()) -> (night: Double, dawn: Double) {
        guard dayNight else { return (0, 0) }
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        var h = Double(c.hour ?? 12) + Double(c.minute ?? 0) / 60 + Double(c.second ?? 0) / 3600
        if h < sunrise - 1 { h += 24 }                              // past midnight: still the night before
        func ramp(_ x: Double) -> Double { let x = min(max(x, 0), 1); return x * x * (3 - 2 * x) }
        let day = ramp(h - sunrise + 0.5) * (1 - ramp(h - sunset + 0.5))
        return (1 - day, 4 * day * (1 - day))
    }

    /// whether it is hungry: not fed for as long as it can go
    func hungry(at date: Date = Date()) -> Bool {
        hunger > 0 && date.timeIntervalSince(lastFed) > hunger * 3600
    }

    /// the sets it may wear now
    func allowedPalettes(at date: Date = Date()) -> [Int] {
        switch colourMode {
        case .all: return Array(0..<PALETTE_NAMES.count)
        case .favourites: return favourites.isEmpty ? Array(0..<PALETTE_NAMES.count) : favourites.sorted()
        case .fixed: return [fixedSet]
        case .timeOfDay:
            let h = Calendar.current.component(.hour, from: date)
            switch h {
            case 6..<11: return [3, 2, 7]       // morning: lotus, mustard, pearl
            case 11..<17: return [5, 0, 2]      // day: koi, blue, mustard
            case 17..<22: return [1, 7, 3]      // evening: fire, pearl, lotus
            default: return [4, 0, 6]           // night: ice, blue, aurora
            }
        }
    }
}
