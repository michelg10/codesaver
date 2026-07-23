import AppKit
import Metal
import QuartzCore
import os.log

private let metalLog = AppexLog.logger("Metal")

// BoomMetal — the boom's GPU renderer.
//
// The sim stays on the CPU (BoomCore is untouched); what moves to the GPU is
// the painting, which is where the CPU path hit a wall: even dirty-rect CG
// re-fills cost tens of milliseconds per frame per 5K display. Here the whole
// field is one full-screen fragment pass — each pixel finds its cell in two
// tiny data textures and resolves the entire terminal look (backdrop, dimmed
// mosaic color, code-spot glyphs, flash decay, the flip beat, settled fades)
// from `tick - hitTick`, so there are no flash lists, no dirty rects, and no
// per-cell draw calls at all. Flung glyphs and their trails are instanced
// quads on top; the vignette is a third trivial pass. Per frame the CPU
// uploads ~cols×rows×4 bytes of cell state and a small instance buffer.
//
// The shader mirrors BoomFieldRenderer's constants exactly — that CG renderer
// remains as the fallback (and the snapshot harness's reference) whenever a
// Metal device or pipeline can't be had.

// MARK: - Shared context (device + pipelines, one per process)

/// Compiled once, shared by every display's renderer: three saver views live
/// in one appex process, and pipeline compilation is the expensive part of
/// startup — which must stay fast.
final class BoomMetalContext {
    static let shared: BoomMetalContext? = try? BoomMetalContext()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let fieldPipeline: MTLRenderPipelineState
    let backdropPipeline: MTLRenderPipelineState
    let cellPipeline: MTLRenderPipelineState
    let vignettePipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    let quadPipeline: MTLRenderPipelineState
    let linearSampler: MTLSamplerState

