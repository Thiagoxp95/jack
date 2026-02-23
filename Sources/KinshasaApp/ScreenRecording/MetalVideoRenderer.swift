import AVFoundation
import CoreVideo
import Foundation
import Metal
import MetalKit
import simd

// MARK: - CompositorUniforms

/// Swift representation of the Metal CompositorUniforms struct.
/// Must match the Metal layout exactly (96 bytes total).
struct CompositorUniforms {
    var outputSize: SIMD2<Float>          // offset  0
    var sourceSize: SIMD2<Float>          // offset  8
    var zoomCenter: SIMD2<Float>          // offset 16
    var zoomLevel: Float                  // offset 24
    var _pad0: Float = 0                  // offset 28
    var cursorPosition: SIMD2<Float>      // offset 32
    var cursorScale: Float                // offset 40
    var cursorVisible: Float              // offset 44
    var clickHighlightPhase: Float        // offset 48
    var cursorClickScale: Float = 1.0     // offset 52: cursor press animation (1.0 = normal)
    var _pad2: Float = 0                  // offset 56
    var _pad3: Float = 0                  // offset 60
    var clickHighlightColor: SIMD4<Float> // offset 64
    var clickHighlightRadius: Float       // offset 80
    var contentOffsetX: Float = 0         // offset 84
    var contentOffsetY: Float = 0         // offset 88
    var _pad6: Float = 0                  // offset 92  (total: 96)
}

// MARK: - MetalVideoRenderer

