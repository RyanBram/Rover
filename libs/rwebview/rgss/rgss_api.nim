# =============================================================================
# rgss/rgss_api.nim
# RGSS (Rover Game Scripting System) — engine-agnostic scripting abstraction layer
# =============================================================================
#
# Author    : Ryan Bramantya
# Copyright : Copyright (c) 2026 Ryan Bramantya
# License   : Apache License 2.0
# Website   : https://github.com/RyanBram/Rover
#
# -----------------------------------------------------------------------------
#
# Description:
#   Defines the unified ScriptEngine vtable, ScriptValue, and ScriptCtx
#   types that allow rwebview modules (dom, xhr, audio, canvas2d, gl, storage)
#   to speak to any scripting engine without importing engine-specific FFI.
#
#   Design constraints:
#   - ScriptValue is always 16 bytes (fits JSValue, mrb_value, Lua ref).
#     No heap allocation. Stack-allocatable everywhere.
#   - Ownership: every ScriptValue is a strong reference unless marked
#     "unowned" in a comment. Use engine.dupValue / engine.freeValue via
#     the ctx.dupValue / ctx.freeValue forwarding helpers.
#   - ScriptNativeProc is the universal callback signature.  Each engine
#     adaptor provides a C-level thunk that translates native args to this.
#   - TypedArray support (newArrayBufferCopy / getArrayBufferData) is optional.
#     Procedure fields may be nil for engines that lack typed arrays.
#
# Usage (by rwebview feature modules):
#   Modules receive a ptr ScriptCtx.  They call procs like:
#
#     ctx.newString("hello")
#     ctx.setGlobal("foo", ctx.newInt(42))
#     ctx.bindGlobal("myFunc", myHandler, 2)
#
# Included by:
#   - rgss_quickjs.nim          (implements the vtable for QuickJS)
#   - rwebview_dom.nim          (future migration target)
#   - rwebview_xhr.nim          (future migration target)
#   - rwebview_audio.nim        (future migration target)
#   - rwebview_canvas2d.nim     (future migration target)
#   - rwebview_gl.nim           (future migration target)
#   - rwebview_storage.nim      (future migration target)
#
# =============================================================================

# ---------------------------------------------------------------------------
# ScriptValue — engine-opaque 16-byte value token (bycopy for C ABI compat)
# ---------------------------------------------------------------------------
# Layout: data[0..1] — two uint64 words, interpreted by the engine adaptor.
#   QuickJS      : JSValue in-place { union u (8 bytes); int64 tag (8 bytes) }
#   Lua 5.4     : data[0] = int32 registry ref; data[1] = uint8 Lua type tag
#   mruby       : mrb_value in-place (64-bit tagged pointer, 8 bytes used)

type
  ScriptValue* {.bycopy.} = object
    data*: array[2, uint64]

# ---------------------------------------------------------------------------
# All types that mutually reference one another live in a single type block.
# Nim does not support forward declarations for object types — everything
# that refers to ScriptEngine or ScriptCtx must appear in one type section.
# ---------------------------------------------------------------------------

