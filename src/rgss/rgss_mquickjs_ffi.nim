# =============================================================================
# rgss/rgss_mquickjs_ffi.nim
# MicroQuickJS FFI types and function declarations (prefixed with mqjs_)
# =============================================================================
#
# Author    : Ryan Bramantya
# Copyright : Copyright (c) 2026 Ryan Bramantya
# License   : Apache License 2.0
# Website   : https://github.com/RyanBram/Rover
#
# Description:
#   Declares the Nim FFI bindings for the mqjs_-prefixed MicroQuickJS API.
#   All symbols are renamed via mqjs_prefix.h at C compile time.
#
#   Key differences from QuickJS-NG (rgss_quickjs_ffi.nim):
#     - JSValue is uint64 (8 bytes) not a 16-byte struct
#     - No JSRuntime — context created with memory pool + stdlib
#     - No ref counting (no FreeValue / DupValue)
#     - No job queue (no Promises)
#     - Strings use JSCStringBuf (stack buffer), no FreeCString needed
#     - JS_Call is stack-based (we use mqjs_CallFunction wrapper)
#     - JSCFunction receives this_val as pointer, not value
#
# Included by:
#   - rgss/rgss_mquickjs.nim
#
# =============================================================================

type
  MQJSContext = object   # opaque (JSContext in mquickjs)

  # JSValue in mquickjs (64-bit): uint64_t, NaN-boxed
  MQJSValue* = uint64

  # JSCStringBuf — 5-byte stack buffer for JS_ToCStringLen
  MQJSCStringBuf* = array[5, uint8]

  # MicroQuickJS JSCFunction: note this_val is a POINTER (JSValue*)
  MQJSCFunction* =
    proc(ctx: ptr MQJSContext; thisVal: ptr MQJSValue;
         argc: cint; argv: ptr MQJSValue): MQJSValue {.cdecl.}

  # JSCFunction with magic parameter
  MQJSCFunctionMagic* =
    proc(ctx: ptr MQJSContext; thisVal: ptr MQJSValue;
         argc: cint; argv: ptr MQJSValue; magic: cint): MQJSValue {.cdecl.}

  # JSSTDLibraryDef (opaque — we just pass a pointer)
  MQJSSTDLibraryDef = object

# ===========================================================================
# Constants (matching mquickjs.h tag definitions)
# ===========================================================================
const
  MQJS_TAG_INT*         = 0
  MQJS_TAG_PTR*         = 1
  MQJS_TAG_SPECIAL*     = 3
  MQJS_TAG_BOOL*        = 3   # JS_TAG_SPECIAL | (0 << 2)
  MQJS_TAG_NULL*        = 7   # JS_TAG_SPECIAL | (1 << 2)
  MQJS_TAG_UNDEFINED*   = 11  # JS_TAG_SPECIAL | (2 << 2)
  MQJS_TAG_EXCEPTION*   = 15  # JS_TAG_SPECIAL | (3 << 2)
  MQJS_TAG_SHORT_FUNC*  = 19  # JS_TAG_SPECIAL | (4 << 2)
  MQJS_TAG_SPECIAL_BITS = 5

  MQJS_EVAL_RETVAL* = (1 shl 0).cint
  MQJS_EVAL_JSON*   = (1 shl 3).cint

  MQJS_CFUNC_generic*       = 0.cint
  MQJS_CFUNC_generic_magic* = 1.cint

# ===========================================================================
# Inline value helpers (matching mquickjs.h macros)
# ===========================================================================
proc mqjsMakeSpecial(tag: int; v: int): MQJSValue {.inline.} =
  MQJSValue(uint64(tag) or (uint64(v) shl MQJS_TAG_SPECIAL_BITS))

