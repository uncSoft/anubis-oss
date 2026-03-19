//
//  GPUStressWorker.swift
//  anubis
//

import Foundation
import Metal
import MetalKit

enum GPUStressLevel: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case extreme = "Extreme"

    var id: String { rawValue }

    /// Max Mandelbrot iterations per pixel
    var maxIterations: UInt32 {
        switch self {
        case .low:     return 500
        case .medium:  return 2000
        case .high:    return 4000
        case .extreme: return 8000
        }
    }

    /// Resolution multiplier (supersampling)
    var supersampling: Int {
        switch self {
        case .low:     return 1
        case .medium:  return 2
        case .high:    return 3
        case .extreme: return 4
        }
    }

    /// Number of compute passes per frame
    var passesPerFrame: Int {
        switch self {
        case .low:     return 1
        case .medium:  return 2
        case .high:    return 4
        case .extreme: return 8
        }
    }

    /// Next level down, if any
    var downgraded: GPUStressLevel? {
        switch self {
        case .extreme: return .high
        case .high:    return .medium
        case .medium:  return .low
        case .low:     return nil
        }
    }

    var description: String {
        "\(rawValue): \(maxIterations) iter, \(supersampling)x SS, \(passesPerFrame) passes/frame"
    }
}

/// Drives a Mandelbrot compute shader on the GPU at max frame rate.
final class GPUStressWorker: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLComputePipelineState
    private(set) var mtkView: MTKView?
    private(set) var isRunning = false
    var stressLevel: GPUStressLevel = .medium

    // Offscreen texture for supersampled rendering
    private var offscreenTexture: MTLTexture?

    // Mandelbrot zoom parameters — randomized each start()
    private var zoomTarget: (x: Float, y: Float) = (-0.7435669, 0.1314023)
    private var zoomLevel: Float = 1.0
    private let zoomSpeed: Float = 1.002
    private let maxZoom: Float = 1e12

    // Color parameters — randomized each start()
    private var hueOffset: Float = 0.6
    private var hueCycles: Float = 5.0

    /// Interesting deep-zoom locations in the Mandelbrot set.
    /// Each has rich spiral/filament structure that stays visually interesting at high zoom.
    private static let zoomTargets: [(x: Float, y: Float)] = [
        (-0.7435669,  0.1314023),   // Seahorse valley spiral
        (-0.16,       1.0405),      // Top of main bulb — dendrite filaments
        (-1.25066,    0.02012),     // Elephant valley mini-brot
        (-0.745428,   0.113009),    // Seahorse valley — different spiral arm
        (-0.0452407,  0.9868162),   // Near period-3 bulb boundary
        ( 0.001643721971153,  0.822467633298876),  // Deep mini-brot in antenna
        (-1.768778833,  -0.001738996),  // Period-doubling cascade tip
        (-0.10109636384562,  0.95628651080914),    // Near basilica Julia set
        ( 0.37001085813,  -0.67143543269),         // Spiral near period-5 bulb
        (-0.749988802228,  0.006997251),           // Valley of double spirals
    ]

    // FPS tracking
    private var frameCount = 0
    private var lastFPSTime = CACurrentMediaTime()
    var currentFPS: Int = 0
    var onFPSUpdate: ((Int) -> Void)?

    /// Called when the worker auto-downgrades due to unresponsiveness
    var onAutoDowngrade: ((GPUStressLevel) -> Void)?

    // Responsiveness watchdog
    private var lowFPSStreak = 0
    private let lowFPSThreshold = 3  // 3 consecutive seconds below minimum

    struct Params {
        var centerX: Float
        var centerY: Float
        var zoom: Float
        var maxIterations: UInt32
        var width: UInt32
        var height: UInt32
        var hueOffset: Float
        var hueCycles: Float
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue, pipelineState: MTLComputePipelineState) {
        self.device = device
        self.commandQueue = commandQueue
        self.pipelineState = pipelineState
        super.init()
    }

    /// Returns nil if Metal is unavailable or the shader can't be compiled.
    static func create() -> GPUStressWorker? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "mandelbrot"),
              let pipeline = try? device.makeComputePipelineState(function: function) else {
            return nil
        }
        return GPUStressWorker(device: device, commandQueue: queue, pipelineState: pipeline)
    }

    func setupView(_ view: MTKView) {
        view.device = device
        view.delegate = self
        view.preferredFramesPerSecond = 120
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.isPaused = true
        mtkView = view
    }

    func start() {
        guard let view = mtkView else { return }
        isRunning = true
        zoomLevel = 1.0
        frameCount = 0
        lastFPSTime = CACurrentMediaTime()
        currentFPS = 0
        lowFPSStreak = 0
        offscreenTexture = nil

        // Randomize zoom target and color palette
        zoomTarget = Self.zoomTargets.randomElement() ?? Self.zoomTargets[0]
        hueOffset = Float.random(in: 0.0...1.0)
        hueCycles = Float.random(in: 3.0...8.0)

        view.isPaused = false
    }

    func stop() {
        isRunning = false
        // Detach from view to prevent draw calls during/after teardown
        if let view = mtkView {
            view.isPaused = true
            view.delegate = nil
        }
        mtkView = nil
        zoomLevel = 1.0
        currentFPS = 0
        offscreenTexture = nil
    }

    // MARK: - Offscreen Texture

    private func ensureOffscreenTexture(drawableWidth: Int, drawableHeight: Int) -> MTLTexture? {
        let ss = stressLevel.supersampling
        let w = drawableWidth * ss
        let h = drawableHeight * ss

        if let tex = offscreenTexture, tex.width == w, tex.height == h {
            return tex
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: w,
            height: h,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        offscreenTexture = device.makeTexture(descriptor: desc)
        return offscreenTexture
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        offscreenTexture = nil
    }

    func draw(in view: MTKView) {
        guard isRunning,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let drawableTexture = drawable.texture
        let drawableW = drawableTexture.width
        let drawableH = drawableTexture.height
        let ss = stressLevel.supersampling

        // Advance zoom — pick new random target + colors on each cycle
        if zoomLevel < maxZoom {
            zoomLevel *= zoomSpeed
        } else {
            zoomLevel = 1.0
            zoomTarget = Self.zoomTargets.randomElement() ?? Self.zoomTargets[0]
            hueOffset = Float.random(in: 0.0...1.0)
            hueCycles = Float.random(in: 3.0...8.0)
        }

        // Determine render target
        let renderTexture: MTLTexture
        if ss > 1, let offscreen = ensureOffscreenTexture(drawableWidth: drawableW, drawableHeight: drawableH) {
            renderTexture = offscreen
        } else {
            renderTexture = drawableTexture
        }

        let renderW = renderTexture.width
        let renderH = renderTexture.height

        var params = Params(
            centerX: zoomTarget.x,
            centerY: zoomTarget.y,
            zoom: zoomLevel,
            maxIterations: stressLevel.maxIterations,
            width: UInt32(renderW),
            height: UInt32(renderH),
            hueOffset: hueOffset,
            hueCycles: hueCycles
        )

        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (renderW + 15) / 16,
            height: (renderH + 15) / 16,
            depth: 1
        )

        // Multiple passes for extra GPU load
        for _ in 0..<stressLevel.passesPerFrame {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { continue }
            encoder.setComputePipelineState(pipelineState)
            encoder.setTexture(renderTexture, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<Params>.size, index: 0)
            encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }

        // Blit supersampled texture down to drawable
        if ss > 1, renderTexture !== drawableTexture {
            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                commandBuffer.commit()
                return
            }
            blitEncoder.copy(
                from: renderTexture, sourceSlice: 0, sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: min(renderW, drawableW), height: min(renderH, drawableH), depth: 1),
                to: drawableTexture, destinationSlice: 0, destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()

        // FPS tracking
        frameCount += 1
        let now = CACurrentMediaTime()
        let elapsed = now - lastFPSTime
        if elapsed >= 1.0 {
            currentFPS = Int(Double(frameCount) / elapsed)
            frameCount = 0
            lastFPSTime = now
            onFPSUpdate?(currentFPS)

            // Responsiveness watchdog: auto-downgrade if FPS stays below 5
            if currentFPS < 5 {
                lowFPSStreak += 1
                if lowFPSStreak >= lowFPSThreshold, let lower = stressLevel.downgraded {
                    stressLevel = lower
                    offscreenTexture = nil
                    lowFPSStreak = 0
                    onAutoDowngrade?(lower)
                }
            } else {
                lowFPSStreak = 0
            }
        }
    }
}
