// Adapted from tkzmux c961533 (MIT, see third_party/tkzmux).
// SwiftPM needs at least one source file in a C target, and this one earns its keep: including the
// header here is what makes the C compiler evaluate the TKZ_STATIC_ASSERTs at the bottom of
// TkzShaderTypes.h on every `swift build`. The Metal compilers evaluate the same assertions from
// Terminal.metal, and ShaderCompileTests.swift checks the same numbers through MemoryLayout, so all
// three views of the structs are pinned to one set of literals.
//
// No definitions belong here — the header is the whole contract.
#include "TkzShaderTypes.h"
