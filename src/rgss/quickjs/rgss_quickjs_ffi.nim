# =============================================================================
# rgss_quickjs_ffi.nim
# QuickJS FFI types and function declarations
# =============================================================================
#
# This file declares the Nim FFI bindings for QuickJS (quickjs-ng/quickjs).
# The header (bin/include/quickjs.h) and library (bin/lib/libqjs.a) are both
# from the QuickJS project â€” NOT the original Fabrice Bellard QuickJS.
#
# Key differences from original QuickJS:
#   - JS_BOOL is removed (uses C99 bool directly)
#   - JS_IsJobPending returns bool (not int)
#   - JS_NewCFunction3 added
#   - All public APIs are marked JS_EXTERN (__declspec(dllexport) on Windows)
#   - JSValue layout is the same on x86_64 (struct {union u; int64_t tag;})
#
# Author    : Ryan Bramantya
# Copyright : Copyright (c) 2026 Ryan Bramantya
# License   : Apache License 2.0
# Website   : https://github.com/RyanBram/Rover
#
# -----------------------------------------------------------------------------
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# -----------------------------------------------------------------------------
#
# Description:
#   QuickJS FFI types and constants.
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   None.
#
# Used by:
#   - rwebview.nim             # included before rwebview_html.nim
#   - rgss/rgss_quickjs.nim    # when compiled standalone
#
# =============================================================================
#
# JSValue in the non-NaN-boxing struct build:
#   typedef struct JSValue { JSValueUnion u; int64_t tag; } JSValue;   -- 16 bytes
# Nim {.bycopy.} ensures the struct is passed by value matching C ABI.

type
  JSRuntime = object   # opaque
  JSContext = object   # opaque

  JSValueUnion {.union.} = object
    int32Val: int32
    float64:  float64
    ptrVal:   pointer

  JSValue* {.bycopy.} = object
    u:   JSValueUnion  # 8 bytes
    tag: int64         # 8 bytes

  JSCFunction* =
    proc(ctx: ptr JSContext; thisVal: JSValue;
         argc: cint; argv: ptr JSValue): JSValue {.cdecl.}

  JSCFunctionMagic* =
    proc(ctx: ptr JSContext; thisVal: JSValue;
         argc: cint; argv: ptr JSValue; magic: cint): JSValue {.cdecl.}

const
  JS_EVAL_TYPE_GLOBAL*    = 0.cint
  JS_CFUNC_generic*       = 0.cint
  JS_CFUNC_generic_magic* = 1.cint

# ===========================================================================
# QuickJS exported functions (non-inline) -- linked via -lquickjs
# ===========================================================================

proc JS_NewRuntime(): ptr JSRuntime         {.importc: "JS_NewRuntime".}
proc JS_FreeRuntime(rt: ptr JSRuntime)      {.importc: "JS_FreeRuntime".}
proc JS_RunGC(rt: ptr JSRuntime)            {.importc: "JS_RunGC".}
proc JS_NewContext(rt: ptr JSRuntime): ptr JSContext
                                            {.importc: "JS_NewContext".}
proc JS_FreeContext(ctx: ptr JSContext)     {.importc: "JS_FreeContext".}
proc JS_Eval(ctx: ptr JSContext; input: cstring; inputLen: csize_t;
             filename: cstring; evalFlags: cint): JSValue
                                            {.importc: "JS_Eval".}
proc JS_GetException(ctx: ptr JSContext): JSValue
                                            {.importc: "JS_GetException".}
proc JS_GetGlobalObject(ctx: ptr JSContext): JSValue
                                            {.importc: "JS_GetGlobalObject".}
proc JS_NewObject(ctx: ptr JSContext): JSValue
                                            {.importc: "JS_NewObject".}
## JS_SetPropertyStr steals ownership of 'val'.
proc JS_SetPropertyStr(ctx: ptr JSContext; thisObj: JSValue;
                       prop: cstring; val: JSValue): cint
                                            {.importc: "JS_SetPropertyStr".}
