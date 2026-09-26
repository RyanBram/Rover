# =============================================================================
# rwebview_dom.nim
# DOM preamble representation
# =============================================================================
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
#   DOM preamble (loaded from dom_preamble.js via staticRead).
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rgss/rgss_api            # ScriptCtx, ScriptValue
#
# Used by:
#   - rwebview.nim             # included after rwebview_html.nim
#
# =============================================================================

const domPreambleJs = staticRead("dom_preamble.js")

proc domPreamble(w, h: cint; navigateUrl: string = "";
                 screenW: cint = 0; screenH: cint = 0): string =
  ## Return the JS source that installs minimal window/document stubs.
  ## Loaded from dom_preamble.js at compile time; placeholders are substituted
  ## at runtime with actual pixel dimensions and the navigate URL so that
  ## window.location reflects the real URL (required by polyfill.js to detect
  ## VirtualHost mode vs HTTP-server mode and to read package.json correctly).
  ## screenW/screenH are the actual monitor resolution for screen.width/height.
  var href     = navigateUrl
  var hostname = "localhost"
  var protocol = "file:"
  var origin   = "file://"
  var pathname = "/"
  if navigateUrl.startsWith("http://") or navigateUrl.startsWith("https://"):
    let noScheme = navigateUrl[navigateUrl.find("://") + 3 .. ^1]
    let slashPos = noScheme.find('/')
    if slashPos >= 0:
      hostname = noScheme[0 ..< slashPos]
      pathname = noScheme[slashPos .. ^1]
    else:
      hostname = noScheme
      pathname = "/"
    if navigateUrl.startsWith("https://"):
      protocol = "https:"
      origin   = "https://" & hostname
    else:
      protocol = "http:"
      origin   = "http://" & hostname
  let actualScreenW = if screenW > 0: screenW else: w
  let actualScreenH = if screenH > 0: screenH else: h
  domPreambleJs
    .replace("__CANVAS_W__",          $w)
    .replace("__CANVAS_H__",          $h)
    .replace("__SCREEN_W__",          $actualScreenW)
    .replace("__SCREEN_H__",          $actualScreenH)
    .replace("__LOCATION_HREF__",     href)
    .replace("__LOCATION_PATHNAME__", pathname)
    .replace("__LOCATION_HOSTNAME__", hostname)
    .replace("__LOCATION_PROTOCOL__", protocol)
    .replace("__LOCATION_ORIGIN__",   origin)

# ===========================================================================
# Phase 3 — Native JS bindings installed by bindDom
# ===========================================================================

# Forward declaration — webview state is needed for rAF/timer callbacks.
# We store the state pointer in a module-level global because QuickJS
# `JS_NewCFunction2` only gives us a `magic` int, not a user-data pointer.
# For a single-window runtime this is fine.
var gState {.global.}: ptr RWebviewState = nil

proc jsGetTicks(ctx: ptr ScriptCtx; this: ScriptValue;
                args: openArray[ScriptValue]): ScriptValue =
  ## __rw_getTicksMs() → number   (milliseconds since SDL init)
  ctx.newFloat(float64(SDL_GetTicks()))

proc jsRequestAnimationFrame(ctx: ptr ScriptCtx; this: ScriptValue;
                              args: openArray[ScriptValue]): ScriptValue =
  ## requestAnimationFrame(callback) → id  (int)
  if args.len < 1: return ctx.newInt(0)
  let fn = args[0]
  if not ctx.isFunction(fn): return ctx.newInt(0)
  let state = gState
  if state == nil: return ctx.newInt(0)
  let id = state.nextTimerId
  inc state.nextTimerId
  let duped = ctx.dupValue(fn)
  state.rafPending.add(RAfEntry(id: id, fn: duped))
  ctx.newInt(int32(id))

proc jsCancelAnimationFrame(ctx: ptr ScriptCtx; this: ScriptValue;
                             args: openArray[ScriptValue]): ScriptValue =
  if args.len < 1 or gState == nil: return ctx.newUndefined()
  let id = int(ctx.toInt32(args[0]))
  let state = gState
  for i in 0..<state.rafPending.len:
    if state.rafPending[i].id == id:
      ctx.freeValue(state.rafPending[i].fn)
      state.rafPending.delete(i)
      break
  ctx.newUndefined()

