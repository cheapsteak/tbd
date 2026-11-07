// Adapted from tkzmux c961533 Shaders/Terminal.metal (MIT, see LICENSE-tkzmux.txt). The shader is embedded as a string.
// The Metal shader source, compiled at start-up with `MTLDevice.makeLibrary(source:)`.
//
// TBD runs as a bare SwiftPM executable: there is no bundle, so there is no `default.metallib` and
// no `Bundle.module` to load a `.metal` file from. The shader is a string instead.
//
// `makeLibrary(source:)` has no include search path, so `source` is the shader-types header's
// text, then a `#line` reset, then the shader, whose `#include` is guarded off by the header's
// include guard. `header` must stay byte-identical to
// `Sources/TBDGhosttyShaderTypes/include/TBDGhosttyShaderTypes.h`, the copy Swift reads the same
// structs through; `RendererTests.shaderHeaderMatchesTheCTarget` checks that.
//
// Both strings are raw (`#"""`), so a backslash in either is literal, as the Metal compiler wants.

/// The Metal shader source the renderer compiles.
enum TerminalShaderSource {
    /// What `makeLibrary(source:)` compiles.
    static let source = header + "\n#line 1 \"Terminal.metal\"\n" + metal

    /// The text of `TBDGhosttyShaderTypes.h`, byte for byte.
    static let header = #"""
// Adapted from tkzmux c961533 Sources/TkzShaderTypes/include/TkzShaderTypes.h (MIT, see Sources/TBDGhosttyTerminal/LICENSE-tkzmux.txt).
// TBDGhosttyShaderTypes — structs shared byte for byte between Swift (TBDGhosttyTerminal's
// renderer) and the Metal shaders in `TerminalShaderSource.swift`. Header only; compiled by both of:
//
//   1. `swift build` — as C, imported into Swift as module `TBDGhosttyShaderTypes`.
//   2. `MTLDevice.makeLibrary(source:options:)` at runtime. TBD runs as an unbundled executable, so
//      there is no `default.metallib` and no resource bundle: the shader source is a Swift string,
//      and that path has NO include search path. So `TerminalShaderSource` carries a copy of this
//      header's text in front of the shader text, and the shader wraps its own `#include` in
//      `#if !defined(TKZ_SHADER_TYPES_H)`. That is why this file uses a classic include guard and NOT
//      `#pragma once`: `#pragma once` sets no macro, so the guard could not tell that the header was
//      already textually present, and the runtime preprocessor would try to open a file that is not
//      there.
//
// The copy in `TerminalShaderSource.header` must stay byte-identical to this file.
// `RendererTests.shaderHeaderMatchesTheCTarget` compares the two.
//
// Layout rules
// - Every field is a fixed-width integer, a float, or a `simd` vector type. No `int`/`long`/`bool`.
// - `_Static_assert`s at the bottom pin `sizeof`, `alignof` and every `offsetof`. They are compiled
//   by the C compiler AND by the Metal compiler, and `RendererTests` asserts the same sizes through
//   `MemoryLayout`. A layout divergence between Swift, C and Metal is therefore a build or test
//   failure, never a corrupt frame.
// - Colours are packed `uint32_t`, byte order R,G,B,A from the low byte (see `tkz_unpack_rgba`
//   in the shader; Swift builds them with `r | g << 8 | b << 16 | a << 24`).
//   They are *straight* (non-premultiplied) sRGB-encoded 8-bit values. The shaders premultiply on
//   output.
//
// Coordinate conventions
// - Pixel space = device (backing) pixels, origin top-left, +y down. This is `[[position]]` in the
//   fragment shaders and the space `viewportSizePx` / `gridOriginPx` / `TkzRectInstance` live in.
// - Grid space = (column, row), origin top-left. Cell (c, r) covers the pixel rect
//   `gridOriginPx + (c, r) * cellSizePx` … `+ cellSizePx`.
// - Atlas space = texels, origin top-left. Both atlases are sampled with `coord::pixel`, so the
//   atlas dimensions in `TkzUniforms` are informational only and a regrow cannot desync UVs.

#ifndef TKZ_SHADER_TYPES_H
#define TKZ_SHADER_TYPES_H

#include <simd/simd.h>

#ifdef __METAL_VERSION__
#include <metal_stdlib>
#endif

/// Bumped whenever a struct in this header changes shape. `TerminalRenderer` has no use for it at
/// runtime; it exists so a mismatched header is easy to name in a bug report.
#define TKZ_SHADER_TYPES_VERSION 1

// `static_assert` is a keyword in Metal (C++14) and in C++; `_Static_assert` is the C11 spelling.
#if defined(__METAL_VERSION__) || defined(__cplusplus)
#define TKZ_STATIC_ASSERT(cond, msg) static_assert(cond, msg)
#else
#define TKZ_STATIC_ASSERT(cond, msg) _Static_assert(cond, msg)
#endif

// `offsetof` lives in <stddef.h> in C and <cstddef> in C++; `__builtin_offsetof` is what both
// expand to under clang and is available in Metal without any include.
#define TKZ_OFFSETOF(type, field) __builtin_offsetof(type, field)

// `_Alignof` is C11, `alignof` is C++/Metal; `__alignof__` is the clang spelling that works in both.
#define TKZ_ALIGNOF(type) __alignof__(type)

// MARK: - Binding contract
//
// Every pipeline reads its uniforms from buffer 0 and its per-instance array from buffer 1, in both
// the vertex and the fragment function. No `MTLVertexDescriptor` is used anywhere: quads are
// generated from `[[vertex_id]]` + `[[instance_id]]`, so `pipelineDescriptor.vertexDescriptor`
// must stay `nil`.

/// Metal buffer argument indices. Same numbers in the vertex and fragment functions.
enum {
    /// `TkzUniforms` — one per pass, `setVertexBytes` / `setFragmentBytes` is fine (80 bytes).
    TKZ_BUFFER_INDEX_UNIFORMS = 0,
    /// The per-instance array: `TkzBgCell[cols*rows]`, `TkzRectInstance[n]` or
    /// `TkzGlyphInstance[n]` depending on the pass.
    TKZ_BUFFER_INDEX_INSTANCES = 1
};

/// Metal texture argument indices for the glyph fragment function. BOTH must always be bound, even
/// when a frame contains no colour glyphs — Metal validation faults on an unbound argument that the
/// function declares, regardless of whether the branch that samples it is taken.
enum {
    /// `r8Unorm` coverage atlas. Red channel = alpha mask.
    TKZ_TEXTURE_INDEX_GRAYSCALE = 0,
    /// `bgra8Unorm` colour atlas (emoji, colour fonts). Already premultiplied by CoreGraphics.
    TKZ_TEXTURE_INDEX_COLOR = 1
};

/// Shader entry-point names. Exposed as macros so Swift, the tests and the `.metal` file cannot
/// drift apart on a string literal. These import into Swift as `String`.
#define TKZ_FN_BG_VERTEX      "tkz_bg_vertex"
#define TKZ_FN_BG_FRAGMENT    "tkz_bg_fragment"
#define TKZ_FN_RECT_VERTEX    "tkz_rect_vertex"
#define TKZ_FN_RECT_FRAGMENT  "tkz_rect_fragment"
#define TKZ_FN_GLYPH_VERTEX   "tkz_glyph_vertex"
#define TKZ_FN_GLYPH_FRAGMENT "tkz_glyph_fragment"

// MARK: - Uniforms

/// Per-pass constants. Identical for all three passes of a frame; upload once, bind at
/// `TKZ_BUFFER_INDEX_UNIFORMS`.
typedef struct {
    /// Drawable size in device pixels. Used to map pixel space to clip space.
    vector_float2 viewportSizePx;
    /// `CellMetrics` cell size in device pixels (width, height). Integral in practice, but float so
    /// a future fractional-advance mode does not change the layout.
    vector_float2 cellSizePx;
    /// Pixel position of the top-left corner of cell (0, 0) inside the drawable. Lets the grid be
    /// padded/centred without moving every instance.
    vector_float2 gridOriginPx;
    /// Dimensions of the `r8Unorm` atlas in texels. Informational — the shaders sample with
    /// `coord::pixel`, so a regrow does not invalidate any instance already built.
    vector_float2 grayscaleAtlasSizePx;
    /// Dimensions of the `bgra8Unorm` atlas in texels. Informational, as above.
    vector_float2 colorAtlasSizePx;
    /// Grid dimensions (columns, rows). The background pass reads
    /// `TkzBgCell[row * gridSize.x + col]`, so the bg buffer must hold exactly `x * y` entries.
    vector_uint2 gridSize;
    /// Theme `terminalBackground`, packed RGBA. Painted where a cell has no explicit background and
    /// in the letterbox outside the grid. Alpha should be 255 (the layer is opaque).
    uint32_t defaultBackground;
    /// Theme `terminalForeground`, packed RGBA. Not read by the current shaders — the frame builder
    /// resolves the default foreground into each `TkzGlyphInstance.color` — but kept in the
    /// contract so a future pass (e.g. a procedural box-drawing fallback) has it.
    uint32_t defaultForeground;
    /// Cursor colour, packed RGBA. Not read by the shaders either: the cursor is a
    /// `TkzRectInstance` with this colour. Kept for symmetry and for the min-contrast path.
    uint32_t cursorColor;
    /// Colour used for a glyph whose cell is under a *filled* (focused) block cursor. Read by the
    /// glyph fragment function when `TKZ_GLYPH_FLAG_UNDER_CURSOR` is set.
    uint32_t cursorTextColor;
    /// Minimum WCAG contrast ratio to force between a glyph and its own background. `1.0` (or any
    /// value ≤ 1) disables the adjustment entirely. Only applied to instances that opt in with
    /// `TKZ_GLYPH_FLAG_MIN_CONTRAST`. Set from `Theme.terminalMinContrast`.
    float minContrast;
    /// Reserved; must be zero. Present so the struct is a round 80 bytes and so three more
    /// scalars can be added later without moving any existing field.
    uint32_t reserved0;
    uint32_t reserved1;
    uint32_t reserved2;
} TkzUniforms;

// MARK: - Background pass

/// One entry per grid cell, row-major: index `row * gridSize.x + col`. Bound at
/// `TKZ_BUFFER_INDEX_INSTANCES` for the background pass only. Deliberately a struct rather than a
/// bare `uint32_t` so the buffer type is self-documenting on both sides.
typedef struct {
    /// Packed RGBA. Alpha < 255 composites over `TkzUniforms.defaultBackground`; alpha 0 therefore
    /// means "no explicit background, use the theme's", which is what `GHOSTTY_INVALID_VALUE` from
    /// `row_cells_get_multi(BG_COLOR)` maps to.
    uint32_t color;
} TkzBgCell;

// MARK: - Glyph pass

/// Bit flags for `TkzGlyphInstance.flags`. Import into Swift as `UInt32` constants.
enum {
    /// Sample the `bgra8Unorm` colour atlas (already premultiplied) instead of the `r8Unorm`
    /// coverage atlas. Set for emoji and other colour-font glyphs.
    TKZ_GLYPH_FLAG_COLOR = 1u << 0,
    /// The cell sits under a filled block cursor: use `TkzUniforms.cursorTextColor` instead of
    /// `color`. Ignored for colour glyphs (emoji keep their own colours) and it suppresses the
    /// min-contrast adjustment, because the cursor colours are already contrast-checked by the
    /// theme.
    TKZ_GLYPH_FLAG_UNDER_CURSOR = 1u << 1,
    /// Opt in to the `TkzUniforms.minContrast` adjustment against `bgColor`. Leave clear for glyphs
    /// whose colours come from the theme (they are contrast-checked already) and set it for glyphs
    /// coloured by the program running in the terminal.
    TKZ_GLYPH_FLAG_MIN_CONTRAST = 1u << 2,
    /// Informational: this glyph occupies two cells (CJK, most emoji). The shaders ignore it —
    /// `sizePx` already spans both cells — but the frame builder and the tests use it.
    TKZ_GLYPH_FLAG_WIDE = 1u << 3
};

/// One instanced quad per glyph. Bound at `TKZ_BUFFER_INDEX_INSTANCES` for the glyph pass.
/// Draw as `.triangleStrip`, `vertexCount: 4`, `instanceCount: n`.
typedef struct {
    /// Grid position (column, row) of the cell the glyph is anchored to. For a wide glyph this is
    /// the *left* cell.
    vector_ushort2 gridPos;
    /// Signed pixel offset of the glyph bitmap's top-left corner relative to the cell's top-left
    /// corner. This is the CoreText bearing folded into cell space: typically
    /// `(bearingX, ascent - bearingY)`. Negative values (glyphs that overhang left or above) are
    /// legal and are why this is `short2` and not `ushort2`.
    vector_short2 offsetPx;
    /// Glyph bitmap size in pixels — the size of the quad, and of the region sampled from the atlas.
    vector_ushort2 sizePx;
    /// Top-left texel of the glyph inside its atlas (grayscale or colour, per `TKZ_GLYPH_FLAG_COLOR`).
    vector_ushort2 atlasPos;
    /// Foreground colour, packed RGBA, straight alpha. For colour glyphs only the alpha is used
    /// (as an extra opacity multiplier on the premultiplied texel).
    uint32_t color;
    /// The background this glyph is drawn over, packed RGBA. Only read when
    /// `TKZ_GLYPH_FLAG_MIN_CONTRAST` is set; the frame builder must fill it with the same colour it
    /// wrote into the cell's `TkzBgCell` (composited over `defaultBackground` if that was
    /// translucent), otherwise the contrast fix pushes the glyph the wrong way.
    uint32_t bgColor;
    /// `TKZ_GLYPH_FLAG_*` bitmask.
    uint32_t flags;
    /// Reserved; must be zero.
    uint32_t reserved0;
} TkzGlyphInstance;

// MARK: - Rect pass

/// `TkzRectInstance.style`. Everything here is drawn procedurally in the fragment shader — no
/// texture is bound to the rect pipeline at all. Import into Swift as `UInt32` constants.
enum {
    /// Fill the whole rect. Selection highlight, filled block cursor, bar/underscore cursor
    /// (just a thin rect), `SGR 7` inverse backgrounds that the bg grid cannot express.
    TKZ_RECT_STYLE_SOLID = 0,
    /// Box outline of `thicknessPx`, drawn inside the rect. The unfocused cursor.
    TKZ_RECT_STYLE_HOLLOW = 1,
    /// One horizontal line of `thicknessPx`, vertically centred in the rect.
    TKZ_RECT_STYLE_UNDERLINE_SINGLE = 2,
    /// Two horizontal lines of `thicknessPx`, flush with the top and bottom edges of the rect.
    /// The rect height should be at least `3 * thicknessPx` for a visible gap.
    TKZ_RECT_STYLE_UNDERLINE_DOUBLE = 3,
    /// Antialiased sine wave of `thicknessPx`, centred in the rect, peak-to-peak
    /// `rect height - thicknessPx`, wavelength `cellSizePx.x / 2` (so the phase is continuous
    /// across rects that start on a cell boundary).
    TKZ_RECT_STYLE_UNDERLINE_CURLY = 4,
    /// Centred line, dotted: `thicknessPx` on, `thicknessPx` off.
    TKZ_RECT_STYLE_UNDERLINE_DOTTED = 5,
    /// Centred line, dashed: `4 * thicknessPx` on, `2 * thicknessPx` off.
    TKZ_RECT_STYLE_UNDERLINE_DASHED = 6,
    /// Same geometry as `UNDERLINE_SINGLE`; a distinct value only so the frame builder stays
    /// explicit and so the two can diverge later without touching Swift.
    TKZ_RECT_STYLE_STRIKETHROUGH = 7,
    /// Number of styles. An out-of-range style renders nothing (alpha 0).
    TKZ_RECT_STYLE_COUNT = 8
};

/// One instanced quad per decoration. Bound at `TKZ_BUFFER_INDEX_INSTANCES` for the rect pass,
/// which runs twice per frame: "rects-below" (selection, filled cursor) before the glyph pass and
/// "rects-above" (underlines, strikethrough, hollow cursor) after it.
/// Draw as `.triangleStrip`, `vertexCount: 4`, `instanceCount: n`.
///
/// The rect is the *box the decoration lives in*, not the ink itself: every style is laid out
/// relative to this box, so the frame builder positions an underline by giving it a box that spans
/// the run horizontally and the underline band vertically (for curly, tall enough for the wave).
typedef struct {
    /// Top-left corner in device pixels. Usually `gridOriginPx + (col, row) * cellSizePx` plus a
    /// `CellMetrics` offset, but any pixel rect is legal.
    vector_float2 originPx;
    /// Width and height in device pixels.
    vector_float2 sizePx;
    /// Packed RGBA, straight alpha. Premultiplied by the shader on output, so a selection overlay
    /// is simply the theme's `selection` token with its alpha.
    uint32_t color;
    /// One of `TKZ_RECT_STYLE_*`.
    uint32_t style;
    /// Line thickness in device pixels for every style except `SOLID`. Comes from `CellMetrics`
    /// (`CTFontGetUnderlineThickness`, rounded to at least 1 device pixel). Values below 1 are
    /// clamped to 1 by the shader so a hairline never disappears.
    float thicknessPx;
    /// Reserved; must be zero.
    uint32_t reserved0;
} TkzRectInstance;

// MARK: - Layout assertions
//
// The sizes are duplicated in RendererTests.swift. Change one, change both.

TKZ_STATIC_ASSERT(sizeof(TkzUniforms) == 80, "TkzUniforms size");
TKZ_STATIC_ASSERT(TKZ_ALIGNOF(TkzUniforms) == 8, "TkzUniforms align");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, viewportSizePx) == 0, "TkzUniforms.viewportSizePx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, cellSizePx) == 8, "TkzUniforms.cellSizePx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, gridOriginPx) == 16, "TkzUniforms.gridOriginPx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, grayscaleAtlasSizePx) == 24, "TkzUniforms.grayscaleAtlasSizePx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, colorAtlasSizePx) == 32, "TkzUniforms.colorAtlasSizePx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, gridSize) == 40, "TkzUniforms.gridSize");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, defaultBackground) == 48, "TkzUniforms.defaultBackground");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, defaultForeground) == 52, "TkzUniforms.defaultForeground");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, cursorColor) == 56, "TkzUniforms.cursorColor");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, cursorTextColor) == 60, "TkzUniforms.cursorTextColor");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, minContrast) == 64, "TkzUniforms.minContrast");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzUniforms, reserved0) == 68, "TkzUniforms.reserved0");

