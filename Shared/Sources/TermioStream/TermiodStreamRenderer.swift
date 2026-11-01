import CoreGraphics
import Foundation
import os
import CoreText
import GhosttyVt
import Metal
import QuartzCore

/// Draws a `TermiodStreamTerminal` with Metal: cell backgrounds, decorations
/// and the cursor as solid rectangles, text as glyph sprites from one atlas.
///
/// libghostty-vt has no renderer of its own, so this is termio's, grown from
/// the phase 1 spike (`spike/vt-renderer`). Text is shaped per grapheme with
/// CoreText, which supplies font fallback for CJK and color emoji; runs across
/// cells, and with them ligatures, are not shaped.
@MainActor
public final class TermiodStreamRenderer {
    public struct Appearance: Equatable {
        public init(fontFamily: String, fallbackFamilies: [String], fontSize: CGFloat, paddingX: CGFloat, paddingY: CGFloat, backgroundOpacity: CGFloat) {
            self.fontFamily = fontFamily
            self.fallbackFamilies = fallbackFamilies
            self.fontSize = fontSize
            self.paddingX = paddingX
            self.paddingY = paddingY
            self.backgroundOpacity = backgroundOpacity
        }
        public var fontFamily: String
        /// Faces tried, in order, for a character the primary lacks, before
        /// CoreText's own fallback.
        public var fallbackFamilies: [String]
        public var fontSize: CGFloat
        public var paddingX: CGFloat
        public var paddingY: CGFloat
        public var backgroundOpacity: CGFloat
    }

    public enum CursorStyle: Equatable {
        case block, bar, underline, hollow
    }

    public enum Failure: Error {
        case metal(String)
    }

    /// Made once for every pane: a pane that built its own paid for a shader
    /// compile and a 64 MB atlas, and a tab switch that mounts one should not.
    private static let shared = Result { try TermiodStreamRenderResources() }

    /// Whether a renderer can be made on this Mac at all: a Metal device and
    /// shaders that compile. Asked once, before a link offers the plane.
    public static var isAvailable: Bool {
        (try? shared.get()) != nil
    }

    /// Why no renderer can be made, when none can.
    public static var unavailableReason: String? {
        if case .failure(let error) = shared { return String(describing: error) }
        return nil
    }

    private let resources: TermiodStreamRenderResources
    public var device: MTLDevice { resources.device }
    private let builder: TermiodStreamFrameBuilder
    private let images: TermiodStreamImages
    public private(set) var atlas: TermiodGlyphAtlas
    public private(set) var appearance: Appearance
    private var scale: CGFloat
    private let inFlight = DispatchSemaphore(value: 3)
    private var rectangles: [TermiodStreamRectangle] = []
    private var glyphs: [TermiodStreamGlyph] = []

    public init(appearance: Appearance, scale: CGFloat) throws {
        resources = try Self.shared.get()
        self.appearance = appearance
        self.scale = scale
        builder = try TermiodStreamFrameBuilder()
        images = try TermiodStreamImages()
        atlas = try resources.atlas(appearance: appearance, scale: scale)
    }

    /// One cell in points, which is what a pane measures its viewport with.
    public var cellSize: CGSize {
        CGSize(width: CGFloat(atlas.metrics.width) / scale, height: CGFloat(atlas.metrics.height) / scale)
    }

    /// Rebuilds the atlas when the font or the display's scale changed, and
    /// says whether the grid a pane holds may have changed — font or padding —
    /// so the caller can redeclare its viewport.
    public func update(appearance: Appearance, scale: CGFloat) throws -> Bool {
        guard appearance != self.appearance || scale != self.scale else { return false }
        let paddingChanged = appearance.paddingX != self.appearance.paddingX
            || appearance.paddingY != self.appearance.paddingY
        let fontChanged = appearance.fontFamily != self.appearance.fontFamily
            || appearance.fallbackFamilies != self.appearance.fallbackFamilies
            || appearance.fontSize != self.appearance.fontSize
            || scale != self.scale
        self.appearance = appearance
        self.scale = scale
        if fontChanged {
            atlas = try resources.atlas(appearance: appearance, scale: scale)
            builder.invalidate()
        }
        return fontChanged || paddingChanged
    }

    /// The terminal's default background as of the last frame built, which a
    /// program may change with OSC 11. Never a row's color: a row scrolls.
    public var background: GhosttyColorRgb { builder.background }
    /// The terminal's scrollbar state as of the last frame prepared.
    public private(set) var scrollbar: TermiodStreamTerminal.Scrollbar?

    /// Draws one frame into `layer` if the terminal changed since the last one,
    /// or `force` asks for it regardless (a resize, focus, or new appearance).
    /// True when a frame was presented.
    @discardableResult
    public func draw(
        _ terminal: TermiodStreamTerminal, into layer: CAMetalLayer, focused: Bool, force: Bool, preedit: String? = nil,
        link: TermiodStreamTerminal.Link? = nil
    ) throws -> Bool {
        let changed = try prepare(terminal, focused: focused, force: force, preedit: preedit, link: link)
        guard changed || force else { return false }
        // A frame the GPU cannot take yet is dropped, not queued: the next
        // tick draws the newer screen anyway.
        guard inFlight.wait(timeout: .now()) == .success else {
            builder.invalidate()
            return false
        }
        guard let drawable = layer.nextDrawable(), let buffer = resources.queue.makeCommandBuffer() else {
            inFlight.signal()
            builder.invalidate()
            return false
        }
        guard encode(into: buffer, texture: drawable.texture) else {
            inFlight.signal()
            return false
        }
        buffer.present(drawable)
        let semaphore = inFlight
        buffer.addCompletedHandler { _ in semaphore.signal() }
        buffer.commit()
        return true
    }

    /// For a texture the CPU writes or reads. On an Intel Mac no GPU takes a
    /// shared texture, an integrated one included, though it reports unified
    /// memory; managed is the macOS default and works on every GPU, Apple
    /// silicon's included. iOS has only Apple GPUs, and no managed storage.
    #if os(macOS)
    public static let cpuTextureStorage = MTLStorageMode.managed
    #else
    public static let cpuTextureStorage = MTLStorageMode.shared
    #endif

    /// The whole screen drawn into an image of the given pixel size, for
    /// looking at a frame without a window — the renderer's own tests.
    public func image(
        of terminal: TermiodStreamTerminal, width: Int, height: Int, focused: Bool = true, preedit: String? = nil
    ) throws -> CGImage {
        _ = try prepare(terminal, focused: focused, force: true, preedit: preedit, link: nil)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = Self.cpuTextureStorage
        guard let texture = device.makeTexture(descriptor: descriptor),
              let buffer = resources.queue.makeCommandBuffer(),
              encode(into: buffer, texture: texture)
        else { throw Failure.metal("offscreen frame") }
        #if os(macOS)
        // The GPU's copy is the one drawn into; this brings it back.
        guard let blit = buffer.makeBlitCommandEncoder() else { throw Failure.metal("offscreen readback") }
        blit.synchronize(resource: texture)
        blit.endEncoding()
        #endif
        buffer.commit()
        buffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(
                  width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw Failure.metal("offscreen image") }
        return image
    }

    private func prepare(
        _ terminal: TermiodStreamTerminal, focused: Bool, force: Bool, preedit: String?, link: TermiodStreamTerminal.Link?
    ) throws -> Bool {
        // A forced frame may follow a terminal swap, after which no cached row
        // describes the screen.
        if force { builder.invalidate() }
        // Ghostty's blink: 600 ms on, 600 ms off.
        let blinkOn = Int(Date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
        let changed = try terminal.withFrame { state, theme, storage in
            let text = try builder.build(
                from: state, atlas: atlas, focused: focused, blinkOn: blinkOn, theme: theme, preedit: preedit, link: link
            )
            let pictures = images.read(state, storage: storage, force: force)
            scrollbar = storage.scrollbar
            return text || pictures
        }
        images.upload(device: device)
        return changed
    }

    private func encode(into buffer: MTLCommandBuffer, texture: MTLTexture) -> Bool {
        builder.flatten(rectangles: &rectangles, glyphs: &glyphs, padding: paddingExtension(texture))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let background = builder.background
        let opacity = Double(appearance.backgroundOpacity)
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(background.r) / 255 * opacity, green: Double(background.g) / 255 * opacity,
            blue: Double(background.b) / 255 * opacity, alpha: opacity
        )
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = TermiodStreamUniforms(
            viewport: SIMD2(Float(texture.width), Float(texture.height)),
            cell: SIMD2(Float(atlas.metrics.width), Float(atlas.metrics.height)),
            atlas: SIMD2(Float(atlas.size), Float(atlas.size)),
            origin: SIMD2(Float(appearance.paddingX * scale).rounded(), Float(appearance.paddingY * scale).rounded())
        )
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<TermiodStreamUniforms>.stride, index: 1)
        // Images are drawn in Ghostty's three layers around the text, at the
        // renderer's cell size: the terminal places them on cells of
        // `TermiodStreamTerminal.cellWidth` by `cellHeight` pixels, the pair
        // termiod's VT shares, so a program's layout is the same on both.
        let images = self.images
        let layout = TermiodStreamImages.Layout(
            origin: uniforms.origin, cell: uniforms.cell,
            textureWidth: texture.width, textureHeight: texture.height
        )
        func drawImages(_ layer: GhosttyRenderStateImageLayer) {
            images.encode(layer, layout: layout, encoder: encoder, pipeline: resources.imagePipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<TermiodStreamUniforms>.stride, index: 1)
        }
        drawImages(GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_BACKGROUND)
        // Rectangles carry their own pass order: backgrounds and the block
        // cursor go under the text, decorations and the thin cursors over it.
        drawRectangles(rectangles.filter { !$0.overText }, encoder: encoder)
        drawImages(GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_TEXT)
        if !glyphs.isEmpty,
           let data = device.makeBuffer(bytes: glyphs, length: glyphs.count * MemoryLayout<TermiodStreamGlyph>.stride) {
            encoder.setRenderPipelineState(resources.glyphPipeline)
            encoder.setVertexBuffer(data, offset: 0, index: 0)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: glyphs.count)
        }
        drawImages(GHOSTTY_RENDER_STATE_IMAGE_LAYER_ABOVE_TEXT)
        drawRectangles(rectangles.filter(\.overText), encoder: encoder)
        encoder.endEncoding()
        return true
    }

    /// The padding the edge cells paint. The right and bottom sides hold the
    /// padding plus less than a cell when the grid fills the pane; a wider gap
    /// means the session is sized for another screen, and stays the
    /// background so the grid's edge shows.
    private func paddingExtension(_ texture: MTLTexture) -> TermiodStreamFrameBuilder.PaddingExtension {
        let left = Int((appearance.paddingX * scale).rounded())
        let top = Int((appearance.paddingY * scale).rounded())
        let cell = atlas.metrics
        let right = texture.width - left - Int(builder.columns) * cell.width
        let bottom = texture.height - top - builder.rowCount * cell.height
        return TermiodStreamFrameBuilder.PaddingExtension(
            left: left, top: top,
            right: right >= 0 && right < left + cell.width ? right : 0,
            bottom: bottom >= 0 && bottom < top + cell.height ? bottom : 0
        )
    }

    private func drawRectangles(_ items: [TermiodStreamRectangle], encoder: MTLRenderCommandEncoder) {
        guard !items.isEmpty,
              let data = device.makeBuffer(bytes: items, length: items.count * MemoryLayout<TermiodStreamRectangle>.stride)
        else { return }
        encoder.setRenderPipelineState(resources.rectanglePipeline)
        encoder.setVertexBuffer(data, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: items.count)
    }
}