proc jsSetTimeout(ctx: ptr ScriptCtx; this: ScriptValue;
                  args: openArray[ScriptValue]): ScriptValue =
  if args.len < 1 or gState == nil: return ctx.newInt(0)
  let fn = args[0]
  if not ctx.isFunction(fn): return ctx.newInt(0)
  var ms: int32 = 0
  if args.len >= 2:
    ms = ctx.toInt32(args[1])
  if ms < 0: ms = 0
  let state = gState
  let id = state.nextTimerId
  inc state.nextTimerId
  state.timers.add(TimerEntry(
    id: id, fn: ctx.dupValue(fn),
    fireAt: SDL_GetTicks() + uint64(ms),
    interval: 0, active: true))
  ctx.newInt(int32(id))

proc jsSetInterval(ctx: ptr ScriptCtx; this: ScriptValue;
                   args: openArray[ScriptValue]): ScriptValue =
  if args.len < 1 or gState == nil: return ctx.newInt(0)
  let fn = args[0]
  if not ctx.isFunction(fn): return ctx.newInt(0)
  var ms: int32 = 0
  if args.len >= 2:
    ms = ctx.toInt32(args[1])
  if ms <= 0: ms = 1
  let state = gState
  let id = state.nextTimerId
  inc state.nextTimerId
  state.timers.add(TimerEntry(
    id: id, fn: ctx.dupValue(fn),
    fireAt: SDL_GetTicks() + uint64(ms),
    interval: uint64(ms), active: true))
  ctx.newInt(int32(id))

proc jsClearTimer(ctx: ptr ScriptCtx; this: ScriptValue;
                  args: openArray[ScriptValue]): ScriptValue =
  if args.len < 1 or gState == nil: return ctx.newUndefined()
  let id = int(ctx.toInt32(args[0]))
  for t in gState.timers.mitems:
    if t.id == id and t.active:
      t.active = false
      break
  ctx.newUndefined()

proc jsLoadImage(ctx: ptr ScriptCtx; this: ScriptValue;
                 args: openArray[ScriptValue]): ScriptValue =
  ## __rw_loadImage(imgObj, src) — stub: immediately fires onload with size 1×1.
  ## A real implementation would load via SDL_image and set naturalWidth/Height.
  if args.len < 1: return ctx.newUndefined()
  let imgObj = args[0]
  # Mark complete
  ctx.setPropSteal(imgObj, "complete",      ctx.newBool(true))
  ctx.setPropSteal(imgObj, "naturalWidth",  ctx.newInt(1))
  ctx.setPropSteal(imgObj, "naturalHeight", ctx.newInt(1))
  ctx.setPropSteal(imgObj, "width",         ctx.newInt(1))
  ctx.setPropSteal(imgObj, "height",        ctx.newInt(1))
  # Fire load event via dispatchEvent (covers both addEventListener and onload)
  let dispFn = ctx.getProp(imgObj, "dispatchEvent")
  if ctx.isFunction(dispFn):
    let evtObj = ctx.newObject()
    ctx.setPropSteal(evtObj, "type", ctx.newString("load"))
    let r = ctx.callFunction1(dispFn, imgObj, evtObj)
    discard ctx.checkException(r, "Image.dispatchEvent(load)")
    ctx.freeValue(evtObj)
  else:
    let onload = ctx.getProp(imgObj, "onload")
    if ctx.isFunction(onload):
      let r = ctx.callFunction0(onload, imgObj)
      discard ctx.checkException(r, "Image.onload")
    ctx.freeValue(onload)
  ctx.freeValue(dispFn)
  ctx.newUndefined()