proc JS_FreeCString(ctx: ptr JSContext; str: cstring)
                                            {.importc: "JS_FreeCString".}
## JS_NewCFunction2 is the non-inline core used by JS_NewCFunction / JS_NewCFunctionMagic.
proc JS_NewCFunction2(ctx: ptr JSContext; fn: JSCFunction; name: cstring;
                      length: cint; cproto: cint; magic: cint): JSValue
                                            {.importc: "JS_NewCFunction2".}
proc JS_NewStringLen(ctx: ptr JSContext; str: cstring; len: csize_t): JSValue
                                            {.importc: "JS_NewStringLen".}
proc JS_ToCStringLen2(ctx: ptr JSContext; plen: ptr csize_t;
                      val: JSValue; cesu8: cint): cstring
                                            {.importc: "JS_ToCStringLen2".}

# ===========================================================================
# QuickJS inline-function wrappers (from c_src/rwebview_rgss_wrap.c)
# ===========================================================================

proc rw_JS_IsException(v: JSValue): cint   {.importc: "rw_JS_IsException".}
proc rw_JS_FreeValue(ctx: ptr JSContext; v: JSValue)
                                           {.importc: "rw_JS_FreeValue".}
proc rw_JS_DupValue(ctx: ptr JSContext; v: JSValue): JSValue
                                           {.importc: "rw_JS_DupValue".}
proc rw_JS_Undefined(): JSValue            {.importc: "rw_JS_Undefined".}
proc rw_JS_Null(): JSValue                 {.importc: "rw_JS_Null".}
proc rw_JS_True(): JSValue                 {.importc: "rw_JS_True".}
proc rw_JS_False(): JSValue                {.importc: "rw_JS_False".}
proc rw_JS_NewString(ctx: ptr JSContext; s: cstring): JSValue
                                           {.importc: "rw_JS_NewString".}

# ===========================================================================
# QuickJS additional non-inline API
# ===========================================================================

proc rw_JS_NewInt32(ctx: ptr JSContext; v: int32): JSValue
    {.importc: "rw_JS_NewInt32".}
proc rw_JS_NewFloat64(ctx: ptr JSContext; v: float64): JSValue
    {.importc: "rw_JS_NewFloat64".}
proc rw_JS_NewBool(ctx: ptr JSContext; v: cint): JSValue
    {.importc: "rw_JS_NewBool".}

proc JS_GetPropertyStr(ctx: ptr JSContext; thisObj: JSValue;
                       prop: cstring): JSValue
    {.importc: "JS_GetPropertyStr".}
proc JS_SetPropertyUint32(ctx: ptr JSContext; thisObj: JSValue;
                           idx: uint32; val: JSValue): cint
    {.importc: "JS_SetPropertyUint32".}
proc JS_GetPropertyUint32(ctx: ptr JSContext; thisObj: JSValue;
                           idx: uint32): JSValue
    {.importc: "JS_GetPropertyUint32".}
proc JS_NewArray(ctx: ptr JSContext): JSValue
    {.importc: "JS_NewArray".}
proc JS_Call(ctx: ptr JSContext; funcObj: JSValue; thisObj: JSValue;
             argc: cint; argv: ptr JSValue): JSValue
    {.importc: "JS_Call".}
