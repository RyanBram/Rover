# =============================================================================
# rgss/rgss_mquickjs.nim
# RGSS ScriptEngine adaptor for MicroQuickJS (mquickjs)
# =============================================================================
#
# Author    : Ryan Bramantya
# Copyright : Copyright (c) 2026 Ryan Bramantya
# License   : Apache License 2.0
# Website   : https://github.com/RyanBram/Rover
#
# Description:
#   Implements the ScriptEngine vtable (defined in rgss_api.nim) backed
#   by patched MicroQuickJS. Opt-in via -d:withMQuickJS at compile time.
#
#   Key differences from QuickJS-NG adaptor (rgss_quickjs.nim):
#     - JSValue is 8 bytes (uint64) stored in ScriptValue.data[0]; data[1]=0
#     - No JSRuntime — context created with pre-allocated memory pool
#     - No ref counting — freeValue/dupValue are no-ops
#     - No job queue — flushJobs is a no-op
#     - No ArrayBuffer/TypedArray — stubs returning nil/empty
#     - GC via JS_GC(ctx) not JS_RunGC(rt)
#     - Strings are GC-managed; no JS_FreeCString needed
#
# =============================================================================

# Bring in the abstract API types.
include "rgss_api"

# Bring in mquickjs FFI (only when this file is compiled).
when not declared(MQJSContext):
  include "rgss_mquickjs_ffi"

# Compile the amalgamated mquickjs source (prefix + all .c files).
# Path is relative to this file (rgss/).
{.compile: "../c_src/rwebview_mquickjs_all.c".}

# Compile the C thunk.
# Tell the compiler where to find mquickjs headers.
{.passC: "-I" & currentSourcePath().parentDir() & "/../libs/mquickjs".}
{.compile: "rgss_mqjs_thunk.c".}

# =============================================================================
# C-side thunk declarations
# =============================================================================

type
  NimScriptProcRaw = proc(ctx: pointer;
                          this_val: ScriptValue;
                          args: ptr ScriptValue;
                          argc: int;
                          env: pointer): ScriptValue {.cdecl.}

proc mqjs_bind_native(ctx: ptr MQJSContext;
                       name: cstring;
                       nim_fn: NimScriptProcRaw;
                       nim_env: pointer;
                       arity: cint): MQJSValue
    {.importc: "mqjs_bind_native".}

proc mqjs_thunk_reset()
    {.importc: "mqjs_thunk_reset".}

# =============================================================================
# Internal per-engine state
# =============================================================================

const
  MQJS_MEM_POOL_SIZE = 4 * 1024 * 1024  # 4 MB default memory pool

type
  MQJSState = object
    memPool: pointer    # heap-allocated memory pool for mquickjs context
    memSize: int

var gMQJSState {.threadvar.}: MQJSState

# =============================================================================
# ScriptValue <-> MQJSValue conversion helpers
# =============================================================================
# ScriptValue.data is 2×uint64 = 16 bytes.
# MQJSValue is uint64 = 8 bytes.
# Store MQJSValue in data[0], data[1] = 0.

proc svFromMqjs(v: MQJSValue): ScriptValue {.inline.} =
  result.data[0] = uint64(v)
  result.data[1] = 0

proc mqjsFromSv(v: ScriptValue): MQJSValue {.inline.} =
  MQJSValue(v.data[0])

# =============================================================================
# Vtable proc implementations (all {.cdecl.})
# =============================================================================

# ---- Lifecycle --------------------------------------------------------------

proc mqjs_initEngine(eng: ptr ScriptEngine) {.cdecl.} =
  # Pre-allocate the memory pool (will be used when creating context)
  gMQJSState.memSize = MQJS_MEM_POOL_SIZE
  gMQJSState.memPool = alloc(MQJS_MEM_POOL_SIZE)

