# ===========================================================================
# Phase 3 - DOM preamble (loaded from dom_preamble.js via staticRead)
# ===========================================================================

const domPreambleJs = staticRead("dom_preamble.js")

proc domPreamble(w, h: cint): string =
  ## Return the JS source that installs minimal window/document stubs.
  ## Loaded from dom_preamble.js at compile time; __CANVAS_W__ / __CANVAS_H__
  ## are substituted at runtime with the actual pixel dimensions.
  domPreambleJs
    .replace("__CANVAS_W__", $w)
    .replace("__CANVAS_H__", $h)

# ===========================================================================
# Phase 3 — Native JS bindings installed by bindDom
# ===========================================================================

# Forward declaration — webview state is needed for rAF/timer callbacks.
# We store the state pointer in a module-level global because QuickJS
# `JS_NewCFunction2` only gives us a `magic` int, not a user-data pointer.
# For a single-window runtime this is fine.
var gState {.global.}: ptr RWebviewState = nil

proc jsGetTicks(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_getTicksMs() → number   (milliseconds since SDL init)
  rw_JS_NewFloat64(ctx, float64(SDL_GetTicks()))

proc jsRequestAnimationFrame(ctx: ptr JSContext; thisVal: JSValue;
                              argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## requestAnimationFrame(callback) → id  (int)
  if argc < 1: return rw_JS_NewInt32(ctx, 0)
  let fn = cast[ptr JSValue](argv)[]
  if JS_IsFunction(ctx, fn) == 0: return rw_JS_NewInt32(ctx, 0)
  let state = gState
  if state == nil: return rw_JS_NewInt32(ctx, 0)
  let id = state.nextTimerId
  inc state.nextTimerId
  state.rafPending.add(RAfEntry(id: id, fn: rw_JS_DupValue(ctx, fn)))
  rw_JS_NewInt32(ctx, int32(id))

proc jsCancelAnimationFrame(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_Undefined()
  var id: int32
  discard JS_ToInt32(ctx, addr id, cast[ptr JSValue](argv)[])
  let state = gState
  for i in 0..<state.rafPending.len:
    if state.rafPending[i].id == int(id):
      rw_JS_FreeValue(ctx, state.rafPending[i].fn)
      state.rafPending.delete(i)
      break
  rw_JS_Undefined()

proc jsSetTimeout(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_NewInt32(ctx, 0)
  let fn = cast[ptr JSValue](cast[uint](argv))[]
  if JS_IsFunction(ctx, fn) == 0: return rw_JS_NewInt32(ctx, 0)
  var ms: int32 = 0
  if argc >= 2:
    discard JS_ToInt32(ctx, addr ms, cast[ptr JSValue](cast[uint](argv) + uint(sizeof(JSValue)))[])
  if ms < 0: ms = 0
  let state = gState
  let id = state.nextTimerId
  inc state.nextTimerId
  state.timers.add(TimerEntry(
    id: id, fn: rw_JS_DupValue(ctx, fn),
    fireAt: SDL_GetTicks() + uint64(ms),
    interval: 0, active: true))
  rw_JS_NewInt32(ctx, int32(id))

proc jsSetInterval(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_NewInt32(ctx, 0)
  let fn = cast[ptr JSValue](cast[uint](argv))[]
  if JS_IsFunction(ctx, fn) == 0: return rw_JS_NewInt32(ctx, 0)
  var ms: int32 = 0
  if argc >= 2:
    discard JS_ToInt32(ctx, addr ms, cast[ptr JSValue](cast[uint](argv) + uint(sizeof(JSValue)))[])
  if ms <= 0: ms = 1
  let state = gState
  let id = state.nextTimerId
  inc state.nextTimerId
  state.timers.add(TimerEntry(
    id: id, fn: rw_JS_DupValue(ctx, fn),
    fireAt: SDL_GetTicks() + uint64(ms),
    interval: uint64(ms), active: true))
  rw_JS_NewInt32(ctx, int32(id))

proc jsClearTimer(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc < 1 or gState == nil: return rw_JS_Undefined()
  var id: int32
  discard JS_ToInt32(ctx, addr id, cast[ptr JSValue](argv)[])
  for t in gState.timers.mitems:
    if t.id == int(id) and t.active:
      t.active = false
      # Do NOT free t.fn here — dispatchTimers owns lifetime and will free it
      # when it sweeps inactive entries.  Freeing here causes use-after-free.
      break
  rw_JS_Undefined()

proc jsLoadImage(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_loadImage(imgObj, src) — stub: immediately fires onload with size 1×1.
  ## A real implementation would load via SDL_image and set naturalWidth/Height.
  if argc < 1: return rw_JS_Undefined()
  let imgObj = cast[ptr JSValue](argv)[]
  # Mark complete
  discard JS_SetPropertyStr(ctx, imgObj, "complete",      rw_JS_True())
  discard JS_SetPropertyStr(ctx, imgObj, "naturalWidth",  rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, imgObj, "naturalHeight", rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, imgObj, "width",         rw_JS_NewInt32(ctx, 1))
  discard JS_SetPropertyStr(ctx, imgObj, "height",        rw_JS_NewInt32(ctx, 1))
  # Fire load event via dispatchEvent (covers both addEventListener and onload)
  let dispFn = JS_GetPropertyStr(ctx, imgObj, "dispatchEvent")
  if JS_IsFunction(ctx, dispFn) != 0:
    let evtObj = JS_NewObject(ctx)
    discard JS_SetPropertyStr(ctx, evtObj, "type", rw_JS_NewString(ctx, "load"))
    var ea = evtObj
    let r = JS_Call(ctx, dispFn, imgObj, 1, addr ea)
    discard jsCheck(ctx, r, "Image.dispatchEvent(load)")
    rw_JS_FreeValue(ctx, r)
    rw_JS_FreeValue(ctx, evtObj)
  else:
    let onload = JS_GetPropertyStr(ctx, imgObj, "onload")
    if JS_IsFunction(ctx, onload) != 0:
      let r = JS_Call(ctx, onload, imgObj, 0, nil)
      discard jsCheck(ctx, r, "Image.onload")
      rw_JS_FreeValue(ctx, r)
    rw_JS_FreeValue(ctx, onload)
  rw_JS_FreeValue(ctx, dispFn)
  rw_JS_Undefined()

proc bindDom(state: ptr RWebviewState) =
  ## Install native C functions into the QuickJS global object.
  gState = state
  let ctx    = state.jsCtx
  let global = JS_GetGlobalObject(ctx)
  let winObj = JS_GetPropertyStr(ctx, global, "window")

  template installFn(obj: JSValue; name: cstring; fn: JSCFunction; nargs: cint) =
    let f = JS_NewCFunction(ctx, fn, name, nargs)
    discard JS_SetPropertyStr(ctx, obj, name, f)
    # Also install on global so bare `setTimeout(...)` works.
    let g2 = JS_NewCFunction(ctx, fn, name, nargs)
    discard JS_SetPropertyStr(ctx, global, name, g2)

  # performance.now native
  let perfObj = JS_GetPropertyStr(ctx, winObj, "performance")
  let nowFn   = JS_NewCFunction(ctx, jsGetTicks, "now", 0)
  discard JS_SetPropertyStr(ctx, perfObj, "now", nowFn)
  # Also update the global performance.now
  let gPerfObj = JS_GetPropertyStr(ctx, global, "performance")
  let nowFn2   = JS_NewCFunction(ctx, jsGetTicks, "now", 0)
  discard JS_SetPropertyStr(ctx, gPerfObj, "now", nowFn2)
  rw_JS_FreeValue(ctx, perfObj)
  rw_JS_FreeValue(ctx, gPerfObj)

  # rAF / timer natives on window + global
  installFn(winObj, "requestAnimationFrame",  cast[JSCFunction](jsRequestAnimationFrame), 1)
  installFn(winObj, "cancelAnimationFrame",   cast[JSCFunction](jsCancelAnimationFrame),  1)
  installFn(winObj, "setTimeout",             cast[JSCFunction](jsSetTimeout),            2)
  installFn(winObj, "setInterval",            cast[JSCFunction](jsSetInterval),           2)
  installFn(winObj, "clearTimeout",           cast[JSCFunction](jsClearTimer),            1)
  installFn(winObj, "clearInterval",          cast[JSCFunction](jsClearTimer),            1)

  # __rw_getTicksMs and __rw_loadImage on global (used by JS preamble)
  let tmFn = JS_NewCFunction(ctx, jsGetTicks, "__rw_getTicksMs", 0)
  discard JS_SetPropertyStr(ctx, global, "__rw_getTicksMs", tmFn)
  let liFn = JS_NewCFunction(ctx, cast[JSCFunction](jsLoadImage), "__rw_loadImage", 2)
  discard JS_SetPropertyStr(ctx, global, "__rw_loadImage", liFn)

  rw_JS_FreeValue(ctx, winObj)
  rw_JS_FreeValue(ctx, global)

# ===========================================================================
# Phase 3 — per-frame timer/rAF dispatch helpers
# ===========================================================================

proc dispatchTimers(state: ptr RWebviewState) =
  ## Fire any timers whose fireAt <= now.  setInterval timers reschedule themselves.
  let ctx  = state.jsCtx
  let now  = SDL_GetTicks()
  var i = 0
  while i < state.timers.len:
    let t = addr state.timers[i]
    if not t.active:
      rw_JS_FreeValue(ctx, t.fn)
      state.timers.delete(i)
      continue
    if now >= t.fireAt:
      if t.interval > 0:
        # setInterval: reschedule first, then call (so cleared interval in callback works)
        t.fireAt = now + t.interval
        let fn = rw_JS_DupValue(ctx, t.fn)
        let r  = JS_Call(ctx, fn, rw_JS_Undefined(), 0, nil)
        discard jsCheck(ctx, r, "setInterval callback")
        rw_JS_FreeValue(ctx, fn)
        inc i
      else:
        # setTimeout: deactivate, extract fn, delete, call
        t.active = false
        let fn = t.fn   # don't dup — we take ownership
        state.timers.delete(i)
        let r = JS_Call(ctx, fn, rw_JS_Undefined(), 0, nil)
        discard jsCheck(ctx, r, "setTimeout callback")
        rw_JS_FreeValue(ctx, fn)
        # don't inc i: slot was removed
    else:
      inc i

proc dispatchRaf(state: ptr RWebviewState) =
  ## Fire all pending rAF callbacks, then pump micro-tasks.
  ## Callbacks registered during dispatch go to rafPending for next frame.
  let ctx = state.jsCtx

  # Pump any micro-tasks / Promise continuations BEFORE rAF callbacks,
  # so Promises queued during script execution resolve before rAF checks them.
  while JS_ExecutePendingJob(state.rt, nil) > 0: discard

  # Take current rafPending; anything registered during execution goes
  # to the fresh rafPending and fires on the NEXT frame (correct browser behaviour).
  var toRun = move(state.rafPending)
  state.rafPending = @[]
  let ts = rw_JS_NewFloat64(ctx, float64(SDL_GetTicks()))
  for e in toRun:
    var tsArg = ts
    let r = JS_Call(ctx, e.fn, rw_JS_Undefined(), 1, addr tsArg)
    discard jsCheck(ctx, r, "requestAnimationFrame callback")
    rw_JS_FreeValue(ctx, e.fn)
  rw_JS_FreeValue(ctx, ts)
  # Pump any micro-tasks / Promise continuations
  while JS_ExecutePendingJob(state.rt, nil) > 0: discard

