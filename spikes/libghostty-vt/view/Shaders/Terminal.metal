// Adapted from tkzmux c961533 (MIT, see third_party/tkzmux).
// Terminal.metal — the whole tkzmux terminal renderer, three pipelines. M1.5.
// See TkzShaderTypes.h for the struct
// contract (field meanings, units, flag bits, buffer/texture indices).
//
// Draw order per frame, all into one `.bgra8Unorm` colour attachment on an opaque sRGB layer:
//
//   1. background   `tkz_bg_vertex` / `tkz_bg_fragment`        — full-screen triangle, no blending
//   2. rects-below  `tkz_rect_vertex` / `tkz_rect_fragment`    — selection, filled block cursor
//   3. glyphs       `tkz_glyph_vertex` / `tkz_glyph_fragment`  — one instanced quad per glyph
//   4. rects-above  the rect pipeline again                    — underline, strike, hollow cursor
//
// Passes 2–4 use premultiplied blending: rgb and alpha both `.one` / `.oneMinusSourceAlpha`. Every
// fragment function therefore returns a *premultiplied* colour; the colours in the buffers are
// straight sRGB (see `tkz_premultiply`).
//
// No `MTLVertexDescriptor` anywhere: quads come from `[[vertex_id]]` + `[[instance_id]]`, and the
// instance arrays are read as `const device` pointers. `pipelineDescriptor.vertexDescriptor` stays
// `nil`, and the draw calls are `.triangleStrip` with `vertexCount: 4` (background: `.triangle`
// with `vertexCount: 3`, no buffers on the vertex stage at all).
//
// Include note: `xcrun metal -I Sources/TkzShaderTypes/include` (scripts/make-app.sh) resolves the
// include normally. The `device.makeLibrary(source:)` fallback has no include search path, so the
// loader textually prepends TkzShaderTypes.h — the guard below is what makes that a no-op instead
// of a "file not found".

#if !defined(TKZ_SHADER_TYPES_H)
#include "TkzShaderTypes.h"
#endif

#include <metal_stdlib>

using namespace metal;

// MARK: - Shared helpers

/// Unpack a `TkzShaderTypes` colour: R in the low byte, then G, B, A. Straight (non-premultiplied)
/// sRGB-encoded, 0…1 on return.
static inline float4 tkz_unpack_rgba(uint32_t v) {
    return float4(float( v        & 0xFFu),
                  float((v >>  8) & 0xFFu),
                  float((v >> 16) & 0xFFu),
                  float((v >> 24) & 0xFFu)) * (1.0f / 255.0f);
}

/// Straight alpha → premultiplied, for `.one` / `.oneMinusSourceAlpha` blending.
static inline float4 tkz_premultiply(float4 c) {
    return float4(c.rgb * c.a, c.a);
}

/// `src` over an *opaque* `dst`, both straight-alpha. Result is opaque.
static inline float4 tkz_over_opaque(float4 src, float4 dst) {
    return float4(mix(dst.rgb, src.rgb, src.a), 1.0f);
}

/// Pixel space (origin top-left, +y down) → clip space.
static inline float4 tkz_pixel_to_clip(float2 px, float2 viewportPx) {
    float2 n = px / viewportPx;
    return float4(n.x * 2.0f - 1.0f, 1.0f - n.y * 2.0f, 0.0f, 1.0f);
}

/// Unit-quad corner for a 4-vertex `.triangleStrip`: (0,0) (1,0) (0,1) (1,1).
static inline float2 tkz_quad_corner(uint vid) {
    return float2(float(vid & 1u), float((vid >> 1) & 1u));
}

// MARK: - Background pass
//
// One full-screen triangle, no vertex buffer, no blending. Every pixel maps back to a grid cell and
// takes that cell's colour composited over the theme background; pixels outside the grid (the
// letterbox left over when the view is not an exact multiple of the cell size) take the theme
// background alone. Doing it this way instead of one instance per cell keeps a 200×60 grid at three
// vertices and one buffer read per pixel.

struct TkzBgVaryings {
    float4 position [[position]];
};

vertex TkzBgVaryings tkz_bg_vertex(uint vid [[vertex_id]]) {
    // (-1,-1), (3,-1), (-1,3): one oversized triangle that covers the whole clip square.
    float2 p = float2(vid == 1u ? 3.0f : -1.0f,
                      vid == 2u ? 3.0f : -1.0f);
    TkzBgVaryings out;
    out.position = float4(p, 0.0f, 1.0f);
    return out;
}