proc mqjsGetSpecialTag(v: MQJSValue): int {.inline.} =
  int(v and ((1'u64 shl MQJS_TAG_SPECIAL_BITS) - 1))

proc mqjsGetSpecialValue(v: MQJSValue): int {.inline.} =
  int(cast[int32](v) shr MQJS_TAG_SPECIAL_BITS)

# ===========================================================================
# Stdlib definition (defined in mqjs_stdlib.h, renamed to mqjs_stdlib_def)
# ===========================================================================
var mqjs_stdlib_def* {.importc: "mqjs_stdlib_def".}: MQJSSTDLibraryDef

# ===========================================================================
# Core API (non-inline, linked via amalgamated rwebview_mquickjs_all.c)
# All symbols use mqjs_ prefix per mqjs_prefix.h
# ===========================================================================

proc mqjs_JS_NewContext(memStart: pointer; memSize: csize_t;
                        stdlibDef: ptr MQJSSTDLibraryDef): ptr MQJSContext
    {.importc: "mqjs_JS_NewContext".}
proc mqjs_JS_FreeContext(ctx: ptr MQJSContext)
    {.importc: "mqjs_JS_FreeContext".}
proc mqjs_JS_SetContextOpaque(ctx: ptr MQJSContext; opaque: pointer)
    {.importc: "mqjs_JS_SetContextOpaque".}
proc mqjs_JS_GetContextOpaque(ctx: ptr MQJSContext): pointer
    {.importc: "mqjs_JS_GetContextOpaque".}

proc mqjs_JS_Eval(ctx: ptr MQJSContext; input: cstring; inputLen: csize_t;
                   filename: cstring; evalFlags: cint): MQJSValue
    {.importc: "mqjs_JS_Eval".}
proc mqjs_JS_GetGlobalObject(ctx: ptr MQJSContext): MQJSValue
    {.importc: "mqjs_JS_GetGlobalObject".}
proc mqjs_JS_GetException(ctx: ptr MQJSContext): MQJSValue
    {.importc: "mqjs_JS_GetException".}
proc mqjs_JS_Throw(ctx: ptr MQJSContext; obj: MQJSValue): MQJSValue
    {.importc: "mqjs_JS_Throw".}

# Value constructors
proc mqjs_JS_NewObject(ctx: ptr MQJSContext): MQJSValue
    {.importc: "mqjs_JS_NewObject".}
proc mqjs_JS_NewArray(ctx: ptr MQJSContext; initialLen: cint): MQJSValue
    {.importc: "mqjs_JS_NewArray".}
proc mqjs_JS_NewString(ctx: ptr MQJSContext; buf: cstring): MQJSValue
    {.importc: "mqjs_JS_NewString".}
proc mqjs_JS_NewStringLen(ctx: ptr MQJSContext; buf: cstring;
                           bufLen: csize_t): MQJSValue
    {.importc: "mqjs_JS_NewStringLen".}
proc mqjs_JS_NewInt32(ctx: ptr MQJSContext; val: int32): MQJSValue
    {.importc: "mqjs_JS_NewInt32".}
proc mqjs_JS_NewUint32(ctx: ptr MQJSContext; val: uint32): MQJSValue
    {.importc: "mqjs_JS_NewUint32".}
proc mqjs_JS_NewFloat64(ctx: ptr MQJSContext; d: float64): MQJSValue
    {.importc: "mqjs_JS_NewFloat64".}

# Property access
proc mqjs_JS_GetPropertyStr(ctx: ptr MQJSContext; thisObj: MQJSValue;
                             str: cstring): MQJSValue
    {.importc: "mqjs_JS_GetPropertyStr".}
proc mqjs_JS_SetPropertyStr(ctx: ptr MQJSContext; thisObj: MQJSValue;
                             str: cstring; val: MQJSValue): MQJSValue
    {.importc: "mqjs_JS_SetPropertyStr".}
proc mqjs_JS_GetPropertyUint32(ctx: ptr MQJSContext; obj: MQJSValue;
                                idx: uint32): MQJSValue
    {.importc: "mqjs_JS_GetPropertyUint32".}
proc mqjs_JS_SetPropertyUint32(ctx: ptr MQJSContext; thisObj: MQJSValue;
                                idx: uint32; val: MQJSValue): MQJSValue
    {.importc: "mqjs_JS_SetPropertyUint32".}

# String extraction
proc mqjs_JS_ToCStringLen(ctx: ptr MQJSContext; plen: ptr csize_t;
                           val: MQJSValue; buf: ptr MQJSCStringBuf): cstring
    {.importc: "mqjs_JS_ToCStringLen".}
proc mqjs_JS_ToCString(ctx: ptr MQJSContext; val: MQJSValue;
                        buf: ptr MQJSCStringBuf): cstring
    {.importc: "mqjs_JS_ToCString".}
proc mqjs_JS_ToString(ctx: ptr MQJSContext; val: MQJSValue): MQJSValue
    {.importc: "mqjs_JS_ToString".}

# Numeric conversion
proc mqjs_JS_ToInt32(ctx: ptr MQJSContext; pres: ptr cint;
                      val: MQJSValue): cint
    {.importc: "mqjs_JS_ToInt32".}
proc mqjs_JS_ToUint32(ctx: ptr MQJSContext; pres: ptr uint32;
                       val: MQJSValue): cint
    {.importc: "mqjs_JS_ToUint32".}
proc mqjs_JS_ToNumber(ctx: ptr MQJSContext; pres: ptr float64;
                       val: MQJSValue): cint
    {.importc: "mqjs_JS_ToNumber".}

# Type predicates (non-inline)
proc mqjs_JS_IsFunction(ctx: ptr MQJSContext; val: MQJSValue): cint
    {.importc: "mqjs_JS_IsFunction".}
proc mqjs_JS_IsString(ctx: ptr MQJSContext; val: MQJSValue): cint
    {.importc: "mqjs_JS_IsString".}
proc mqjs_JS_IsNumber(ctx: ptr MQJSContext; val: MQJSValue): cint
    {.importc: "mqjs_JS_IsNumber".}
proc mqjs_JS_IsError(ctx: ptr MQJSContext; val: MQJSValue): cint
    {.importc: "mqjs_JS_IsError".}

# Opaque user data on objects
proc mqjs_JS_SetOpaque(ctx: ptr MQJSContext; val: MQJSValue; opaque: pointer)
    {.importc: "mqjs_JS_SetOpaque".}
proc mqjs_JS_GetOpaque(ctx: ptr MQJSContext; val: MQJSValue): pointer
    {.importc: "mqjs_JS_GetOpaque".}

# Dynamic function creation (Rover extension)
proc mqjs_JS_NewCFunctionMagic(ctx: ptr MQJSContext;
    fn: MQJSCFunctionMagic; name: cstring;
    length: cint; cproto: cint; magic: cint): MQJSValue
    {.importc: "mqjs_JS_NewCFunctionMagic".}

# GC
proc mqjs_JS_GC(ctx: ptr MQJSContext)
    {.importc: "mqjs_JS_GC".}
proc mqjs_JS_StackCheck(ctx: ptr MQJSContext; len: uint32): cint
    {.importc: "mqjs_JS_StackCheck".}
proc mqjs_JS_PushArg(ctx: ptr MQJSContext; val: MQJSValue)
    {.importc: "mqjs_JS_PushArg".}

# ===========================================================================
# Inline-function wrappers (from rwebview_mquickjs_all.c)
# ===========================================================================

proc mqjs_rw_IsException(v: MQJSValue): cint   {.importc: "mqjs_rw_IsException".}
proc mqjs_rw_IsNull(v: MQJSValue): cint        {.importc: "mqjs_rw_IsNull".}
proc mqjs_rw_IsUndefined(v: MQJSValue): cint   {.importc: "mqjs_rw_IsUndefined".}
proc mqjs_rw_IsBool(v: MQJSValue): cint        {.importc: "mqjs_rw_IsBool".}
proc mqjs_rw_IsInt(v: MQJSValue): cint         {.importc: "mqjs_rw_IsInt".}

proc mqjs_rw_Undefined(): MQJSValue   {.importc: "mqjs_rw_Undefined".}
proc mqjs_rw_Null(): MQJSValue        {.importc: "mqjs_rw_Null".}
proc mqjs_rw_True(): MQJSValue        {.importc: "mqjs_rw_True".}
proc mqjs_rw_False(): MQJSValue       {.importc: "mqjs_rw_False".}
proc mqjs_rw_Exception(): MQJSValue   {.importc: "mqjs_rw_Exception".}
proc mqjs_rw_NewBool(v: cint): MQJSValue {.importc: "mqjs_rw_NewBool".}

# Convenience call wrapper (argc/argv style)
proc mqjs_CallFunction(ctx: ptr MQJSContext; funcObj: MQJSValue;
                        thisObj: MQJSValue; argc: cint;
                        argv: ptr MQJSValue): MQJSValue
    {.importc: "mqjs_CallFunction".}

# ===========================================================================
# Nim helpers
# ===========================================================================

proc mqjsToCString*(ctx: ptr MQJSContext; v: MQJSValue): cstring {.inline.} =
  ## Convert a JS string value to cstring using stack-allocated buffer.
  ## The returned string is valid only until the next GC cycle.
  ## (mquickjs strings are GC-managed; no JS_FreeCString needed.)
  var buf: MQJSCStringBuf
  mqjs_JS_ToCStringLen(ctx, nil, v, addr buf)

proc mqjsValToStr*(ctx: ptr MQJSContext; v: MQJSValue): string =
  ## Convert a JS value to a Nim string (copies the data).
  var buf: MQJSCStringBuf
  let s = mqjs_JS_ToCStringLen(ctx, nil, v, addr buf)
  if s == nil: return "undefined"
  result = $s
  # No JS_FreeCString needed — mquickjs manages strings via GC

proc mqjsCheck*(ctx: ptr MQJSContext; v: MQJSValue; label: string): bool =
  ## Return false and log if v is an exception.
  if mqjs_rw_IsException(v) != 0:
    let exc = mqjs_JS_GetException(ctx)
    var buf: MQJSCStringBuf
    let msg = mqjs_JS_ToCStringLen(ctx, nil, exc, addr buf)
    if msg != nil:
      stderr.writeLine("[mquickjs] JS exception in '" & label & "': " & $msg)
    return false
  true