type
  # ScriptCtx — per-context handle (one per webview instance)
  ScriptCtx* = object
    engine*: ptr ScriptEngine  ## vtable pointer (shared for all contexts of same engine)
    native*: pointer           ## ptr JSContext / lua_State* / mrb_state*

  # ScriptNativeProc — universal host-function callback.
  # Engine adaptor wraps its native callback convention to call this.
  # IMPORTANT: args elements are borrowed — do NOT freeValue them inside the
  # callback.  dupValue them if you need to keep them after return.
  ScriptNativeProc* = proc(ctx: ptr ScriptCtx;
                           this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue {.closure.}

  # ScriptEngine — vtable; one instance per engine type (not per context).
  # All function-pointer fields are {.cdecl.} so they are interoperable with C.
  ScriptEngine* = object

    # ---- Lifecycle -------------------------------------------------------
    initEngine*:    proc(eng: ptr ScriptEngine) {.cdecl.}
    destroyEngine*: proc(eng: ptr ScriptEngine) {.cdecl.}

    # ---- Context management ----------------------------------------------
    newCtx*:  proc(eng: ptr ScriptEngine): ptr ScriptCtx {.cdecl.}
    freeCtx*: proc(ctx: ptr ScriptCtx) {.cdecl.}

    # ---- Evaluation ------------------------------------------------------
    eval*: proc(ctx: ptr ScriptCtx; src: cstring; filename: cstring): ScriptValue {.cdecl.}

    # ---- Value constructors ----------------------------------------------
    newString*:    proc(ctx: ptr ScriptCtx; s: cstring): ScriptValue {.cdecl.}
    newStringLen*: proc(ctx: ptr ScriptCtx; s: cstring; len: int): ScriptValue {.cdecl.}
    newInt*:       proc(ctx: ptr ScriptCtx; i: int32): ScriptValue {.cdecl.}
    newUint*:      proc(ctx: ptr ScriptCtx; u: uint32): ScriptValue {.cdecl.}
    newFloat*:     proc(ctx: ptr ScriptCtx; f: float64): ScriptValue {.cdecl.}
    newBool*:      proc(ctx: ptr ScriptCtx; b: bool): ScriptValue {.cdecl.}
    newNull*:      proc(ctx: ptr ScriptCtx): ScriptValue {.cdecl.}
    newUndefined*: proc(ctx: ptr ScriptCtx): ScriptValue {.cdecl.}
    newObject*:    proc(ctx: ptr ScriptCtx): ScriptValue {.cdecl.}
    newArray*:     proc(ctx: ptr ScriptCtx): ScriptValue {.cdecl.}

    # ---- Value extraction ------------------------------------------------
    toString*:    proc(ctx: ptr ScriptCtx; v: ScriptValue): cstring {.cdecl.}
    freeCString*: proc(ctx: ptr ScriptCtx; s: cstring) {.cdecl.}
    toInt32*:     proc(ctx: ptr ScriptCtx; v: ScriptValue): int32 {.cdecl.}
    toUint32*:    proc(ctx: ptr ScriptCtx; v: ScriptValue): uint32 {.cdecl.}
    toFloat64*:   proc(ctx: ptr ScriptCtx; v: ScriptValue): float64 {.cdecl.}
    toBool*:      proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}

    # ---- Type predicates -------------------------------------------------
    isString*:    proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isNumber*:    proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isNull*:      proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isUndefined*: proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isObject*:    proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isFunction*:  proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isException*: proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}
    isBool*:      proc(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.}

    # ---- Object / Array operations ---------------------------------------
    getProp*:      proc(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring): ScriptValue {.cdecl.}
    ## setProp: copies val (engine dup's internally so caller still owns val).
    setProp*:      proc(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue) {.cdecl.}
    ## setPropSteal: engine takes ownership of val; caller must NOT free it.
    setPropSteal*: proc(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue) {.cdecl.}
    getIndex*:     proc(ctx: ptr ScriptCtx; arr: ScriptValue; idx: uint32): ScriptValue {.cdecl.}
    ## setIndex: copies val (engine dup's internally).
    setIndex*:     proc(ctx: ptr ScriptCtx; arr: ScriptValue; idx: uint32; val: ScriptValue) {.cdecl.}

    # ---- Globals ---------------------------------------------------------
    getGlobal*:      proc(ctx: ptr ScriptCtx): ScriptValue {.cdecl.}
    ## setGlobal: copies val.
    setGlobal*:      proc(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.cdecl.}
    ## setGlobalSteal: engine takes ownership of val.
    setGlobalSteal*: proc(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.cdecl.}
    getGlobalProp*:  proc(ctx: ptr ScriptCtx; name: cstring): ScriptValue {.cdecl.}

    # ---- Function binding / calling --------------------------------------
    ## bindGlobal: install a ScriptNativeProc as a named global function.
    bindGlobal*:   proc(ctx: ptr ScriptCtx; name: cstring;
                        fn: ScriptNativeProc; arity: int) {.cdecl.}
    ## bindMethod: install a proc as a property on an object value.
    bindMethod*:   proc(ctx: ptr ScriptCtx; obj: ScriptValue; name: cstring;
                        fn: ScriptNativeProc; arity: int) {.cdecl.}
    ## callFunction: invoke a stored function value.
    callFunction*: proc(ctx: ptr ScriptCtx; fn: ScriptValue; this: ScriptValue;
                        argc: int; argv: ptr ScriptValue): ScriptValue {.cdecl.}
    ## newFunction: wrap a ScriptNativeProc as a ScriptValue (storable/passable).
    newFunction*:  proc(ctx: ptr ScriptCtx; name: cstring;
                        fn: ScriptNativeProc; arity: int): ScriptValue {.cdecl.}

    # ---- GC / Ownership --------------------------------------------------
    dupValue*:  proc(ctx: ptr ScriptCtx; v: ScriptValue): ScriptValue {.cdecl.}
    freeValue*: proc(ctx: ptr ScriptCtx; v: ScriptValue) {.cdecl.}
    runGC*:     proc(ctx: ptr ScriptCtx) {.cdecl.}

    # ---- Microtask / job queue -------------------------------------------
    flushJobs*: proc(ctx: ptr ScriptCtx) {.cdecl.}

    # ---- Exception handling ----------------------------------------------
    getException*:    proc(ctx: ptr ScriptCtx): ScriptValue {.cdecl.}
    ## formatException: returns a human-readable cstring (message + stack).
    ## Caller must call freeCString on the result.
    formatException*: proc(ctx: ptr ScriptCtx; exc: ScriptValue): cstring {.cdecl.}

    # ---- TypedArray / ArrayBuffer (optional — may be nil) ----------------
    newArrayBufferCopy*: proc(ctx: ptr ScriptCtx;
                              data: pointer; len: int): ScriptValue {.cdecl.}
    getArrayBufferData*: proc(ctx: ptr ScriptCtx; v: ScriptValue;
                              outLen: var int): pointer {.cdecl.}

    # ---- Engine metadata -------------------------------------------------
    name*:    cstring
    version*: cstring