fragment float4 tkz_bg_fragment(TkzBgVaryings in [[stage_in]],
                                constant TkzUniforms &u [[buffer(TKZ_BUFFER_INDEX_UNIFORMS)]],
                                const device TkzBgCell *cells [[buffer(TKZ_BUFFER_INDEX_INSTANCES)]]) {
    float4 base = tkz_unpack_rgba(u.defaultBackground);

    // Signed on purpose: `position.xy` is left of / above `gridOriginPx` in the letterbox, and
    // casting a negative float to uint wraps to ~4e9 and would read far past the buffer.
    float2 cell = floor((in.position.xy - u.gridOriginPx) / u.cellSizePx);
    if (cell.x < 0.0f || cell.y < 0.0f ||
        cell.x >= float(u.gridSize.x) || cell.y >= float(u.gridSize.y)) {
        return tkz_premultiply(base);
    }

    uint index = uint(cell.y) * u.gridSize.x + uint(cell.x);
    return tkz_premultiply(tkz_over_opaque(tkz_unpack_rgba(cells[index].color), base));
}

// MARK: - Rect pass
//
// Everything a terminal draws that is not a glyph: selection, both cursor shapes, and the five
// underline styles plus strikethrough. All procedural — no texture is bound to this pipeline.
//
// The instance rect is the *box the decoration lives in*, and every style lays itself out relative
// to that box, so the frame builder only has to place a box (see TKZ_RECT_STYLE_* in the header).
// Coverage is computed analytically with a one-pixel filter width, which antialiases fractional
// thicknesses and the curly wave without any multisampling.

struct TkzRectVaryings {
    float4 position [[position]];
    /// Position inside the rect, in pixels, 0…sizePx. The only interpolated varying.
    float2 localPx;
    float2 sizePx       [[flat]];
    float4 color        [[flat]];
    uint   style        [[flat]];
    float  thicknessPx  [[flat]];
    /// Curly-underline wavelength in pixels. Half a cell, so two humps per cell and the phase is
    /// continuous across rects that start on a cell boundary.
    float  waveLengthPx [[flat]];
};

/// Analytic coverage of the interval [lo, hi] at x, with a one-pixel filter.
static inline float tkz_span_coverage(float x, float lo, float hi) {
    return clamp(min(x - lo, hi - x) + 0.5f, 0.0f, 1.0f);
}

/// Coverage of an axis-aligned box, one-pixel filtered on all four edges.
static inline float tkz_box_coverage(float2 p, float2 lo, float2 hi) {
    return tkz_span_coverage(p.x, lo.x, hi.x) * tkz_span_coverage(p.y, lo.y, hi.y);
}

/// Coverage of a periodic mask along x: `period` px long, ink for the first `on` px.
static inline float tkz_dash_coverage(float x, float period, float on) {
    float m = x - period * floor(x / period);
    return clamp(min(m, on - m) + 0.5f, 0.0f, 1.0f);
}

/// Coverage of a sine wave of thickness `t`, centred vertically in `size`, peak-to-peak
/// `size.y - t`. The distance to the curve is the vertical distance corrected by the local slope,
/// which is what keeps the stroke an even width through the steep parts of the wave.
static inline float tkz_curly_coverage(float2 p, float2 size, float t, float waveLengthPx) {
    float amplitude = max((size.y - t) * 0.5f, 0.0f);
    float k = 2.0f * M_PI_F / max(waveLengthPx, 1.0f);
    float phase = k * p.x;
    float curveY = size.y * 0.5f + amplitude * sin(phase);
    float slope = amplitude * k * cos(phase);
    float distance = abs(p.y - curveY) * rsqrt(1.0f + slope * slope);
    return clamp(t * 0.5f - distance + 0.5f, 0.0f, 1.0f);
}

vertex TkzRectVaryings tkz_rect_vertex(uint vid [[vertex_id]],
                                       uint iid [[instance_id]],
                                       constant TkzUniforms &u [[buffer(TKZ_BUFFER_INDEX_UNIFORMS)]],
                                       const device TkzRectInstance *rects [[buffer(TKZ_BUFFER_INDEX_INSTANCES)]]) {
    TkzRectInstance r = rects[iid];
    float2 corner = tkz_quad_corner(vid);

    TkzRectVaryings out;
    out.position = tkz_pixel_to_clip(r.originPx + corner * r.sizePx, u.viewportSizePx);
    out.localPx = corner * r.sizePx;
    out.sizePx = r.sizePx;
    out.color = tkz_unpack_rgba(r.color);
    out.style = r.style;
    // A sub-pixel underline thickness would vanish once antialiased; clamp so hairlines survive.
    out.thicknessPx = max(r.thicknessPx, 1.0f);
    out.waveLengthPx = max(u.cellSizePx.x * 0.5f, 2.0f);
    return out;
}