/// Composites zoom, cursor, and click highlight effects onto screen capture frames
/// using a Metal compute shader.
final class MetalVideoRenderer {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var cachedOutputTexture: MTLTexture?
    private var cachedOutputWidth: Int = 0
    private var cachedOutputHeight: Int = 0

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return nil
        }
        self.device = device

        guard let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue

        // Load the Metal shader source from bundle resources and compile at runtime.
        // SPM does not natively compile .metal files; they are bundled as resources.
        guard let shaderURL = Bundle.module.url(
            forResource: "ZoomCursorCompositor",
            withExtension: "metal"
        ) else {
            return nil
        }

        let library: MTLLibrary
        do {
            let source = try String(contentsOf: shaderURL, encoding: .utf8)
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            return nil
        }

        guard let function = library.makeFunction(name: "zoomCursorComposite") else {
            return nil
        }

        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            return nil
        }

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let validCache = cache else {
            return nil
        }
        self.textureCache = validCache
    }

    // MARK: - Render Frame

    /// Composites a source frame with zoom, cursor overlay, and click highlight.
    ///
    /// - Parameters:
    ///   - sourcePixelBuffer: The captured screen frame.
    ///   - outputSize: Desired output texture dimensions.
    ///   - zoomCenter: Normalized zoom center (0-1).
    ///   - zoomLevel: Zoom magnification (1.0 = none).
    ///   - cursorPosition: Cursor position in output coordinates, or nil if hidden.
    ///   - cursorScale: Cursor scale factor (1.0-3.0).
    ///   - clickPhase: Click animation phase (0-1, 0 = no click).
    ///   - clickColor: RGBA color for click highlight.
    ///   - clickRadius: Maximum click highlight radius in pixels.
    /// - Returns: The composited output texture, or nil on failure.
    func renderFrame(
        sourcePixelBuffer: CVPixelBuffer,
        outputSize: CGSize,
        zoomCenter: CGPoint,
        zoomLevel: Double,
        cursorPosition: CGPoint?,
        cursorScale: Double,
        clickPhase: Double,
        clickColor: SIMD4<Float>,
        clickRadius: Double
    ) -> MTLTexture? {
        guard let sourceTexture = makeTexture(from: sourcePixelBuffer) else {
            return nil
        }

        let outWidth = Int(outputSize.width)
        let outHeight = Int(outputSize.height)

        // Reuse the output texture when dimensions match to avoid per-frame GPU allocation
        let outputTexture: MTLTexture
        if let cached = cachedOutputTexture,
           cachedOutputWidth == outWidth, cachedOutputHeight == outHeight {
            outputTexture = cached
        } else {
            let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: outWidth,
                height: outHeight,
                mipmapped: false
            )
            outputDescriptor.usage = [.shaderWrite, .shaderRead]
            outputDescriptor.storageMode = .private

            guard let newTexture = device.makeTexture(descriptor: outputDescriptor) else {
                return nil
            }
            cachedOutputTexture = newTexture
            cachedOutputWidth = outWidth
            cachedOutputHeight = outHeight
            outputTexture = newTexture
        }

        let cursorPos = cursorPosition ?? CGPoint(x: -100, y: -100)

        var uniforms = CompositorUniforms(
            outputSize: SIMD2<Float>(Float(outWidth), Float(outHeight)),
            sourceSize: SIMD2<Float>(
                Float(sourceTexture.width),
                Float(sourceTexture.height)
            ),
            zoomCenter: SIMD2<Float>(Float(zoomCenter.x), Float(zoomCenter.y)),
            zoomLevel: Float(zoomLevel),
            cursorPosition: SIMD2<Float>(Float(cursorPos.x), Float(cursorPos.y)),
            cursorScale: Float(cursorScale),
            cursorVisible: cursorPosition != nil ? 1.0 : 0.0,
            clickHighlightPhase: Float(clickPhase),
            clickHighlightColor: clickColor,
            clickHighlightRadius: Float(clickRadius)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        // Cursor texture (index 1) is optional; encoder tolerates nil.
        encoder.setTexture(nil, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<CompositorUniforms>.size, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (outWidth + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (outHeight + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Flush the texture cache to release CVMetalTexture references from makeTexture().
        // Without this, the cache accumulates ~20MB of GPU memory per frame and crashes.
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        return outputTexture
    }

    // MARK: - Render Into Texture (Zero-Copy Export Path)

    /// Composites a source frame into a **caller-provided** output texture.
    ///
    /// Used by the export pipeline where the output texture is backed by an
    /// IOSurface CVPixelBuffer obtained from the writer's pixel buffer pool.
    /// The GPU writes directly into the pixel buffer memory — zero CPU copies.
    ///
    /// - Parameters:
    ///   - sourcePixelBuffer: The captured screen frame.
    ///   - outputTexture: Caller-provided texture to render into (must be `.shaderWrite`).
    ///   - zoomCenter: Normalized zoom center (0-1).
    ///   - zoomLevel: Zoom magnification (1.0 = none).
    ///   - cursorPosition: Cursor position in output coordinates, or nil if hidden.
    ///   - cursorScale: Cursor scale factor (1.0-3.0).
    ///   - clickPhase: Click animation phase (0-1, 0 = no click).
    ///   - clickColor: RGBA color for click highlight.
    ///   - clickRadius: Maximum click highlight radius in pixels.
    /// - Returns: `true` if the render succeeded.
    /// - Parameter renderCursorOverlay: When `false`, the cursor texture is not drawn
    ///   (but click highlight still uses `cursorPosition`). Use when compositing the
    ///   cursor via Core Graphics for pixel-perfect vector quality.
    func renderIntoTexture(
        sourcePixelBuffer: CVPixelBuffer,
        outputTexture: MTLTexture,
        zoomCenter: CGPoint,
        zoomLevel: Double,
        cursorPosition: CGPoint?,
        cursorScale: Double,
        cursorClickScale: Double = 1.0,
        renderCursorOverlay: Bool = true,
        clickPhase: Double,
        clickColor: SIMD4<Float>,
        clickRadius: Double,
        cursorTexture: MTLTexture? = nil,
        contentOffset: CGPoint = .zero
    ) -> Bool {
        guard let sourceTexture = makeTexture(from: sourcePixelBuffer) else {
            return false
        }

        let outWidth = outputTexture.width
        let outHeight = outputTexture.height
        let cursorPos = cursorPosition ?? CGPoint(x: -100, y: -100)

        var uniforms = CompositorUniforms(
            outputSize: SIMD2<Float>(Float(outWidth), Float(outHeight)),
            sourceSize: SIMD2<Float>(
                Float(sourceTexture.width),
                Float(sourceTexture.height)
            ),
            zoomCenter: SIMD2<Float>(Float(zoomCenter.x), Float(zoomCenter.y)),
            zoomLevel: Float(zoomLevel),
            cursorPosition: SIMD2<Float>(Float(cursorPos.x), Float(cursorPos.y)),
            cursorScale: Float(cursorScale),
            cursorVisible: (cursorPosition != nil && renderCursorOverlay) ? 1.0 : 0.0,
            clickHighlightPhase: Float(clickPhase),
            cursorClickScale: Float(cursorClickScale),
            clickHighlightColor: clickColor,
            clickHighlightRadius: Float(clickRadius),
            contentOffsetX: Float(contentOffset.x),
            contentOffsetY: Float(contentOffset.y)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return false
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(cursorTexture, index: 1)
        encoder.setTexture(outputTexture, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<CompositorUniforms>.size, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupCount = MTLSize(
            width: (outWidth + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (outHeight + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )
        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }

        return true
    }

    // MARK: - Cursor Texture Factory

    /// Pre-renders the macOS-style arrow cursor into a Metal texture.
    ///
    /// The texture is square with the arrow drawn at the top-left, matching
    /// how the compute shader samples cursor UV coordinates in a non-square
    /// region of `14 * scale` by `20 * scale` pixels starting at `cursorPosition`.
    ///
    /// - Parameters:
    ///   - style: Cursor color style (fill + stroke colors).
    ///   - size: Texture dimensions in pixels (default 256 for crisp edges with mipmaps).
    /// - Returns: A mipmapped BGRA8 texture with premultiplied alpha, or nil on failure.
    func createCursorTexture(style: CursorStyle, size: Int = 1024) -> MTLTexture? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGBitmapInfo.byteOrder32Little.rawValue |
            CGImageAlphaInfo.premultipliedFirst.rawValue
        )
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setShouldAntialias(true)
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // Flip to top-left origin so the arrow tip is at (0,0) in the Metal texture.
        // CGContext defaults to bottom-left origin; Metal textures use top-left.
        ctx.translateBy(x: 0, y: CGFloat(size))
        ctx.scaleBy(x: 1.0, y: -1.0)

        // Build the arrow CGPath (same geometry as CursorShape in CursorOverlayView)
        let w = CGFloat(size)
        let h = CGFloat(size)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 0, y: h * 0.85))
        path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.65))
        path.addLine(to: CGPoint(x: w * 0.5, y: h))
        path.addLine(to: CGPoint(x: w * 0.7, y: h * 0.92))
        path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.9, y: h * 0.55))
        path.closeSubpath()

        let fillColor = Self.cgColor(fromHex: style.fillHex)
        let strokeColor = Self.cgColor(fromHex: style.strokeHex)

        // Fill
        ctx.addPath(path)
        ctx.setFillColor(fillColor)
        ctx.fillPath()

        // Stroke (scale line width proportionally to texture size).
        // Use round joins and caps to match SwiftUI's default stroke rendering,
        // producing uniform borders instead of sharp miter spikes at arrow vertices.
        let strokeWidth = 1.5 * (CGFloat(size) / 14.0)
        ctx.addPath(path)
        ctx.setStrokeColor(strokeColor)
        ctx.setLineWidth(strokeWidth)
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        ctx.strokePath()

        guard let cgImage = ctx.makeImage() else { return nil }

        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
            .generateMipmaps: true,
        ]
        return try? loader.newTexture(cgImage: cgImage, options: options)
    }

    static func cgColor(fromHex hex: String) -> CGColor {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return CGColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - Texture Creation

    /// Creates an MTLTexture from a CVPixelBuffer using CVMetalTextureCache.
    func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &cvTexture
        )

        guard status == kCVReturnSuccess, let unwrapped = cvTexture else {
            return nil
        }

        return CVMetalTextureGetTexture(unwrapped)
    }

    // MARK: - Static Helpers

    /// Default cinematic ramp duration in seconds.
    static let cinematicRampDuration: Double = 0.6

    /// Interpolates zoom level at a given time using cinematic asymmetric easing.
    /// Zoom-in uses ease-out cubic (fast start, gentle landing).
    /// Zoom-out uses ease-in cubic (gentle start, accelerating exit).
    ///
    /// - Parameters:
    ///   - time: Current time in seconds.
    ///   - keyframes: Array of zoom keyframes.
    ///   - rampDuration: Duration of the ease-in/ease-out ramp in seconds.
    /// - Returns: Interpolated zoom level at the given time.
    static func interpolateZoom(
        at time: Double,
        keyframes: [ZoomKeyframe],
        rampDuration: Double
    ) -> Double {
        guard let keyframe = keyframes.first(where: {
            time >= $0.startTime && time <= $0.endTime
        }) else {
            return 1.0
        }

        let duration = keyframe.endTime - keyframe.startTime
        guard duration > 0 else { return keyframe.zoomLevel }

        let ramp = min(rampDuration, duration / 2.0)
        let elapsed = time - keyframe.startTime
        let remaining = keyframe.endTime - time

        if elapsed < ramp {
            let t = elapsed / ramp
            let eased = cinematicEaseOut(t)
            return 1.0 + (keyframe.zoomLevel - 1.0) * eased
        } else if remaining < ramp {
            let t = remaining / ramp
            let eased = cinematicEaseIn(t)
            return 1.0 + (keyframe.zoomLevel - 1.0) * eased
        } else {
            return keyframe.zoomLevel
        }
    }

    /// Ease-out cubic: 1 - (1 - t)^3
    /// Fast start, gentle deceleration. Used for zoom-in transitions.
    private static func cinematicEaseOut(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        let inv = 1.0 - clamped
        return 1.0 - inv * inv * inv
    }

    /// Ease-in cubic: t^3
    /// Gentle start, accelerating. Used for zoom-out transitions.
    private static func cinematicEaseIn(_ t: Double) -> Double {
        let clamped = max(0.0, min(1.0, t))
        return clamped * clamped * clamped
    }

    /// Applies exponential smoothing to cursor position for fluid movement.
    ///
    /// - Parameters:
    ///   - previous: Previous smoothed position.
    ///   - current: Current raw position.
    ///   - factor: Smoothing factor (default 0.15). Lower = smoother.
    /// - Returns: Smoothed cursor position.
    static func smoothCursorPosition(
        previous: CGPoint,
        current: CGPoint,
        factor: Double = 0.15
    ) -> CGPoint {
        let x = previous.x + (current.x - previous.x) * factor
        let y = previous.y + (current.y - previous.y) * factor
        return CGPoint(x: x, y: y)
    }

}
