// Drawing one screen's part of the tank on the GPU. The CPU hands over one character and one colour
// per cell, for the fish's layer and the scenery's; Metal does what pygame did on the CPU: letters
// from a glyph atlas tinted per cell (the fish's over the scenery's), a trail that keeps half of the
// last frame, and a tight and a wide glow added on top. Then, if wanted, light playing over
// everything (caustics), rays coming down through the water, darker edges, the colour of the sun
// rising or setting, and all of it dimmer at night.

import AppKit
import CoreText
import Metal
import simd

let CELL_W = 7, CELL_H = 10                             // a cell of the Python window, in its pixels
let TRAIL: Float = 0.50                                 // how much of the last frame stays behind

private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut fullscreen(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VOut o;
    o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

struct Grid {
    uint2 fcells; uint2 scells;                 // the fish's layer and the scenery's, in cells
    float2 ftile; float2 fstride; float2 stile; float2 sstride;
    float2 origin; float2 size;                 // this screen, in points from the top left of all of them
    uint atlasCols; float decay; float unit; float time; float caustics; float dawn;
};

// light through a rippling surface, as it plays over the bottom of a pool (after the well-known
// tileable water caustic by joltz0r and Dave Hoskins)
float caustic(float2 p, float t) {
    float2 i = p;
    float c = 1.0;
    const float inten = 0.005;
    for (int n = 0; n < 4; n++) {
        float tt = t * (1.0 - 3.5 / float(n + 1));
        i = p + float2(cos(tt - i.x) + sin(tt + i.y), sin(tt - i.y) + cos(tt + i.x));
        c += 1.0 / length(float2(p.x / (sin(i.x + tt) / inten), p.y / (cos(i.y + tt) / inten)));
    }
    c /= 4.0;
    c = 1.17 - pow(c, 1.4);
    return clamp(pow(abs(c), 8.0), 0.0, 1.0);
}

float3 glyph(texture2d<float> atlas, uchar4 cell, float2 g, float2 tile, float2 stride, uint atlasCols) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float2 local = clamp(fract(g) * tile, 0.5, tile - 0.5);
    float2 o = float2(cell.a % atlasCols, cell.a / atlasCols) * stride + 1.0;
    float cover = atlas.sample(lin, (o + local) / float2(atlas.get_width(), atlas.get_height())).r;
    return cover * float3(cell.rgb) / 255.0;
}

// this frame's letters, each tinted with its cell's colour (a fish's in front of the scenery), kept
// wherever brighter than the trail
fragment float4 letters(VOut in [[stage_in]], constant Grid& u [[buffer(0)]], device const uchar4* fish [[buffer(1)]],
                        device const uchar4* scenery [[buffer(2)]], texture2d<float> fatlas [[texture(0)]],
                        texture2d<float> prev [[texture(1)]], texture2d<float> satlas [[texture(2)]]) {
    float2 g = in.uv * float2(u.fcells);
    uint2 c = min(uint2(g), u.fcells - 1);
    uchar4 cell = fish[c.y * u.fcells.x + c.x];
    float3 art = 0.0;
    if (cell.a > 0) {
        art = glyph(fatlas, cell, g, u.ftile, u.fstride, u.atlasCols);
    } else {
        float2 h = in.uv * float2(u.scells);
        uint2 d = min(uint2(h), u.scells - 1);
        uchar4 back = scenery[d.y * u.scells.x + d.x];
        if (back.a > 0) { art = glyph(satlas, back, h, u.stile, u.sstride, u.atlasCols); }
    }
    if (u.caustics > 0.0 && max(art.r, max(art.g, art.b)) > 0.0) {
        float2 world = (u.origin + in.uv * u.size) / u.unit;
        float k = caustic(world * 5.5 - 250.0, u.time * 0.45);
        float lum = max(art.r, max(art.g, art.b));
        art *= 1.0 - 0.25 * u.caustics * (1.0 - k);                     // a little shade between the bright lines
        art += float3(0.55, 0.80, 1.00) * (0.55 * u.caustics * k * min(lum * 2.0, 1.0));   // and light on them
    }
    if (u.dawn > 0.0) { art *= mix(float3(1.0), float3(1.18, 0.92, 0.70), u.dawn); }     // the sun low and golden
    float3 last = prev.read(uint2(in.pos.xy)).rgb * u.decay;
    return float4(max(last, art), 1.0);
}

