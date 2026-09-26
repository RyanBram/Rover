# =============================================================================
# rgss/rgss_test.nim
# Minimal compile-time validation for rgss_api + rgss_quickjs
# =============================================================================
#
# This file is NOT compiled as part of rwebview.nim.
# It exists to verify that scripting_api.nim compiles cleanly and that
# rgss_quickjs.nim correctly populates the ScriptEngine vtable.
#
# Run standalone with:
#   nim c --hints:off -d:rwebviewLib rgss/rgss_test.nim
# (No game is launched; just tests the vtable smoke path.)
#
# =============================================================================

# Reference the rwebview root for passC / passL pragmas.
# This test lives in scripting/ so "../" reaches libs/rwebview/.
import std/os
const rwebviewRoot = currentSourcePath().parentDir().parentDir()
const includeDir   = rwebviewRoot / "bin" / "include"
const libDir       = rwebviewRoot / "bin" / "lib"
{.passC: "-I" & includeDir.}
{.passC: "-std=gnu99".}
# Compile the QJS C wrapper and link the QuickJS static library.
{.compile: "../c_src/rwebview_rgss_wrap.c".}
const qjsLibPath = libDir / "libqjs.a"
{.passL: qjsLibPath.}

include "rgss_quickjs"  # includes rgss_api transitively

when isMainModule:
  # --- Engine lifecycle ---
  var eng = newQuickJSEngine()
  eng.initEngine(addr eng)

  let ctx = eng.newCtx(addr eng)
  assert ctx != nil, "newCtx returned nil"

  # --- Basic eval ---
  let r1 = ctx.eval("1 + 2")
  assert not ctx.isException(r1)
  assert ctx.toInt32(r1) == 3
  ctx.freeValue(r1)

  # --- newString / toString ---
  let sv = ctx.newString("hello")
  let s  = ctx.toString(sv)
  assert $s == "hello"
  ctx.freeCString(s)
  ctx.freeValue(sv)

  # --- setGlobal / getGlobalProp ---
  ctx.setGlobal("_testNum", ctx.newInt(99))
  let got = ctx.getGlobalProp("_testNum")
  assert ctx.toInt32(got) == 99
  ctx.freeValue(got)

  # --- bindGlobal + callFunction via eval ---
  let addFn: ScriptNativeProc = proc(ctx: ptr ScriptCtx;
                                      this: ScriptValue;
                                      args: openArray[ScriptValue]): ScriptValue =
    let a = ctx.toInt32(args[0])
    let b = ctx.toInt32(args[1])
    ctx.newInt(a + b)
  ctx.bindGlobal("_testAdd", addFn, 2)

  let r2 = ctx.eval("_testAdd(10, 32)")
  assert not ctx.isException(r2)
  assert ctx.toInt32(r2) == 42
  ctx.freeValue(r2)

  # --- ArrayBuffer round-trip ---
  var buf: array[4, uint8] = [1'u8, 2, 3, 4]
  let abv = ctx.newArrayBufferCopy(addr buf[0], 4)
  var outLen: int
  let p = ctx.getArrayBufferData(abv, outLen)
  assert outLen == 4
  let pb = cast[ptr UncheckedArray[uint8]](p)
  assert pb[0] == 1 and pb[3] == 4
  ctx.freeValue(abv)

  # --- Teardown ---
  eng.freeCtx(ctx)
  eng.destroyEngine(addr eng)

  echo "[scripting_test] All assertions passed."
