# =============================================================================
# rgss/rgss_quickjs.nim
# RGSS ScriptEngine adaptor for QuickJS (QuickJS/quickjs)
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
#   Implements the ScriptEngine vtable (defined in rgss_api.nim) backed
#   by QuickJS.  All vtable procs are {.cdecl.} to match the C-compatible
#   function-pointer fields in ScriptEngine.
#
#   This file is standalone it imports rgss_api.nim and
#   rwebview_ffi_quickjs.nim (via relative path) and compiles the C thunk.
#   It does NOT include rwebview.nim and does NOT touch gState directly.
#
#   Entry point for callers:
#     var eng = newQuickJSEngine()     # fills ScriptEngine vtable
#     eng.initEngine(addr eng)           # creates JSRuntime
#     let ctx = eng.newCtx(addr eng)     # creates JSContext
#     ctx.eval("console.log('hi')", "<test>")
#     ...
#     eng.freeCtx(ctx)
#     eng.destroyEngine(addr eng)
#
#   Integration with rwebview.nim:
#     rwebview.nim stores one global ScriptEngine (gScriptEngine) and one
#     global ScriptCtx (gScriptCtx).  All feature modules (dom, xhr, audio,
#     canvas2d, gl, storage) will accept ptr ScriptCtx once migrated.
#
# Compile note:
#   This file compiles rgss_qjs_thunk.c (relative to its own dir).
#   The include path for quickjs.h is inherited from rwebview.nim's
#   {.passC: "-I" & includeDir.} pragma.
#
# =============================================================================

# Bring in the abstract API types.
# Path is relative to this file's location (rgss/rgss_quickjs.nim).
include "rgss_api"

# Bring in QJS FFI (already included by rwebview.nim via textual include,
# but we also reference it directly here for standalone compilability).
# We only re-include if the marker type JSRuntime is not yet defined.
when not declared(JSRuntime):
  include "rwebview_ffi_quickjs"

# Compile the C thunk that bridges QJS JSCFunction -> ScriptNativeProc.
# {.compile.} requires a string literal; currentSourcePath() is evaluated at
# compile-time so the concatenation works as a constant expression.
{.compile: "rgss_qjs_thunk.c".}

# =============================================================================
# C-side thunk declarations (must match scripting_qjs_thunk.c exactly)
# =============================================================================

type
  NimScriptProcRaw = proc(ctx: pointer;       # ptr ScriptCtx (opaque to C)
                          this_val: ScriptValue;
                          args: ptr ScriptValue;
                          argc: int;
                          env: pointer): ScriptValue {.cdecl.}

proc qjs_bind_native(ctx: ptr JSContext;
                        name: cstring;
                        nim_fn: NimScriptProcRaw;
                        nim_env: pointer;
                        arity: cint): JSValue
    {.importc: "qjs_bind_native".}

proc qjs_thunk_reset()
    {.importc: "qjs_thunk_reset".}

# =============================================================================
# Internal per-engine state
# =============================================================================

type
  QJSState = object
    rt:  ptr JSRuntime

var gQJSState {.threadvar.}: QJSState

# =============================================================================
# ScriptValue <-> JSValue in-place conversion helpers
# =============================================================================
# ScriptValue.data is 2Ã—uint64 = 16 bytes.
# JSValue is {union u: 8 bytes; int64 tag: 8 bytes} = 16 bytes.
# We use copyMem to transfer without aliasing UB.

proc svFromJsv(v: JSValue): ScriptValue {.inline.} =
  copyMem(addr result.data[0], unsafeAddr v, sizeof(JSValue))

proc jsvFromSv(v: ScriptValue): JSValue {.inline.} =
  copyMem(addr result, unsafeAddr v.data[0], sizeof(JSValue))

# =============================================================================
# Vtable proc implementations (all {.cdecl.})
# =============================================================================

# ---- Lifecycle --------------------------------------------------------------

proc qjs_initEngine(eng: ptr ScriptEngine) {.cdecl.} =
  gQJSState.rt = JS_NewRuntime()

proc qjs_destroyEngine(eng: ptr ScriptEngine) {.cdecl.} =
  if gQJSState.rt != nil:
    JS_FreeRuntime(gQJSState.rt)
    gQJSState.rt = nil
  qjs_thunk_reset()

# ---- Context management -----------------------------------------------------

