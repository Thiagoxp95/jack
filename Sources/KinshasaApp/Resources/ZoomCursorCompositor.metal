#include <metal_stdlib>
using namespace metal;

// MARK: - Uniforms

struct CompositorUniforms {
    float2 outputSize;            // offset  0: output texture dimensions
    float2 sourceSize;            // offset  8: input texture dimensions
    float2 zoomCenter;            // offset 16: normalized zoom center (0-1)
    float  zoomLevel;             // offset 24: 1.0 = no zoom, 2.0 = 2x zoom
    float  _pad0;                 // offset 28: alignment padding
    float2 cursorPosition;        // offset 32: cursor position in output coords
    float  cursorScale;           // offset 40: 1.0 - 3.0
    float  cursorVisible;         // offset 44: 0 or 1
    float  clickHighlightPhase;   // offset 48: 0-1 for click animation (0 = no click)
    float  _pad1;                 // offset 52: padding
    float  _pad2;                 // offset 56: padding
    float  _pad3;                 // offset 60: padding to align float4 to 16-byte boundary
    float4 clickHighlightColor;   // offset 64: RGBA
    float  clickHighlightRadius;  // offset 80: max radius in pixels
    float  _pad4;                 // offset 84: struct tail padding
    float  _pad5;                 // offset 88: struct tail padding
    float  _pad6;                 // offset 92: struct tail padding (total: 96 bytes)
};

// MARK: - Catmull-Rom Helpers

/// Catmull-Rom spline weight for bicubic interpolation.
static float catmullRom(float x) {
    float ax = abs(x);
    if (ax < 1.0) {
        return 0.5 * (2.0 + ax * ax * (-5.0 + 3.0 * ax));
    } else if (ax < 2.0) {
        return 0.5 * (4.0 - 8.0 * ax + 5.0 * ax * ax - ax * ax * ax);
    }
    return 0.0;
}

/// Sample a texture using bicubic (Catmull-Rom) interpolation.
static float4 sampleBicubic(texture2d<float, access::sample> tex,
                            sampler s,
                            float2 uv,
                            float2 texSize) {
    float2 texelCoord = uv * texSize - 0.5;
    float2 f = fract(texelCoord);
    float2 origin = floor(texelCoord);

    float4 result = float4(0.0);
    float  weightSum = 0.0;

    for (int j = -1; j <= 2; j++) {
        for (int i = -1; i <= 2; i++) {
            float2 samplePos = origin + float2(float(i), float(j)) + 0.5;
            float2 sampleUV  = samplePos / texSize;

            float wx = catmullRom(float(i) - f.x);
            float wy = catmullRom(float(j) - f.y);
            float w  = wx * wy;

            result    += tex.sample(s, sampleUV) * w;
            weightSum += w;
        }
    }

    return result / max(weightSum, 1e-6);
}

// MARK: - Soft Clamp Helper

/// Soft-clamps a value within [low, high] with exponential deceleration in the margin zone.
/// margin: fraction of the viewport half-size used as the deceleration zone (0.05 = 5%).
static float softClamp(float value, float low, float high, float margin) {
    float range = high - low;
    float softLow = low + range * margin;
    float softHigh = high - range * margin;

    if (value < softLow) {
        // Exponential ease into the lower bound
        float t = (softLow - value) / (softLow - low);
        t = clamp(t, 0.0f, 1.0f);
        return softLow - (softLow - low) * (1.0 - exp(-3.0 * t)) / (1.0 - exp(-3.0));
    } else if (value > softHigh) {
        // Exponential ease into the upper bound
        float t = (value - softHigh) / (high - softHigh);
        t = clamp(t, 0.0f, 1.0f);
        return softHigh + (high - softHigh) * (1.0 - exp(-3.0 * t)) / (1.0 - exp(-3.0));
    }
    return value;
}

// MARK: - Compute Kernel

kernel void zoomCursorComposite(
    texture2d<float, access::sample> sourceTexture [[texture(0)]],
    texture2d<float, access::sample> cursorTexture [[texture(1)]],
    texture2d<float, access::write>  outputTexture [[texture(2)]],
    constant CompositorUniforms &uniforms          [[buffer(0)]],
    uint2 gid                                      [[thread_position_in_grid]]
) {
    // Bail if outside output dimensions.
    if (gid.x >= uint(uniforms.outputSize.x) || gid.y >= uint(uniforms.outputSize.y)) {
        return;
    }

    constexpr sampler textureSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear
    );

    float2 outUV = (float2(gid) + 0.5) / uniforms.outputSize;

    // ---- Phase 1: Zoom Transform ----
    float invZoom = 1.0 / max(uniforms.zoomLevel, 1e-4);
    float halfView = invZoom * 0.5;

    // Soft-clamp zoom center so viewport doesn't reveal outside the source frame.
    // The safe range for the center is [halfView, 1-halfView].
    float2 clampedCenter = float2(
        softClamp(uniforms.zoomCenter.x, halfView, 1.0 - halfView, 0.05),
        softClamp(uniforms.zoomCenter.y, halfView, 1.0 - halfView, 0.05)
    );

    float2 sourceUV = clampedCenter + (outUV - clampedCenter) * invZoom;
    sourceUV = clamp(sourceUV, float2(0.0), float2(1.0));

    float4 color;
    if (uniforms.zoomLevel > 1.01) {
        // Bicubic (Catmull-Rom) for zoomed view.
        color = sampleBicubic(sourceTexture, textureSampler, sourceUV, uniforms.sourceSize);
    } else {
        // Bilinear for 1:1 mapping.
        color = sourceTexture.sample(textureSampler, sourceUV);
    }

    // ---- Phase 2: Cursor Overlay ----
    if (uniforms.cursorVisible > 0.5) {
        float cursorBaseSize = 24.0;
        float cursorSize = cursorBaseSize * uniforms.cursorScale;
        float2 pixelPos  = float2(gid) + 0.5;
        float2 delta     = pixelPos - uniforms.cursorPosition;

        // Check if this pixel falls within the cursor rectangle.
        if (delta.x >= 0.0 && delta.x < cursorSize &&
            delta.y >= 0.0 && delta.y < cursorSize) {
            float2 cursorUV = delta / cursorSize;
            float4 cursorSample = cursorTexture.sample(textureSampler, cursorUV);

            // Alpha-blend cursor over the scene.
            float a = cursorSample.a;
            color.rgb = mix(color.rgb, cursorSample.rgb, a);
            color.a   = max(color.a, a);
        }
    }

    // ---- Phase 3: Click Highlight ----
    if (uniforms.clickHighlightPhase > 0.0) {
        float2 pixelPos = float2(gid) + 0.5;
        float dist = length(pixelPos - uniforms.cursorPosition);

        float currentRadius = uniforms.clickHighlightRadius * uniforms.clickHighlightPhase;

        if (dist < currentRadius) {
            // Radial gradient falloff: 1 at center, 0 at edge.
            float falloff = 1.0 - (dist / max(currentRadius, 1e-4));
            falloff = falloff * falloff; // quadratic falloff for smoother look

            // Fading opacity as the phase progresses.
            float fadeOut = 1.0 - uniforms.clickHighlightPhase;

            float alpha = uniforms.clickHighlightColor.a * falloff * fadeOut;
            color.rgb = mix(color.rgb, uniforms.clickHighlightColor.rgb, alpha);
        }
    }

    outputTexture.write(color, gid);
}
