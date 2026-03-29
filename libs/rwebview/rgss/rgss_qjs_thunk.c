/*
 * rgss/rgss_qjs_thunk.c
 *
 * C-level thunk that bridges QuickJS's native JSCFunction convention to
 * the RGSS ScriptNativeProc callback.
 *
 * Why a C file?
 *   QuickJS's JS_NewCFunction2 requires a raw C function pointer (JSCFunction*).
 *   Nim closures are not raw C function pointers.  We therefore allocate a
 *   small heap thunk (ThunkEntry) that stores the Nim closure and a static C
 *   dispatcher function reads from it.
 *
 *   The thunk list is a fixed-size array (THUNK_CAP = 4096).  Slots are
 *   deduplicated: if the same (nim_fn, nim_env) pair is registered again,
 *   the existing slot index is reused.  This is critical for objects like
 *   canvas2d contexts which bind ~43 methods with identical proc pointers.
 *   Without dedup, ~95 canvas contexts exhaust the table and subsequent
 *   bindings fail silently with JS_EXCEPTION -> "not a function" TypeError.
 *
 * Thread safety:
 *   All QuickJS calls happen on the main thread. No locking needed.
 *
 * Compiled via {.compile: ...} from rgss_quickjs.nim.
 * Include path (-I bin/include) supplied by rwebview.nim {.passC.}.
 */

#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* -- ScriptValue layout must match rgss_api.nim exactly -------------------
 * ScriptValue = object { data: array[2, uint64] }  => 16 bytes
 * We alias it here as SV_Raw so C can pass it by value.
 */
typedef struct {
    uint64_t d[2];
} SV_Raw;   /* matches ScriptValue in Nim */

/* -- ScriptCtx forward (opaque from C's perspective) ----------------------*/
typedef struct ScriptCtx ScriptCtx;

/* -- Nim closure layout (Nim passes closures as {fn, env} pairs) -----------
 * We store both the function pointer and the environment pointer.
 * The Nim-side NativeProc type must match:
 *   proc(ctx: ptr ScriptCtx; this: ScriptValue;
 *        args: ptr SV_Raw; argc: int): ScriptValue
 * This is the "unpacked openArray" form that C can call.
 */
typedef SV_Raw (*NimScriptProc)(ScriptCtx *ctx,
                                SV_Raw     this_val,
                                SV_Raw    *args,
                                ptrdiff_t  argc,
                                void      *env);

/* -- Adapter: JSValue <-> SV_Raw ------------------------------------------
 * JSValue is a 16-byte struct on x86_64 (same layout as SV_Raw).
 * We memcpy to avoid strict-aliasing UB.
 */
static SV_Raw jsval_to_sv(JSValue v) {
    SV_Raw out;
    memcpy(&out, &v, 16);
    return out;
}
static JSValue sv_to_jsval(SV_Raw v) {
    JSValue out;
    memcpy(&out, &v, 16);
    return out;
}

/* -- ThunkEntry: one slot per unique (nim_fn, nim_env) pair ---------------*/
#define THUNK_CAP 4096

typedef struct {
    NimScriptProc nim_fn;   /* Nim function pointer extracted from closure */
    void         *nim_env;  /* Nim closure environment pointer */
    int           magic;    /* slot index, stored as magic for JS_NewCFunctionMagic */
} ThunkEntry;

static ThunkEntry g_thunks[THUNK_CAP];
static int        g_thunk_count = 0;

/* -- Central C dispatcher: all bound functions route through here ---------*/
static JSValue qjs_thunk_dispatch(JSContext *ctx, JSValue this_val,
                                  int argc, JSValue *argv,
                                  int magic) {
    if (magic < 0 || magic >= g_thunk_count) {
        return JS_UNDEFINED;
    }
    ThunkEntry *e = &g_thunks[magic];

    /* Convert JSValue argv to SV_Raw array on the stack.
     * Maximum 32 args -- plenty for any web API binding. */
    SV_Raw sv_args[32];
    int n = argc < 32 ? argc : 32;
    for (int i = 0; i < n; i++) sv_args[i] = jsval_to_sv(argv[i]);

    SV_Raw sv_this = jsval_to_sv(this_val);

    /* ScriptCtx* is smuggled via JS_SetContextOpaque / JS_GetContextOpaque.
     * See rgss_quickjs.nim: the JSContext's opaque pointer IS the ScriptCtx. */
    ScriptCtx *sctx = (ScriptCtx *)JS_GetContextOpaque(ctx);
    if (sctx == NULL) {
        return JS_UNDEFINED;
    }

    SV_Raw ret = e->nim_fn(sctx, sv_this, sv_args, (ptrdiff_t)n, e->nim_env);
    return sv_to_jsval(ret);
}