proc qjs_newCtx(eng: ptr ScriptEngine): ptr ScriptCtx {.cdecl.} =
  let jsCtx = JS_NewContext(gQJSState.rt)
  if jsCtx == nil: return nil
  let sctx = cast[ptr ScriptCtx](alloc0(sizeof(ScriptCtx)))
  sctx.engine = eng
  sctx.native = jsCtx
  # Store ScriptCtx* in QJS context opaque so C thunks can retrieve it
  rw_JS_SetContextOpaque(cast[pointer](jsCtx), cast[pointer](sctx))
  sctx

proc qjs_freeCtx(ctx: ptr ScriptCtx) {.cdecl.} =
  if ctx == nil: return
  let jsCtx = cast[ptr JSContext](ctx.native)
  JS_FreeContext(jsCtx)
  dealloc(ctx)

proc qjs_wrapExistingCtx*(eng: ptr ScriptEngine; jsCtx: ptr JSContext): ptr ScriptCtx =
  ## Wrap an already-created JSContext in a ScriptCtx without creating a new
  ## QJS context.  Used by rwebview.nim which manages JSRuntime/JSContext
  ## directly.  Caller must dealloc() the result â€” do NOT call freeCtx() on
  ## it (that would double-free the JSContext).
  let sctx = cast[ptr ScriptCtx](alloc0(sizeof(ScriptCtx)))
  sctx.engine = eng
  sctx.native = jsCtx
  rw_JS_SetContextOpaque(cast[pointer](jsCtx), cast[pointer](sctx))
  sctx

# ---- Evaluation -------------------------------------------------------------

proc qjs_eval(ctx: ptr ScriptCtx; src: cstring; filename: cstring): ScriptValue {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let v = JS_Eval(jsCtx, src, csize_t(src.len), filename, JS_EVAL_TYPE_GLOBAL)
  svFromJsv(v)

# ---- Value constructors -----------------------------------------------------

proc qjs_newString(ctx: ptr ScriptCtx; s: cstring): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_NewString(cast[ptr JSContext](ctx.native), s))

proc qjs_newStringLen(ctx: ptr ScriptCtx; s: cstring; len: int): ScriptValue {.cdecl.} =
  svFromJsv(JS_NewStringLen(cast[ptr JSContext](ctx.native), s, csize_t(len)))

proc qjs_newInt(ctx: ptr ScriptCtx; i: int32): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_NewInt32(cast[ptr JSContext](ctx.native), i))

proc qjs_newUint(ctx: ptr ScriptCtx; u: uint32): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_NewInt32(cast[ptr JSContext](ctx.native), int32(u)))

proc qjs_newFloat(ctx: ptr ScriptCtx; f: float64): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_NewFloat64(cast[ptr JSContext](ctx.native), f))

proc qjs_newBool(ctx: ptr ScriptCtx; b: bool): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_NewBool(cast[ptr JSContext](ctx.native), if b: 1 else: 0))

proc qjs_newNull(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_Null())

proc qjs_newUndefined(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_Undefined())