fragment float4 tkz_rect_fragment(TkzRectVaryings in [[stage_in]]) {
    float2 p = in.localPx;
    float2 size = in.sizePx;
    float t = in.thicknessPx;
    float centerY = size.y * 0.5f;
    float coverage = 0.0f;

    switch (in.style) {
    case TKZ_RECT_STYLE_SOLID:
        coverage = 1.0f;
        break;

    case TKZ_RECT_STYLE_HOLLOW: {
        float outer = tkz_box_coverage(p, float2(0.0f), size);
        float inner = tkz_box_coverage(p, float2(t), size - t);
        coverage = saturate(outer - inner);
        break;
    }

    case TKZ_RECT_STYLE_UNDERLINE_SINGLE:
    case TKZ_RECT_STYLE_STRIKETHROUGH:
        coverage = tkz_span_coverage(p.y, centerY - t * 0.5f, centerY + t * 0.5f);
        break;

    case TKZ_RECT_STYLE_UNDERLINE_DOUBLE:
        coverage = max(tkz_span_coverage(p.y, 0.0f, t),
                       tkz_span_coverage(p.y, size.y - t, size.y));
        break;

    case TKZ_RECT_STYLE_UNDERLINE_CURLY:
        coverage = tkz_curly_coverage(p, size, t, in.waveLengthPx);
        break;

    case TKZ_RECT_STYLE_UNDERLINE_DOTTED:
        coverage = tkz_span_coverage(p.y, centerY - t * 0.5f, centerY + t * 0.5f)
                 * tkz_dash_coverage(p.x, t * 2.0f, t);
        break;

    case TKZ_RECT_STYLE_UNDERLINE_DASHED:
        coverage = tkz_span_coverage(p.y, centerY - t * 0.5f, centerY + t * 0.5f)
                 * tkz_dash_coverage(p.x, t * 6.0f, t * 4.0f);
        break;

    default:
        // Unknown style: draw nothing rather than a mystery block.
        coverage = 0.0f;
        break;
    }

    return tkz_premultiply(float4(in.color.rgb, in.color.a * coverage));
}

// MARK: - Glyph pass
//
// One pipeline, not two, with both atlases bound and a branch on TKZ_GLYPH_FLAG_COLOR. The flag is
// constant across an instance's four vertices and across every fragment of its quad, so the branch
// is uniform within a quad and costs nothing beyond the (unavoidable) second texture binding.
// Splitting into two pipelines would instead cost a second sort of the instance array, a second
// buffer, and a pipeline switch in the middle of the text pass — for glyph counts in the low
// thousands that is strictly worse.
//
// Colour selection (cursor swap, min contrast) happens in the *vertex* function: four invocations
// per glyph instead of a few hundred fragments, and the results ride along as flat varyings.

struct TkzGlyphVaryings {
    float4 position [[position]];
    /// Atlas position in *texels* (both atlases are sampled with `coord::pixel`), so an atlas
    /// regrow cannot invalidate instances that were already built against the old dimensions.
    float2 atlasPx;
    float4 color [[flat]];
    uint   flags [[flat]];
};

static inline float tkz_srgb_to_linear(float c) {
    return c <= 0.04045f ? c * (1.0f / 12.92f) : pow((c + 0.055f) * (1.0f / 1.055f), 2.4f);
}

/// WCAG relative luminance of an sRGB-encoded colour.
static inline float tkz_relative_luminance(float3 c) {
    float3 linear = float3(tkz_srgb_to_linear(c.r),
                           tkz_srgb_to_linear(c.g),
                           tkz_srgb_to_linear(c.b));
    return dot(linear, float3(0.2126f, 0.7152f, 0.0722f));
}

static inline float tkz_contrast_ratio(float lumA, float lumB) {
    return (max(lumA, lumB) + 0.05f) / (min(lumA, lumB) + 0.05f);
}

static inline float tkz_linear_to_srgb(float c) {
    return c <= 0.0031308f ? c * 12.92f : 1.055f * pow(c, 1.0f / 2.4f) - 0.055f;
}