# =============================================================================
# Convenience forwarding procs
# Allow callers to write  ctx.newString("hello")  instead of
#   ctx.engine.newString(ctx, "hello")
# The forwarding procs use the engine vtable via ctx.engine.
# =============================================================================

proc newString*(ctx: ptr ScriptCtx; s: cstring): ScriptValue {.inline.} =
  ctx.engine.newString(ctx, s)

proc newStringLen*(ctx: ptr ScriptCtx; s: cstring; len: int): ScriptValue {.inline.} =
  ctx.engine.newStringLen(ctx, s, len)

proc newInt*(ctx: ptr ScriptCtx; i: int32): ScriptValue {.inline.} =
  ctx.engine.newInt(ctx, i)

proc newUint*(ctx: ptr ScriptCtx; u: uint32): ScriptValue {.inline.} =
  ctx.engine.newUint(ctx, u)

proc newFloat*(ctx: ptr ScriptCtx; f: float64): ScriptValue {.inline.} =
  ctx.engine.newFloat(ctx, f)

proc newBool*(ctx: ptr ScriptCtx; b: bool): ScriptValue {.inline.} =
  ctx.engine.newBool(ctx, b)

proc newNull*(ctx: ptr ScriptCtx): ScriptValue {.inline.} =
  ctx.engine.newNull(ctx)

proc newUndefined*(ctx: ptr ScriptCtx): ScriptValue {.inline.} =
  ctx.engine.newUndefined(ctx)

