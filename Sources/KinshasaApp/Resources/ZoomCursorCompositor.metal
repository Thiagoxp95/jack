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
    float  cursorClickScale;     // offset 52: cursor press animation (1.0 = normal, <1 = pressed)
    float  _pad2;                 // offset 56: padding
    float  _pad3;                 // offset 60: padding to align float4 to 16-byte boundary
    float4 clickHighlightColor;   // offset 64: RGBA
    float  clickHighlightRadius;  // offset 80: max radius in pixels
    float  contentOffsetX;        // offset 84: content area X offset for aspect ratio bars
    float  contentOffsetY;        // offset 88: content area Y offset for aspect ratio bars
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

    // Mip-filtered sampler for the cursor texture — uses trilinear filtering
    // across mip levels so the cursor stays crisp at any rendered size.
    constexpr sampler cursorSampler(
        coord::normalized,
        address::clamp_to_edge,
        filter::linear,
        mip_filter::linear
    );

    float2 pixelPos = float2(gid) + 0.5;

    // ---- Phase 0: Content Area (aspect ratio bars) ----
    float2 contentOffset = float2(uniforms.contentOffsetX, uniforms.contentOffsetY);
    float2 contentSize = uniforms.outputSize - 2.0 * contentOffset;
    float2 contentPos = pixelPos - contentOffset;
    float2 contentUV = contentPos / contentSize;

    bool inContent = (contentUV.x >= 0.0 && contentUV.x <= 1.0 &&
                      contentUV.y >= 0.0 && contentUV.y <= 1.0);

    float4 color;

    if (!inContent) {
        // Outside content area: black bar
        color = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        float2 outUV = contentUV;

        // ---- Phase 1: Zoom Transform ----
        // Use the zoom center directly from CameraTracker. No soft-clamping —
        // the preview uses .scaleEffect with the same anchor, and CameraTracker
        // already keeps the viewport reasonable via its deadzone logic.
        float invZoom = 1.0 / max(uniforms.zoomLevel, 1e-4);

        float2 sourceUV = uniforms.zoomCenter + (outUV - uniforms.zoomCenter) * invZoom;
        sourceUV = clamp(sourceUV, float2(0.0), float2(1.0));

        if (uniforms.zoomLevel > 1.01) {
            // Bicubic (Catmull-Rom) for zoomed view.
            color = sampleBicubic(sourceTexture, textureSampler, sourceUV, uniforms.sourceSize);
        } else {
            // Bilinear for 1:1 mapping.
            color = sourceTexture.sample(textureSampler, sourceUV);
        }
    }

    // ---- Phase 2: Cursor Overlay ----
    // Matches CursorOverlayView's 14×20 base frame and click press animation.
    if (uniforms.cursorVisible > 0.5) {
        float scale = uniforms.cursorScale * uniforms.cursorClickScale;
        float cursorWidth  = 14.0 * scale;
        float cursorHeight = 20.0 * scale;
        float2 delta     = pixelPos - uniforms.cursorPosition;

        // Check if this pixel falls within the cursor rectangle.
        if (delta.x >= 0.0 && delta.x < cursorWidth &&
            delta.y >= 0.0 && delta.y < cursorHeight) {
            float2 cursorUV = float2(delta.x / cursorWidth, delta.y / cursorHeight);
            float4 cursorSample = cursorTexture.sample(cursorSampler, cursorUV);

            // Alpha-blend cursor over the scene.
            float a = cursorSample.a;
            color.rgb = mix(color.rgb, cursorSample.rgb, a);
            color.a   = max(color.a, a);
        }
    }

    // ---- Phase 3: Click Highlight ----
    if (uniforms.clickHighlightPhase > 0.0) {
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