proc qjs_newObject(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromJsv(JS_NewObject(cast[ptr JSContext](ctx.native)))

proc qjs_newArray(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromJsv(JS_NewArray(cast[ptr JSContext](ctx.native)))

# ---- Value extraction -------------------------------------------------------

proc qjs_toString(ctx: ptr ScriptCtx; v: ScriptValue): cstring {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  JS_ToCStringLen2(jsCtx, nil, jsvFromSv(v), 0)

proc qjs_freeCString(ctx: ptr ScriptCtx; s: cstring) {.cdecl.} =
  JS_FreeCString(cast[ptr JSContext](ctx.native), s)

proc qjs_toInt32(ctx: ptr ScriptCtx; v: ScriptValue): int32 {.cdecl.} =
  var res: int32
  discard JS_ToInt32(cast[ptr JSContext](ctx.native), addr res, jsvFromSv(v))
  res

proc qjs_toUint32(ctx: ptr ScriptCtx; v: ScriptValue): uint32 {.cdecl.} =
  var res: uint32
  discard rw_JS_ToUint32(cast[ptr JSContext](ctx.native), addr res, jsvFromSv(v))
  res

proc qjs_toFloat64(ctx: ptr ScriptCtx; v: ScriptValue): float64 {.cdecl.} =
  var res: float64
  discard JS_ToFloat64(cast[ptr JSContext](ctx.native), addr res, jsvFromSv(v))
  res

proc qjs_toBool(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  qjs_toInt32(ctx, v) != 0

# ---- Type predicates --------------------------------------------------------

proc qjs_isString(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  let tag = rw_JS_VALUE_GET_TAG(jsvFromSv(v))
  tag == 5.cint  # JS_TAG_STRING in QJS internal numbering

proc qjs_isNumber(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  let tag = rw_JS_VALUE_GET_TAG(jsvFromSv(v))
  tag == JS_TAG_INT_C or tag == JS_TAG_FLOAT64_C

proc qjs_isNull(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  rw_JS_VALUE_GET_TAG(jsvFromSv(v)) == JS_TAG_NULL_C

proc qjs_isUndefined(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  rw_JS_VALUE_GET_TAG(jsvFromSv(v)) == JS_TAG_UNDEFINED_C

proc qjs_isObject(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  let tag = rw_JS_VALUE_GET_TAG(jsvFromSv(v))
  tag == -1.cint  # JS_TAG_OBJECT = -1

proc qjs_isFunction(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  JS_IsFunction(cast[ptr JSContext](ctx.native), jsvFromSv(v)) != 0

proc qjs_isException(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  rw_JS_IsException(jsvFromSv(v)) != 0

proc qjs_isBool(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  let tag = rw_JS_VALUE_GET_TAG(jsvFromSv(v))
  tag == 1.cint  # JS_TAG_BOOL

# ---- Object / Array operations ----------------------------------------------

proc qjs_getProp(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring): ScriptValue {.cdecl.} =
  svFromJsv(JS_GetPropertyStr(cast[ptr JSContext](ctx.native), jsvFromSv(obj), key))

proc qjs_setProp(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue) {.cdecl.} =
  ## Dup val before setting â€” JS_SetPropertyStr steals ownership.
  let jsCtx = cast[ptr JSContext](ctx.native)
  let duped = rw_JS_DupValue(jsCtx, jsvFromSv(val))
  discard JS_SetPropertyStr(jsCtx, jsvFromSv(obj), key, duped)

proc qjs_setPropSteal(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue) {.cdecl.} =
  ## Transfer ownership directly â€” caller must NOT free val after this.
  discard JS_SetPropertyStr(cast[ptr JSContext](ctx.native),
                             jsvFromSv(obj), key, jsvFromSv(val))

proc qjs_getIndex(ctx: ptr ScriptCtx; arr: ScriptValue; idx: uint32): ScriptValue {.cdecl.} =
  svFromJsv(JS_GetPropertyUint32(cast[ptr JSContext](ctx.native), jsvFromSv(arr), idx))

proc qjs_setIndex(ctx: ptr ScriptCtx; arr: ScriptValue; idx: uint32; val: ScriptValue) {.cdecl.} =
  ## JS_SetPropertyUint32 steals val â€” dup before.
  let jsCtx = cast[ptr JSContext](ctx.native)
  let duped = rw_JS_DupValue(jsCtx, jsvFromSv(val))
  discard JS_SetPropertyUint32(jsCtx, jsvFromSv(arr), idx, duped)

# ---- Globals ----------------------------------------------------------------

proc qjs_getGlobal(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromJsv(JS_GetGlobalObject(cast[ptr JSContext](ctx.native)))

proc qjs_setGlobal(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.cdecl.} =
  ## Dup val â€” JS_SetPropertyStr steals.
  let jsCtx = cast[ptr JSContext](ctx.native)
  let glb = JS_GetGlobalObject(jsCtx)
  let duped = rw_JS_DupValue(jsCtx, jsvFromSv(val))
  discard JS_SetPropertyStr(jsCtx, glb, name, duped)
  rw_JS_FreeValue(jsCtx, glb)

proc qjs_setGlobalSteal(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.cdecl.} =
  ## Steals val. Caller must NOT free after this.
  let jsCtx = cast[ptr JSContext](ctx.native)
  let glb = JS_GetGlobalObject(jsCtx)
  discard JS_SetPropertyStr(jsCtx, glb, name, jsvFromSv(val))
  rw_JS_FreeValue(jsCtx, glb)

proc qjs_getGlobalProp(ctx: ptr ScriptCtx; name: cstring): ScriptValue {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let glb = JS_GetGlobalObject(jsCtx)
  let v = JS_GetPropertyStr(jsCtx, glb, name)
  rw_JS_FreeValue(jsCtx, glb)
  svFromJsv(v)

# ---- Function binding -------------------------------------------------------

# Nim closure unwrapper: converts ScriptNativeProc (Nim closure) into the raw
# C-callable form that C thunk expects.
# A Nim closure is a {fn_ptr, env_ptr} pair.  We extract these manually.
type NimClosureLayout = object
  fn:  pointer
  env: pointer

proc makeThunkProc(nimClosure: ScriptNativeProc): tuple[fn: NimScriptProcRaw; env: pointer] =
  ## Extract raw fn pointer + env from a Nim closure.
  ## The raw fn has signature matching NimScriptProcRaw (cdecl).
  let layout = cast[ptr NimClosureLayout](unsafeAddr nimClosure)
  # Nim closures: fn pointer is a raw proc(ctx, this, args, argc, env): ScriptValue
  # We cast to NimScriptProcRaw â€” the types match when openArray is decomposed.
  let rawFn = cast[NimScriptProcRaw](layout.fn)
  (rawFn, layout.env)

proc qjs_bindGlobal(ctx: ptr ScriptCtx; name: cstring;
                       fn: ScriptNativeProc; arity: int) {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let (rawFn, env) = makeThunkProc(fn)
  let funcVal = qjs_bind_native(jsCtx, name, rawFn, env, cint(arity))
  # Install on global object (steal ownership)
  let glb = JS_GetGlobalObject(jsCtx)
  discard JS_SetPropertyStr(jsCtx, glb, name, funcVal)
  rw_JS_FreeValue(jsCtx, glb)

proc qjs_bindMethod(ctx: ptr ScriptCtx; obj: ScriptValue; name: cstring;
                       fn: ScriptNativeProc; arity: int) {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let (rawFn, env) = makeThunkProc(fn)
  let funcVal = qjs_bind_native(jsCtx, name, rawFn, env, cint(arity))
  let jsObj = jsvFromSv(obj)
  let rc = JS_SetPropertyStr(jsCtx, jsObj, name, funcVal)
  discard rc

proc qjs_callFunction(ctx: ptr ScriptCtx; fn: ScriptValue; this: ScriptValue;
                         argc: int; argv: ptr ScriptValue): ScriptValue {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let jsFn   = jsvFromSv(fn)
  let jsThis = jsvFromSv(this)
  if argc == 0:
    svFromJsv(JS_Call(jsCtx, jsFn, jsThis, 0, nil))
  else:
    svFromJsv(JS_Call(jsCtx, jsFn, jsThis, cint(argc),
                      cast[ptr JSValue](argv)))

proc qjs_newFunction(ctx: ptr ScriptCtx; name: cstring;
                        fn: ScriptNativeProc; arity: int): ScriptValue {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let (rawFn, env) = makeThunkProc(fn)
  svFromJsv(qjs_bind_native(jsCtx, name, rawFn, env, cint(arity)))

# ---- GC / Ownership ---------------------------------------------------------

proc qjs_dupValue(ctx: ptr ScriptCtx; v: ScriptValue): ScriptValue {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let jsv = jsvFromSv(v)
  let duped = rw_JS_DupValue(jsCtx, jsv)
  svFromJsv(duped)

proc qjs_freeValue(ctx: ptr ScriptCtx; v: ScriptValue) {.cdecl.} =
  rw_JS_FreeValue(cast[ptr JSContext](ctx.native), jsvFromSv(v))

proc qjs_runGC(ctx: ptr ScriptCtx) {.cdecl.} =
  JS_RunGC(gQJSState.rt)

# ---- Job queue --------------------------------------------------------------

proc qjs_flushJobs(ctx: ptr ScriptCtx) {.cdecl.} =
  flushJobs(gQJSState.rt)

# ---- Error handling ---------------------------------------------------------

proc qjs_getException(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromJsv(JS_GetException(cast[ptr JSContext](ctx.native)))

proc qjs_formatException(ctx: ptr ScriptCtx; exc: ScriptValue): cstring {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let jsExc = jsvFromSv(exc)
  # Try to get .message first, fallback to full toString
  let msgVal = JS_GetPropertyStr(jsCtx, jsExc, "message")
  let msgStr = JS_ToCStringLen2(jsCtx, nil, msgVal, 0)
  rw_JS_FreeValue(jsCtx, msgVal)
  if msgStr != nil and msgStr[0] != '\0':
    return msgStr
  if msgStr != nil: JS_FreeCString(jsCtx, msgStr)
  # Fallback: convert exception value itself to string
  JS_ToCStringLen2(jsCtx, nil, jsExc, 0)

# ---- TypedArray / ArrayBuffer -----------------------------------------------

proc qjs_newArrayBufferCopy(ctx: ptr ScriptCtx;
                               data: pointer; len: int): ScriptValue {.cdecl.} =
  svFromJsv(rw_JS_NewArrayBufferCopy(cast[ptr JSContext](ctx.native),
                                      cast[ptr uint8](data), csize_t(len)))

proc qjs_getArrayBufferData(ctx: ptr ScriptCtx; v: ScriptValue;
                               outLen: var int): pointer {.cdecl.} =
  let jsCtx = cast[ptr JSContext](ctx.native)
  let jsv = jsvFromSv(v)
  var size: csize_t
  let buf = JS_GetArrayBuffer(jsCtx, addr size, jsv)
  if buf != nil:
    outLen = int(size)
    return cast[pointer](buf)
  # Try TypedArray â†’ underlying ArrayBuffer
  var byteOffset, byteLength, bytesPerElement: csize_t
  let ab = JS_GetTypedArrayBuffer(jsCtx, jsv,
                                   addr byteOffset, addr byteLength,
                                   addr bytesPerElement)
  if rw_JS_IsException(ab) == 0:
    let abBuf = JS_GetArrayBuffer(jsCtx, addr size, ab)
    rw_JS_FreeValue(jsCtx, ab)
    if abBuf != nil:
      outLen = int(byteLength)
      return cast[pointer](cast[uint](abBuf) + uint(byteOffset))
  else:
    rw_JS_FreeValue(jsCtx, ab)
  outLen = 0
  nil

# =============================================================================
# Factory â€” fill and return a ScriptEngine vtable for QuickJS
# =============================================================================

proc newQuickJSEngine*(): ScriptEngine =
  ## Return a fully-populated ScriptEngine vtable backed by QuickJS.
  ## Caller should call eng.initEngine(addr eng) before use.
  result = ScriptEngine(
    name:    "quickjs",
    version: "0.5.0",   # QuickJS approximate version

    # Lifecycle
    initEngine:    qjs_initEngine,
    destroyEngine: qjs_destroyEngine,

    # Context
    newCtx:  qjs_newCtx,
    freeCtx: qjs_freeCtx,

    # Evaluation
    eval: qjs_eval,

    # Constructors
    newString:    qjs_newString,
    newStringLen: qjs_newStringLen,
    newInt:       qjs_newInt,
    newUint:      qjs_newUint,
    newFloat:     qjs_newFloat,
    newBool:      qjs_newBool,
    newNull:      qjs_newNull,
    newUndefined: qjs_newUndefined,
    newObject:    qjs_newObject,
    newArray:     qjs_newArray,

    # Extraction
    toString:    qjs_toString,
    freeCString: qjs_freeCString,
    toInt32:     qjs_toInt32,
    toUint32:    qjs_toUint32,
    toFloat64:   qjs_toFloat64,
    toBool:      qjs_toBool,

    # Predicates
    isString:    qjs_isString,
    isNumber:    qjs_isNumber,
    isNull:      qjs_isNull,
    isUndefined: qjs_isUndefined,
    isObject:    qjs_isObject,
    isFunction:  qjs_isFunction,
    isException: qjs_isException,
    isBool:      qjs_isBool,

    # Object/Array
    getProp:      qjs_getProp,
    setProp:      qjs_setProp,
    setPropSteal: qjs_setPropSteal,
    getIndex:     qjs_getIndex,
    setIndex:     qjs_setIndex,

    # Globals
    getGlobal:     qjs_getGlobal,
    setGlobal:     qjs_setGlobal,
    setGlobalSteal:qjs_setGlobalSteal,
    getGlobalProp: qjs_getGlobalProp,

    # Binding / calling
    bindGlobal:   qjs_bindGlobal,
    bindMethod:   qjs_bindMethod,
    callFunction: qjs_callFunction,
    newFunction:  qjs_newFunction,

    # GC
    dupValue:  qjs_dupValue,
    freeValue: qjs_freeValue,
    runGC:     qjs_runGC,
    flushJobs: qjs_flushJobs,

    # Error
    getException:    qjs_getException,
    formatException: qjs_formatException,

    # TypedArray
    newArrayBufferCopy: qjs_newArrayBufferCopy,
    getArrayBufferData: qjs_getArrayBufferData,
  )
