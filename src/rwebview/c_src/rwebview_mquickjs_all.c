/*
 * c_src/rwebview_mquickjs_all.c
 *
 * Amalgamated compilation unit for MicroQuickJS (mquickjs).
 * Applies the mqjs_ symbol prefix to avoid linker conflicts with QuickJS-NG,
 * then includes all mquickjs source files as a single translation unit.
 *
 * Compiled via {.compile: ...} from rgss_mquickjs.nim (only when -d:withMQuickJS).
 *
 * Author    : Ryan Bramantya
 * Copyright : Copyright (c) 2026 Ryan Bramantya
 * License   : Apache License 2.0
 */

/* Symbol renaming — must be included BEFORE any mquickjs headers */
#include "../libs/mquickjs/mqjs_prefix.h"

/* Generated stdlib definitions (c_function_table, atom table, etc.) */
#include "../libs/mquickjs/mqjs_stdlib.h"

/* Core mquickjs engine */
#include "../libs/mquickjs/mquickjs.c"

/* Helper libraries */
#include "../libs/mquickjs/cutils.c"
#include "../libs/mquickjs/dtoa.c"
#include "../libs/mquickjs/libm.c"

/* =========================================================================
 * Convenience wrapper: argc/argv-style JS_Call for use from Nim/thunks.
 *
 * mquickjs's native JS_Call is stack-based:
 *   JS_PushArg(ctx, arg[n-1]); ... JS_PushArg(ctx, arg[0]);
 *   JS_PushArg(ctx, func); JS_PushArg(ctx, this_obj);
 *   result = JS_Call(ctx, argc);
 *
 * This wrapper provides the conventional argc/argv interface.
 * ========================================================================= */
JSValue mqjs_CallFunction(JSContext *ctx, JSValue func_obj,
                          JSValue this_obj, int argc, JSValue *argv)
{
    /* Check stack space: argc + 2 (func + this) */
    if (JS_StackCheck(ctx, (uint32_t)(argc + 2)))
        return JS_EXCEPTION;

    /* Push arguments in reverse order */
    for (int i = argc - 1; i >= 0; i--)
        JS_PushArg(ctx, argv[i]);
    /* Push function and this */
    JS_PushArg(ctx, func_obj);
    JS_PushArg(ctx, this_obj);

    return JS_Call(ctx, argc);
}

/* =========================================================================
 * Inline-function wrappers (exported as linkable symbols)
 *
 * mquickjs.h defines several static inline functions that cannot be
 * imported directly from Nim.  We provide thin wrapper functions.
 * ========================================================================= */

int mqjs_rw_IsException(JSValue v)  { return JS_IsException(v); }
int mqjs_rw_IsNull(JSValue v)      { return JS_IsNull(v); }
int mqjs_rw_IsUndefined(JSValue v)  { return JS_IsUndefined(v); }
int mqjs_rw_IsBool(JSValue v)      { return JS_IsBool(v); }
int mqjs_rw_IsInt(JSValue v)       { return JS_IsInt(v); }
int mqjs_rw_IsPtr(JSValue v)       { return JS_IsPtr(v); }

JSValue mqjs_rw_Undefined(void)    { return JS_UNDEFINED; }
JSValue mqjs_rw_Null(void)         { return JS_NULL; }
JSValue mqjs_rw_True(void)         { return JS_TRUE; }
JSValue mqjs_rw_False(void)        { return JS_FALSE; }
JSValue mqjs_rw_Exception(void)    { return JS_EXCEPTION; }
JSValue mqjs_rw_NewBool(int v)     { return JS_NewBool(v); }