proc newObject*(ctx: ptr ScriptCtx): ScriptValue {.inline.} =
  ctx.engine.newObject(ctx)

proc newArray*(ctx: ptr ScriptCtx): ScriptValue {.inline.} =
  ctx.engine.newArray(ctx)

proc eval*(ctx: ptr ScriptCtx; src: cstring;
           filename: cstring = "<eval>"): ScriptValue {.inline.} =
  ctx.engine.eval(ctx, src, filename)

proc getProp*(ctx: ptr ScriptCtx; obj: ScriptValue;
              key: cstring): ScriptValue {.inline.} =
  ctx.engine.getProp(ctx, obj, key)

proc setProp*(ctx: ptr ScriptCtx; obj: ScriptValue;
              key: cstring; val: ScriptValue) {.inline.} =
  ctx.engine.setProp(ctx, obj, key, val)

proc setPropSteal*(ctx: ptr ScriptCtx; obj: ScriptValue;
                   key: cstring; val: ScriptValue) {.inline.} =
  ctx.engine.setPropSteal(ctx, obj, key, val)

proc getIndex*(ctx: ptr ScriptCtx; arr: ScriptValue;
               idx: uint32): ScriptValue {.inline.} =
  ctx.engine.getIndex(ctx, arr, idx)

proc setIndex*(ctx: ptr ScriptCtx; arr: ScriptValue;
               idx: uint32; val: ScriptValue) {.inline.} =
  ctx.engine.setIndex(ctx, arr, idx, val)

proc setIndexSteal*(ctx: ptr ScriptCtx; arr: ScriptValue;
                    idx: uint32; val: ScriptValue) {.inline.} =
  ## Set array element and consume val (engine takes ownership).
  ctx.engine.setIndex(ctx, arr, idx, val)
  ctx.engine.freeValue(ctx, val)

proc getGlobal*(ctx: ptr ScriptCtx): ScriptValue {.inline.} =
  ctx.engine.getGlobal(ctx)

proc setGlobal*(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.inline.} =
  ctx.engine.setGlobal(ctx, name, val)

proc setGlobalSteal*(ctx: ptr ScriptCtx; name: cstring;
                     val: ScriptValue) {.inline.} =
  ctx.engine.setGlobalSteal(ctx, name, val)

proc getGlobalProp*(ctx: ptr ScriptCtx; name: cstring): ScriptValue {.inline.} =
  ctx.engine.getGlobalProp(ctx, name)

proc bindGlobal*(ctx: ptr ScriptCtx; name: cstring;
                 fn: ScriptNativeProc; arity: int) {.inline.} =
  ctx.engine.bindGlobal(ctx, name, fn, arity)

proc bindMethod*(ctx: ptr ScriptCtx; obj: ScriptValue; name: cstring;
                 fn: ScriptNativeProc; arity: int) {.inline.} =
  ctx.engine.bindMethod(ctx, obj, name, fn, arity)

proc callFunction*(ctx: ptr ScriptCtx; fn: ScriptValue; this: ScriptValue;
                   argc: int; argv: ptr ScriptValue): ScriptValue {.inline.} =
  ctx.engine.callFunction(ctx, fn, this, argc, argv)

proc newFunction*(ctx: ptr ScriptCtx; name: cstring;
                  fn: ScriptNativeProc; arity: int): ScriptValue {.inline.} =
  ctx.engine.newFunction(ctx, name, fn, arity)

proc dupValue*(ctx: ptr ScriptCtx; v: ScriptValue): ScriptValue {.inline.} =
  ctx.engine.dupValue(ctx, v)

proc freeValue*(ctx: ptr ScriptCtx; v: ScriptValue) {.inline.} =
  ctx.engine.freeValue(ctx, v)

proc runGC*(ctx: ptr ScriptCtx) {.inline.} =
  ctx.engine.runGC(ctx)