    enum Failure: Error { case noDevice, noQueue, noFunction, noSampler }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.noDevice }
        guard let queue = device.makeCommandQueue() else { throw Failure.noQueue }
        self.device = device
        self.queue = queue
        // Compiled from source at runtime: no .metallib plumbing to keep in
        // sync across xcodebuild, the plain-swiftc .saver build, and the
        // preview harness. One-time cost, shared process-wide.
        let library = try device.makeLibrary(source: Self.shaderSource, options: nil)

        func pipeline(_ vertex: String, _ fragment: String, blended: Bool) throws -> MTLRenderPipelineState {
            guard let vf = library.makeFunction(name: vertex),
                  let ff = library.makeFunction(name: fragment) else { throw Failure.noFunction }
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = vf
            d.fragmentFunction = ff
            let att = d.colorAttachments[0]!
            att.pixelFormat = .bgra8Unorm
            if blended {
                // Fragments emit premultiplied color.
                att.isBlendingEnabled = true
                att.rgbBlendOperation = .add
                att.alphaBlendOperation = .add
                att.sourceRGBBlendFactor = .one
                att.sourceAlphaBlendFactor = .one
                att.destinationRGBBlendFactor = .oneMinusSourceAlpha
                att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        fieldPipeline = try pipeline("fsqVertex", "fieldFragment", blended: false)
        backdropPipeline = try pipeline("fsqVertex", "backdropFragment", blended: false)
        cellPipeline = try pipeline("cellVertex", "cellFragment", blended: true)
        vignettePipeline = try pipeline("fsqVertex", "vignetteFragment", blended: true)
        glyphPipeline = try pipeline("glyphVertex", "glyphFragment", blended: true)
        quadPipeline = try pipeline("quadVertex", "quadFragment", blended: true)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sd.sAddressMode = .clampToEdge
        sd.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sd) else { throw Failure.noSampler }
        linearSampler = sampler
    }

    // MARK: Shaders

    // Layouts must match the Swift-side FieldUniforms / CellInstance structs.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct FieldU {
        float2 viewSize;   // render target, px
        float2 cellSize;   // px
        float2 inset;      // grid origin, px (at or below zero: the grid
                           // extends past every screen edge)
        float2 pad;
        float4 timing;     // x = tick, y = vignette factor, z = vignette max,
                           // w = reveal (armed fade-in: backdrop × w)
        float4 atlas;      // xy = glyph slot px, zw = atlas px
        uint4  grid;       // x = cols, y = rows, z = flags (1: backdrop bound)
    };

    struct FSQOut { float4 pos [[position]]; };

    vertex FSQOut fsqVertex(uint vid [[vertex_id]]) {
        // One triangle covering the screen.
        float2 v = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
        FSQOut o;
        o.pos = float4(v, 0.0, 1.0);
        return o;
    }

    // Glyph coverage at `local` (0…1 across the cell) for an ASCII code,
    // from the 16×8 slot atlas. Integer read = the CPU path's nearest blit.
    static float glyphMask(texture2d<float, access::read> atlasTex, uint code,
                           float2 local, constant FieldU& u) {
        float2 slot = float2(float(code % 16u), float(code / 16u)) * u.atlas.xy;
        float2 tp = clamp(slot + local * u.cellSize, float2(0.0), u.atlas.zw - 1.0);
        return atlasTex.read(uint2(tp)).a;
    }

    constant float3 kGlyphWhite = float3(0.93, 0.98, 1.0);

    // The detonation flash from the glow texture's a-channel: nearest
    // per-cell read, brightness stepped to 5 levels.
    static float dynBlast(texture2d<float> glowTex, int2 c) {
        float v = glowTex.read(uint2(c)).a * 1.5;
        return floor(v * 5.0) / 5.0;
    }

    // Cheap integer hash → 0…1, stable per cell (and per time slice when the
    // caller folds one in). Drives the wave-1 burn glitches.
    static float cellHash(uint2 p) {
        uint h = p.x * 374761393u + p.y * 668265263u;
        h = (h ^ (h >> 13u)) * 1274126177u;
        return float((h ^ (h >> 16u)) & 0x00FFFFFFu) / 16777216.0;
    }


    fragment float4 fieldFragment(FSQOut in [[stage_in]],
                                  constant FieldU& u [[buffer(0)]],
                                  texture2d<float, access::read> colorTex [[texture(0)]],
                                  texture2d<uint,  access::read> dynTex   [[texture(1)]],
                                  texture2d<float>               backdrop [[texture(2)]],
                                  texture2d<float, access::read> atlasTex [[texture(3)]],
                                  texture2d<float>               glowTex  [[texture(4)]],
                                  sampler lin [[sampler(0)]]) {
        float2 p = in.pos.xy;
        float2 cf = (p - u.inset) / u.cellSize;
        int2 c = clamp(int2(floor(cf)), int2(0),
                       int2(int(u.grid.x) - 1, int(u.grid.y) - 1));
        uint4 dyn = dynTex.read(uint2(c));
        uint state = dyn.x;                       // BoomField.state*
        uint code = dyn.y;                        // ASCII (0 = none)
        int hitTick = int(dyn.z | (dyn.w << 8u)) - 1;
        int age = int(u.timing.x) - hitTick;
        float2 local = cf - float2(c);
        float3 col;
        bool burnBlack = false;
        if (state == 0u) {
            // Untouched: the desktop itself, ahead of the first front —
            // rising out of black during the armed reveal.
            col = (u.grid.z & 1u) ? backdrop.sample(lin, p / u.viewSize).rgb * u.timing.w
                                  : float3(0.0);
        } else if (state == 1u) {
            // Asciified: dimmed average color, code spots in near-white.
            // Wave 1 has NO edge treatment at all — the pixelation boundary
            // itself (sharp desktop → mosaic) is the event; decorating it
            // was tacky and made wave 2's flip edge read as a rerun. The
            // flip beat is the show's only boundary flourish.
            col = colorTex.read(uint2(c)).rgb * 0.82;
            if (code >= 33u) {
                col = mix(col, kGlyphWhite,
                          glyphMask(atlasTex, code, local, u) * (0.95 * 0.82));
            }
            // Burn glitches riding the front: sparse cells strobe pure
            // black ↔ pure white in the wake — damage the wave leaves
            // behind. Whites radiate into the glow field, blacks absorb
            // from it (both injected CPU-side in updateGlow, which mirrors
            // this selection exactly). Burn lengths stagger 5–14 ticks —
            // a tight band hugging the front, not a long tail. Density
            // 5%: at 12% the burns fused into a solid second front.
            float h = cellHash(uint2(c));
            if (h < 0.05) {
                float dur = 5.0 + fract(h * 83.13) * 9.0;   // sim ticks
                if (float(age) < dur) {
                    uint slice = (uint(age) + uint(fract(h * 517.0) * 8.0)) / 4u;
                    bool white = (fract(h * 259.3) < 0.5) != ((slice & 1u) == 1u);
                    col = white ? float3(1.0) : float3(0.0);
                    burnBlack = !white;
                }
            }
        } else if (state == 2u) {
            // Terminal time, glitching out: sparse cells surge like
            // over-volted LEDs behind the front — the spike whitens past
            // the palette, then the phosphor ghost lingers. Levels are
            // CPU-computed per cell (glowTex.r); bloom is its CPU-blurred
            // twin (glowTex.g), added below.
            col = float3(0.0);
            float lvl = glowTex.read(uint2(c)).r * 1.5;
            if (lvl > 0.0) {
                // Blue-purple, not sky-blue: the blast speaks the
                // statusline's accent family (the boom IS its energy).
                col = float3(0.72, 0.62, 1.0) * min(lvl, 1.0);
                if (lvl > 1.0) {
                    col = mix(col, float3(1.0), min(lvl - 1.0, 1.0));
                }
            }
        } else {
            // Settled debris: glyph fading white → grey → black on the decay
            // clock started back in flight (BoomCore.settledFade, 30 Hz / 5 s).
            col = float3(0.0);
            float t = clamp(1.0 - (float(age) / 60.0) / 5.0, 0.0, 1.0);
            float fade = t * t;
            if (code >= 33u && fade > 0.01) {
                col = mix(col, kGlyphWhite,
                          glyphMask(atlasTex, code, local, u) * (0.95 * 0.95) * fade);
            }
        }
        // Bloom: one bilinear sample of the CPU-blurred glow field —
        // cell-resolution data interpolated across pixels IS the soft
        // spill. (The old 15-sample per-pixel loop was ~660M texture reads
        // per frame at 3×5K: invisible in the small preview, molasses live.)
        // g = light, b = darkness: the two halves of one signed blur. A
        // black burn dims local color and incoming bloom (its dark halo),
        // and takes no bloom itself — it's a hole, not a surface.
        // Applies to state 0 too: the detonation flash lights the sharp
        // desktop before the wave converts it (light precedes the front).
        // Absorption stays post-front only — darkness doesn't leak ahead.
        {
            float4 gs = glowTex.sample(lin, cf / float2(float(u.grid.x),
                                                        float(u.grid.y)));
            float absorb = state != 0u ? gs.b * 1.5 : 0.0;
            col *= 1.0 - min(absorb, 0.85);
            if (!burnBlack) {
                col += float3(0.52, 0.42, 1.0) * gs.g * 1.5 * 1.35
                     * (1.0 - min(absorb, 1.0));
                // Detonation flash: PER-CELL and level-stepped — one flat
                // quantum of light per cell (nearest read, no bilinear),
                // added after absorption so the flash simply wins. Burn-
                // black cells stay holes: debris silhouetted in the blast.
                float blast = dynBlast(glowTex, c) ;
                if (blast > 0.0) {
                    col += float3(0.60, 0.48, 1.0) * blast * 1.1;
                }
            }
        }
        return float4(clamp(col, 0.0, 1.0), 1.0);
    }

    // Armed phase before any field exists (preview arming): backdrop only.
    fragment float4 backdropFragment(FSQOut in [[stage_in]],
                                     constant FieldU& u [[buffer(0)]],
                                     texture2d<float> backdrop [[texture(2)]],
                                     sampler lin [[sampler(0)]]) {
        return float4(backdrop.sample(lin, in.pos.xy / u.viewSize).rgb, 1.0);
    }

    struct CellInst {
        float2 origin;      // px
        float2 size;        // px
        float4 fill;        // straight alpha
        float4 glyphColor;  // a == 0: no glyph
        uint4  glyph;       // x = ASCII code
    };

    struct CellOut {
        float4 pos [[position]];
        float2 local;
        float4 fill [[flat]];
        float4 glyphColor [[flat]];
        uint   glyph [[flat]];
    };

    vertex CellOut cellVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device CellInst* insts [[buffer(0)]],
                              constant FieldU& u [[buffer(1)]]) {
        CellInst inst = insts[iid];
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        float2 px = inst.origin + corner * inst.size;
        CellOut o;
        o.pos = float4(px.x / u.viewSize.x * 2.0 - 1.0,
                       1.0 - px.y / u.viewSize.y * 2.0, 0.0, 1.0);
        o.local = corner;
        o.fill = inst.fill;
        o.glyphColor = inst.glyphColor;
        o.glyph = inst.glyph.x;
        return o;
    }

    fragment float4 cellFragment(CellOut in [[stage_in]],
                                 constant FieldU& u [[buffer(0)]],
                                 texture2d<float, access::read> atlasTex [[texture(0)]]) {
        float3 prem = in.fill.rgb * in.fill.a;
        float a = in.fill.a;
        if (in.glyphColor.a > 0.001 && in.glyph >= 33u) {
            float m = glyphMask(atlasTex, in.glyph, in.local, u) * in.glyphColor.a;
            prem = in.glyphColor.rgb * m + prem * (1.0 - m);
            a = m + a * (1.0 - m);
        }
        return float4(prem, a);
    }

    // Text as instanced quads over a dynamic glyph atlas — the steady saver's
    // whole typed-code field with zero CoreText per frame. flags.x = color
    // glyph (emoji: sample is the color, premultiplied), flags.y = halo atlas
    // (baked shadow blur: the typing-head glow and cursor halo).
    struct GlyphInst {
        float2 origin;   // px
        float2 size;     // px
        float4 color;    // straight alpha; tint for monochrome glyphs
        float4 uvRect;   // px in atlas
        uint4  flags;
    };

    struct GlyphOut {
        float4 pos [[position]];
        float2 local;
        float4 color [[flat]];
        float4 uvRect [[flat]];
        uint2  flags [[flat]];
    };

    vertex GlyphOut glyphVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device GlyphInst* insts [[buffer(0)]],
                                constant FieldU& u [[buffer(1)]]) {
        GlyphInst g = insts[iid];
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        float2 px = g.origin + corner * g.size;
        GlyphOut o;
        o.pos = float4(px.x / u.viewSize.x * 2.0 - 1.0,
                       1.0 - px.y / u.viewSize.y * 2.0, 0.0, 1.0);
        o.local = corner;
        o.color = g.color;
        o.uvRect = g.uvRect;
        o.flags = uint2(g.flags.x, g.flags.y);
        return o;
    }

    fragment float4 glyphFragment(GlyphOut in [[stage_in]],
                                  texture2d<float, access::read> atlasN [[texture(0)]],
                                  texture2d<float, access::read> atlasH [[texture(1)]]) {
        float2 tp = in.uvRect.xy + in.local * in.uvRect.zw;
        uint2 ip = uint2(clamp(tp, float2(0.0), in.uvRect.xy + in.uvRect.zw - 1.0));
        float4 s = in.flags.y ? atlasH.read(ip) : atlasN.read(ip);
        if (in.flags.x) {
            return s * in.color.a;              // emoji: premultiplied color
        }
        float m = s.a * in.color.a;
        return float4(in.color.rgb * m, m);
    }

    // UI rasters (clock, spinner panel, idle line) composited as quads.
    // flags.x masks the quad to wiped/settled cells — the clock assembling
    // piece-wise behind the second front.
    struct QuadU {
        float4 rect;    // px
        float4 tint;    // a = overall alpha
        uint4  flags;
    };

    struct QuadOut { float4 pos [[position]]; float2 local; };

    vertex QuadOut quadVertex(uint vid [[vertex_id]],
                              constant FieldU& u [[buffer(1)]],
                              constant QuadU& q [[buffer(2)]]) {
        float2 corner = float2(float(vid & 1u), float(vid >> 1u));
        float2 px = q.rect.xy + corner * q.rect.zw;
        QuadOut o;
        o.pos = float4(px.x / u.viewSize.x * 2.0 - 1.0,
                       1.0 - px.y / u.viewSize.y * 2.0, 0.0, 1.0);
        o.local = corner;
        return o;
    }

    fragment float4 quadFragment(QuadOut in [[stage_in]],
                                 constant FieldU& u [[buffer(0)]],
                                 constant QuadU& q [[buffer(1)]],
                                 texture2d<float> img [[texture(0)]],
                                 texture2d<uint, access::read> dynTex [[texture(1)]],
                                 sampler lin [[sampler(0)]]) {
        if (q.flags.x) {
            float2 cf = (in.pos.xy - u.inset) / u.cellSize;
            int2 c = clamp(int2(floor(cf)), int2(0),
                           int2(int(u.grid.x) - 1, int(u.grid.y) - 1));
            if (dynTex.read(uint2(c)).x < 2u) { return float4(0.0); }
        }
        return img.sample(lin, in.local) * q.tint.a;   // premultiplied raster
    }

    // Radial vignette matching CodeSaverView.renderVignette's gradient stops
    // (0 / 0.55 / 1 → 0 / 0.12·max / max), breathing in behind the second
    // front via timing.y.
    fragment float4 vignetteFragment(FSQOut in [[stage_in]],
                                     constant FieldU& u [[buffer(0)]]) {
        float2 p = in.pos.xy;
        float r = distance(p, u.viewSize * 0.5) / (length(u.viewSize) * 0.5);
        float m = u.timing.z;
        float a = r < 0.55 ? mix(0.0, m * 0.12, r / 0.55)
                           : mix(m * 0.12, m, clamp((r - 0.55) / 0.45, 0.0, 1.0));
        return float4(0.0, 0.0, 0.0, a * u.timing.y);
    }
    """
}

// MARK: - Host view

/// A CAMetalLayer-backed subview: sits above the saver view's own (black)
/// content and below the transparent UI overlay — sublayer z-tricks can't
/// put a layer *under* a view's content, but subview order can.
final class BoomMetalHostView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // We render imperatively; AppKit must never ask this view to draw.
        layerContentsRedrawPolicy = .never
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.pixelFormat = .bgra8Unorm
        l.framebufferOnly = true
        // Display sync ON: ticks come from a CADisplayLink pinned to 30 Hz,
        // so presents latch cleanly onto every second vsync — steady frame
        // durations. (The old free-running timer + sync produced drawable
        // blocking; the link removes the beat-frequency problem instead.)
        l.isOpaque = true
        return l
    }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
}

// MARK: - Renderer

final class BoomMetalRenderer {
    private let ctx: BoomMetalContext

    // Bound field (static per boom): rebuilt when the view migrates displays.
    private var boundField: BoomField?
    private var boundScale: CGFloat = 0
    private var colorTex: MTLTexture?
    private var dynTex: MTLTexture?
    private var glowTex: MTLTexture?
    private var glowRaw: [Float] = []
    private var glowBlurA: [Float] = []
    private var glowBlurB: [Float] = []
    private var glowBytes: [UInt8] = []
    private var backdropTex: MTLTexture?
    private weak var backdropImage: CGImage?   // identity: skip re-upload
    private weak var boundBuffer: BoomCaptureBuffer?
    private var lastDynTick = Int.min
    private var dynBytes: [UInt8] = []

    // Glyph atlas, keyed by cell metrics.
    private var atlasTex: MTLTexture?
    private var atlasKey = ""
    private var atlasSlot = (w: 0, h: 0)

    // Debris instances stage CPU-side, then upload to a buffer that GROWS
    // on demand (doubling; Metal keeps the old allocation alive for frames
    // in flight). No tunable cap to outgrow: the sim itself bounds the
    // count — ≤1300 particles × ≤64 trail cells/tick (Bresenham guard) ×
    // 5-tick window ≈ 417k instances ≈ 27 MB absolute worst case; measured
    // peak on a 3-display setup is ~15k ≈ 1 MB.
    private var instanceBuffer: MTLBuffer
    private var instanceCap = 32768
    private var instanceStaging: [CellInstance] = []
    private let glyphBuffer: MTLBuffer
    private static let glyphCap = 32768
    private let fillBuffer: MTLBuffer
    private let lateFillBuffer: MTLBuffer
    private static let fillCap = 1024

    // Steady-state text: dynamic atlas + per-frame UI rasters.
    private var atlas: TerminalGlyphAtlas?
    private var atlasKey2 = ""
    private var uiTextures: [String: MTLTexture] = [:]
    private var uiImageIdentity: [String: ObjectIdentifier] = [:]
    private var dummyDyn: MTLTexture?

    /// Per-view tag for diag attribution on multi-display runs.
    var diagTag = ""

    /// One-frame pressure pulse injected into the glow field: (cell x, cell
    /// y, level, radius in row-cells — the disc is 1.6:1 wider than tall).
    /// The detonation's "contained blowout" (radius ~14) and the armed
    /// glitch's phosphor (radius ~3). Set by the view per frame; nil = none.
    var blastPulse: (cx: Int, cy: Int, level: Float, radius: Double)?
    /// True while the previous frame had a pulse — one extra glow refresh
    /// clears the phosphor when the pulse ends.
    private var lastPulseActive = false

    // Rolling perf counters (CODESAVER_PERF=1).
    private static let perfEnabled = ProcessInfo.processInfo.environment["CODESAVER_PERF"] == "1"
    private var perfFrames = 0
    private var perfCPU = 0.0
    private var perfGPU = 0.0

    /// Matches the MSL FieldU layout.
    private struct FieldUniforms {
        var viewSize: SIMD2<Float>
        var cellSize: SIMD2<Float>
        var inset: SIMD2<Float>
        var pad: SIMD2<Float> = .zero
        var timing: SIMD4<Float>
        var atlas: SIMD4<Float>
        var grid: SIMD4<UInt32>
    }

    /// Matches the MSL CellInst layout (stride 64).
    struct CellInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var fill: SIMD4<Float>
        var glyphColor: SIMD4<Float>
        var glyph: SIMD4<UInt32>
    }

    init?(context: BoomMetalContext) {
        guard let buf = context.device.makeBuffer(
                  length: 32768 * MemoryLayout<CellInstance>.stride,
                  options: .storageModeShared),
              let gbuf = context.device.makeBuffer(
                  length: Self.glyphCap * MemoryLayout<GlyphInstance>.stride,
                  options: .storageModeShared),
              let fbuf = context.device.makeBuffer(
                  length: Self.fillCap * MemoryLayout<CellInstance>.stride,
                  options: .storageModeShared),
              let lbuf = context.device.makeBuffer(
                  length: Self.fillCap * MemoryLayout<CellInstance>.stride,
                  options: .storageModeShared) else { return nil }
        ctx = context
        instanceBuffer = buf
        glyphBuffer = gbuf
        fillBuffer = fbuf
        lateFillBuffer = lbuf
        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Uint, width: 1, height: 1, mipmapped: false)
        dd.usage = .shaderRead
        dummyDyn = context.device.makeTexture(descriptor: dd)
    }

    // MARK: Steady-state text plumbing

    /// Matches the MSL GlyphInst layout (stride 64).
    struct GlyphInstance {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
        var color: SIMD4<Float>
        var uvRect: SIMD4<Float>
        var flags: SIMD4<UInt32>   // x: color glyph, y: halo atlas
    }

    /// A UI raster (clock, panel, idle line) composited above the vignette.
    struct ImageQuad {
        var key: String
        var rect: CGRect          // view points
        var alpha: Double = 1
        var maskToWipedCells = false
    }

    /// One frame of the whole saver: the boom field (optional), the typed
    /// rows as glyph instances, teleport fills, UI rasters, vignette.
    struct FrameInput {
        var holdBlack = false
        var reveal = 1.0
        var vignetteFactor = 0.0
        var vignetteMax = 0.0
        var glyphs: [GlyphInstance] = []
        var fills: [CellInstance] = []       // above vignette, below UI quads
        var quads: [ImageQuad] = []
        var lateFills: [CellInstance] = []   // above UI quads (arrival flash)
    }

    static func fill(_ rect: CGRect, scale: CGFloat, color: SIMD4<Float>) -> CellInstance {
        CellInstance(origin: SIMD2(Float(rect.minX * scale), Float(rect.minY * scale)),
                     size: SIMD2(Float(rect.width * scale), Float(rect.height * scale)),
                     fill: color, glyphColor: .zero, glyph: .zero)
    }

    /// (Re)builds the glyph atlas for the view's text metrics.
    func configureText(fontBase: CGFloat, charW: CGFloat, lineH: CGFloat, scale: CGFloat) {
        let key = "\(fontBase)|\(charW)|\(lineH)|\(scale)"
        guard key != atlasKey2 else { return }
        atlasKey2 = key
        atlas = TerminalGlyphAtlas(device: ctx.device, fontBase: fontBase,
                                   charW: charW, lineH: lineH, scale: scale)
    }

    func glyphSlot(for ch: Character, cells: Int) -> TerminalGlyphAtlas.Slot? {
        atlas?.slot(for: ch, cells: cells)
    }

    /// Uploads a UI raster; re-uploads only when the image identity changes
    /// (`always` = per-frame content like the panel text).
    func setUITexture(_ key: String, image: CGImage, always: Bool = false) {
        if !always, uiImageIdentity[key] == ObjectIdentifier(image),
           uiTextures[key] != nil { return }
        uiImageIdentity[key] = ObjectIdentifier(image)
        if let tex = uiTextures[key], tex.width == image.width, tex.height == image.height,
           let data = imageBytes(image) {
            data.withUnsafeBytes { raw in
                tex.replace(region: MTLRegionMake2D(0, 0, image.width, image.height),
                            mipmapLevel: 0, withBytes: raw.baseAddress!,
                            bytesPerRow: image.width * 4)
            }
            return
        }
        uiTextures[key] = Self.makeTexture(from: image, device: ctx.device)
    }

    private func imageBytes(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = cg.data else { return nil }
        return Data(bytes: data, count: w * 4 * h)
    }

    // MARK: Binding

    /// Whether this renderer is currently staged for `field` — the readiness
    /// signal the session's start gate waits on.
    func isBound(to field: BoomField) -> Bool { boundField === field }

    /// Uploads a field's static textures; no-op while the binding is current.
    /// A mapped capture `buffer` becomes the backdrop with zero copies — the
    /// GPU reads the mmap'd page-cache pages directly; the CGImage upload
    /// path remains for stand-ins and legacy captures.
    func bindFieldIfNeeded(_ field: BoomField, backdrop: CGImage?,
                           buffer: BoomCaptureBuffer? = nil, scale: CGFloat) {
        guard boundField !== field || boundScale != scale else { return }
        let bindStart = CACurrentMediaTime()
        boundField = field
        boundScale = scale
        colorTex = makeColorTexture(field)
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Uint, width: field.grid.cols, height: field.grid.rows,
            mipmapped: false)
        d.usage = .shaderRead
        dynTex = ctx.device.makeTexture(descriptor: d)
        let gd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: field.grid.cols, height: field.grid.rows,
            mipmapped: false)
        gd.usage = .shaderRead
        glowTex = ctx.device.makeTexture(descriptor: gd)
        lastDynTick = .min
        var backdropKind = "cached"
        if let buffer {
            if boundBuffer !== buffer {
                if let tex = makeZeroCopyTexture(buffer) {
                    backdropTex = tex
                    backdropKind = "zero-copy"
                } else {
                    backdropTex = backdrop.flatMap { Self.makeTexture(from: $0, device: ctx.device) }
                    backdropKind = "upload (zero-copy REJECTED)"
                }
                boundBuffer = buffer
                backdropImage = nil
            }
        } else if backdropImage !== backdrop || boundBuffer != nil {
            backdropTex = backdrop.flatMap { Self.makeTexture(from: $0, device: ctx.device) }
            backdropImage = backdrop
            boundBuffer = nil
            backdropKind = "upload"
        }
        rebuildAtlasIfNeeded(grid: field.grid, scale: scale)
        BoomDiag.log(String(format: "bind field %d×%d: backdrop %@ (%d×%d px), took %.1f ms",
                            field.grid.cols, field.grid.rows, backdropKind,
                            backdropTex?.width ?? 0, backdropTex?.height ?? 0,
                            (CACurrentMediaTime() - bindStart) * 1000))
    }

    /// Wraps a mapped capture as a linear texture over its own pages: no
    /// upload, no copy — the texture's parent MTLBuffer retains the mapping.
    private func makeZeroCopyTexture(_ b: BoomCaptureBuffer) -> MTLTexture? {
        let align = max(1, ctx.device.minimumLinearTextureAlignment(for: .bgra8Unorm))
        guard b.pixelOffset % align == 0, b.bytesPerRow % align == 0 else { return nil }
        let page = Int(getpagesize())
        let mapLen = (b.length + page - 1) & ~(page - 1)
        guard let mtlBuf = ctx.device.makeBuffer(
            bytesNoCopy: b.base, length: mapLen, options: .storageModeShared,
            deallocator: { _, _ in _ = b }) else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: b.width, height: b.height, mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        return mtlBuf.makeTexture(descriptor: d, offset: b.pixelOffset,
                                  bytesPerRow: b.bytesPerRow)
    }

    /// Armed phase before any core exists: just the captured desktop.
    func bindBackdropOnly(_ image: CGImage) {
        boundField = nil
        colorTex = nil
        dynTex = nil
        guard backdropImage !== image || backdropTex == nil else { return }
        backdropTex = Self.makeTexture(from: image, device: ctx.device)
        backdropImage = image
    }

    // MARK: Rendering

    /// Renders one complete saver frame — boom field, typed rows, UI — into
    /// the layer's next drawable. `holdBlack` presents pure black (the
    /// pre-reveal curtain).
    func renderFrame(_ frame: FrameInput, core: BoomCore?, fieldIndex: Int,
                     viewSize: CGSize, scale: CGFloat, into layer: CAMetalLayer) {
        let pw = max(1, Int(viewSize.width * scale))
        let ph = max(1, Int(viewSize.height * scale))
        if layer.device == nil { layer.device = ctx.device }
        if Int(layer.drawableSize.width) != pw || Int(layer.drawableSize.height) != ph {
            layer.drawableSize = CGSize(width: pw, height: ph)
            layer.contentsScale = scale
        }
        if let core, let field = boundField { uploadDyn(field: field, tick: core.tickCount) }
        let cpuStart = CACurrentMediaTime()
        autoreleasepool {
            guard let drawable = layer.nextDrawable(),
                  let cb = ctx.queue.makeCommandBuffer() else { return }
            encodeFrame(frame, target: drawable.texture, core: core,
                        fieldIndex: fieldIndex, commandBuffer: cb, scale: scale)
            cb.addCompletedHandler { [weak self] done in
                let gpu = (done.gpuEndTime - done.gpuStartTime) * 1000
                DispatchQueue.main.async { self?.notePerf(gpuMs: gpu) }
            }
            cb.present(drawable)
            cb.commit()
        }
        perfCPU += (CACurrentMediaTime() - cpuStart) * 1000
    }

    // Rolling 60-frame averages — os.log always (visible from the live appex
    // via the com.michelg10.CodeSaver subsystem), stdout for the harness.
    private func notePerf(gpuMs: Double) {
        perfGPU += gpuMs
        perfFrames += 1
        if perfFrames >= 60 {
            let cpu = perfCPU / Double(perfFrames)
            let gpu = perfGPU / Double(perfFrames)
            metalLog.notice("boom frame avg — cpu \(cpu, format: .fixed(precision: 2), privacy: .public) ms, gpu \(gpu, format: .fixed(precision: 2), privacy: .public) ms")
            BoomDiag.log(diagTag + String(format: " frame avg: cpu %.2f ms, gpu %.2f ms (60 frames)", cpu, gpu))
            if Self.perfEnabled {
                print(String(format: "boom-metal: cpu %.2f ms  gpu %.2f ms  (60-frame avg)", cpu, gpu))
                fflush(stdout)   // the harness pipes stdout; don't lose the report
            }
            perfFrames = 0
            perfCPU = 0
            perfGPU = 0
        }
    }

    /// Offscreen frame for the snapshot harness — the full Metal frame.
    func snapshot(_ frame: FrameInput, core: BoomCore?, fieldIndex: Int,
                  viewSize: CGSize, scale: CGFloat) -> CGImage? {
        let pw = max(1, Int(viewSize.width * scale))
        let ph = max(1, Int(viewSize.height * scale))
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pw, height: ph, mipmapped: false)
        d.usage = .renderTarget
        d.storageMode = .private
        guard let target = ctx.device.makeTexture(descriptor: d),
              let cb = ctx.queue.makeCommandBuffer() else { return nil }
        if let core, let field = boundField { uploadDyn(field: field, tick: core.tickCount) }
        encodeFrame(frame, target: target, core: core, fieldIndex: fieldIndex,
                    commandBuffer: cb, scale: scale)
        let bpr = (pw * 4 + 255) & ~255
        guard let buf = ctx.device.makeBuffer(length: bpr * ph, options: .storageModeShared),
              let blit = cb.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: target, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: pw, height: ph, depth: 1),
                  to: buf, destinationOffset: 0,
                  destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * ph)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if Self.perfEnabled {
            BoomDiag.log(String(format: "snapshot gpu %.2f ms (%d×%d)",
                                (cb.gpuEndTime - cb.gpuStartTime) * 1000, pw, ph))
        }
        guard let provider = CGDataProvider(data: Data(bytes: buf.contents(),
                                                       count: bpr * ph) as CFData)
        else { return nil }
        return CGImage(
            width: pw, height: ph, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bpr, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)
    }

    // MARK: Encoding

    private func copyFills(_ fills: [CellInstance], into buffer: MTLBuffer) -> Int {
        let n = min(fills.count, Self.fillCap)
        if n > 0 {
            buffer.contents().bindMemory(to: CellInstance.self, capacity: n)
                .update(from: fills, count: n)
        }
        return n
    }

    private func drawFills(_ enc: MTLRenderCommandEncoder, _ u: inout FieldUniforms,
                           buffer: MTLBuffer, count: Int) {
        guard count > 0 else { return }
        let ulen = MemoryLayout<FieldUniforms>.stride
        enc.setRenderPipelineState(ctx.cellPipeline)
        enc.setVertexBuffer(buffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: ulen, index: 1)
        enc.setFragmentBytes(&u, length: ulen, index: 0)
        enc.setFragmentTexture(atlas?.texture ?? atlasTex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                           vertexCount: 4, instanceCount: count)
    }

    private func encodeFrame(_ frame: FrameInput, target: MTLTexture, core: BoomCore?,
                             fieldIndex: Int, commandBuffer: MTLCommandBuffer,
                             scale: CGFloat) {
        var u = uniforms(target: target, core: core,
                         vignetteFactor: frame.vignetteFactor,
                         vignetteMax: frame.vignetteMax,
                         scale: scale, reveal: frame.reveal)
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) else { return }
        let ulen = MemoryLayout<FieldUniforms>.stride

        if frame.holdBlack {
            enc.endEncoding()
            return
        }

        // 1. The boom field (or the armed backdrop pre-core), plus debris.
        if let core, let field = boundField, let colorTex, let dynTex, let atlasTex {
            enc.setRenderPipelineState(ctx.fieldPipeline)
            enc.setFragmentBytes(&u, length: ulen, index: 0)
            enc.setFragmentTexture(colorTex, index: 0)
            enc.setFragmentTexture(dynTex, index: 1)
            enc.setFragmentTexture(backdropTex ?? colorTex, index: 2)
            enc.setFragmentTexture(atlasTex, index: 3)
            enc.setFragmentTexture(glowTex ?? colorTex, index: 4)
            enc.setFragmentSamplerState(ctx.linearSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

            let n = buildInstances(core: core, fieldIndex: fieldIndex,
                                   field: field, scale: scale)
            if n > 0 {
                enc.setRenderPipelineState(ctx.cellPipeline)
                enc.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: ulen, index: 1)
                enc.setFragmentBytes(&u, length: ulen, index: 0)
                enc.setFragmentTexture(atlasTex, index: 0)
                enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                   vertexCount: 4, instanceCount: n)
            }
        } else if core == nil, boundField == nil, let backdropTex, frame.reveal > 0.001 {
            enc.setRenderPipelineState(ctx.backdropPipeline)
            enc.setFragmentBytes(&u, length: ulen, index: 0)
            enc.setFragmentTexture(backdropTex, index: 2)
            enc.setFragmentSamplerState(ctx.linearSampler, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 2. Typed rows (and fading debris glyphs): instanced text.
        let glyphCount = min(frame.glyphs.count, Self.glyphCap)
        if glyphCount > 0, let a = atlas, let an = a.texture, let ah = a.haloTexture {
            glyphBuffer.contents().bindMemory(to: GlyphInstance.self, capacity: glyphCount)
                .update(from: frame.glyphs, count: glyphCount)
            enc.setRenderPipelineState(ctx.glyphPipeline)
            enc.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: ulen, index: 1)
            enc.setFragmentTexture(an, index: 0)
            enc.setFragmentTexture(ah, index: 1)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                               vertexCount: 4, instanceCount: glyphCount)
        }

        // 3. Vignette (rows sit under it, UI above — the CG path's order).
        if frame.vignetteFactor > 0.02, frame.vignetteMax > 0.01 {
            enc.setRenderPipelineState(ctx.vignettePipeline)
            enc.setFragmentBytes(&u, length: ulen, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // 4. Teleport fills (departure flash, blip) — bright, un-vignetted.
        let fillCount = copyFills(frame.fills, into: fillBuffer)
        drawFills(enc, &u, buffer: fillBuffer, count: fillCount)

        // 5. UI rasters: clock (cell-masked during the boom), panel, line.
        for quad in frame.quads {
            guard let tex = uiTextures[quad.key], quad.alpha > 0.01 else { continue }
            var q = QuadUniforms(
                rect: SIMD4(Float(quad.rect.minX * scale), Float(quad.rect.minY * scale),
                            Float(quad.rect.width * scale), Float(quad.rect.height * scale)),
                tint: SIMD4(1, 1, 1, Float(quad.alpha)),
                flags: SIMD4(quad.maskToWipedCells ? 1 : 0, 0, 0, 0))
            enc.setRenderPipelineState(ctx.quadPipeline)
            enc.setVertexBytes(&u, length: ulen, index: 1)
            enc.setVertexBytes(&q, length: MemoryLayout<QuadUniforms>.stride, index: 2)
            enc.setFragmentBytes(&u, length: ulen, index: 0)
            enc.setFragmentBytes(&q, length: MemoryLayout<QuadUniforms>.stride, index: 1)
            enc.setFragmentTexture(tex, index: 0)
            enc.setFragmentTexture(dynTex ?? dummyDyn, index: 1)
            enc.setFragmentSamplerState(ctx.linearSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // 6. Arrival flash burns over the landed panel text.
        let lateCount = copyFills(frame.lateFills, into: lateFillBuffer)
        drawFills(enc, &u, buffer: lateFillBuffer, count: lateCount)

        enc.endEncoding()
    }

    /// Matches the MSL QuadU layout.
    private struct QuadUniforms {
        var rect: SIMD4<Float>
        var tint: SIMD4<Float>
        var flags: SIMD4<UInt32>
    }

    private func uniforms(target: MTLTexture, core: BoomCore?,
                          vignetteFactor: Double, vignetteMax: Double,
                          scale: CGFloat, reveal: Double = 1) -> FieldUniforms {
        var u = FieldUniforms(
            viewSize: SIMD2(Float(target.width), Float(target.height)),
            cellSize: SIMD2(1, 1), inset: .zero,
            timing: SIMD4(Float(core?.tickCount ?? 0), Float(vignetteFactor),
                          Float(vignetteMax), Float(reveal)),
            atlas: .zero, grid: SIMD4(1, 1, 0, 0))
        if let g = boundField?.grid, let atlasTex {
            u.cellSize = SIMD2(Float(g.charW * scale), Float(g.lineH * scale))
            u.inset = SIMD2(Float(g.leftInset * scale), Float(g.topInset * scale))
            u.grid = SIMD4(UInt32(g.cols), UInt32(g.rows),
                           backdropTex != nil ? 1 : 0, 0)
            u.atlas = SIMD4(Float(atlasSlot.w), Float(atlasSlot.h),
                            Float(atlasTex.width), Float(atlasTex.height))
        }
        return u
    }

    // MARK: Per-frame data

    /// Cell state → the dynamic texture, once per sim tick. A live
    /// blastPulse forces the glow refresh even on a stalled tick — the
    /// armed-phase phosphor glitch animates while the sim sits at 0.
    private func uploadDyn(field: BoomField, tick: Int) {
        guard let dynTex else { return }
        let dynDirty = tick != lastDynTick
        guard dynDirty || blastPulse != nil || lastPulseActive else { return }
        lastPulseActive = blastPulse != nil
        if !dynDirty {
            updateGlow(field: field, tick: tick)
            return
        }
        lastDynTick = tick
        let cols = field.grid.cols
        let n = field.state.count
        if dynBytes.count != n * 4 { dynBytes = [UInt8](repeating: 0, count: n * 4) }
        dynBytes.withUnsafeMutableBufferPointer { buf in
            let p = buf.baseAddress!
            for i in 0..<n {
                let o = i * 4
                p[o] = field.state[i]
                p[o + 1] = field.ascii[i]
                // hitTick + 1 so "never" (-1) encodes as 0.
                let h = min(max(Int(field.hitTick[i]) + 1, 0), 65535)
                p[o + 2] = UInt8(h & 0xFF)
                p[o + 3] = UInt8(h >> 8)
            }
        }
        dynTex.replace(region: MTLRegionMake2D(0, 0, cols, field.grid.rows),
                             mipmapLevel: 0, withBytes: &dynBytes,
                             bytesPerRow: cols * 4)
        updateGlow(field: field, tick: tick)
    }

    /// Voltage-surge level for a wiped cell: spike → sustain → optional
    /// re-surge → phosphor ghost. Computed here per CELL per tick (15k cells,
    /// microseconds) instead of per PIXEL in the shader — the old in-shader
    /// version sampled a 15-cell neighborhood per pixel and buried 3×5K GPUs.
    private func blipLevel(age: Int, n1: Double, n2: Double) -> Float {
        guard n1 < 0.22, age >= 0 else { return 0 }
        let t1 = age - Int(n2 * 6)
        guard t1 >= 0 else { return 0 }
        if t1 <= 1 { return 1.35 }                       // over-surge spike
        if t1 <= 4 { return 0.95 }                       // sustain
        let resurge = n1 > 0.13
        if resurge, t1 >= 6, t1 <= 8 { return 0.75 }     // stutter
        let g = t1 - (resurge ? 9 : 5)
        guard g >= 0 else { return 0 }
        let ghost = 0.30 * exp(-Double(g) / 10)          // phosphor cools
        return ghost < 0.02 ? 0 : Float(ghost)
    }

    /// Mirrors the shader's cellHash bit-for-bit (float32 ops) so the CPU
    /// glow field and the GPU burn blocks agree on every cell.
    @inline(__always) private static func burnHash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x) &* 374761393
            &+ UInt32(truncatingIfNeeded: y) &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        return Float((h ^ (h >> 16)) & 0x00FF_FFFF) / 16777216.0
    }

    @inline(__always) private static func fract(_ x: Float) -> Float {
        x - x.rounded(.down)
    }

    /// The wave-1 burn state of a mosaic cell: 0 none, 1 white, 2 black.
    /// Must stay in lockstep with the shader's state-1 burn block.
    @inline(__always) static func burnState(col: Int, row: Int, age: Int) -> Int {
        let h = burnHash(col, row)
        guard h < 0.05 else { return 0 }
        let dur = 5.0 + fract(h * 83.13) * 9.0
        guard Float(age) < dur else { return 0 }
        let slice = (age + Int(fract(h * 517.0) * 8.0)) / 4
        let white = (fract(h * 259.3) < 0.5) != (slice & 1 == 1)
        return white ? 1 : 2
    }

    /// The glow field: raw per-cell levels (r) + a small tent blur split into
    /// light (g) and darkness (b) that the shader samples bilinearly. The
    /// blurred field is SIGNED before encoding: burning-white cells radiate
    /// (positive), burning-black cells absorb (negative) — one blur, so a
    /// black burn carves its halo out of any bloom that reaches it.
    private func updateGlow(field: BoomField, tick: Int) {
        guard let glowTex else { return }
        let cols = field.grid.cols
        let rows = field.grid.rows
        let n = cols * rows
        if glowRaw.count != n {
            glowRaw = [Float](repeating: 0, count: n)
            glowBlurA = [Float](repeating: 0, count: n)
            glowBlurB = [Float](repeating: 0, count: n)
            glowBytes = [UInt8](repeating: 0, count: n * 4)
        }
        for i in 0..<n {
            if field.state[i] == BoomField.stateBlack {
                let age = tick - Int(field.hitTick[i])
                if age <= 60 {
                    let col = i % cols, row = i / cols
                    glowRaw[i] = blipLevel(age: age,
                                           n1: boomCellNoise(col, row, 0xF1A5),
                                           n2: boomCellNoise(col + 7919, row + 104729, 0xF1A5))
                } else {
                    glowRaw[i] = 0
                }
            } else if field.state[i] == BoomField.stateAscii {
                // Wave-1 burns: white radiates, black eats light.
                switch Self.burnState(col: i % cols, row: i / cols,
                                      age: tick - Int(field.hitTick[i])) {
                case 1: glowRaw[i] = 1.2
                case 2: glowRaw[i] = -1.5
                default: glowRaw[i] = 0
                }
            } else {
                glowRaw[i] = 0
            }
        }
        // Tent blur: horizontal radius 2 (cells are ~half as wide as tall),
        // vertical radius 1 — the bilinear upsample does the rest.
        for row in 0..<rows {
            let base = row * cols
            for col in 0..<cols {
                var acc: Float = 0
                var w: Float = 0
                for d in -2...2 {
                    let cc = col + d
                    guard cc >= 0, cc < cols else { continue }
                    let k: Float = d == 0 ? 3 : (abs(d) == 1 ? 2 : 1)
                    acc += glowRaw[base + cc] * k
                    w += k
                }
                glowBlurA[base + col] = acc / w
            }
        }
        for col in 0..<cols {
            for row in 0..<rows {
                var acc: Float = 0
                var w: Float = 0
                for d in -1...1 {
                    let rr = row + d
                    guard rr >= 0, rr < rows else { continue }
                    let k: Float = d == 0 ? 2 : 1
                    acc += glowBlurA[rr * cols + col] * k
                    w += k
                }
                glowBlurB[row * cols + col] = acc / w
            }
        }
        for i in 0..<n {
            let b = glowBlurB[i]
            glowBytes[i * 4] = UInt8(max(0, min(255, glowRaw[i] / 1.5 * 255)))
            glowBytes[i * 4 + 1] = UInt8(max(0, min(255, b / 1.5 * 255)))
            glowBytes[i * 4 + 2] = UInt8(max(0, min(255, -b / 1.5 * 255)))
            glowBytes[i * 4 + 3] = 0
        }
        // The detonation pressure pulse rides the UNUSED a-channel: no
        // blur, no bilinear — the shader reads it nearest-per-cell and
        // steps the levels, so the flash is quantized light over the cell
        // lattice, not a gradient (gradients read as vector art). Grainy
        // falloff re-rolled every 2 ticks: crackling overexposure.
        // ~±28 cells wide / ±14 tall ≈ a ~500 pt halo.
        if let b = blastPulse, b.level > 0 {
            let tickSalt = 0xF00D &+ UInt64(tick / 2)
            let rv = Int(b.radius.rounded(.up))
            let rh = Int((b.radius * 3.2).rounded(.up))
            for dr in -rv...rv {
                let row = b.cy + dr
                guard row >= 0, row < rows else { continue }
                for dc in -rh...rh {
                    let col = b.cx + dc
                    guard col >= 0, col < cols else { continue }
                    // 1.6:1 ellipse — the blast source (the line) is wider
                    // than tall; its light should be too.
                    let d = sqrt(pow(Double(dc) * 0.5 / 1.6, 2)
                        + pow(Double(dr), 2)) / b.radius
                    guard d < 1 else { continue }
                    let grain = 0.55 + 0.9 * boomCellNoise(col, row, tickSalt)
                    let v = b.level * Float(pow(1 - d, 1.5) * grain)
                    glowBytes[(row * cols + col) * 4 + 3] =
                        UInt8(max(0, min(255, v / 1.5 * 255)))
                }
            }
        }
        glowTex.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0,
                        withBytes: &glowBytes, bytesPerRow: cols * 4)
    }

    /// Trails + flung glyph heads as instanced quads, mirroring the CPU
    /// renderer's colors and fade rules.
    private func buildInstances(core: BoomCore, fieldIndex: Int,
                                field: BoomField, scale: CGFloat) -> Int {
        let g = field.grid
        let tick = core.tickCount
        let cw = Float(g.charW * scale)
        let lh = Float(g.lineH * scale)
        let ix = Float(g.leftInset * scale)
        let iy = Float(g.topInset * scale)
        let size = SIMD2(cw, lh)
        instanceStaging.removeAll(keepingCapacity: true)
        func origin(_ col: Int, _ row: Int) -> SIMD2<Float> {
            SIMD2(ix + Float(col) * cw, iy + Float(row) * lh)
        }
        // Trails under heads — nothing truncates (the buffer grows), so
        // draw order is purely aesthetic again.
        for d in core.trailDecals where d.field == fieldIndex && tick - d.tick <= 4 {
            // Age-faded, not constant-then-gone: a speed line that pops out
            // in one frame reads as a glitch (especially in slow motion).
            let fade = 1 - Float(tick - d.tick) / 5
            instanceStaging.append(CellInstance(
                origin: origin(d.idx % g.cols, d.idx / g.cols), size: size,
                fill: SIMD4(0.78, 0.68, 1.0, 0.10 * fade),
                glyphColor: .zero, glyph: .zero))
        }
        for p in core.particles where !p.settled {
            let local = CGPoint(x: p.x - Double(field.originCG.x),
                                y: p.y - Double(field.originCG.y))
            guard let cell = g.cell(at: local) else { continue }
            let fade = p.decayTick >= 0
                ? BoomCore.settledFade(age: Double(tick - Int(p.decayTick)) / BoomCore.tickHz)
                : 1.0
            guard fade > 0.01 else { continue }
            // Bare glyph, no block cursor behind it: the slab gave every
            // mote billboard weight. Same white and fade curve as the
            // settled state-3 cells, so parking is a non-event.
            instanceStaging.append(CellInstance(
                origin: origin(cell.col, cell.row), size: size,
                fill: .zero,
                glyphColor: SIMD4(0.93, 0.98, 1.0, Float(0.90 * fade)),
                glyph: SIMD4(UInt32(p.ch), 0, 0, 0)))
        }
        let n = instanceStaging.count
        if n > instanceCap {
            var newCap = instanceCap
            while newCap < n { newCap *= 2 }
            if let buf = ctx.device.makeBuffer(
                length: newCap * MemoryLayout<CellInstance>.stride,
                options: .storageModeShared) {
                instanceBuffer = buf
                instanceCap = newCap
                BoomDiag.log("instance buffer grown to \(newCap)")
            }
        }
        let m = min(n, instanceCap)   // only binds if a grow allocation failed
        if m > 0 {
            instanceStaging.withUnsafeBufferPointer { src in
                instanceBuffer.contents().copyMemory(
                    from: src.baseAddress!,
                    byteCount: m * MemoryLayout<CellInstance>.stride)
            }
        }
        return m
    }

    // MARK: Static textures

    private func makeColorTexture(_ field: BoomField) -> MTLTexture? {
        let cols = field.grid.cols, rows = field.grid.rows
        var bytes = [UInt8](repeating: 255, count: cols * rows * 4)
        for i in 0..<(cols * rows) {
            let c = field.color[i]           // 0xRRGGBB
            let o = i * 4
            bytes[o] = UInt8(c & 0xFF)              // B
            bytes[o + 1] = UInt8((c >> 8) & 0xFF)   // G
            bytes[o + 2] = UInt8((c >> 16) & 0xFF)  // R
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: cols, height: rows, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = ctx.device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, cols, rows), mipmapLevel: 0,
                          withBytes: &bytes, bytesPerRow: cols * 4)
        return tex
    }

    private static func makeTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = cg.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        // Bitmap memory row 0 is the TOP scanline; so is texture row 0.
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                          withBytes: data, bytesPerRow: cg.bytesPerRow)
        return tex
    }

    /// ASCII 33…126 rendered white-on-transparent into a 16×8 slot grid (the
    /// boom field's fixed atlas); the shader reads coverage from alpha.
    /// Glyph placement matches the CPU atlas: glyph top at cell top, as the
    /// saver's flipped draw(at:) does.
    private func rebuildAtlasIfNeeded(grid: BoomGrid, scale: CGFloat) {
        let key = "\(grid.fontBase)|\(grid.charW)|\(grid.lineH)|\(scale)"
        guard key != atlasKey else { return }
        let slotW = max(1, Int(ceil(grid.charW * scale)))
        let slotH = max(1, Int(ceil(grid.lineH * scale)))
        let aw = slotW * 16, ah = slotH * 8
        guard let cg = CGContext(data: nil, width: aw, height: ah, bitsPerComponent: 8,
                                 bytesPerRow: aw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        let font = NSFont(name: "SFMono-Regular", size: grid.fontBase)
            ?? .monospacedSystemFont(ofSize: grid.fontBase, weight: .regular)
        let g = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        cg.saveGState()
        cg.scaleBy(x: scale, y: scale)
        let totalHpt = CGFloat(ah) / scale
        let slotWpt = CGFloat(slotW) / scale
        let slotHpt = CGFloat(slotH) / scale
        for code in 33..<127 {
            guard let scalar = Unicode.Scalar(code) else { continue }
            let x = CGFloat(code % 16) * slotWpt
            let rowTop = CGFloat(code / 16) * slotHpt      // from texture top
            NSAttributedString(string: String(Character(scalar)), attributes: [
                .font: font, .foregroundColor: NSColor.white,
            ]).draw(at: NSPoint(x: x, y: totalHpt - rowTop - (font.ascender - font.descender)))
        }
        cg.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = cg.data else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: aw, height: ah, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = ctx.device.makeTexture(descriptor: d) else { return }
        tex.replace(region: MTLRegionMake2D(0, 0, aw, ah), mipmapLevel: 0,
                          withBytes: data, bytesPerRow: cg.bytesPerRow)
        atlasTex = tex
        atlasSlot = (slotW, slotH)
        atlasKey = key
    }
}

// MARK: - Dynamic glyph atlas (steady-state text)

/// Any Character the corpus can produce — ASCII, box drawing, CJK, emoji —
/// rasterized on first use into a shared shelf-packed atlas, plus a halo
/// twin holding the same glyph as a baked shadow blur (the typing-head glow
/// and cursor halo; intensity scales via instance alpha rather than radius).
/// A full atlas resets and glyphs lazily re-enter.
final class TerminalGlyphAtlas {
    struct Slot {
        let uv: SIMD4<Float>     // x, y, w, h in atlas px
        let isColor: Bool        // emoji: the sample carries its own color
    }

    private let device: MTLDevice
    private let font: NSFont
    private let cellW: CGFloat
    private let lineH: CGFloat
    private let scale: CGFloat
    private let haloRadius: CGFloat
    private(set) var texture: MTLTexture?
    private(set) var haloTexture: MTLTexture?
    private var slots: [Character: Slot] = [:]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfH = 0
    private static let size = 2048

    init(device: MTLDevice, fontBase: CGFloat, charW: CGFloat, lineH: CGFloat,
         scale: CGFloat) {
        self.device = device
        self.font = NSFont(name: "SFMono-Regular", size: fontBase)
            ?? .monospacedSystemFont(ofSize: fontBase, weight: .regular)
        self.cellW = charW
        self.lineH = lineH
        self.scale = scale
        self.haloRadius = fontBase * 0.6
    }

    func slot(for ch: Character, cells: Int) -> Slot? {
        if let s = slots[ch] { return s }
        return rasterize(ch, cells: max(1, min(3, cells)))
    }

    private func ensureTextures() -> Bool {
        if texture == nil {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: Self.size, height: Self.size,
                mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
            haloTexture = device.makeTexture(descriptor: d)
        }
        return texture != nil && haloTexture != nil
    }

    private func rasterize(_ ch: Character, cells: Int) -> Slot? {
        guard ensureTextures(), let tex = texture, let halo = haloTexture else { return nil }
        let w = max(1, Int(ceil(cellW * CGFloat(cells) * scale)))
        let h = max(1, Int(ceil(lineH * scale)))
        if shelfX + w > Self.size {
            shelfY += shelfH
            shelfX = 0
            shelfH = 0
        }
        if shelfY + h > Self.size {
            slots.removeAll()
            shelfX = 0
            shelfY = 0
            shelfH = 0
        }
        guard let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                     | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        let isColor = ch.unicodeScalars.contains { $0.properties.isEmojiPresentation }
        let baseline = NSPoint(x: 0, y: lineH - (font.ascender - font.descender))

        func draw(_ attrs: [NSAttributedString.Key: Any], at p: NSPoint) {
            let g = NSGraphicsContext(cgContext: cg, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = g
            cg.saveGState()
            cg.scaleBy(x: scale, y: scale)
            NSAttributedString(string: String(ch), attributes: attrs).draw(at: p)
            cg.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
        }

        draw([.font: font, .foregroundColor: NSColor.white], at: baseline)
        guard let data = cg.data else { return nil }
        tex.replace(region: MTLRegionMake2D(shelfX, shelfY, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: cg.bytesPerRow)

        // Halo: draw far off-slot with the shadow offset back in, so only
        // the blur lands in the texture.
        cg.clear(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        let shadow = NSShadow()
        shadow.shadowColor = .white
        shadow.shadowBlurRadius = haloRadius
        shadow.shadowOffset = NSSize(width: 4000, height: 0)
        draw([.font: font, .foregroundColor: NSColor.white, .shadow: shadow],
             at: NSPoint(x: baseline.x - 4000, y: baseline.y))
        if let data2 = cg.data {
            halo.replace(region: MTLRegionMake2D(shelfX, shelfY, w, h), mipmapLevel: 0,
                         withBytes: data2, bytesPerRow: cg.bytesPerRow)
        }

        let s = Slot(uv: SIMD4(Float(shelfX), Float(shelfY), Float(w), Float(h)),
                     isColor: isColor)
        slots[ch] = s
        shelfX += w
        shelfH = max(shelfH, h)
        return s
    }
}