proc mqjs_destroyEngine(eng: ptr ScriptEngine) {.cdecl.} =
  if gMQJSState.memPool != nil:
    dealloc(gMQJSState.memPool)
    gMQJSState.memPool = nil
  mqjs_thunk_reset()

# ---- Context management -----------------------------------------------------

proc mqjs_newCtx(eng: ptr ScriptEngine): ptr ScriptCtx {.cdecl.} =
  if gMQJSState.memPool == nil: return nil
  let mqCtx = mqjs_JS_NewContext(gMQJSState.memPool,
                                  csize_t(gMQJSState.memSize),
                                  addr mqjs_stdlib_def)
  if mqCtx == nil: return nil
  let sctx = cast[ptr ScriptCtx](alloc0(sizeof(ScriptCtx)))
  sctx.engine = eng
  sctx.native = mqCtx
  mqjs_JS_SetContextOpaque(mqCtx, cast[pointer](sctx))
  sctx

proc mqjs_freeCtx(ctx: ptr ScriptCtx) {.cdecl.} =
  if ctx == nil: return
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  mqjs_JS_FreeContext(mqCtx)
  dealloc(ctx)

# ---- Evaluation -------------------------------------------------------------

proc mqjs_eval(ctx: ptr ScriptCtx; src: cstring; filename: cstring): ScriptValue {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let v = mqjs_JS_Eval(mqCtx, src, csize_t(src.len), filename, MQJS_EVAL_RETVAL)
  svFromMqjs(v)

# ---- Value constructors -----------------------------------------------------

proc mqjs_newString(ctx: ptr ScriptCtx; s: cstring): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewString(cast[ptr MQJSContext](ctx.native), s))

proc mqjs_newStringLen(ctx: ptr ScriptCtx; s: cstring; len: int): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewStringLen(cast[ptr MQJSContext](ctx.native), s, csize_t(len)))

proc mqjs_newInt(ctx: ptr ScriptCtx; i: int32): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewInt32(cast[ptr MQJSContext](ctx.native), i))

proc mqjs_newUint(ctx: ptr ScriptCtx; u: uint32): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewUint32(cast[ptr MQJSContext](ctx.native), u))

proc mqjs_newFloat(ctx: ptr ScriptCtx; f: float64): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewFloat64(cast[ptr MQJSContext](ctx.native), f))

proc mqjs_newBool(ctx: ptr ScriptCtx; b: bool): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_rw_NewBool(if b: 1 else: 0))

proc mqjs_newNull(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_rw_Null())

proc mqjs_newUndefined(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_rw_Undefined())

proc mqjs_newObject(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewObject(cast[ptr MQJSContext](ctx.native)))

proc mqjs_newArray(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_NewArray(cast[ptr MQJSContext](ctx.native), 0))

# ---- Value extraction -------------------------------------------------------

proc mqjs_toString(ctx: ptr ScriptCtx; v: ScriptValue): cstring {.cdecl.} =
  ## Returns a cstring that is valid until next GC cycle.
  ## mquickjs manages strings via GC — no FreeCString needed.
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  var buf: MQJSCStringBuf
  mqjs_JS_ToCStringLen(mqCtx, nil, mqjsFromSv(v), addr buf)

proc mqjs_freeCString(ctx: ptr ScriptCtx; s: cstring) {.cdecl.} =
  # mquickjs strings are GC-managed — no explicit free needed.
  discard

proc mqjs_toInt32(ctx: ptr ScriptCtx; v: ScriptValue): int32 {.cdecl.} =
  var res: cint
  discard mqjs_JS_ToInt32(cast[ptr MQJSContext](ctx.native), addr res, mqjsFromSv(v))
  int32(res)

proc mqjs_toUint32(ctx: ptr ScriptCtx; v: ScriptValue): uint32 {.cdecl.} =
  var res: uint32
  discard mqjs_JS_ToUint32(cast[ptr MQJSContext](ctx.native), addr res, mqjsFromSv(v))
  res