proc flushJobs*(ctx: ptr ScriptCtx) {.inline.} =
  ctx.engine.flushJobs(ctx)

proc getException*(ctx: ptr ScriptCtx): ScriptValue {.inline.} =
  ctx.engine.getException(ctx)

proc isException*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isException(ctx, v)

proc isNull*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isNull(ctx, v)

proc isUndefined*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isUndefined(ctx, v)

proc isObject*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isObject(ctx, v)

proc isFunction*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isFunction(ctx, v)

proc isString*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isString(ctx, v)

proc isNumber*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isNumber(ctx, v)

proc isBool*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.isBool(ctx, v)

proc toString*(ctx: ptr ScriptCtx; v: ScriptValue): cstring {.inline.} =
  ctx.engine.toString(ctx, v)

proc freeCString*(ctx: ptr ScriptCtx; s: cstring) {.inline.} =
  ctx.engine.freeCString(ctx, s)

proc toInt32*(ctx: ptr ScriptCtx; v: ScriptValue): int32 {.inline.} =
  ctx.engine.toInt32(ctx, v)

proc toUint32*(ctx: ptr ScriptCtx; v: ScriptValue): uint32 {.inline.} =
  ctx.engine.toUint32(ctx, v)

proc toFloat64*(ctx: ptr ScriptCtx; v: ScriptValue): float64 {.inline.} =
  ctx.engine.toFloat64(ctx, v)

proc toBool*(ctx: ptr ScriptCtx; v: ScriptValue): bool {.inline.} =
  ctx.engine.toBool(ctx, v)

proc newArrayBufferCopy*(ctx: ptr ScriptCtx;
                         data: pointer; len: int): ScriptValue {.inline.} =
  assert ctx.engine.newArrayBufferCopy != nil, "engine does not support ArrayBuffer"
  ctx.engine.newArrayBufferCopy(ctx, data, len)

proc getArrayBufferData*(ctx: ptr ScriptCtx; v: ScriptValue;
                         outLen: var int): pointer {.inline.} =
  assert ctx.engine.getArrayBufferData != nil, "engine does not support ArrayBuffer"
  ctx.engine.getArrayBufferData(ctx, v, outLen)

# ---------------------------------------------------------------------------
# Nim-only higher-level helpers (build on top of forwarding procs above)
# ---------------------------------------------------------------------------

proc toNimString*(ctx: ptr ScriptCtx; v: ScriptValue): string =
  ## Convert a ScriptValue to a Nim string. Safe even if engine returns nil.
  let s = ctx.engine.toString(ctx, v)
  if s == nil: return ""
  result = $s
  ctx.engine.freeCString(ctx, s)

proc checkException*(ctx: ptr ScriptCtx; v: ScriptValue;
                     label: string): bool =
  ## If v is an exception, log it, free v, return false.
  ## If v is normal, free v, return true.
  if ctx.engine.isException(ctx, v):
    let exc = ctx.engine.getException(ctx)
    let msg = ctx.engine.formatException(ctx, exc)
    if msg != nil:
      stderr.writeLine("[scripting] exception in '" & label & "': " & $msg)
      ctx.engine.freeCString(ctx, msg)
    ctx.engine.freeValue(ctx, exc)
    ctx.engine.freeValue(ctx, v)
    return false
  ctx.engine.freeValue(ctx, v)
  true

proc callFunction0*(ctx: ptr ScriptCtx;
                    fn: ScriptValue; this: ScriptValue): ScriptValue {.inline.} =
  ## Call fn with zero arguments.
  ctx.engine.callFunction(ctx, fn, this, 0, nil)

proc callFunction1*(ctx: ptr ScriptCtx;
                    fn: ScriptValue; this: ScriptValue;
                    a0: ScriptValue): ScriptValue =
  ## Call fn with one argument (stack-allocated argv).
  var argv = a0
  ctx.engine.callFunction(ctx, fn, this, 1, addr argv)
