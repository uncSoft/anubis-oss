//
//  MetalStressView.swift
//  anubis
//

import SwiftUI
import MetalKit

/// NSViewRepresentable wrapping MTKView for the GPU stress Mandelbrot render.
struct MetalStressView: NSViewRepresentable {
    let gpuWorker: GPUStressWorker

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        gpuWorker.setupView(view)
        if gpuWorker.isRunning {
            view.isPaused = false
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // View updates are driven by the MTKViewDelegate
    }
}