proc JS_CallConstructor(ctx: ptr JSContext; funcObj: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue
    {.importc: "JS_CallConstructor".}
proc JS_IsFunction(ctx: ptr JSContext; v: JSValue): cint
    {.importc: "JS_IsFunction".}
proc JS_ToInt32(ctx: ptr JSContext; pres: ptr int32; v: JSValue): cint
    {.importc: "JS_ToInt32".}
proc JS_NewCFunction(ctx: ptr JSContext; fn: JSCFunction; name: cstring;
                     length: cint): JSValue
    {.importc: "rw_JS_NewCFunction".}
proc JS_IsJobPending(rt: ptr JSRuntime): bool
    {.importc: "JS_IsJobPending".}
proc JS_ExecutePendingJob(rt: ptr JSRuntime; pctx: ptr ptr JSContext): cint
    {.importc: "JS_ExecutePendingJob".}

proc flushJobs*(rt: ptr JSRuntime) {.inline.} =
  ## Execute all pending QuickJS microtask jobs (Promise resolutions etc.).
  ## Passes a valid ctx pointer — QuickJS may not accept nil for pctx.
  var pctx: ptr JSContext
  while JS_ExecutePendingJob(rt, addr pctx) > 0: discard

# Phase 4 additions â€” numeric conversion + typed array access
proc JS_ToFloat64(ctx: ptr JSContext; pres: ptr float64; v: JSValue): cint
    {.importc: "JS_ToFloat64".}
proc rw_JS_ToUint32(ctx: ptr JSContext; pres: ptr uint32; v: JSValue): cint
    {.importc: "rw_JS_ToUint32".}
proc JS_GetArrayBuffer(ctx: ptr JSContext; psize: ptr csize_t; obj: JSValue): ptr uint8
    {.importc: "JS_GetArrayBuffer".}
proc JS_GetTypedArrayBuffer(ctx: ptr JSContext; obj: JSValue;
                             pbyteOffset: ptr csize_t;
                             pbyteLength: ptr csize_t;
                             pbytesPerElement: ptr csize_t): JSValue
    {.importc: "JS_GetTypedArrayBuffer".}
proc rw_JS_VALUE_GET_TAG(v: JSValue): cint
    {.importc: "rw_JS_VALUE_GET_TAG".}
proc rw_JS_NewArrayBufferCopy(ctx: ptr JSContext; buf: pointer; len: csize_t): JSValue
    {.importc: "rw_JS_NewArrayBufferCopy".}
## void* variant used by rgss_quickjs.nim; avoids JSContext type-name conflict
## in Nim's generated C (mangled names vs quickjs.h's typedef).
proc rw_JS_SetContextOpaque*(ctx: pointer; opaque: pointer)
    {.importc: "rw_JS_SetContextOpaque".}

# ===========================================================================
# Nim helpers
# ===========================================================================

proc jsToCString(ctx: ptr JSContext; v: JSValue): cstring {.inline.} =
  JS_ToCStringLen2(ctx, nil, v, 0)

proc jsValToStr(ctx: ptr JSContext; v: JSValue): string =
  let s = jsToCString(ctx, v)
  if s == nil: return "undefined"
  result = $s
  JS_FreeCString(ctx, s)

proc jsCheck(ctx: ptr JSContext; v: JSValue; label: string): bool =
  ## Consume v; return false and print if it is an exception.
  if rw_JS_IsException(v) != 0:
    let exc = JS_GetException(ctx)
    let msg = jsToCString(ctx, exc)
    if msg != nil:
      stderr.writeLine("[rwebview] JS exception in '" & label & "': " & $msg)
      JS_FreeCString(ctx, msg)
    # Print stack trace when available (QuickJS stores it as exc.stack)
    let stackVal = JS_GetPropertyStr(ctx, exc, "stack")
    if rw_JS_IsException(stackVal) == 0:
      let stackStr = jsToCString(ctx, stackVal)
      if stackStr != nil:
        let ss = $stackStr
        if ss.len > 0 and ss != "undefined" and ss != "null":
          stderr.writeLine("[rwebview] Stack:\n" & ss)
        JS_FreeCString(ctx, stackStr)
    rw_JS_FreeValue(ctx, stackVal)
    rw_JS_FreeValue(ctx, exc)
    rw_JS_FreeValue(ctx, v)
    return false
  rw_JS_FreeValue(ctx, v)
  true


# -- Argument extraction helpers (argv is a C array of 16-byte JSValue) ------

proc arg(argv: ptr JSValue; i: int): JSValue {.inline.} =
  cast[ptr JSValue](cast[uint](argv) + uint(i * sizeof(JSValue)))[]

proc argI32(ctx: ptr JSContext; argv: ptr JSValue; i: int): int32 {.inline.} =
  var v: int32
  discard JS_ToInt32(ctx, addr v, arg(argv, i))
  v

proc argU32(ctx: ptr JSContext; argv: ptr JSValue; i: int): uint32 {.inline.} =
  var v: uint32
  discard rw_JS_ToUint32(ctx, addr v, arg(argv, i))
  v

proc argF64(ctx: ptr JSContext; argv: ptr JSValue; i: int): float64 {.inline.} =
  var v: float64
  discard JS_ToFloat64(ctx, addr v, arg(argv, i))
  v

proc argF32(ctx: ptr JSContext; argv: ptr JSValue; i: int): float32 {.inline.} =
  float32(argF64(ctx, argv, i))

proc argBool(ctx: ptr JSContext; argv: ptr JSValue; i: int): bool {.inline.} =
  argI32(ctx, argv, i) != 0

proc argStr(ctx: ptr JSContext; argv: ptr JSValue; i: int): string =
  let v = arg(argv, i)
  let s = jsToCString(ctx, v)
  if s == nil: return ""
  result = $s
  JS_FreeCString(ctx, s)

# -- GL handle helpers -------------------------------------------------------

proc jsNewGLHandle(ctx: ptr JSContext; id: uint32): JSValue =
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "__id", rw_JS_NewInt32(ctx, int32(id)))
  obj