/// What every stream pane draws with: one device, queue and set of
/// pipelines, and one glyph atlas per font and scale. A pane keeps only its
/// frame builder, its terminal's images and its own in-flight limit.
@MainActor
public final class TermiodStreamRenderResources {
    private struct AtlasKey: Hashable {
        public var fontFamily: String
        public var fallbackFamilies: [String]
        public var fontSize: CGFloat
        public var scale: CGFloat
    }

    private struct WeakAtlas {
        weak var atlas: TermiodGlyphAtlas?
    }

    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let rectanglePipeline: MTLRenderPipelineState
    public let glyphPipeline: MTLRenderPipelineState
    public let imagePipeline: MTLRenderPipelineState
    /// Weak, so an atlas goes when the last pane using that font closes or
    /// moves on to another one.
    private var atlases: [AtlasKey: WeakAtlas] = [:]
    /// The atlas handed out last, held strongly: a pane is mounted only while
    /// it shows, so switching to a session that is not a stream pane would
    /// otherwise drop the atlas and rasterize every glyph again on the way back.
    private var current: TermiodGlyphAtlas?

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw TermiodStreamRenderer.Failure.metal("no Metal device")
        }
        self.device = device
        self.queue = queue
        // Compiled from source at runtime: a SwiftPM resource bundle is the one
        // thing termio must never ship (AGENTS.md, "Dependencies").
        let library = try device.makeLibrary(source: streamShaderSource, options: nil)
        rectanglePipeline = try Self.pipeline(device, library, "rectangle_vertex", "rectangle_fragment")
        glyphPipeline = try Self.pipeline(device, library, "glyph_vertex", "glyph_fragment")
        imagePipeline = try Self.pipeline(device, library, "image_vertex", "image_fragment")
    }

    public func atlas(appearance: TermiodStreamRenderer.Appearance, scale: CGFloat) throws -> TermiodGlyphAtlas {
        let key = AtlasKey(
            fontFamily: appearance.fontFamily, fallbackFamilies: appearance.fallbackFamilies,
            fontSize: appearance.fontSize, scale: scale
        )
        if let atlas = atlases[key]?.atlas {
            current = atlas
            return atlas
        }
        atlases = atlases.filter { $0.value.atlas != nil }
        let atlas = try TermiodGlyphAtlas(device: device, appearance: appearance, scale: scale)
        atlases[key] = WeakAtlas(atlas: atlas)
        current = atlas
        return atlas
    }

    private static func pipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ vertex: String, _ fragment: String
    ) throws -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        guard let attachment = descriptor.colorAttachments[0] else {
            throw TermiodStreamRenderer.Failure.metal("no color attachment")
        }
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        // Every fragment is premultiplied.
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }
}

/// Layouts shared with the shaders. Every field is 2 or 4 bytes wide and
/// 4-byte aligned in Metal, so Swift lays them out the same way.
public struct TermiodStreamUniforms {
    public init(viewport: SIMD2<Float>, cell: SIMD2<Float>, atlas: SIMD2<Float>, origin: SIMD2<Float>) {
        self.viewport = viewport
        self.cell = cell
        self.atlas = atlas
        self.origin = origin
    }
    public var viewport: SIMD2<Float>
    public var cell: SIMD2<Float>
    public var atlas: SIMD2<Float>
    public var origin: SIMD2<Float>
}

/// A solid rectangle inside a cell, in pixels from the cell's top-left.
public struct TermiodStreamRectangle {
    public init(cellX: UInt16, cellY: UInt16, x: Int16, y: Int16, width: UInt16, height: UInt16, r: UInt8, g: UInt8, b: UInt8, a: UInt8, overText: Bool = false, padding: (UInt8, UInt8, UInt8) = (0, 0, 0)) {
        self.cellX = cellX
        self.cellY = cellY
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.r = r
        self.g = g
        self.b = b
        self.a = a
        self.overText = overText
        self.padding = padding
    }
    public var cellX: UInt16, cellY: UInt16
    public var x: Int16, y: Int16
    public var width: UInt16, height: UInt16
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    /// Not read by the shader.
    public var overText: Bool = false
    public var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

public struct TermiodStreamGlyph {
    public init(cellX: UInt16, cellY: UInt16, atlasX: UInt16, atlasY: UInt16, atlasWidth: UInt16, atlasHeight: UInt16, offsetX: Int16, offsetY: Int16, r: UInt8, g: UInt8, b: UInt8, a: UInt8, colored: UInt32) {
        self.cellX = cellX
        self.cellY = cellY
        self.atlasX = atlasX
        self.atlasY = atlasY
        self.atlasWidth = atlasWidth
        self.atlasHeight = atlasHeight
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.r = r
        self.g = g
        self.b = b
        self.a = a
        self.colored = colored
    }
    public var cellX: UInt16, cellY: UInt16
    public var atlasX: UInt16, atlasY: UInt16
    public var atlasWidth: UInt16, atlasHeight: UInt16
    public var offsetX: Int16, offsetY: Int16
    public var r: UInt8, g: UInt8, b: UInt8, a: UInt8
    /// 1 when the sprite carries its own color (emoji), so the shader keeps it.
    public var colored: UInt32
}

private let streamShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms { float2 viewport; float2 cell; float2 atlas; float2 origin; };
struct Rectangle { ushort2 cell; short2 offset; ushort2 size; uchar4 color; uchar4 extra; };
struct Glyph { ushort2 cell; ushort2 atlasOrigin; ushort2 atlasSize; short2 offset; uchar4 color; uint colored; };
struct VertexOut { float4 position [[position]]; float2 uv; float4 color; uint colored [[flat]]; };

constant float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };

static float4 clip(float2 pixel, float2 viewport) {
    return float4(pixel / viewport * float2(2, -2) + float2(-1, 1), 0, 1);
}

vertex VertexOut rectangle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  const device Rectangle* items [[buffer(0)]],
                                  constant Uniforms& u [[buffer(1)]]) {
    Rectangle r = items[iid];
    float2 pixel = u.origin + float2(r.cell) * u.cell + float2(r.offset) + corners[vid] * float2(r.size);
    VertexOut out;
    out.position = clip(pixel, u.viewport);
    out.uv = float2(0);
    out.color = float4(r.color) / 255.0;
    out.colored = 0;
    return out;
}

fragment float4 rectangle_fragment(VertexOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

vertex VertexOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device Glyph* items [[buffer(0)]],
                              constant Uniforms& u [[buffer(1)]]) {
    Glyph g = items[iid];
    float2 size = float2(g.atlasSize);
    float2 pixel = u.origin + float2(g.cell) * u.cell + float2(g.offset) + corners[vid] * size;
    VertexOut out;
    out.position = clip(pixel, u.viewport);
    out.uv = (float2(g.atlasOrigin) + corners[vid] * size) / u.atlas;
    out.color = float4(g.color) / 255.0;
    out.colored = g.colored;
    return out;
}

struct Image { float2 origin; float2 size; float2 uvOrigin; float2 uvSize; };
struct ImageOut { float4 position [[position]]; float2 uv; };

vertex ImageOut image_vertex(uint vid [[vertex_id]], constant Image& image [[buffer(0)]],
                             constant Uniforms& u [[buffer(1)]]) {
    ImageOut out;
    out.position = clip(image.origin + corners[vid] * image.size, u.viewport);
    out.uv = image.uvOrigin + corners[vid] * image.uvSize;
    return out;
}

