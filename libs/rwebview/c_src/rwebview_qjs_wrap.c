/*
 * rwebview_qjs_wrap.c
 *
 * Thin C wrappers that expose QuickJS *inline* functions and macros as
 * real, linkable symbols so that Nim's {.importc.} FFI can call them.
 *
 * Compiled via {.compile: "c_src/rwebview_qjs_wrap.c".} in rwebview.nim.
 * The include path for quickjs.h is supplied by the {.passC.} pragma in
 * rwebview.nim.
 *
 * NOTE: This file must be compiled with -std=gnu99 (set by rwebview.nim's
 *       {.passC.} pragma) because QuickJS uses GCC extensions (asm volatile).
 */

#include "quickjs.h"

/* ── inline predicate wrappers ─────────────────────────────────────────── */

int rw_JS_IsException(JSValue v)  { return JS_IsException(v); }
int rw_JS_IsUndefined(JSValue v)  { return JS_IsUndefined(v); }
int rw_JS_IsNull(JSValue v)       { return JS_IsNull(v); }
int rw_JS_IsString(JSValue v)     { return JS_IsString(v); }
int rw_JS_IsObject(JSValue v)     { return JS_IsObject(v); }
int rw_JS_IsNumber(JSValue v)     { return JS_IsNumber(v); }

/* ── ref-count / lifetime ──────────────────────────────────────────────── */

void rw_JS_FreeValue(JSContext *ctx, JSValue v) { JS_FreeValue(ctx, v); }

/* Dup increases the ref-count so the caller gets its own reference. */
JSValue rw_JS_DupValue(JSContext *ctx, JSValue v) { return JS_DupValue(ctx, v); }

/* ── string conversion ─────────────────────────────────────────────────── */

/* JS_ToCString is a macro wrapping JS_ToCStringLen2 */
const char *rw_JS_ToCString(JSContext *ctx, JSValue val) {
    return JS_ToCString(ctx, val);
}

/* JS_NewString is an inline wrapping JS_NewStringLen */
JSValue rw_JS_NewString(JSContext *ctx, const char *str) {
    return JS_NewString(ctx, str);
}

/* ── special constant values ───────────────────────────────────────────── */

/* JS_UNDEFINED / JS_NULL are macros that create JSValue structs. */
JSValue rw_JS_Undefined(void) { return JS_UNDEFINED; }
JSValue rw_JS_Null(void)      { return JS_NULL; }
JSValue rw_JS_True(void)      { return JS_TRUE; }
JSValue rw_JS_False(void)     { return JS_FALSE; }

/* ── numeric / bool constructors ────────────────────────────────────────── */

JSValue rw_JS_NewInt32(JSContext *ctx, int32_t val) { return JS_NewInt32(ctx, val); }
JSValue rw_JS_NewFloat64(JSContext *ctx, double val) { return JS_NewFloat64(ctx, val); }
JSValue rw_JS_NewBool(JSContext *ctx, int val) { return JS_NewBool(ctx, val); }

/* ── function constructors ───────────────────────────────────────────────── */

/* JS_NewCFunction is a static inline wrapper around JS_NewCFunction2 */
JSValue rw_JS_NewCFunction(JSContext *ctx, JSCFunction *func,
                            const char *name, int length) {
    return JS_NewCFunction(ctx, func, name, length);
}

/* ── typed array / ArrayBuffer access ────────────────────────────────────── */

/* JS_ToUint32 is a static inline */
int rw_JS_ToUint32(JSContext *ctx, uint32_t *pres, JSValue val) {
    return JS_ToUint32(ctx, pres, val);
}

/* JS_VALUE_GET_TAG — extract tag for type checking */
int rw_JS_VALUE_GET_TAG(JSValue v) {
    return JS_VALUE_GET_TAG(v);
}

/* ── ArrayBuffer creation ────────────────────────────────────────────────── */

/* JS_NewArrayBufferCopy is a non-inline function in quickjs.c, but we wrap it
   here for consistency with the rw_ naming convention used by the Nim FFI. */
JSValue rw_JS_NewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len) {
    return JS_NewArrayBufferCopy(ctx, buf, len);
}
