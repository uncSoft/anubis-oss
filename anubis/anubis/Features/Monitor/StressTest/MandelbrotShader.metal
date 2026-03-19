//
//  MandelbrotShader.metal
//  anubis
//

#include <metal_stdlib>
using namespace metal;

struct MandelbrotParams {
    float centerX;
    float centerY;
    float zoom;
    uint maxIterations;
    uint width;
    uint height;
    float hueOffset;    // 0.0–1.0, shifts the color palette
    float hueCycles;    // how many times the palette cycles (e.g. 3–8)
};

kernel void mandelbrot(
    texture2d<float, access::write> output [[texture(0)]],
    constant MandelbrotParams &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    float aspect = float(params.width) / float(params.height);
    float scale = 1.0 / params.zoom;

    // Map pixel to complex plane
    float cx = params.centerX + (float(gid.x) / float(params.width) - 0.5) * 4.0 * scale * aspect;
    float cy = params.centerY + (float(gid.y) / float(params.height) - 0.5) * 4.0 * scale;

    float zx = 0.0;
    float zy = 0.0;
    uint iter = 0;

    // Escape-time iteration
    while (zx * zx + zy * zy < 4.0 && iter < params.maxIterations) {
        float tmp = zx * zx - zy * zy + cx;
        zy = 2.0 * zx * zy + cy;
        zx = tmp;
        iter++;
    }

    float4 color;
    if (iter == params.maxIterations) {
        color = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        // Smooth coloring using escape radius
        float smoothIter = float(iter) + 1.0 - log2(log2(zx * zx + zy * zy));
        float t = smoothIter / float(params.maxIterations);

        // HSV-like palette with randomized hue offset and cycle count
        float h = fract(t * params.hueCycles + params.hueOffset);
        float s = 0.85;
        float v = 1.0 - pow(t, 0.4);

        // HSV to RGB
        float c = v * s;
        float x = c * (1.0 - abs(fmod(h * 6.0, 2.0) - 1.0));
        float m = v - c;
        float3 rgb;
        if (h < 1.0/6.0)      rgb = float3(c, x, 0);
        else if (h < 2.0/6.0) rgb = float3(x, c, 0);
        else if (h < 3.0/6.0) rgb = float3(0, c, x);
        else if (h < 4.0/6.0) rgb = float3(0, x, c);
        else if (h < 5.0/6.0) rgb = float3(x, 0, c);
        else                   rgb = float3(c, 0, x);
        rgb += m;

        color = float4(rgb, 1.0);
    }

    output.write(color, gid);
}