// a smaller copy, averaged through the mipmaps
fragment float4 shrink(VOut in [[stage_in]], constant float& lod [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    constexpr sampler tri(filter::linear, mip_filter::linear, address::clamp_to_edge);
    return float4(src.sample(tri, in.uv, level(lod)).rgb, 1.0);
}

// one direction of a gaussian blur; p = (dx, dy, sigma, half width)
fragment float4 blur(VOut in [[stage_in]], constant float4& p [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    int2 size = int2(src.get_width(), src.get_height());
    int2 at = int2(in.pos.xy);
    int hw = int(p.w);
    float3 acc = 0.0;
    float total = 0.0;
    for (int i = -hw; i <= hw; i++) {
        float w = exp(-float(i * i) / (2.0 * p.z * p.z));
        int2 q = clamp(at + i * int2(p.xy), int2(0), size - 1);
        acc += src.read(uint2(q)).rgb * w;
        total += w;
    }
    return float4(acc / total, 1.0);
}

struct Look { float2 origin; float2 size; float glow; float brightness; float rays; float vignette; float time;
              float unit; float dawn; float pad; };

// the trail with both glows added; then, if wanted, light coming down through the water and the
// edges darkened; and all of it dimmer at night
fragment float4 compose(VOut in [[stage_in]], constant Look& L [[buffer(0)]], texture2d<float> trail [[texture(0)]],
                        texture2d<float> tight [[texture(1)]], texture2d<float> wide [[texture(2)]]) {
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    float3 c = trail.read(uint2(in.pos.xy)).rgb;
    if (L.glow > 0.0) { c += L.glow * (0.75 * tight.sample(lin, in.uv).rgb + 0.45 * wide.sample(lin, in.uv).rgb); }
    if (L.rays > 0.0) {
        float x = (L.origin.x + in.uv.x * L.size.x) / L.unit + in.uv.y * 0.35;     // slanting down from the top left
        float b = 0.0;
        b += pow(0.5 + 0.5 * sin(x * 5.0 + L.time * 0.07), 8.0);
        b += 0.7 * pow(0.5 + 0.5 * sin(x * 9.0 - L.time * 0.05 + 1.7), 10.0);
        b += 0.5 * pow(0.5 + 0.5 * sin(x * 14.0 + L.time * 0.11 + 4.1), 12.0);
        float shimmer = 0.75 + 0.25 * sin(L.time * 0.6 + x * 3.0);
        float3 tint = mix(float3(0.30, 0.50, 0.70), float3(0.80, 0.50, 0.28), L.dawn);
        c += tint * (b * shimmer * pow(1.0 - in.uv.y, 1.6) * 0.07 * L.rays);
    }
    if (L.vignette > 0.0) {
        float aspect = L.size.x / L.size.y;
        float2 d = (in.uv - 0.5) * float2(aspect, 1.0);
        float r = length(d) / (0.5 * length(float2(aspect, 1.0)));
        c *= 1.0 - 0.65 * L.vignette * smoothstep(0.35, 1.0, r);
    }
    return float4(min(c * L.brightness, 1.0), 1.0);
}
"""

private struct GridU {
    var fcells: SIMD2<UInt32>, scells: SIMD2<UInt32>
    var ftile: SIMD2<Float>, fstride: SIMD2<Float>, stile: SIMD2<Float>, sstride: SIMD2<Float>
    var origin: SIMD2<Float>, size: SIMD2<Float>
    var atlasCols: UInt32, decay: Float, unit: Float, time: Float, caustics: Float, dawn: Float
}

private struct LookU {
    var origin: SIMD2<Float>, size: SIMD2<Float>
    var glow, brightness, rays, vignette, time, unit, dawn, pad: Float
}

final class Renderer {
    // how it looks: set from the menu
    var glow: Float = 1                     // 0 none, 1 as in the original
    var trail: Float = TRAIL                // how much of the last frame stays behind
    var brightness: Float = 1               // dimmer at night
    var dawn: Float = 0                     // how golden the light is (the sun rising or setting)
    var rays: Float = 0                     // light rays coming down: 0 none, 1 normal
    var caustics: Float = 0                 // light playing over everything: 0 none, 1 normal
    var vignette = false
    var font = "Courier" { didSet { if font != oldValue { rebuildAtlas() } } }
    var time: Float = 0

    let device: MTLDevice
    let queue: MTLCommandQueue
    let tank: Tank
    /// which of the tank's screens this draws
    var screen: Int { didSet { if screen != oldValue { version = -1 } } }
    private let lettersPSO, shrinkPSO, blurPSO, composePSO: MTLRenderPipelineState
    private var trails: [MTLTexture] = []
    private var current = 0
    private var tightA, tightB, wideA, wideB: MTLTexture?
    private var fatlas: MTLTexture?, satlas: MTLTexture?
    private var atlasCols = 16, ftile = SIMD2<Float>(7, 10), stile = SIMD2<Float>(7, 10)
    private var cells: [(fish: MTLBuffer, scenery: MTLBuffer)] = []
    private var slot = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private(set) var width = 0, height = 0
    private var version = -1                // the tank's layout this was last fitted to
    private var fr = Region(x0: 0, y0: 0, cols: 1, rows: 1), sr = Region(x0: 0, y0: 0, cols: 1, rows: 1)
    var resetTrail = true

    init(device: MTLDevice, targetFormat: MTLPixelFormat, tank: Tank, screen: Int = 0) throws {
        self.device = device
        self.tank = tank
        self.screen = screen
        queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        func pipeline(_ fragment: String, _ format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fullscreen")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        lettersPSO = try pipeline("letters", .rgba16Float)
        shrinkPSO = try pipeline("shrink", .rgba16Float)
        blurPSO = try pipeline("blur", .rgba16Float)
        composePSO = try pipeline("compose", targetFormat)
        refit()
    }

    /// this screen's part of the tank's grids, and what goes with their size
    private func refit() {
        version = tank.version
        let layout = tank.layout
        let i = min(screen, layout.fish.regions.count - 1)
        fr = layout.fish.regions[i]; sr = layout.scenery.regions[i]
        // the glows live at a quarter and an eighth of the size the Python would draw this grid at,
        // whatever the size on screen
        let lw = fr.cols * CELL_W, lh = fr.rows * CELL_H
        func texture(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: max(w, 1), height: max(h, 1),
                                                             mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        tightA = texture(lw / 4, lh / 4); tightB = texture(lw / 4, lh / 4)
        wideA = texture(lw / 8, lh / 8); wideB = texture(lw / 8, lh / 8)
        cells = (0..<3).map { _ in
            (device.makeBuffer(length: fr.cols * fr.rows * 4, options: .storageModeShared)!,
             device.makeBuffer(length: sr.cols * sr.rows * 4, options: .storageModeShared)!)
        }
        resetTrail = true
        rebuildAtlas()
    }

    /// the size of what we draw into, in pixels: the trail and the glyph atlases follow it
    func resize(_ w: Int, _ h: Int) {
        guard w > 0, h > 0, w != width || h != height else { return }
        width = w; height = h
        trails = (0..<2).map { _ in
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: w, height: h, mipmapped: true)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        resetTrail = true
        rebuildAtlas()
    }

    private func rebuildAtlas() {
        guard width > 0, height > 0 else { return }
        func size(_ r: Region) -> (Int, Int) {
            (max(Int((Double(width) / Double(r.cols)).rounded()), 3), max(Int((Double(height) / Double(r.rows)).rounded()), 4))
        }
        let (fw, fh) = size(fr), (sw, sh) = size(sr)
        fatlas = makeAtlas(fw, fh)
        satlas = (sw, sh) == (fw, fh) ? fatlas : makeAtlas(sw, sh)
        ftile = SIMD2(Float(fw), Float(fh)); stile = SIMD2(Float(sw), Float(sh))
    }

    /// white letters on black, one cell each with a pixel of space round it, drawn the way pygame
    /// did: 11 px in a 7 x 10 cell, centred, scaled up to the cell we have. Courier is what the
    /// original's font list falls back to on a Mac.
    private func makeAtlas(_ cw: Int, _ ch: Int) -> MTLTexture {
        let rows = (95 + atlasCols - 1) / atlasCols
        let sw = cw + 2, sh = ch + 2
        let W = atlasCols * sw, H = rows * sh
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldSmoothFonts(false)
        let size = CGFloat(ch) * 1.1
        let font: CTFont = self.font == "SF Mono" ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont
            : CTFontCreateWithName(self.font as CFString, size, nil)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        for code in 33..<127 {
            let gi = code - 32
            let ox = (gi % atlasCols) * sw + 1, oy = (gi / atlasCols) * sh + 1           // from the top
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(UnicodeScalar(code)!), attributes: attrs))
            let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let top = (CGFloat(ch) - (ascent + descent)) / 2
            ctx.saveGState()
            ctx.clip(to: CGRect(x: ox, y: H - oy - ch, width: cw, height: ch))
            ctx.textPosition = CGPoint(x: CGFloat(ox) + (CGFloat(cw) - advance) / 2, y: CGFloat(H - oy) - top - ascent)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: W, height: H, mipmapped: false)
        d.usage = .shaderRead
        let tex = device.makeTexture(descriptor: d)!
        tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: ctx.data!, bytesPerRow: W)
        return tex
    }

    private func pass(_ cmd: MTLCommandBuffer, _ target: MTLTexture, _ pso: MTLRenderPipelineState,
                      _ setup: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .dontCare
        rp.colorAttachments[0].storeAction = .store
        let enc = cmd.makeRenderCommandEncoder(descriptor: rp)!
        enc.setRenderPipelineState(pso)
        setup(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// copy this screen's part of a layer into a buffer for the GPU
    private func pack(_ r: Region, cols: Int, _ char: Buf<Int16>, _ col: Buf<V3>, into buf: MTLBuffer) {
        let out = buf.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: r.cols * r.rows)
        let ch = char.p, cl = col.p
        let lo = V3(repeating: 0), hi = V3(repeating: 1)
        for y in 0..<r.rows {
            let from = (r.y0 + y) * cols + r.x0, to = y * r.cols
            for x in 0..<r.cols {
                let g = ch[from + x]
                if g == 0 { out[to + x] = .zero; continue }
                let c = pointwiseMin(pointwiseMax(cl[from + x], lo), hi) * 255
                out[to + x] = SIMD4<UInt8>(UInt8(c.x), UInt8(c.y), UInt8(c.z), UInt8(clamping: g))
            }
        }
    }

    /// Hand this screen's part of the tank's frame to the GPU and draw it into target (the window, or a picture).
    func draw(into target: MTLTexture, _ cmd: MTLCommandBuffer) {
        if version != tank.version { refit() }
        guard let fatlas, let satlas, let tightA, let tightB, let wideA, let wideB else { return }
        inFlight.wait()
        let sem = inFlight
        cmd.addCompletedHandler { _ in sem.signal() }
        slot = (slot + 1) % cells.count
        let buf = cells[slot]
        pack(fr, cols: tank.cols, tank.char, tank.col, into: buf.fish)
        pack(sr, cols: tank.scols, tank.schar, tank.scol, into: buf.scenery)

        let layout = tank.layout
        let f = layout.screens[min(screen, layout.screens.count - 1)]
        let origin = SIMD2<Float>(Float(f.minX - layout.world.minX), Float(layout.world.maxY - f.maxY))
        let size = SIMD2<Float>(Float(f.width), Float(f.height)), unit = Float(layout.screens[0].height)

        let prev = trails[current], next = trails[1 - current]
        current = 1 - current
        var grid = GridU(fcells: SIMD2(UInt32(fr.cols), UInt32(fr.rows)), scells: SIMD2(UInt32(sr.cols), UInt32(sr.rows)),
                         ftile: ftile, fstride: ftile + 2, stile: stile, sstride: stile + 2, origin: origin, size: size,
                         atlasCols: UInt32(atlasCols), decay: resetTrail ? 0 : Float(Int(trail * 255)) / 255,
                         unit: unit, time: time, caustics: caustics, dawn: dawn)
        resetTrail = false
        pass(cmd, next, lettersPSO) { enc in
            enc.setFragmentBytes(&grid, length: MemoryLayout<GridU>.stride, index: 0)
            enc.setFragmentBuffer(buf.fish, offset: 0, index: 1)
            enc.setFragmentBuffer(buf.scenery, offset: 0, index: 2)
            enc.setFragmentTexture(fatlas, index: 0)
            enc.setFragmentTexture(prev, index: 1)
            enc.setFragmentTexture(satlas, index: 2)
        }
        if glow > 0 {                                       // no glow: none of its passes either
            let blit = cmd.makeBlitCommandEncoder()!
            blit.generateMipmaps(for: next)
            blit.endEncoding()

            var lod = log2(Float(next.width) / Float(tightA.width))
            pass(cmd, tightA, shrinkPSO) { enc in
                enc.setFragmentBytes(&lod, length: 4, index: 0)
                enc.setFragmentTexture(next, index: 0)
            }
            blur(cmd, tightA, tightB, sigma: 2)
            var zero: Float = 0
            pass(cmd, wideA, shrinkPSO) { enc in
                enc.setFragmentBytes(&zero, length: 4, index: 0)
                enc.setFragmentTexture(tightA, index: 0)
            }
            blur(cmd, wideA, wideB, sigma: 3)
        }
        var look = LookU(origin: origin, size: size, glow: glow, brightness: brightness, rays: rays, vignette: vignette ? 1 : 0,
                         time: time, unit: unit, dawn: dawn, pad: 0)
        pass(cmd, target, composePSO) { enc in
            enc.setFragmentBytes(&look, length: MemoryLayout<LookU>.stride, index: 0)
            enc.setFragmentTexture(next, index: 0)
            enc.setFragmentTexture(tightA, index: 1)
            enc.setFragmentTexture(wideA, index: 2)
        }
    }

    private func blur(_ cmd: MTLCommandBuffer, _ tex: MTLTexture, _ scratch: MTLTexture, sigma: Float) {
        // pygame-ce's gaussian_blur(radius): sigma = radius, reaching out two radii
        for (src, dst, dir) in [(tex, scratch, SIMD2<Float>(1, 0)), (scratch, tex, SIMD2<Float>(0, 1))] {
            var p = SIMD4<Float>(dir.x, dir.y, sigma, 2 * sigma)
            pass(cmd, dst, blurPSO) { enc in
                enc.setFragmentBytes(&p, length: 16, index: 0)
                enc.setFragmentTexture(src, index: 0)
            }
        }
    }
}