proc bindDom(state: ptr RWebviewState) =
  ## Install native DOM functions via RGSS ScriptCtx.
  gState = state
  let ctx = state.scriptCtx

  # performance.now — installed on window.performance + global performance
  # We use ctx.eval to set up the property chain since performance.now
  # must be an object method, not a global function.
  ctx.bindGlobal("__rw_getTicksMs", jsGetTicks, 0)

  # rAF / timer natives — these get installed on both window.* and global
  ctx.bindGlobal("requestAnimationFrame",  jsRequestAnimationFrame, 1)
  ctx.bindGlobal("cancelAnimationFrame",   jsCancelAnimationFrame,  1)
  ctx.bindGlobal("setTimeout",             jsSetTimeout,            2)
  ctx.bindGlobal("setInterval",            jsSetInterval,           2)
  ctx.bindGlobal("clearTimeout",           jsClearTimer,            1)
  ctx.bindGlobal("clearInterval",          jsClearTimer,            1)

  # Image loader stub — will be overridden by XHR module's jsLoadImageReal
  ctx.bindGlobal("__rw_loadImage", jsLoadImage, 2)

  # Also put these on the window object so `window.setTimeout(...)` works
  let winTimerGlue = """
(function() {
  var w = (typeof window !== 'undefined') ? window : {};
  w.requestAnimationFrame  = requestAnimationFrame;
  w.cancelAnimationFrame   = cancelAnimationFrame;
  w.setTimeout             = setTimeout;
  w.setInterval            = setInterval;
  w.clearTimeout           = clearTimeout;
  w.clearInterval          = clearInterval;
  if (w.performance) w.performance.now = __rw_getTicksMs;
  if (typeof performance !== 'undefined') performance.now = __rw_getTicksMs;
})();
"""
  discard ctx.checkException(ctx.eval(cstring(winTimerGlue), "<dom-bind-glue>"),
                             "<dom-bind-glue>")

# ===========================================================================
# Phase 3 — per-frame timer/rAF dispatch helpers
# ===========================================================================

proc dispatchTimers(state: ptr RWebviewState) =
  ## Fire any timers whose fireAt <= now.  setInterval timers reschedule themselves.
  let ctx  = state.scriptCtx
  let now  = SDL_GetTicks()
  var i = 0
  while i < state.timers.len:
    let t = addr state.timers[i]
    if not t.active:
      ctx.freeValue(t.fn)
      state.timers.delete(i)
      continue
    if now >= t.fireAt:
      if t.interval > 0:
        # setInterval: reschedule first, then call (so cleared interval in callback works)
        t.fireAt = now + t.interval
        let fn = ctx.dupValue(t.fn)
        let r  = ctx.callFunction0(fn, ctx.newUndefined())
        discard ctx.checkException(r, "setInterval callback")
        ctx.freeValue(fn)
        inc i
      else:
        # setTimeout: deactivate, extract fn, delete, call
        t.active = false
        let fn = t.fn   # don't dup — we take ownership
        state.timers.delete(i)
        let r = ctx.callFunction0(fn, ctx.newUndefined())
        discard ctx.checkException(r, "setTimeout callback")
        ctx.freeValue(fn)
        # don't inc i: slot was removed
    else:
      inc i

proc dispatchRaf(state: ptr RWebviewState) =
  ## Fire all pending rAF callbacks, then pump micro-tasks.
  ## Callbacks registered during dispatch go to rafPending for next frame.
  let ctx = state.scriptCtx

  # Pump any micro-tasks / Promise continuations BEFORE rAF callbacks,
  # so Promises queued during script execution resolve before rAF checks them.
  ctx.flushJobs()

  # Take current rafPending; anything registered during execution goes
  # to the fresh rafPending and fires on the NEXT frame (correct browser behaviour).
  var toRun = move(state.rafPending)
  state.rafPending = @[]
  let ts = ctx.newFloat(float64(SDL_GetTicks()))
  for e in toRun:
    let r = ctx.callFunction1(e.fn, ctx.newUndefined(), ts)
    discard ctx.checkException(r, "requestAnimationFrame callback")
    ctx.freeValue(e.fn)
  ctx.freeValue(ts)
  # Pump any micro-tasks / Promise continuations
  ctx.flushJobs()