fragment float4 image_fragment(ImageOut in [[stage_in]], texture2d<float> pixels [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    // Uploaded premultiplied.
    return pixels.sample(s, in.uv);
}

fragment float4 glyph_fragment(VertexOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(coord::normalized, filter::nearest);
    float4 texel = atlas.sample(s, in.uv);
    if (in.colored != 0) { return texel * in.color.a; }
    float coverage = texel.a * in.color.a;
    return float4(in.color.rgb * coverage, coverage);
}
"""

/// The Kitty images on screen: the placements the render state lists, and a
/// texture for each image generation they show. The list is read again only
/// when its generation moves, and pixels only for a generation not yet held.
public final class TermiodStreamImages {
    public struct Placement: Equatable {
        public init(id: UInt32, generation: UInt64, layer: GhosttyRenderStateImageLayer, z: Int32, column: Int32, row: Int32, offsetX: UInt32, offsetY: UInt32, width: UInt32, height: UInt32, sourceX: UInt32, sourceY: UInt32, sourceWidth: UInt32, sourceHeight: UInt32) {
            self.id = id
            self.generation = generation
            self.layer = layer
            self.z = z
            self.column = column
            self.row = row
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.width = width
            self.height = height
            self.sourceX = sourceX
            self.sourceY = sourceY
            self.sourceWidth = sourceWidth
            self.sourceHeight = sourceHeight
        }
        public var id: UInt32
        public var generation: UInt64
        public var layer: GhosttyRenderStateImageLayer
        public var z: Int32
        public var column: Int32
        public var row: Int32
        public var offsetX: UInt32
        public var offsetY: UInt32
        public var width: UInt32
        public var height: UInt32
        public var sourceX: UInt32
        public var sourceY: UInt32
        public var sourceWidth: UInt32
        public var sourceHeight: UInt32
    }

    public struct Key: Hashable {
        public init(id: UInt32, generation: UInt64) {
            self.id = id
            self.generation = generation
        }
        public var id: UInt32
        public var generation: UInt64
    }

    public struct Layout {
        public init(origin: SIMD2<Float>, cell: SIMD2<Float>, textureWidth: Int, textureHeight: Int) {
            self.origin = origin
            self.cell = cell
            self.textureWidth = textureWidth
            self.textureHeight = textureHeight
        }
        public var origin: SIMD2<Float>
        public var cell: SIMD2<Float>
        public var textureWidth: Int
        public var textureHeight: Int
    }

    private struct Quad {
        public var origin: SIMD2<Float>
        public var size: SIMD2<Float>
        public var uvOrigin: SIMD2<Float>
        public var uvSize: SIMD2<Float>
    }

    nonisolated(unsafe) private var iterator: GhosttyRenderStateImageIterator?
    public private(set) var placements: [Placement] = []
    private var listGeneration: UInt64?
    private var columns: UInt16 = 0
    private var rows: UInt16 = 0
    private var textures: [Key: MTLTexture] = [:]
    private var sizes: [Key: (width: Int, height: Int)] = [:]
    private var pending: [Key: TermiodStreamTerminal.ImagePixels] = [:]
    /// A placement whose pixels have not arrived: looked for every frame.
    private var missing = false

    public init() throws {
        guard ghostty_render_state_image_iterator_new(nil, &iterator) == GHOSTTY_SUCCESS else {
            throw TermiodStreamRenderer.Failure.metal("render state image iterator")
        }
    }

    deinit {
        ghostty_render_state_image_iterator_free(iterator)
    }

    /// Under the frame's lock: rereads the list if it moved, and copies the
    /// pixels the textures lack. Returns whether the frame must be drawn for
    /// the images' sake.
    public func read(_ state: GhosttyRenderState, storage: TermiodStreamTerminal.FrameImages, force: Bool) -> Bool {
        var generation: UInt64 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION, &generation)
        guard force || missing || generation != listGeneration else { return false }
        let moved = force || generation != listGeneration
        listGeneration = generation
        if moved {
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
            placements = list(state)
        }
        missing = false
        var arrived = false
        for key in Set(placements.map { Key(id: $0.id, generation: $0.generation) })
        where textures[key] == nil && pending[key] == nil {
            // An image's pixels move to a new generation together, so a read
            // that finds another generation is the next frame's to draw.
            if let pixels = storage.pixels(id: key.id), pixels.generation == key.generation {
                pending[key] = pixels
                arrived = true
            } else {
                missing = true
            }
        }
        return moved || arrived
    }

    private func list(_ state: GhosttyRenderState) -> [Placement] {
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR, &iterator) == GHOSTTY_SUCCESS
        else { return [] }
        var placements: [Placement] = []
        while ghostty_render_state_image_iterator_next(iterator) {
            var kind = GHOSTTY_IMAGE_PROTOCOL_KITTY
            guard ghostty_render_state_image_get(iterator, GHOSTTY_RENDER_STATE_IMAGE_DATA_PROTOCOL, &kind)
                    == GHOSTTY_SUCCESS,
                  kind == GHOSTTY_IMAGE_PROTOCOL_KITTY
            else { continue }
            var placement = Placement(
                id: 0, generation: 0, layer: GHOSTTY_RENDER_STATE_IMAGE_LAYER_BELOW_TEXT, z: 0, column: 0, row: 0,
                offsetX: 0, offsetY: 0, width: 0, height: 0, sourceX: 0, sourceY: 0, sourceWidth: 0, sourceHeight: 0
            )
            func read<Value>(_ key: GhosttyRenderStateImageData, _ value: inout Value) -> Bool {
                ghostty_render_state_image_get(iterator, key, &value) == GHOSTTY_SUCCESS
            }
            guard read(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_ID, &placement.id),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_IMAGE_GENERATION, &placement.generation),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_LAYER, &placement.layer),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_Z, &placement.z),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_COL, &placement.column),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_VIEWPORT_ROW, &placement.row),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_X, &placement.offsetX),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_CELL_OFFSET_Y, &placement.offsetY),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_WIDTH, &placement.width),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_PIXEL_HEIGHT, &placement.height),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_X, &placement.sourceX),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_Y, &placement.sourceY),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_WIDTH, &placement.sourceWidth),
                  read(GHOSTTY_RENDER_STATE_IMAGE_DATA_SOURCE_HEIGHT, &placement.sourceHeight),
                  placement.width > 0, placement.height > 0
            else { continue }
            placements.append(placement)
        }
        // Iteration order is not drawing order: lower z first within a layer.
        return placements.enumerated()
            .sorted { $0.element.z != $1.element.z ? $0.element.z < $1.element.z : $0.offset < $1.offset }
            .map(\.element)
    }

    /// Outside the lock: turns copied pixels into textures, and lets go of
    /// textures no placement shows any more.
    public func upload(device: MTLDevice) {
        for (key, pixels) in pending {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: pixels.width, height: pixels.height, mipmapped: false
            )
            descriptor.usage = .shaderRead
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                StreamLog.logger.error("image texture \(pixels.width)x\(pixels.height) failed")
                continue
            }
            pixels.rgba().withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                    withBytes: base, bytesPerRow: pixels.width * 4
                )
            }
            textures[key] = texture
            sizes[key] = (pixels.width, pixels.height)
        }
        pending.removeAll()
        let shown = Set(placements.map { Key(id: $0.id, generation: $0.generation) })
        for key in textures.keys where !shown.contains(key) {
            textures[key] = nil
            sizes[key] = nil
        }
    }

    /// The quads of one layer, in pixels of the drawable, clipped to the grid.
    public func quads(_ layer: GhosttyRenderStateImageLayer, layout: Layout) -> [(Key, SIMD4<Float>, SIMD4<Float>)] {
        let scale = SIMD2(
            layout.cell.x / Float(TermiodStreamTerminal.cellWidth),
            layout.cell.y / Float(TermiodStreamTerminal.cellHeight)
        )
        return placements.compactMap { placement in
            let key = Key(id: placement.id, generation: placement.generation)
            guard placement.layer == layer, let size = sizes[key], size.width > 0, size.height > 0 else { return nil }
            let origin = layout.origin + SIMD2(Float(placement.column), Float(placement.row)) * layout.cell
                + SIMD2(Float(placement.offsetX), Float(placement.offsetY)) * scale
            let extent = SIMD2(Float(placement.width), Float(placement.height)) * scale
            let image = SIMD2(Float(size.width), Float(size.height))
            let uv = SIMD4(
                Float(placement.sourceX) / image.x, Float(placement.sourceY) / image.y,
                Float(placement.sourceWidth) / image.x, Float(placement.sourceHeight) / image.y
            )
            return (key, SIMD4(origin.x, origin.y, extent.x, extent.y), uv)
        }
    }

    public func encode(
        _ layer: GhosttyRenderStateImageLayer, layout: Layout, encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState
    ) {
        let quads = quads(layer, layout: layout)
        guard !quads.isEmpty else { return }
        // A placement is reported at its full size even when part of it is
        // off the grid; the scissor keeps it to the cells.
        let left = max(0, Int(layout.origin.x))
        let top = max(0, Int(layout.origin.y))
        let width = min(layout.textureWidth - left, Int(Float(columns) * layout.cell.x))
        let height = min(layout.textureHeight - top, Int(Float(rows) * layout.cell.y))
        guard width > 0, height > 0 else { return }
        encoder.setScissorRect(MTLScissorRect(x: left, y: top, width: width, height: height))
        encoder.setRenderPipelineState(pipeline)
        for (key, rectangle, uv) in quads {
            guard let texture = textures[key] else { continue }
            var quad = Quad(
                origin: SIMD2(rectangle.x, rectangle.y), size: SIMD2(rectangle.z, rectangle.w),
                uvOrigin: SIMD2(uv.x, uv.y), uvSize: SIMD2(uv.z, uv.w)
            )
            encoder.setVertexBytes(&quad, length: MemoryLayout<Quad>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: layout.textureWidth, height: layout.textureHeight))
    }
}

/// A glyph's bitmap and where its origin falls in it. The origin is a whole pixel,
/// so every glyph of a line shares the cell's baseline: drawing from the glyph's
/// own fractional bounds moved each one by a different part of a pixel (#820).
public struct GlyphPlacement: Equatable {
    public init(bounds: CGRect, padding: Int) {
        let minX = Int(bounds.minX.rounded(.down))
        let minY = Int(bounds.minY.rounded(.down))
        let maxY = Int(bounds.maxY.rounded(.up))
        width = Int(bounds.maxX.rounded(.up)) - minX + 2 * padding
        height = maxY - minY + 2 * padding
        origin = CGPoint(x: padding - minX, y: padding - minY)
        ascent = maxY + padding
        left = minX - padding
    }

    public var width: Int
    public var height: Int
    /// Where to draw the glyph in the bitmap, counted up from its bottom edge.
    public var origin: CGPoint
    /// How far the bitmap's top edge sits above the baseline.
    public var ascent: Int
    /// How far the bitmap's left edge sits from the cell's.
    public var left: Int
}

/// The pixel size of one cell and where the baseline and decorations sit in it.
public struct TermiodCellMetrics: Equatable {
    public init(width: Int, height: Int, baseline: Int, underlinePosition: Int, underlineThickness: Int, strikethroughPosition: Int) {
        self.width = width
        self.height = height
        self.baseline = baseline
        self.underlinePosition = underlinePosition
        self.underlineThickness = underlineThickness
        self.strikethroughPosition = strikethroughPosition
    }
    public var width: Int
    public var height: Int
    public var baseline: Int
    public var underlinePosition: Int
    public var underlineThickness: Int
    public var strikethroughPosition: Int
}

/// Glyph sprites rasterized with CoreText into one premultiplied BGRA texture,
/// packed in shelves. A sprite is one grapheme in one face, so combining marks,
/// ZWJ emoji and fallback fonts all come out of CoreText's own line layout.
@MainActor
public final class TermiodGlyphAtlas {
    public struct Slot {
        public init(origin: SIMD2<UInt16>, size: SIMD2<UInt16>, offset: SIMD2<Int16>, colored: Bool) {
            self.origin = origin
            self.size = size
            self.offset = offset
            self.colored = colored
        }
        public var origin: SIMD2<UInt16>
        public var size: SIMD2<UInt16>
        /// The sprite's top-left from the cell's top-left, in pixels.
        public var offset: SIMD2<Int16>
        public var colored: Bool
    }

    private struct Key: Hashable {
        public var graphemes: [UInt32]
        public var bold: Bool
        public var italic: Bool
        /// One grapheme can be one cell or two (mode 2027 decides an emoji's
        /// width), and an emoji's sprite is sized to its cells.
        public var cells: Int
        /// A glyph a run shaped to (`ligatures`), drawn as itself, `shift`
        /// pixels right of its cell; nil draws `graphemes`.
        public var glyph: CGGlyph? = nil
        public var shift: Int = 0
    }

    /// What one character of a shaped run draws.
    public enum Shaped: Equatable {
        /// What the character draws on its own.
        case same
        /// A glyph its neighbours swapped in, `shift` pixels right of its cell.
        case glyph(CGGlyph, shift: Int)
        /// Nothing: a ligature glyph from a character before it covers it.
        case covered
    }

    private struct RunKey: Hashable {
        var run: [UInt16]
        var bold: Bool
        var italic: Bool
    }

    /// Replaced, never rewritten, when the atlas is emptied: a frame still on
    /// the GPU keeps sampling the texture it was encoded with.
    public private(set) var texture: MTLTexture
    public let metrics: TermiodCellMetrics
    public let size: Int
    private let device: MTLDevice
    private let fonts: [CTFont]
    /// Off for the pass that rebuilds a screen after the atlas was emptied:
    /// emptying it again would undo the rows that pass already built. A
    /// glyph that does not fit then is dropped, not drawn from a stale slot.
    public var mayEmpty = true
    private var slots: [Key: Slot?] = [:]
    private var shaped: [RunKey: [Shaped]?] = [:]
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var exhausted = false
    /// Bumped each time the atlas is emptied to make room, which moves every
    /// sprite: anything built from an older generation must be rebuilt.
    public private(set) var generation = 0

    public init(device: MTLDevice, appearance: TermiodStreamRenderer.Appearance, scale: CGFloat, size: Int = 4096) throws {
        let pointSize = appearance.fontSize * scale
        let primary = Self.font(family: appearance.fontFamily, size: pointSize)
        let cascade = appearance.fallbackFamilies.map { family in
            CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        }
        let base = CTFontCreateCopyWithAttributes(
            primary, pointSize, nil,
            CTFontDescriptorCreateWithAttributes([kCTFontCascadeListAttribute: cascade] as CFDictionary)
        )
        func variant(_ traits: CTFontSymbolicTraits) -> CTFont {
            CTFontCreateCopyWithSymbolicTraits(base, 0, nil, traits, traits) ?? base
        }
        fonts = [base, variant(.traitBold), variant(.traitItalic), variant([.traitBold, .traitItalic])]

        var glyph = CGGlyph(0)
        var character: UniChar = 0x4D
        CTFontGetGlyphsForCharacters(base, &character, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(base, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(base)
        let descent = CTFontGetDescent(base)
        let leading = CTFontGetLeading(base)
        let height = Int((ascent + descent + leading).rounded(.up))
        let baseline = Int((ascent + leading / 2).rounded(.up))
        let thickness = max(1, Int(CTFontGetUnderlineThickness(base).rounded()))
        metrics = TermiodCellMetrics(
            width: max(1, Int(advance.width.rounded())),
            height: max(1, height),
            baseline: baseline,
            underlinePosition: min(height - thickness, baseline - Int(CTFontGetUnderlinePosition(base).rounded())),
            underlineThickness: thickness,
            strikethroughPosition: baseline - Int((CTFontGetXHeight(base) / 2).rounded())
        )
        self.size = size
        self.device = device
        texture = try Self.makeTexture(device, size: size)
    }

    private static func makeTexture(_ device: MTLDevice, size: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: size, height: size, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = TermiodStreamRenderer.cpuTextureStorage
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw TermiodStreamRenderer.Failure.metal("atlas texture")
        }
        return texture
    }

    private static func font(family: String, size: CGFloat) -> CTFont {
        if !family.isEmpty {
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let font = CTFontCreateWithFontDescriptor(descriptor, size, nil)
            // CoreText answers an unknown family with its default face rather
            // than nil, which is not monospaced.
            if (CTFontCopyFamilyName(font) as String) == family { return font }
        }
        return CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)
            ?? CTFontCreateWithName("Menlo" as CFString, size, nil)
    }

    /// The sprite for a grapheme, rasterized on first use. Nil for a grapheme
    /// with nothing to draw, or once the atlas is full.
    public func slot(graphemes: [UInt32], bold: Bool, italic: Bool, cells: Int) -> Slot? {
        lookup(Key(graphemes: graphemes, bold: bold, italic: italic, cells: cells))
    }

    /// The sprite for a glyph a shaped run swapped in. An empty glyph, the
    /// spacer a ligature font puts after its ligature, is an empty sprite.
    public func slot(glyph: CGGlyph, shift: Int, bold: Bool, italic: Bool) -> Slot? {
        lookup(Key(graphemes: [], bold: bold, italic: italic, cells: 1, glyph: glyph, shift: shift))
    }

    /// How a run of characters in one style shapes, as Ghostty shapes runs:
    /// a font with programming ligatures (Fira Code, JetBrains Mono) swaps in
    /// glyphs by their neighbours, which shaping each cell alone never sees.
    /// One entry per character; nil when every character draws as it does
    /// alone, or when a fallback face would draw part of the run.
    public func ligatures(_ run: [UInt16], bold: Bool, italic: Bool) -> [Shaped]? {
        let key = RunKey(run: run, bold: bold, italic: italic)
        if let cached = shaped[key] { return cached }
        let result = shape(run, font: fonts[(bold ? 1 : 0) + (italic ? 2 : 0)])
        // Runs repeat on a screen; a cap keeps a stream of novel ones bounded.
        if shaped.count >= 4096 { shaped.removeAll(keepingCapacity: true) }
        shaped[key] = result
        return result
    }

    private func shape(_ run: [UInt16], font: CTFont) -> [Shaped]? {
        let string = String(utf16CodeUnits: run, count: run.count) as CFString
        guard let attributed = CFAttributedStringCreate(nil, string, [kCTFontAttributeName: font] as CFDictionary),
              let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(attributed)) as? [CTRun],
              runs.count == 1, let line = runs.first,
              let used = (CTRunGetAttributes(line) as NSDictionary)[kCTFontAttributeName] as CFTypeRef?,
              CFGetTypeID(used) == CTFontGetTypeID(),
              CFEqual(CTFontCopyPostScriptName(unsafeBitCast(used, to: CTFont.self)), CTFontCopyPostScriptName(font))
        else { return nil }
        let count = CTRunGetGlyphCount(line)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var advances = [CGSize](repeating: .zero, count: count)
        CTRunGetGlyphs(line, CFRange(location: 0, length: count), &glyphs)
        CTRunGetStringIndices(line, CFRange(location: 0, length: count), &indices)
        CTRunGetPositions(line, CFRange(location: 0, length: count), &positions)
        CTRunGetAdvances(line, CFRange(location: 0, length: count), &advances)
        var alone = [CGGlyph](repeating: 0, count: run.count)
        var characters = run
        CTFontGetGlyphsForCharacters(font, &characters, &alone, run.count)
        var result = [Shaped](repeating: .covered, count: run.count)
        var seen = Set<Int>()
        // Where the pen stood when the glyph's cell began, as Ghostty's shaper
        // keeps it: measured against the cell grid instead, the font's
        // fractional advance would add up along the run and walk every glyph
        // off its cell, ligatures or not.
        var pen: CGFloat = 0
        for (glyph, (index, (position, advance))) in zip(glyphs, zip(indices, zip(positions, advances))) {
            // Two glyphs for one character is not a cell's worth of drawing.
            guard index >= 0, index < run.count, seen.insert(index).inserted else { return nil }
            let shift = Int((position.x - pen).rounded())
            pen += advance.width
            result[index] = glyph == alone[index] && shift == 0 ? .same : .glyph(glyph, shift: shift)
        }
        return result.allSatisfy { $0 == .same } ? nil : result
    }

    private func lookup(_ key: Key) -> Slot? {
        if let cached = slots[key] { return cached }
        var slot = rasterize(key, cells: key.cells)
        if slot == nil, exhausted, mayEmpty, let fresh = try? Self.makeTexture(device, size: size) {
            // Full: start over rather than stop drawing new characters. The
            // screen's own glyphs come back on the rebuild this triggers.
            texture = fresh
            slots.removeAll(keepingCapacity: true)
            shelfX = 0
            shelfY = 0
            shelfHeight = 0
            exhausted = false
            generation += 1
            slot = rasterize(key, cells: key.cells)
        }
        slots[key] = slot
        return slot
    }

    /// Box drawing, block elements and the powerline arrows meet their
    /// neighbours only when they fill the cell exactly; drawn at the font's
    /// own size they stop short of the line spacing and leave gaps.
    /// Characters that draw pictures rather than text, which keep the exact
    /// color a program chose: Ghostty exempts them from minimum contrast.
    public static func isGraphic(_ graphemes: [UInt32]) -> Bool {
        guard graphemes.count == 1, let codepoint = graphemes.first else { return false }
        return (0x2500...0x259F).contains(codepoint) || (0x2800...0x28FF).contains(codepoint)
            || (0xE0B0...0xE0D7).contains(codepoint) || (0x1FB00...0x1FBFF).contains(codepoint)
            || (0x1CC00...0x1CEBF).contains(codepoint)
    }

    private static func fillsCell(_ graphemes: [UInt32]) -> Bool {
        guard graphemes.count == 1, let codepoint = graphemes.first else { return false }
        return (0x2500...0x259F).contains(codepoint) || (0xE0B0...0xE0B3).contains(codepoint)
    }

    private func rasterizeFillingCell(_ key: Key) -> Slot? {
        guard let scalar = key.graphemes.first.flatMap(Unicode.Scalar.init) else { return nil }
        var font = fonts[key.bold ? 1 : 0]
        let utf16 = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: utf16.count)
        if !CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) {
            font = CTFontCreateForString(font, String(scalar) as CFString, CFRange(location: 0, length: utf16.count))
            guard CTFontGetGlyphsForCharacters(font, utf16, &glyphs, utf16.count) else { return nil }
        }
        var glyph = glyphs[0]
        // The face's own full block is the box every block and line glyph is
        // drawn against; the font's ascent sits above it, so it cannot be.
        var blockCharacter: UniChar = 0x2588
        var block = CGGlyph(0)
        var box = CGRect.zero
        if CTFontGetGlyphsForCharacters(font, &blockCharacter, &block, 1) {
            box = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &block, nil, 1)
        }
        if box.width <= 0 || box.height <= 0 {
            var advance = CGSize.zero
            CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
            box = CGRect(x: 0, y: -CTFontGetDescent(font), width: advance.width,
                         height: CTFontGetAscent(font) + CTFontGetDescent(font))
        }
        guard box.width > 0, box.height > 0 else { return nil }
        let width = metrics.width
        let height = metrics.height
        guard let origin = allocate(width: width, height: height) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.setShouldAntialias(true)
            context.setFillColor(gray: 1, alpha: 1)
            context.scaleBy(x: CGFloat(width) / box.width, y: CGFloat(height) / box.height)
            var position = CGPoint(x: -box.minX, y: -box.minY)
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            return true
        }
        guard drawn else { return nil }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
        )
        return Slot(
            origin: SIMD2(UInt16(origin.x), UInt16(origin.y)),
            size: SIMD2(UInt16(width), UInt16(height)), offset: SIMD2(0, 0), colored: false
        )
    }

    private func rasterize(_ key: Key, cells: Int) -> Slot? {
        if let glyph = key.glyph { return rasterize(glyph: glyph, key: key) }
        if Self.fillsCell(key.graphemes) { return rasterizeFillingCell(key) }
        var text = String.UnicodeScalarView()
        for codepoint in key.graphemes {
            guard let scalar = Unicode.Scalar(codepoint) else { return nil }
            text.append(scalar)
        }
        let font = fonts[(key.bold ? 1 : 0) + (key.italic ? 2 : 0)]
        func layout(_ font: CTFont) -> (CTLine, CGRect)? {
            let attributed = CFAttributedStringCreate(
                nil, String(text) as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
            )
            guard let attributed else { return nil }
            let line = CTLineCreateWithAttributedString(attributed)
            return (line, CTLineGetBoundsWithOptions(line, .useGlyphPathBounds))
        }
        guard let (line, bounds) = layout(font), bounds.width > 0, bounds.height > 0 else { return nil }
        let colored = Self.usesColorFont(line)
        let padding = 1
        // An emoji is drawn at the font's size, which is taller than a cell on
        // most fonts. Its bitmap is its cells exactly, with the emoji scaled
        // and centred inside, so no pixel can reach the rows around it.
        let span = metrics.width * max(1, cells)
        let placement = GlyphPlacement(bounds: bounds, padding: padding)
        let width = colored ? span : placement.width
        let height = colored ? metrics.height : placement.height
        let fit = colored
            ? min(1, CGFloat(span - 2) / bounds.width, CGFloat(metrics.height - 2) / bounds.height)
            : 1
        guard let origin = allocate(width: width, height: height) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            if colored {
                context.translateBy(
                    x: (CGFloat(width) - bounds.width * fit) / 2, y: (CGFloat(height) - bounds.height * fit) / 2)
                context.scaleBy(x: fit, y: fit)
                context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
            } else {
                context.textPosition = placement.origin
            }
            CTLineDraw(line, context)
            return true
        }
        guard drawn else { return nil }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
        )
        // An emoji's bitmap is its cells.
        let top = colored ? 0 : metrics.baseline - placement.ascent
        let left = colored ? 0 : placement.left
        return Slot(
            origin: SIMD2(UInt16(origin.x), UInt16(origin.y)),
            size: SIMD2(UInt16(width), UInt16(height)),
            offset: SIMD2(Int16(clamping: left), Int16(clamping: top)),
            colored: colored
        )
    }

    private func rasterize(glyph: CGGlyph, key: Key) -> Slot? {
        let font = fonts[(key.bold ? 1 : 0) + (key.italic ? 2 : 0)]
        var glyph = glyph
        let bounds = CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyph, nil, 1)
        guard bounds.width > 0, bounds.height > 0 else {
            return Slot(origin: SIMD2(0, 0), size: SIMD2(0, 0), offset: SIMD2(0, 0), colored: false)
        }
        let placement = GlyphPlacement(bounds: bounds, padding: 1)
        let width = placement.width
        let height = placement.height
        guard let origin = allocate(width: width, height: height) else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.setShouldAntialias(true)
            context.setShouldSmoothFonts(false)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            var position = placement.origin
            CTFontDrawGlyphs(font, &glyph, &position, 1, context)
            return true
        }
        guard drawn else { return nil }
        texture.replace(
            region: MTLRegionMake2D(origin.x, origin.y, width, height),
            mipmapLevel: 0, withBytes: pixels, bytesPerRow: width * 4
        )
        let top = metrics.baseline - placement.ascent
        let left = placement.left + key.shift
        return Slot(
            origin: SIMD2(UInt16(origin.x), UInt16(origin.y)),
            size: SIMD2(UInt16(width), UInt16(height)),
            offset: SIMD2(Int16(clamping: left), Int16(clamping: top)),
            colored: false
        )
    }

    private static func usesColorFont(_ line: CTLine) -> Bool {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return false }
        return runs.contains { run in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName], CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else {
                return false
            }
            // Checked just above, so this cast cannot fail.
            let font = unsafeBitCast(value as CFTypeRef, to: CTFont.self)
            return CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs)
        }
    }

    private func allocate(width: Int, height: Int) -> (x: Int, y: Int)? {
        guard width <= size else { return nil }
        if shelfX + width > size {
            shelfY += shelfHeight
            shelfX = 0
            shelfHeight = 0
        }
        guard shelfY + height <= size else {
            exhausted = true
            return nil
        }
        let origin = (shelfX, shelfY)
        shelfX += width
        shelfHeight = max(shelfHeight, height)
        return origin
    }
}

/// Turns the render state into rectangles and glyphs, rebuilding only the rows
/// libghostty marked dirty.
@MainActor
public final class TermiodStreamFrameBuilder {
    public private(set) var background = GhosttyColorRgb(r: 0, g: 0, b: 0)
    private var rowRectangles: [[TermiodStreamRectangle]] = []
    private var rowGlyphs: [[TermiodStreamGlyph]] = []
    /// Each row's cell backgrounds without the selection, or nil for a row
    /// whose edges must not reach into the padding: the rows that
    /// `window-padding-color = extend` paints the padding from.
    private var rowEdgeBackgrounds: [[TermiodStreamRectangle]?] = []
    public private(set) var columns: UInt16 = 0
    public var rowCount: Int { rowRectangles.count }

    private var cellWidth = 1
    /// The columns where a wide character starts, per row, so a cursor on one
    /// covers both of its cells.
    private var rowWideStarts: [Set<UInt16>] = []
    private var minimumContrast: Double = 1
    private var selectionColors: (background: GhosttyColorRgb?, foreground: GhosttyColorRgb?) = (nil, nil)
    private var cursorText: GhosttyColorRgb?
    private var cursor: [TermiodStreamRectangle] = []
    private var cursorGlyph: TermiodStreamGlyph?
    private var cursorCell: (x: UInt16, y: UInt16)?
    /// The input method's unfinished text, drawn over the cells it covers.
    private var preeditRectangles: [TermiodStreamRectangle] = []
    private var preeditGlyphs: [TermiodStreamGlyph] = []
    private var preeditCells: (y: UInt16, first: UInt16, last: UInt16)?
    private var lastPreedit: PreeditState?
    private var hoveredLink: TermiodStreamTerminal.Link?
    private var linkUnderline: [TermiodStreamRectangle] = []
    nonisolated(unsafe) private var rowIterator: GhosttyRenderStateRowIterator?
    nonisolated(unsafe) private var cells: GhosttyRenderStateRowCells?
    private var codepoints = [UInt32](repeating: 0, count: 32)
    private var stale = true
    /// The atlas the cached rows name sprites in, and its generation then.
    /// Panes share an atlas, so another pane can empty it between two builds.
    private weak var builtAtlas: TermiodGlyphAtlas?
    private var builtGeneration = 0

    public init() throws {
        guard ghostty_render_state_row_iterator_new(nil, &rowIterator) == GHOSTTY_SUCCESS,
              ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS
        else { throw TermiodStreamRenderer.Failure.metal("render state iterators") }
    }

    deinit {
        ghostty_render_state_row_iterator_free(rowIterator)
        ghostty_render_state_row_cells_free(cells)
    }

    /// The next build rebuilds every row: the atlas changed, or a frame built
    /// from the render state was never drawn and its dirt was already consumed.
    public func invalidate() {
        stale = true
    }

    /// Returns false when nothing changed since the last build.
    public func build(
        from state: GhosttyRenderState, atlas: TermiodGlyphAtlas, focused: Bool, blinkOn: Bool = true,
        theme: TermiodStreamTerminal.Theme? = nil, preedit: String? = nil, link: TermiodStreamTerminal.Link? = nil
    ) throws -> Bool {
        let contrast = theme?.minimumContrast ?? 1
        if contrast != minimumContrast {
            minimumContrast = contrast
            stale = true
        }
        let selection = (theme?.selectionBackground, theme?.selectionForeground)
        func same(_ a: GhosttyColorRgb?, _ b: GhosttyColorRgb?) -> Bool {
            a.map { a in b.map { a.r == $0.r && a.g == $0.g && a.b == $0.b } ?? false } ?? (b == nil)
        }
        if !same(selection.0, selectionColors.background) || !same(selection.1, selectionColors.foreground) {
            selectionColors = selection
            stale = true
        }
        cursorText = theme?.cursorText
        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var rows: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns)
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors)
        let atlasMoved = builtAtlas !== atlas || builtGeneration != atlas.generation
        let full = stale || atlasMoved || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL || rowRectangles.count != Int(rows)
        // A cursor that moved leaves one row's runs whole again and breaks
        // another's, and moving it dirties neither.
        let cursorBreak = Self.shapingBreak(state)
        var cursorRows: Set<Int> = []
        if cursorBreak?.x != shapingCursor?.x || cursorBreak?.y != shapingCursor?.y {
            if let old = shapingCursor?.y { cursorRows.insert(old) }
            if let new = cursorBreak?.y { cursorRows.insert(new) }
            shapingCursor = cursorBreak
        }
        var changed = false
        if full || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE || !cursorRows.isEmpty {
            stale = false
            changed = true
            background = colors.background
            if rowRectangles.count != Int(rows) {
                rowRectangles = Array(repeating: [], count: Int(rows))
                rowGlyphs = Array(repeating: [], count: Int(rows))
                rowEdgeBackgrounds = Array(repeating: nil, count: Int(rows))
                rowWideStarts = Array(repeating: [], count: Int(rows))
            }
            let generation = atlas.generation
            rebuildRows(state, full: full, also: cursorRows, colors: colors, atlas: atlas)
            // The atlas was emptied to make room partway through, so rows
            // built before that point name sprites that are gone.
            if atlas.generation != generation {
                atlas.mayEmpty = false
                rebuildRows(state, full: true, colors: colors, atlas: atlas)
                atlas.mayEmpty = true
            }
            builtAtlas = atlas
            builtGeneration = atlas.generation
            var clean = GHOSTTY_RENDER_STATE_DIRTY_FALSE
            _ = ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPTION_DIRTY, &clean)
        }
        // The cursor moves without dirtying any cell, so it is compared on
        // its own every frame.
        // A link under the pointer with ⌘ held is underlined, as Ghostty
        // underlines it.
        if link != hoveredLink {
            hoveredLink = link
            linkUnderline = (link?.segments ?? []).map { segment in
                let metrics = atlas.metrics
                return TermiodStreamRectangle(
                    cellX: segment.columns.lowerBound, cellY: segment.row, x: 0,
                    y: Int16(clamping: metrics.underlinePosition),
                    width: UInt16(clamping: metrics.width * (Int(segment.columns.upperBound - segment.columns.lowerBound) + 1)),
                    height: UInt16(clamping: metrics.underlineThickness),
                    r: colors.foreground.r, g: colors.foreground.g, b: colors.foreground.b, a: 255, overText: true
                )
            }
            changed = true
        }
        let preeditState = PreeditState(state, text: preedit, colors: colors)
        if changed || preeditState != lastPreedit {
            lastPreedit = preeditState
            buildPreedit(preeditState, atlas: atlas)
            changed = true
            // The composed text can empty the atlas after the rows were built
            // from it; this frame is encoded against the emptied one.
            if atlas.generation != builtGeneration {
                atlas.mayEmpty = false
                rebuildRows(state, full: true, colors: colors, atlas: atlas)
                buildPreedit(preeditState, atlas: atlas)
                atlas.mayEmpty = true
                builtGeneration = atlas.generation
            }
        }
        // Ghostty draws no cursor while there is text being composed.
        var cursorState = preeditState.text.isEmpty
            ? CursorState(state, colors: colors, focused: focused, blinkOn: blinkOn)
            : CursorState()
        cursorState.text = cursorText.map { [$0.r, $0.g, $0.b] }
        if changed || cursorState != lastCursorState {
            lastCursorState = cursorState
            buildCursor(cursorState, colors: colors, atlas: atlas)
            changed = true
        }
        return changed
    }

    private func rebuildRows(
        _ state: GhosttyRenderState, full: Bool, also extra: Set<Int> = [], colors: GhosttyRenderStateColors,
        atlas: TermiodGlyphAtlas
    ) {
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var y = 0
        while ghostty_render_state_row_iterator_next(rowIterator) {
            defer { y += 1 }
            guard y < rowRectangles.count else { break }
            var rowDirty = false
            _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            guard full || rowDirty || extra.contains(y) else { continue }
            rebuildRow(y, colors: colors, atlas: atlas)
            var clean = false
            _ = ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
        }
    }

    /// Everything the cursor's drawing depends on.
    private struct CursorState: Equatable {
        public var x: UInt16 = 0
        public var y: UInt16 = 0
        public var shape: TermiodStreamRenderer.CursorStyle?
        public var red: UInt8 = 0
        public var green: UInt8 = 0
        public var blue: UInt8 = 0
        /// The theme's cursor-text color, which only the drawing reads.
        public var text: [UInt8]?

        public init() {}

        /// `blinkOn` is the blink phase now; a cursor that blinks is drawn
        /// only in the on half, and a pane out of focus never blinks.
        public init(_ state: GhosttyRenderState, colors: GhosttyRenderStateColors, focused: Bool, blinkOn: Bool) {
            var visible = false
            var hasValue = false
            var blinking = false
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &visible)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasValue)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_BLINKING, &blinking)
            guard visible, hasValue, !(focused && blinking && !blinkOn) else { return }
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
            // The terminal's own style: the program's DECSCUSR, or the setting
            // where it chose none (`TermiodStreamTerminal.Theme.cursorStyle`).
            // An unfocused pane always shows the outline.
            var visual = GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &visual)
            switch (focused, visual) {
            case (false, _): shape = .hollow
            case (_, GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR): shape = .bar
            case (_, GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE): shape = .underline
            case (_, GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW): shape = .hollow
            default: shape = .block
            }
            // On the right half of a wide character the cursor covers all of it.
            var wideTail = false
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL, &wideTail)
            if wideTail, x > 0 { x -= 1 }
            let color = colors.cursor_has_value ? colors.cursor : colors.foreground
            red = color.r
            green = color.g
            blue = color.b
        }
    }

    private var lastCursorState: CursorState?
    /// The cell runs were last broken at: the cursor's, shown or hidden, as
    /// Ghostty breaks them.
    private var shapingCursor: (x: UInt16, y: Int)?

    private static func shapingBreak(_ state: GhosttyRenderState) -> (x: UInt16, y: Int)? {
        var hasValue = false
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasValue)
        guard hasValue else { return nil }
        var x: UInt16 = 0
        var y: UInt16 = 0
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
        _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
        return (x, Int(y))
    }

    /// Everything the composed text's drawing depends on.
    private struct PreeditState: Equatable {
        public var text = ""
        public var x: UInt16 = 0
        public var y: UInt16 = 0
        public var cols: UInt16 = 0
        public var red: UInt8 = 0
        public var green: UInt8 = 0
        public var blue: UInt8 = 0

        public init(_ state: GhosttyRenderState, text: String?, colors: GhosttyRenderStateColors) {
            var hasValue = false
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &hasValue)
            guard let text, !text.isEmpty, hasValue else { return }
            self.text = text
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &x)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &y)
            _ = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &cols)
            red = colors.foreground.r
            green = colors.foreground.g
            blue = colors.foreground.b
        }
    }

    /// Ghostty's preedit: the text from the cursor on in the foreground color,
    /// underlined, over whatever those cells held. Text wider than the row
    /// shifts left, and keeps its end when it cannot fit at all.
    private func buildPreedit(_ state: PreeditState, atlas: TermiodGlyphAtlas) {
        preeditRectangles = []
        preeditGlyphs = []
        preeditCells = nil
        guard !state.text.isEmpty, state.cols > 0 else { return }
        var graphemes: [(codepoints: [UInt32], cells: Int)] = state.text.map { character in
            let codepoints = character.unicodeScalars.map(\.value)
            let width = codepoints.first.map { Int(ghostty_unicode_codepoint_width($0)) } ?? 1
            return (codepoints, min(2, max(1, width)))
        }
        let cols = Int(state.cols)
        var total = graphemes.reduce(0) { $0 + $1.cells }
        while total > cols, !graphemes.isEmpty {
            total -= graphemes.removeFirst().cells
        }
        guard !graphemes.isEmpty else { return }
        var x = min(Int(state.x), cols - total)
        let first = x
        let metrics = atlas.metrics
        for grapheme in graphemes {
            if let slot = atlas.slot(graphemes: grapheme.codepoints, bold: false, italic: false, cells: grapheme.cells) {
                preeditGlyphs.append(TermiodStreamGlyph(
                    cellX: UInt16(x), cellY: state.y,
                    atlasX: slot.origin.x, atlasY: slot.origin.y,
                    atlasWidth: slot.size.x, atlasHeight: slot.size.y,
                    offsetX: slot.offset.x, offsetY: slot.offset.y,
                    r: state.red, g: state.green, b: state.blue, a: 255,
                    colored: slot.colored ? 1 : 0
                ))
            }
            preeditRectangles.append(TermiodStreamRectangle(
                cellX: UInt16(x), cellY: state.y, x: 0, y: Int16(clamping: metrics.underlinePosition),
                width: UInt16(clamping: metrics.width * grapheme.cells),
                height: UInt16(clamping: metrics.underlineThickness),
                r: state.red, g: state.green, b: state.blue, a: 255, overText: true
            ))
            x += grapheme.cells
        }
        preeditCells = (state.y, UInt16(first), UInt16(x - 1))
    }

    private func rebuildRow(_ y: Int, colors: GhosttyRenderStateColors, atlas: TermiodGlyphAtlas) {
        var rectangles: [TermiodStreamRectangle] = []
        var glyphs: [TermiodStreamGlyph] = []
        var ligatureCells: [LigatureCell] = []
        var wideStarts: Set<UInt16> = []
        var edgeBackgrounds: [TermiodStreamRectangle] = []
        var extendsEdges = true
        let metrics = atlas.metrics
        cellWidth = metrics.width
        _ = ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
        // Ghostty draws every selected cell alike: the theme's selection
        // colors, or the default foreground behind the default background.
        var selected = GhosttyRenderStateRowSelection()
        selected.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        let selection: ClosedRange<UInt16>? =
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selected) == GHOSTTY_SUCCESS
            ? selected.start_x ... max(selected.start_x, selected.end_x) : nil
        var x: UInt16 = 0
        while ghostty_render_state_row_cells_next(cells) {
            defer { x &+= 1 }
            var raw: GhosttyCell = 0
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
            var wide = GHOSTTY_CELL_WIDE_NARROW
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
            // A tail is covered by the wide character before it. A head — the
            // last column, left empty when a wide character wrapped — has no
            // glyph but keeps the background it was written with.
            if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
            let spacer = wide == GHOSTTY_CELL_WIDE_SPACER_HEAD
            let span: UInt16 = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : 1
            if span == 2 { wideStarts.insert(x) }

            var style = GhosttyStyle()
            style.size = MemoryLayout<GhosttyStyle>.size
            var hasStyling = false
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_HAS_STYLING, &hasStyling)
            if hasStyling {
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
            }
            var foreground = colors.foreground
            var background = colors.background
            var paintsBackground = false
            var resolved = GhosttyColorRgb()
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &resolved) == GHOSTTY_SUCCESS {
                foreground = resolved
            }
            if ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &resolved) == GHOSTTY_SUCCESS {
                background = resolved
                paintsBackground = true
            }
            if style.inverse {
                swap(&foreground, &background)
                paintsBackground = true
            }
            // The cell's own background, before the selection paints over it:
            // what the padding takes, and what decides whether it may.
            let ownsBackground = paintsBackground
            if paintsBackground {
                edgeBackgrounds.append(TermiodStreamRectangle(
                    cellX: x, cellY: UInt16(y), x: 0, y: 0,
                    width: UInt16(metrics.width) * span, height: UInt16(metrics.height),
                    r: background.r, g: background.g, b: background.b, a: 255
                ))
            }
            if let selection, selection.contains(x) {
                background = selectionColors.background ?? colors.foreground
                foreground = selectionColors.foreground ?? colors.background
                paintsBackground = true
            }
            if paintsBackground {
                rectangles.append(TermiodStreamRectangle(
                    cellX: x, cellY: UInt16(y), x: 0, y: 0,
                    width: UInt16(metrics.width) * span, height: UInt16(metrics.height),
                    r: background.r, g: background.g, b: background.b, a: 255
                ))
            }
            if spacer { continue }
            let alpha: UInt8 = style.faint ? 128 : 255
            if !style.invisible {
                appendDecorations(style, x: x, y: y, span: span, foreground: foreground, alpha: alpha,
                                  palette: colors, metrics: metrics, into: &rectangles)
            }

            var length: UInt32 = 0
            _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length)
            guard length > 0, !style.invisible else { continue }
            if Int(length) > codepoints.count {
                codepoints = [UInt32](repeating: 0, count: Int(length))
            }
            codepoints.withUnsafeMutableBufferPointer { buffer in
                _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, buffer.baseAddress)
            }
            let grapheme = Array(codepoints.prefix(Int(length)))
            if grapheme == [0x20] { continue }
            // Ghostty's `neverExtendBg`: a Powerline segment drawn to the cell
            // edge would smear its color across the padding.
            if ownsBackground, grapheme.contains(where: { (0xE0B0 ... 0xE0D7).contains($0) }) {
                extendsEdges = false
            }
            guard let slot = atlas.slot(graphemes: grapheme, bold: style.bold, italic: style.italic, cells: Int(span)) else {
                continue
            }
            // Before contrast, which follows each cell's own background: Ghostty
            // never breaks a run on the background.
            let styled = foreground
            if minimumContrast > 1, !slot.colored, !TermiodGlyphAtlas.isGraphic(grapheme) {
                foreground = Self.contrasted(foreground, against: background, minimum: minimumContrast)
            }
            if grapheme.count == 1, let unit = Self.ligaturePunctuation(grapheme[0]) {
                let look = LigatureCell.Look(
                    red: styled.r, green: styled.g, blue: styled.b, alpha: alpha, inverse: style.inverse,
                    selected: selection?.contains(x) == true,
                    cursor: shapingCursor.map { $0.y == y && $0.x == x } ?? false)
                ligatureCells.append(LigatureCell(
                    glyph: glyphs.count, x: x, unit: unit, bold: style.bold, italic: style.italic, look: look))
            }
            glyphs.append(TermiodStreamGlyph(
                cellX: x, cellY: UInt16(y),
                atlasX: slot.origin.x, atlasY: slot.origin.y,
                atlasWidth: slot.size.x, atlasHeight: slot.size.y,
                offsetX: slot.offset.x, offsetY: slot.offset.y,
                r: foreground.r, g: foreground.g, b: foreground.b, a: alpha,
                colored: slot.colored ? 1 : 0
            ))
        }
        applyLigatures(ligatureCells, to: &glyphs, atlas: atlas)
        rowRectangles[y] = rectangles
        rowEdgeBackgrounds[y] = extendsEdges ? edgeBackgrounds : nil
        rowGlyphs[y] = glyphs
        rowWideStarts[y] = wideStarts
    }

    /// A cell a ligature can join: one character of ASCII punctuation, the
    /// whole of what programming ligatures are made of (`=>`, `!=`, `-->`).
    private struct LigatureCell {
        var glyph: Int
        var x: UInt16
        var unit: UInt16
        var bold: Bool
        var italic: Bool
        /// What decides how the cell's glyph is drawn. A run breaks where any
        /// of it changes, as Ghostty's does on any style but the background,
        /// at a selection's edges and around the cursor: one glyph spans the
        /// run's cells, and it can only be drawn one way.
        var look: Look

        struct Look: Equatable {
            var red: UInt8
            var green: UInt8
            var blue: UInt8
            var alpha: UInt8
            var inverse: Bool
            var selected: Bool
            var cursor: Bool
        }

        func joins(_ next: LigatureCell) -> Bool {
            next.x == x + 1 && next.bold == bold && next.italic == italic && next.look == look && !look.cursor
        }
    }

    private static func ligaturePunctuation(_ codepoint: UInt32) -> UInt16? {
        let punctuation = (0x21...0x2F).contains(codepoint) || (0x3A...0x40).contains(codepoint)
            || (0x5B...0x60).contains(codepoint) || (0x7B...0x7E).contains(codepoint)
        return punctuation ? UInt16(codepoint) : nil
    }

    /// Shapes each run of adjacent punctuation in one style and swaps in the
    /// glyphs its neighbours select, as Ghostty's run shaper draws them.
    private func applyLigatures(
        _ cells: [LigatureCell], to glyphs: inout [TermiodStreamGlyph], atlas: TermiodGlyphAtlas
    ) {
        var covered: [Int] = []
        var start = 0
        while start < cells.count {
            var end = start + 1
            while end < cells.count, cells[end - 1].joins(cells[end]) { end += 1 }
            let run = cells[start ..< end]
            start = end
            guard run.count >= 2, let first = run.first,
                  let shaped = atlas.ligatures(run.map(\.unit), bold: first.bold, italic: first.italic)
            else { continue }
            // All of the run's glyphs, or none of them: a cell a ligature
            // covers must not vanish while its ligature is not drawn.
            var slots: [(Int, TermiodGlyphAtlas.Slot)] = []
            var complete = true
            for (cell, result) in zip(run, shaped) {
                guard case let .glyph(glyph, shift) = result else { continue }
                guard let slot = atlas.slot(glyph: glyph, shift: shift, bold: cell.bold, italic: cell.italic) else {
                    complete = false
                    break
                }
                slots.append((cell.glyph, slot))
            }
            guard complete else { continue }
            for (index, slot) in slots {
                glyphs[index].atlasX = slot.origin.x
                glyphs[index].atlasY = slot.origin.y
                glyphs[index].atlasWidth = slot.size.x
                glyphs[index].atlasHeight = slot.size.y
                glyphs[index].offsetX = slot.offset.x
                glyphs[index].offsetY = slot.offset.y
            }
            for (cell, result) in zip(run, shaped) where result == .covered { covered.append(cell.glyph) }
        }
        for index in covered.sorted(by: >) { glyphs.remove(at: index) }
    }

    private func appendDecorations(
        _ style: GhosttyStyle, x: UInt16, y: Int, span: UInt16,
        foreground: GhosttyColorRgb, alpha: UInt8, palette colors: GhosttyRenderStateColors,
        metrics: TermiodCellMetrics, into rectangles: inout [TermiodStreamRectangle]
    ) {
        let width = metrics.width * Int(span)
        let thickness = metrics.underlineThickness
        func line(_ top: Int, _ start: Int = 0, _ length: Int? = nil, color: GhosttyColorRgb = foreground) {
            rectangles.append(TermiodStreamRectangle(
                cellX: x, cellY: UInt16(y), x: Int16(clamping: start), y: Int16(clamping: top),
                width: UInt16(clamping: length ?? width), height: UInt16(clamping: thickness),
                r: color.r, g: color.g, b: color.b, a: alpha, overText: true
            ))
        }
        var underlineColor = foreground
        if style.underline_color.tag == GHOSTTY_STYLE_COLOR_RGB {
            underlineColor = style.underline_color.value.rgb
        } else if style.underline_color.tag == GHOSTTY_STYLE_COLOR_PALETTE {
            // The palette in effect now, OSC 4 changes included.
            let index = Int(style.underline_color.value.palette)
            underlineColor = withUnsafeBytes(of: colors.palette) { buffer in
                buffer.bindMemory(to: GhosttyColorRgb.self)[index]
            }
        }
        let position = metrics.underlinePosition
        switch Int32(style.underline) {
        case GHOSTTY_SGR_UNDERLINE_SINGLE.rawValue:
            line(position, color: underlineColor)
        case GHOSTTY_SGR_UNDERLINE_DOUBLE.rawValue:
            line(position, color: underlineColor)
            line(position - 2 * thickness, color: underlineColor)
        case GHOSTTY_SGR_UNDERLINE_CURLY.rawValue:
            // A square wave of half-cell steps, close enough at text size to
            // read as the squiggle an editor's diagnostics use.
            let step = max(1, metrics.width / 2)
            var start = 0
            var up = false
            while start < width {
                line(position - (up ? 2 * thickness : 0), start, min(step, width - start), color: underlineColor)
                start += step
                up.toggle()
            }
        case GHOSTTY_SGR_UNDERLINE_DOTTED.rawValue:
            var start = 0
            while start < width {
                line(position, start, thickness, color: underlineColor)
                start += 2 * thickness
            }
        case GHOSTTY_SGR_UNDERLINE_DASHED.rawValue:
            let dash = max(2, metrics.width / 3)
            var start = 0
            while start < width {
                line(position, start, min(dash, width - start), color: underlineColor)
                start += 2 * dash
            }
        default:
            break
        }
        if style.strikethrough { line(metrics.strikethroughPosition) }
        if style.overline { line(0) }
    }

    private func buildCursor(_ state: CursorState, colors: GhosttyRenderStateColors, atlas: TermiodGlyphAtlas) {
        cursor = []
        cursorCell = nil
        guard let shape = state.shape else { return }
        let metrics = atlas.metrics
        let thickness = max(2, metrics.underlineThickness)
        func rectangle(_ left: Int, _ top: Int, _ width: Int, _ height: Int, overText: Bool) -> TermiodStreamRectangle {
            TermiodStreamRectangle(
                cellX: state.x, cellY: state.y, x: Int16(clamping: left), y: Int16(clamping: top),
                width: UInt16(clamping: width), height: UInt16(clamping: height),
                r: state.red, g: state.green, b: state.blue, a: 255, overText: overText
            )
        }
        let wide = Int(state.y) < rowWideStarts.count && rowWideStarts[Int(state.y)].contains(state.x)
        let width = metrics.width * (wide ? 2 : 1)
        let height = metrics.height
        switch shape {
        case .block:
            cursor = [rectangle(0, 0, width, height, overText: false)]
            cursorCell = (state.x, state.y)
        case .bar:
            cursor = [rectangle(0, 0, thickness, height, overText: true)]
        case .underline:
            cursor = [rectangle(0, height - thickness, width, thickness, overText: true)]
        case .hollow:
            cursor = [
                rectangle(0, 0, width, thickness, overText: true),
                rectangle(0, height - thickness, width, thickness, overText: true),
                rectangle(0, 0, thickness, height, overText: true),
                rectangle(width - thickness, 0, thickness, height, overText: true),
            ]
        }
        cursorBackground = colors.background
    }

    private var cursorBackground = GhosttyColorRgb(r: 0, g: 0, b: 0)

    /// Ghostty's `minimum-contrast`: a glyph below the ratio against its own
    /// background is drawn in black or white, whichever reads better.
    public static func contrasted(_ color: GhosttyColorRgb, against background: GhosttyColorRgb, minimum: Double) -> GhosttyColorRgb {
        func luminance(_ color: GhosttyColorRgb) -> Double {
            func channel(_ value: UInt8) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
        }
        func ratio(_ a: GhosttyColorRgb, _ b: GhosttyColorRgb) -> Double {
            let (x, y) = (luminance(a), luminance(b))
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
        guard ratio(color, background) < minimum else { return color }
        let white = GhosttyColorRgb(r: 255, g: 255, b: 255)
        let black = GhosttyColorRgb(r: 0, g: 0, b: 0)
        return ratio(white, background) > ratio(black, background) ? white : black
    }

    /// The padding around the grid, in pixels, that the edge cells' backgrounds
    /// reach into. A side is zero where the grid does not fill the pane.
    public struct PaddingExtension: Equatable {
        public var left = 0
        public var top = 0
        public var right = 0
        public var bottom = 0

        public init(left: Int = 0, top: Int = 0, right: Int = 0, bottom: Int = 0) {
            self.left = left
            self.top = top
            self.right = right
            self.bottom = bottom
        }
    }

    public func flatten(
        rectangles: inout [TermiodStreamRectangle], glyphs: inout [TermiodStreamGlyph],
        padding: PaddingExtension = PaddingExtension()
    ) {
        rectangles.removeAll(keepingCapacity: true)
        glyphs.removeAll(keepingCapacity: true)
        appendPaddingExtension(padding, into: &rectangles)
        // The cells under composed text show only the composition.
        func covered(_ x: UInt16, row: Int) -> Bool {
            guard let cells = preeditCells, Int(cells.y) == row else { return false }
            let wide = row < rowWideStarts.count && rowWideStarts[row].contains(x)
            return x <= cells.last && x + (wide ? 1 : 0) >= cells.first
        }
        for (index, row) in rowRectangles.enumerated() {
            if preeditCells.map({ Int($0.y) == index }) == true {
                rectangles.append(contentsOf: row.filter { !covered($0.cellX, row: index) })
            } else {
                rectangles.append(contentsOf: row)
            }
        }
        rectangles.append(contentsOf: cursor)
        rectangles.append(contentsOf: preeditRectangles)
        rectangles.append(contentsOf: linkUnderline)
        for (index, row) in rowGlyphs.enumerated() {
            for glyph in row where !covered(glyph.cellX, row: index) {
                var glyph = glyph
                // Text under a block cursor is drawn in the background color,
                // so the character stays readable through it.
                if let cell = cursorCell, Int(cell.y) == index, glyph.cellX == cell.x, glyph.colored == 0 {
                    let text = cursorText ?? cursorBackground
                    glyph.r = text.r
                    glyph.g = text.g
                    glyph.b = text.b
                }
                glyphs.append(glyph)
            }
        }
        glyphs.append(contentsOf: preeditGlyphs)
    }

    /// Ghostty's `window-padding-color = extend`, as Rex draws it: an edge
    /// cell's background continues to the pane's edge, so a program's colored
    /// bar reads as full width while its text keeps the padding.
    private func appendPaddingExtension(_ padding: PaddingExtension, into rectangles: inout [TermiodStreamRectangle]) {
        guard padding != PaddingExtension(), columns > 0, !rowEdgeBackgrounds.isEmpty else { return }
        let last = rowEdgeBackgrounds.count - 1
        for (row, backgrounds) in rowEdgeBackgrounds.enumerated() {
            guard let backgrounds, !backgrounds.isEmpty else { continue }
            // Each span reaches up from the first row and down from the last;
            // the outer two reach sideways, and into the corners there.
            var spans: [(cell: TermiodStreamRectangle, x: Int, width: Int)] = []
            if row == 0 || row == last {
                spans = backgrounds.map { ($0, 0, Int($0.width)) }
            }
            if padding.left > 0, let first = backgrounds.first, first.cellX == 0 {
                rectangles.append(Self.offset(first, x: -padding.left, y: 0, width: padding.left, height: Int(first.height)))
                spans.append((first, -padding.left, padding.left))
            }
            if padding.right > 0, let end = backgrounds.last,
               Int(end.cellX) + Int(end.width) / max(1, cellWidth) >= Int(columns) {
                rectangles.append(Self.offset(end, x: Int(end.width), y: 0, width: padding.right, height: Int(end.height)))
                spans.append((end, Int(end.width), padding.right))
            }
            for span in spans {
                if row == 0, padding.top > 0 {
                    rectangles.append(Self.offset(span.cell, x: span.x, y: -padding.top, width: span.width, height: padding.top))
                }
                if row == last, padding.bottom > 0 {
                    rectangles.append(Self.offset(
                        span.cell, x: span.x, y: Int(span.cell.height), width: span.width, height: padding.bottom))
                }
            }
        }
    }

    private static func offset(_ cell: TermiodStreamRectangle, x: Int, y: Int, width: Int, height: Int) -> TermiodStreamRectangle {
        TermiodStreamRectangle(
            cellX: cell.cellX, cellY: cell.cellY, x: Int16(clamping: x), y: Int16(clamping: y),
            width: UInt16(clamping: width), height: UInt16(clamping: height),
            r: cell.r, g: cell.g, b: cell.b, a: cell.a
        )
    }
}