/// If `fg` on `bg` is below `minRatio`, move it toward black or white — whichever has more contrast
/// against `bg` — just far enough to reach `minRatio`. The mix is done in linear light, where it
/// moves luminance linearly, so the amount is solved exactly rather than searched for, and the hue
/// survives: a pastel a program chose for a dark background comes out as a deeper shade of the same
/// colour on a light one, not as black. The frame builder only opts in for colours the *program*
/// chose, never theme colours.
static inline float3 tkz_min_contrast(float3 fg, float3 bg, float minRatio) {
    float bgLuminance = tkz_relative_luminance(bg);
    float fgLuminance = tkz_relative_luminance(fg);
    if (tkz_contrast_ratio(fgLuminance, bgLuminance) >= minRatio) {
        return fg;
    }
    float3 linear = float3(tkz_srgb_to_linear(fg.r), tkz_srgb_to_linear(fg.g), tkz_srgb_to_linear(fg.b));
    bool whiteWins = tkz_contrast_ratio(1.0f, bgLuminance) > tkz_contrast_ratio(0.0f, bgLuminance);
    if (whiteWins) {
        // L' = L + t(1 - L)
        float target = min(minRatio * (bgLuminance + 0.05f) - 0.05f, 1.0f);
        float t = fgLuminance < 1.0f ? saturate((target - fgLuminance) / (1.0f - fgLuminance)) : 0.0f;
        linear = mix(linear, float3(1.0f), t);
    } else {
        // L' = L * s
        float target = max((bgLuminance + 0.05f) / minRatio - 0.05f, 0.0f);
        float s = fgLuminance > 0.0f ? saturate(target / fgLuminance) : 0.0f;
        linear *= s;
    }
    return float3(tkz_linear_to_srgb(linear.r), tkz_linear_to_srgb(linear.g), tkz_linear_to_srgb(linear.b));
}

vertex TkzGlyphVaryings tkz_glyph_vertex(uint vid [[vertex_id]],
                                         uint iid [[instance_id]],
                                         constant TkzUniforms &u [[buffer(TKZ_BUFFER_INDEX_UNIFORMS)]],
                                         const device TkzGlyphInstance *glyphs [[buffer(TKZ_BUFFER_INDEX_INSTANCES)]]) {
    TkzGlyphInstance g = glyphs[iid];
    float2 corner = tkz_quad_corner(vid);
    float2 glyphSize = float2(g.sizePx);
    float2 cellOriginPx = u.gridOriginPx + float2(g.gridPos) * u.cellSizePx;

    float4 color = tkz_unpack_rgba(g.color);
    if (g.flags & TKZ_GLYPH_FLAG_UNDER_CURSOR) {
        // Emoji keep their own colours under the cursor; only monochrome text is swapped.
        if ((g.flags & TKZ_GLYPH_FLAG_COLOR) == 0u) {
            color.rgb = tkz_unpack_rgba(u.cursorTextColor).rgb;
        }
    } else if ((g.flags & TKZ_GLYPH_FLAG_MIN_CONTRAST) != 0u && u.minContrast > 1.0f) {
        color.rgb = tkz_min_contrast(color.rgb, tkz_unpack_rgba(g.bgColor).rgb, u.minContrast);
    }

    TkzGlyphVaryings out;
    out.position = tkz_pixel_to_clip(cellOriginPx + float2(g.offsetPx) + corner * glyphSize,
                                     u.viewportSizePx);
    out.atlasPx = float2(g.atlasPos) + corner * glyphSize;
    out.color = color;
    out.flags = g.flags;
    return out;
}

fragment float4 tkz_glyph_fragment(TkzGlyphVaryings in [[stage_in]],
                                   texture2d<float> grayscaleAtlas [[texture(TKZ_TEXTURE_INDEX_GRAYSCALE)]],
                                   texture2d<float> colorAtlas [[texture(TKZ_TEXTURE_INDEX_COLOR)]]) {
    // `coord::pixel` + nearest: glyphs are rasterised at device resolution and blitted 1:1, so any
    // filtering would only smear them. `clamp_to_edge` keeps a rounding error on the last texel
    // from wrapping to the far side of the atlas.
    constexpr sampler atlasSampler(coord::pixel, filter::nearest, address::clamp_to_edge);

    if (in.flags & TKZ_GLYPH_FLAG_COLOR) {
        // bgra8Unorm: Metal swizzles to RGBA on read, and CoreGraphics already premultiplied it.
        // `color.a` is the only part of the instance colour that applies — scaling a premultiplied
        // colour by a scalar keeps it premultiplied.
        return colorAtlas.sample(atlasSampler, in.atlasPx) * in.color.a;
    }

    // r8Unorm coverage: the red channel is the glyph's alpha mask. Straight colour × mask, then
    // premultiplied in one step — `float4(rgb * a, a)` with `a = color.a * mask`.
    float alpha = in.color.a * grayscaleAtlas.sample(atlasSampler, in.atlasPx).r;
    return float4(in.color.rgb * alpha, alpha);
}
