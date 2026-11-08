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
