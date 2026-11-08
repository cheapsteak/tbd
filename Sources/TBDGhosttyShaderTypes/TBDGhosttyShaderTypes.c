// Adapted from tkzmux c961533 Sources/TkzShaderTypes/TkzShaderTypes.c (MIT, see Sources/TBDGhosttyTerminal/LICENSE-tkzmux.txt).
// SwiftPM needs at least one source file in a C target, and this one earns its keep: including the
// header here is what makes the C compiler evaluate the TKZ_STATIC_ASSERTs at the bottom of
// TBDGhosttyShaderTypes.h on every `swift build`. The Metal compiler evaluates the same assertions
// from the shader source, and RendererTests checks the sizes through MemoryLayout, so all three
// views of the structs are pinned to one set of literals.
//
// No definitions belong here — the header is the whole contract.
#include "TBDGhosttyShaderTypes.h"
