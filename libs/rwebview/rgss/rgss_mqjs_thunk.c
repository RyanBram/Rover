/*
 * rgss/rgss_mqjs_thunk.c
 *
 * C-level thunk that bridges MicroQuickJS's native JSCFunction convention
 * to the RGSS ScriptNativeProc callback.
 *
 * This is the mquickjs counterpart of rgss_qjs_thunk.c.
 * Key differences from the QuickJS-NG version:
 *   - JSValue is uint64_t (8 bytes), not a 16-byte struct
 *   - SV_Raw is still 16 bytes (ScriptValue); data[0] = mquickjs JSValue, data[1] = 0
 *   - this_val is passed as JSValue* (pointer), not by value
 *   - Uses mqjs_-prefixed API (via mqjs_prefix.h)
 *   - JS_NewCFunctionMagic is a Rover extension patched into mquickjs
 *
 * Compiled via {.compile: ...} from rgss_mquickjs.nim.
 * Include path (-I libs/rwebview/libs/mquickjs) supplied by compile pragma.
 *
 * Author    : Ryan Bramantya
 * Copyright : Copyright (c) 2026 Ryan Bramantya
 * License   : Apache License 2.0
 */

/* Must include prefix header BEFORE mquickjs.h to get renamed API */
#include "mqjs_prefix.h"
#include "mquickjs.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* ──── ScriptValue layout must match rgss_api.nim exactly ──────────────────
 * ScriptValue = object { data: array[2, uint64] }  => 16 bytes
 */
typedef struct {
    uint64_t d[2];
} SV_Raw;   /* matches ScriptValue in Nim */

/* ──── ScriptCtx forward ────────────────────────────────────────────────── */
typedef struct ScriptCtx ScriptCtx;

/* ──── Nim closure layout ────────────────────────────────────────────────── */
typedef SV_Raw (*NimScriptProc)(ScriptCtx *ctx,
                                 SV_Raw     this_val,
                                 SV_Raw    *args,
                                 ptrdiff_t  argc,
                                 void      *env);

/* ──── JSValue <-> SV_Raw conversion ─────────────────────────────────────
 * mquickjs JSValue is 8 bytes (uint64_t).
 * SV_Raw is 16 bytes.  Store JSValue in d[0], zero d[1].
 */
static SV_Raw mqjs_jsval_to_sv(JSValue v) {
    SV_Raw out;
    out.d[0] = (uint64_t)v;
    out.d[1] = 0;
    return out;
}

static JSValue mqjs_sv_to_jsval(SV_Raw v) {
    return (JSValue)v.d[0];
}

/* ──── ThunkEntry ────────────────────────────────────────────────────────── */
#define MQJS_THUNK_CAP 4096

typedef struct {
    NimScriptProc nim_fn;
    void         *nim_env;
    int           magic;
} MQJSThunkEntry;

static MQJSThunkEntry g_mqjs_thunks[MQJS_THUNK_CAP];
static int            g_mqjs_thunk_count = 0;

/* ──── Central C dispatcher ──────────────────────────────────────────────
 * All dynamically-bound functions route through here.
 * Note: in mquickjs, this_val is JSValue* (pointer), not value.
 */
static JSValue mqjs_thunk_dispatch(JSContext *ctx, JSValue *this_val,
                                   int argc, JSValue *argv,
                                   int magic) {
    if (magic < 0 || magic >= g_mqjs_thunk_count) return JS_UNDEFINED;
    MQJSThunkEntry *e = &g_mqjs_thunks[magic];

    /* Convert JSValue argv to SV_Raw array on the stack. */
    SV_Raw sv_args[32];
    int n = argc < 32 ? argc : 32;
    for (int i = 0; i < n; i++) sv_args[i] = mqjs_jsval_to_sv(argv[i]);

    SV_Raw sv_this = mqjs_jsval_to_sv(*this_val);

    ScriptCtx *sctx = (ScriptCtx *)JS_GetContextOpaque(ctx);

    SV_Raw ret = e->nim_fn(sctx, sv_this, sv_args, (ptrdiff_t)n, e->nim_env);
    return mqjs_sv_to_jsval(ret);
}

/* ──── Public API ────────────────────────────────────────────────────────── */

JSValue mqjs_bind_native(JSContext    *ctx,
                         const char   *name,
                         NimScriptProc nim_fn,
                         void         *nim_env,
                         int           arity) {
    if (g_mqjs_thunk_count >= MQJS_THUNK_CAP) return JS_EXCEPTION;
    int slot = g_mqjs_thunk_count++;
    g_mqjs_thunks[slot].nim_fn  = nim_fn;
    g_mqjs_thunks[slot].nim_env = nim_env;
    g_mqjs_thunks[slot].magic   = slot;
    return JS_NewCFunctionMagic(ctx,
        (JSValue (*)(JSContext *, JSValue *, int, JSValue *, int))mqjs_thunk_dispatch,
        name, arity, JS_CFUNC_generic_magic, slot);
}

void mqjs_thunk_reset(void) {
    g_mqjs_thunk_count = 0;
}