proc jsNewGLLocHandle(ctx: ptr JSContext; loc: int32): JSValue =
  if loc < 0: return rw_JS_Null()
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "__id", rw_JS_NewInt32(ctx, loc))
  obj

const JS_TAG_NULL_C      = 2.cint
const JS_TAG_UNDEFINED_C = 3.cint
const JS_TAG_INT_C       = 0.cint
const JS_TAG_FLOAT64_C   = 7.cint

proc jsGetGLId(ctx: ptr JSContext; v: JSValue): uint32 =
  let tag = rw_JS_VALUE_GET_TAG(v)
  if tag == JS_TAG_NULL_C or tag == JS_TAG_UNDEFINED_C: return 0
  let idVal = JS_GetPropertyStr(ctx, v, "__id")
  var id: int32
  discard JS_ToInt32(ctx, addr id, idVal)
  rw_JS_FreeValue(ctx, idVal)
  uint32(id)

proc jsGetGLLocId(ctx: ptr JSContext; v: JSValue): int32 =
  let tag = rw_JS_VALUE_GET_TAG(v)
  if tag == JS_TAG_NULL_C or tag == JS_TAG_UNDEFINED_C: return -1
  let idVal = JS_GetPropertyStr(ctx, v, "__id")
  var id: int32
  discard JS_ToInt32(ctx, addr id, idVal)
  rw_JS_FreeValue(ctx, idVal)
  id

# -- Typed array / ArrayBuffer data extraction --------------------------------

proc jsGetBufferData(ctx: ptr JSContext; v: JSValue): tuple[data: pointer, size: csize_t] =
  ## Extract raw pointer + byte length from an ArrayBuffer or TypedArray.
  ## Returns (nil, 0) if the argument is not a buffer type.
  var size: csize_t
  let buf = JS_GetArrayBuffer(ctx, addr size, v)
  if buf != nil:
    return (cast[pointer](buf), size)
  # Try TypedArray â†’ underlying ArrayBuffer
  var byteOffset, byteLength, bytesPerElement: csize_t
  let ab = JS_GetTypedArrayBuffer(ctx, v, addr byteOffset, addr byteLength, addr bytesPerElement)
  if rw_JS_IsException(ab) == 0:
    let abBuf = JS_GetArrayBuffer(ctx, addr size, ab)
    rw_JS_FreeValue(ctx, ab)
    if abBuf != nil:
      return (cast[pointer](cast[uint](abBuf) + uint(byteOffset)), byteLength)
  else:
    rw_JS_FreeValue(ctx, ab)
  (nil, csize_t(0))