proc mqjs_toFloat64(ctx: ptr ScriptCtx; v: ScriptValue): float64 {.cdecl.} =
  var res: float64
  discard mqjs_JS_ToNumber(cast[ptr MQJSContext](ctx.native), addr res, mqjsFromSv(v))
  res

proc mqjs_toBool(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  # Check for bool tag or convert via int
  let val = mqjsFromSv(v)
  if mqjs_rw_IsBool(val) != 0:
    return mqjsGetSpecialValue(val) != 0
  mqjs_toInt32(ctx, v) != 0

# ---- Type predicates --------------------------------------------------------

proc mqjs_isString(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_JS_IsString(cast[ptr MQJSContext](ctx.native), mqjsFromSv(v)) != 0

proc mqjs_isNumber(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_JS_IsNumber(cast[ptr MQJSContext](ctx.native), mqjsFromSv(v)) != 0

proc mqjs_isNull(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_rw_IsNull(mqjsFromSv(v)) != 0

proc mqjs_isUndefined(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_rw_IsUndefined(mqjsFromSv(v)) != 0

proc mqjs_isObject(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  # In mquickjs, objects are pointer-tagged values (JS_TAG_PTR)
  let val = mqjsFromSv(v)
  mqjs_rw_IsInt(val) == 0 and (val and (8 - 1)) == uint64(MQJS_TAG_PTR)  # JSW=8, TAG_PTR=1

proc mqjs_isFunction(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_JS_IsFunction(cast[ptr MQJSContext](ctx.native), mqjsFromSv(v)) != 0

proc mqjs_isException(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_rw_IsException(mqjsFromSv(v)) != 0

proc mqjs_isBool(ctx: ptr ScriptCtx; v: ScriptValue): bool {.cdecl.} =
  mqjs_rw_IsBool(mqjsFromSv(v)) != 0

# ---- Object / Array operations ----------------------------------------------

proc mqjs_getProp(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_GetPropertyStr(cast[ptr MQJSContext](ctx.native), mqjsFromSv(obj), key))

proc mqjs_setProp(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue) {.cdecl.} =
  # mquickjs: JS_SetPropertyStr does NOT steal ownership (no ref counting).
  # We just set directly.
  discard mqjs_JS_SetPropertyStr(cast[ptr MQJSContext](ctx.native),
                                  mqjsFromSv(obj), key, mqjsFromSv(val))

proc mqjs_setPropSteal(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue) {.cdecl.} =
  # Same as setProp — no ownership semantics in mquickjs (GC handles everything).
  discard mqjs_JS_SetPropertyStr(cast[ptr MQJSContext](ctx.native),
                                  mqjsFromSv(obj), key, mqjsFromSv(val))

proc mqjs_getIndex(ctx: ptr ScriptCtx; arr: ScriptValue; idx: uint32): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_GetPropertyUint32(cast[ptr MQJSContext](ctx.native), mqjsFromSv(arr), idx))

proc mqjs_setIndex(ctx: ptr ScriptCtx; arr: ScriptValue; idx: uint32; val: ScriptValue) {.cdecl.} =
  discard mqjs_JS_SetPropertyUint32(cast[ptr MQJSContext](ctx.native),
                                     mqjsFromSv(arr), idx, mqjsFromSv(val))

# ---- Globals ----------------------------------------------------------------

proc mqjs_getGlobal(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_GetGlobalObject(cast[ptr MQJSContext](ctx.native)))

proc mqjs_setGlobal(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let glb = mqjs_JS_GetGlobalObject(mqCtx)
  discard mqjs_JS_SetPropertyStr(mqCtx, glb, name, mqjsFromSv(val))

proc mqjs_setGlobalSteal(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue) {.cdecl.} =
  # Same as setGlobal — no steal semantics in mquickjs.
  mqjs_setGlobal(ctx, name, val)

proc mqjs_getGlobalProp(ctx: ptr ScriptCtx; name: cstring): ScriptValue {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let glb = mqjs_JS_GetGlobalObject(mqCtx)
  svFromMqjs(mqjs_JS_GetPropertyStr(mqCtx, glb, name))

# ---- Function binding -------------------------------------------------------

type NimClosureLayout = object
  fn:  pointer
  env: pointer

proc mqjsMakeThunkProc(nimClosure: ScriptNativeProc): tuple[fn: NimScriptProcRaw; env: pointer] =
  let layout = cast[ptr NimClosureLayout](unsafeAddr nimClosure)
  let rawFn = cast[NimScriptProcRaw](layout.fn)
  (rawFn, layout.env)

proc mqjs_bindGlobal(ctx: ptr ScriptCtx; name: cstring;
                      fn: ScriptNativeProc; arity: int) {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let (rawFn, env) = mqjsMakeThunkProc(fn)
  let funcVal = mqjs_bind_native(mqCtx, name, rawFn, env, cint(arity))
  let glb = mqjs_JS_GetGlobalObject(mqCtx)
  discard mqjs_JS_SetPropertyStr(mqCtx, glb, name, funcVal)

proc mqjs_bindMethod(ctx: ptr ScriptCtx; obj: ScriptValue; name: cstring;
                      fn: ScriptNativeProc; arity: int) {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let (rawFn, env) = mqjsMakeThunkProc(fn)
  let funcVal = mqjs_bind_native(mqCtx, name, rawFn, env, cint(arity))
  discard mqjs_JS_SetPropertyStr(mqCtx, mqjsFromSv(obj), name, funcVal)

proc mqjs_callFunction(ctx: ptr ScriptCtx; fn: ScriptValue; this: ScriptValue;
                        argc: int; argv: ptr ScriptValue): ScriptValue {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let mqFn   = mqjsFromSv(fn)
  let mqThis = mqjsFromSv(this)
  if argc == 0:
    svFromMqjs(mqjs_CallFunction(mqCtx, mqFn, mqThis, 0, nil))
  else:
    # argv is ptr ScriptValue (16 bytes each), but we need ptr MQJSValue (8 bytes each).
    # Must convert each argument.
    var mqArgs = newSeq[MQJSValue](argc)
    for i in 0 ..< argc:
      let sv = cast[ptr UncheckedArray[ScriptValue]](argv)[i]
      mqArgs[i] = mqjsFromSv(sv)
    svFromMqjs(mqjs_CallFunction(mqCtx, mqFn, mqThis, cint(argc), addr mqArgs[0]))

proc mqjs_newFunction(ctx: ptr ScriptCtx; name: cstring;
                       fn: ScriptNativeProc; arity: int): ScriptValue {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let (rawFn, env) = mqjsMakeThunkProc(fn)
  svFromMqjs(mqjs_bind_native(mqCtx, name, rawFn, env, cint(arity)))

# ---- GC / Ownership ---------------------------------------------------------

proc mqjs_dupValue(ctx: ptr ScriptCtx; v: ScriptValue): ScriptValue {.cdecl.} =
  # No ref counting in mquickjs — just return the value as-is.
  v

proc mqjs_freeValue(ctx: ptr ScriptCtx; v: ScriptValue) {.cdecl.} =
  # No ref counting — GC handles everything. No-op.
  discard

proc mqjs_runGC(ctx: ptr ScriptCtx) {.cdecl.} =
  mqjs_JS_GC(cast[ptr MQJSContext](ctx.native))

# ---- Job queue --------------------------------------------------------------

proc mqjs_flushJobs(ctx: ptr ScriptCtx) {.cdecl.} =
  # mquickjs has no job queue / Promise support. No-op.
  discard

# ---- Error handling ---------------------------------------------------------

proc mqjs_getException(ctx: ptr ScriptCtx): ScriptValue {.cdecl.} =
  svFromMqjs(mqjs_JS_GetException(cast[ptr MQJSContext](ctx.native)))

proc mqjs_formatException(ctx: ptr ScriptCtx; exc: ScriptValue): cstring {.cdecl.} =
  let mqCtx = cast[ptr MQJSContext](ctx.native)
  let mqExc = mqjsFromSv(exc)
  # Try .message property first
  let msgVal = mqjs_JS_GetPropertyStr(mqCtx, mqExc, "message")
  var buf: MQJSCStringBuf
  let msgStr = mqjs_JS_ToCStringLen(mqCtx, nil, msgVal, addr buf)
  if msgStr != nil and msgStr[0] != '\0':
    return msgStr
  # Fallback: convert exception to string
  mqjs_JS_ToCStringLen(mqCtx, nil, mqExc, addr buf)

# ---- TypedArray / ArrayBuffer (stubs) ---------------------------------------

proc mqjs_newArrayBufferCopy(ctx: ptr ScriptCtx;
                              data: pointer; len: int): ScriptValue {.cdecl.} =
  # mquickjs has limited ArrayBuffer support — return undefined for now.
  svFromMqjs(mqjs_rw_Undefined())

proc mqjs_getArrayBufferData(ctx: ptr ScriptCtx; v: ScriptValue;
                              outLen: var int): pointer {.cdecl.} =
  outLen = 0
  nil

# =============================================================================
# Factory
# =============================================================================

proc newMQuickJSEngine*(): ScriptEngine =
  result = ScriptEngine(
    name:    "mquickjs",
    version: "1.0.0",

    # Lifecycle
    initEngine:    mqjs_initEngine,
    destroyEngine: mqjs_destroyEngine,

    # Context
    newCtx:  mqjs_newCtx,
    freeCtx: mqjs_freeCtx,

    # Evaluation
    eval: mqjs_eval,

    # Constructors
    newString:    mqjs_newString,
    newStringLen: mqjs_newStringLen,
    newInt:       mqjs_newInt,
    newUint:      mqjs_newUint,
    newFloat:     mqjs_newFloat,
    newBool:      mqjs_newBool,
    newNull:      mqjs_newNull,
    newUndefined: mqjs_newUndefined,
    newObject:    mqjs_newObject,
    newArray:     mqjs_newArray,

    # Extraction
    toString:    mqjs_toString,
    freeCString: mqjs_freeCString,
    toInt32:     mqjs_toInt32,
    toUint32:    mqjs_toUint32,
    toFloat64:   mqjs_toFloat64,
    toBool:      mqjs_toBool,

    # Predicates
    isString:    mqjs_isString,
    isNumber:    mqjs_isNumber,
    isNull:      mqjs_isNull,
    isUndefined: mqjs_isUndefined,
    isObject:    mqjs_isObject,
    isFunction:  mqjs_isFunction,
    isException: mqjs_isException,
    isBool:      mqjs_isBool,

    # Object/Array
    getProp:      mqjs_getProp,
    setProp:      mqjs_setProp,
    setPropSteal: mqjs_setPropSteal,
    getIndex:     mqjs_getIndex,
    setIndex:     mqjs_setIndex,

    # Globals
    getGlobal:     mqjs_getGlobal,
    setGlobal:     mqjs_setGlobal,
    setGlobalSteal:mqjs_setGlobalSteal,
    getGlobalProp: mqjs_getGlobalProp,

    # Binding / calling
    bindGlobal:   mqjs_bindGlobal,
    bindMethod:   mqjs_bindMethod,
    callFunction: mqjs_callFunction,
    newFunction:  mqjs_newFunction,

    # GC
    dupValue:  mqjs_dupValue,
    freeValue: mqjs_freeValue,
    runGC:     mqjs_runGC,
    flushJobs: mqjs_flushJobs,

    # Error
    getException:    mqjs_getException,
    formatException: mqjs_formatException,

    # TypedArray (stubs)
    newArrayBufferCopy: mqjs_newArrayBufferCopy,
    getArrayBufferData: mqjs_getArrayBufferData,
  )