TKZ_STATIC_ASSERT(sizeof(TkzBgCell) == 4, "TkzBgCell size");
TKZ_STATIC_ASSERT(TKZ_ALIGNOF(TkzBgCell) == 4, "TkzBgCell align");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzBgCell, color) == 0, "TkzBgCell.color");

TKZ_STATIC_ASSERT(sizeof(TkzGlyphInstance) == 32, "TkzGlyphInstance size");
TKZ_STATIC_ASSERT(TKZ_ALIGNOF(TkzGlyphInstance) == 4, "TkzGlyphInstance align");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, gridPos) == 0, "TkzGlyphInstance.gridPos");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, offsetPx) == 4, "TkzGlyphInstance.offsetPx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, sizePx) == 8, "TkzGlyphInstance.sizePx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, atlasPos) == 12, "TkzGlyphInstance.atlasPos");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, color) == 16, "TkzGlyphInstance.color");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, bgColor) == 20, "TkzGlyphInstance.bgColor");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, flags) == 24, "TkzGlyphInstance.flags");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzGlyphInstance, reserved0) == 28, "TkzGlyphInstance.reserved0");

TKZ_STATIC_ASSERT(sizeof(TkzRectInstance) == 32, "TkzRectInstance size");
TKZ_STATIC_ASSERT(TKZ_ALIGNOF(TkzRectInstance) == 8, "TkzRectInstance align");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzRectInstance, originPx) == 0, "TkzRectInstance.originPx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzRectInstance, sizePx) == 8, "TkzRectInstance.sizePx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzRectInstance, color) == 16, "TkzRectInstance.color");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzRectInstance, style) == 20, "TkzRectInstance.style");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzRectInstance, thicknessPx) == 24, "TkzRectInstance.thicknessPx");
TKZ_STATIC_ASSERT(TKZ_OFFSETOF(TkzRectInstance, reserved0) == 28, "TkzRectInstance.reserved0");

#endif /* TKZ_SHADER_TYPES_H */

"""#

    /// The three pipelines' vertex and fragment functions.
    static let metal = #"""
// Terminal.metal — the whole terminal renderer, three pipelines.
// See TBDGhosttyShaderTypes.h for the struct
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
// Include note: this is compiled with `device.makeLibrary(source:)`, which has no include search
// path, so `TerminalShaderSource.source` textually prepends TBDGhosttyShaderTypes.h — the guard
// below is what makes the include a no-op instead of a "file not found".

#if !defined(TKZ_SHADER_TYPES_H)
#include "TBDGhosttyShaderTypes.h"
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

"""#
}