/* -- Public API called from Nim -------------------------------------------*/

/* qjs_bind_native: register a Nim proc as a JS function.
 *
 * Deduplication: if (nim_fn, nim_env) is already in the table, the existing
 * slot is reused -- a new JS function object is created pointing to the same
 * slot.  This is the key fix for thunk table exhaustion: canvas2d creates
 * many context objects, each binding the same set of proc pointers, so only
 * the first context allocates slots (~34 unique procs); all subsequent
 * contexts reuse them at zero cost.
 *
 * Returns JS_EXCEPTION if the table is full (should not happen in practice).
 */
JSValue qjs_bind_native(JSContext    *ctx,
                        const char   *name,
                        NimScriptProc nim_fn,
                        void         *nim_env,
                        int           arity) {
    for (int i = 0; i < g_thunk_count; i++) {
        if (g_thunks[i].nim_fn == nim_fn && g_thunks[i].nim_env == nim_env) {
            return JS_NewCFunctionMagic(ctx, qjs_thunk_dispatch, name, arity,
                                       JS_CFUNC_generic_magic, i);
        }
    }
    if (g_thunk_count >= THUNK_CAP) {
        return JS_EXCEPTION;
    }
    int slot = g_thunk_count++;
    g_thunks[slot].nim_fn  = nim_fn;
    g_thunks[slot].nim_env = nim_env;
    g_thunks[slot].magic   = slot;
    return JS_NewCFunctionMagic(ctx, qjs_thunk_dispatch, name, arity,
                                JS_CFUNC_generic_magic, slot);
}

/* qjs_thunk_reset: clear the slot table.
 * Call when the JS context is destroyed so slots can be reused on reload.
 * Does NOT free any JSValues -- caller must have already freed them. */
void qjs_thunk_reset(void) {
    g_thunk_count = 0;
}

/* ==========================================================================
 * [Documentation] Design Notes & Bug History
 * ==========================================================================
 *
 * THUNK TABLE EXHAUSTION (fixed March 29, 2026)
 * -----------------------------------------------
 * Symptom:
 *   After ~95 canvas2d getContext('2d') calls, new canvas contexts started
 *   throwing "TypeError: not a function" for methods like __rw_setCompositeOp.
 *   Error location: <dom-preamble>:406 (globalCompositeOperation setter).
 *
 * Root cause:
 *   Before deduplication, each jsCreateCanvas2D call allocated ~43 new thunk
 *   slots (one per method binding).  With THUNK_CAP = 4096, the table filled
 *   after approximately 95 contexts (95 * 43 = 4085 slots).  After slot 4095,
 *   qjs_bind_native returned JS_EXCEPTION.  bindMethod translated this to a
 *   property set with an exception value -- JS saw the property as non-callable.
 *
 * Fix:
 *   Added a linear scan before slot allocation.  If a (nim_fn, nim_env) pair
 *   already exists, return a new JS function object aliasing the existing slot.
 *   Result: first canvas2d context allocates ~34 unique slots (many methods
 *   share the same proc pointer, e.g. jsCtx2dNoop); every subsequent context
 *   allocates zero slots.  Table usage is now bounded by the number of unique
 *   native procs, not by the number of JS objects created.
 *
 * Observation:
 *   All plain Nim procs (not closures) have nim_env = NULL (0x0).  Closures
 *   would have non-NULL env.  In practice, all canvas2d/dom bindings are plain
 *   procs, so dedup is maximally effective.
 *
 * CALLING CONVENTION NOTE
 * -----------------------
 *   NimScriptProc is declared with 5 parameters: (ctx, this, args, argc, env).
 *   Plain Nim procs compiled from openArray[ScriptValue] expand to 4 C params
 *   (ctx, this, args_ptr, args_len) -- the 5th param (env) is passed but
 *   ignored.  On Windows x64 (Microsoft ABI), extra register params sit in
 *   unused registers and cause no harm.  This is NOT an ABI bug.
 *
 * --------------------------------------------------------------------------*/