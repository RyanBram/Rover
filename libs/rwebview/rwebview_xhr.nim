# ===========================================================================
# Phase 6 — Asset Loading (XMLHttpRequest, Fetch API, Image Decoding)
# ===========================================================================
#
# Included by rwebview.nim after rwebview_gl.nim.
# Depends on: rwebview_ffi_quickjs (JS helpers), rwebview_ffi_sdl3 (SDL_Surface),
#             rwebview_ffi_sdl3_media (IMG_Load, SDL_ConvertSurface),
#             rwebview_dom (gState), rwebview_html (resolveUrl)

# ===========================================================================
# 6.1 — XMLHttpRequest  (synchronous local-file loader)
# ===========================================================================
#
# RPG Maker MV uses XHR for loading JSON data files, plugin configs, etc.
# All requests are local files resolved via resolveUrl.

proc jsXhrOpen(ctx: ptr JSContext; thisVal: JSValue;
               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## xhr.open(method, url[, async])  — store method + resolved URL
  if argc < 2: return rw_JS_Undefined()
  let url = argStr(ctx, argv, 1)
  discard JS_SetPropertyStr(ctx, thisVal, "_url", rw_JS_NewString(ctx, cstring(url)))
  discard JS_SetPropertyStr(ctx, thisVal, "readyState", rw_JS_NewInt32(ctx, 1))
  rw_JS_Undefined()

proc jsXhrSend(ctx: ptr JSContext; thisVal: JSValue;
               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## xhr.send()  — read file synchronously, set response fields, fire onload
  let state = gState
  if state == nil: return rw_JS_Undefined()

  let urlVal = JS_GetPropertyStr(ctx, thisVal, "_url")
  let url = jsValToStr(ctx, urlVal)
  rw_JS_FreeValue(ctx, urlVal)

  let filePath = resolveUrl(url, state)

  # Check responseType
  let rtVal = JS_GetPropertyStr(ctx, thisVal, "responseType")
  let responseType = jsValToStr(ctx, rtVal)
  rw_JS_FreeValue(ctx, rtVal)

  if fileExists(filePath):
    discard JS_SetPropertyStr(ctx, thisVal, "status", rw_JS_NewInt32(ctx, 200))
    discard JS_SetPropertyStr(ctx, thisVal, "readyState", rw_JS_NewInt32(ctx, 4))

    if responseType == "arraybuffer":
      let data = readFile(filePath)
      let ab = rw_JS_NewArrayBufferCopy(ctx, cast[pointer](cstring(data)), csize_t(data.len))
      discard JS_SetPropertyStr(ctx, thisVal, "response", ab)
      discard JS_SetPropertyStr(ctx, thisVal, "responseText", rw_JS_NewString(ctx, ""))
    else:
      let text = readFile(filePath)
      let jsStr = rw_JS_NewString(ctx, cstring(text))
      discard JS_SetPropertyStr(ctx, thisVal, "responseText", rw_JS_DupValue(ctx, jsStr))
      if responseType == "json":
        # Parse as JSON and set .response
        let global = JS_GetGlobalObject(ctx)
        let jsonObj = JS_GetPropertyStr(ctx, global, "JSON")
        let parseFn = JS_GetPropertyStr(ctx, jsonObj, "parse")
        var arg = jsStr
        let parsed = JS_Call(ctx, parseFn, jsonObj, 1, addr arg)
        discard JS_SetPropertyStr(ctx, thisVal, "response", parsed)
        rw_JS_FreeValue(ctx, parseFn)
        rw_JS_FreeValue(ctx, jsonObj)
        rw_JS_FreeValue(ctx, global)
        rw_JS_FreeValue(ctx, jsStr)
      else:
        # responseType "" or "text" → response = responseText
        discard JS_SetPropertyStr(ctx, thisVal, "response", jsStr)

    # Fire onreadystatechange
    let orsc = JS_GetPropertyStr(ctx, thisVal, "onreadystatechange")
    if JS_IsFunction(ctx, orsc) != 0:
      let r = JS_Call(ctx, orsc, thisVal, 0, nil)
      discard jsCheck(ctx, r, "xhr.onreadystatechange")
    rw_JS_FreeValue(ctx, orsc)

    # Fire onload
    let onload = JS_GetPropertyStr(ctx, thisVal, "onload")
    if JS_IsFunction(ctx, onload) != 0:
      let r = JS_Call(ctx, onload, thisVal, 0, nil)
      discard jsCheck(ctx, r, "xhr.onload")
    rw_JS_FreeValue(ctx, onload)
  else:
    discard JS_SetPropertyStr(ctx, thisVal, "status", rw_JS_NewInt32(ctx, 404))
    discard JS_SetPropertyStr(ctx, thisVal, "readyState", rw_JS_NewInt32(ctx, 4))
    let onerror = JS_GetPropertyStr(ctx, thisVal, "onerror")
    if JS_IsFunction(ctx, onerror) != 0:
      let r = JS_Call(ctx, onerror, thisVal, 0, nil)
      discard jsCheck(ctx, r, "xhr.onerror")
    rw_JS_FreeValue(ctx, onerror)

  rw_JS_Undefined()

proc jsXhrSetRequestHeader(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()  # no-op stub

proc jsXhrGetResponseHeader(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Null()  # no-op stub

proc jsXhrOverrideMimeType(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()  # no-op stub

proc jsXhrAbort(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_Undefined()  # no-op stub

# ===========================================================================
# 6.2 — Fetch API  (local-file based, returns thennable objects)
# ===========================================================================
#
# QuickJS has built-in Promise support. We create a JS-level fetch()
# that reads a local file and returns a Response-like object.
# Since all I/O is local, we do it synchronously but wrap in Promise.resolve().

proc jsFetch(ctx: ptr JSContext; thisVal: JSValue;
             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## fetch(url) → Promise<Response>
  ## Reads local file synchronously, wraps result in a Promise.resolve().
  let state = gState
  if state == nil or argc < 1: return rw_JS_Undefined()

  let url = argStr(ctx, argv, 0)
  let filePath = resolveUrl(url, state)

  # Build a Response-like object
  let resp = JS_NewObject(ctx)

  if fileExists(filePath):
    let data = readFile(filePath)
    discard JS_SetPropertyStr(ctx, resp, "ok", rw_JS_True())
    discard JS_SetPropertyStr(ctx, resp, "status", rw_JS_NewInt32(ctx, 200))
    discard JS_SetPropertyStr(ctx, resp, "statusText", rw_JS_NewString(ctx, "OK"))

    # Store raw data as a hidden property for arrayBuffer() / blob()
    let ab = rw_JS_NewArrayBufferCopy(ctx, cast[pointer](cstring(data)), csize_t(data.len))
    discard JS_SetPropertyStr(ctx, resp, "_data", rw_JS_NewString(ctx, cstring(data)))
    discard JS_SetPropertyStr(ctx, resp, "_ab", ab)
  else:
    discard JS_SetPropertyStr(ctx, resp, "ok", rw_JS_False())
    discard JS_SetPropertyStr(ctx, resp, "status", rw_JS_NewInt32(ctx, 404))
    discard JS_SetPropertyStr(ctx, resp, "statusText", rw_JS_NewString(ctx, "Not Found"))
    discard JS_SetPropertyStr(ctx, resp, "_data", rw_JS_NewString(ctx, ""))

  # Wrap in Promise.resolve(resp) using JS eval
  let global = JS_GetGlobalObject(ctx)
  let promiseObj = JS_GetPropertyStr(ctx, global, "Promise")
  let resolveFn = JS_GetPropertyStr(ctx, promiseObj, "resolve")
  var respArg = resp
  let promise = JS_Call(ctx, resolveFn, promiseObj, 1, addr respArg)
  rw_JS_FreeValue(ctx, resolveFn)
  rw_JS_FreeValue(ctx, promiseObj)
  rw_JS_FreeValue(ctx, global)
  rw_JS_FreeValue(ctx, resp)
  promise

# ===========================================================================
# 6.3 — Image Decoding via SDL3_image
# ===========================================================================
#
# Replaces the stub jsLoadImage in rwebview_dom.nim.
# On img.src = url, decodes the image via IMG_Load, converts to RGBA32,
# stores pixel data as __pixelData / __pixelWidth / __pixelHeight on the
# JS image object, then fires load/error via dispatchEvent.

proc jsFireImgEvt(ctx: ptr JSContext; imgObj: JSValue; evtType: cstring) =
  ## Fire a load/error event on an Image JS object.
  ## Calls dispatchEvent which covers both addEventListener listeners and on* handler.
  let dispFn = JS_GetPropertyStr(ctx, imgObj, "dispatchEvent")
  if JS_IsFunction(ctx, dispFn) != 0:
    let evtObj = JS_NewObject(ctx)
    discard JS_SetPropertyStr(ctx, evtObj, "type", rw_JS_NewString(ctx, evtType))
    var ea = evtObj
    let r = JS_Call(ctx, dispFn, imgObj, 1, addr ea)
    discard jsCheck(ctx, r, $evtType)
    rw_JS_FreeValue(ctx, r)
    rw_JS_FreeValue(ctx, evtObj)
  else:
    # Fallback: call on* handler directly
    let cbName = "on" & $evtType
    let cb = JS_GetPropertyStr(ctx, imgObj, cstring(cbName))
    if JS_IsFunction(ctx, cb) != 0:
      let r = JS_Call(ctx, cb, imgObj, 0, nil)
      discard jsCheck(ctx, r, cbName)
      rw_JS_FreeValue(ctx, r)
    rw_JS_FreeValue(ctx, cb)
  rw_JS_FreeValue(ctx, dispFn)

proc jsLoadImageReal(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_loadImage(imgObj, src) — decode image via SDL3_image
  if argc < 2: return rw_JS_Undefined()
  let imgObj = cast[ptr JSValue](argv)[]
  let src = argStr(ctx, argv, 1)
  let state = gState
  if state == nil: return rw_JS_Undefined()

  let filePath = resolveUrl(src, state)

  if not fileExists(filePath):
    discard JS_SetPropertyStr(ctx, imgObj, "complete", rw_JS_True())
    jsFireImgEvt(ctx, imgObj, "error")
    return rw_JS_Undefined()

  let rawSurf = IMG_Load(cstring(filePath))
  if rawSurf == nil:
    stderr.writeLine("[rwebview] IMG_Load failed: " & filePath)
    discard JS_SetPropertyStr(ctx, imgObj, "complete", rw_JS_True())
    jsFireImgEvt(ctx, imgObj, "error")
    return rw_JS_Undefined()

  # Convert to RGBA32
  let surfPtr = SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_RGBA32)
  SDL_DestroySurface(rawSurf)
  if surfPtr == nil:
    stderr.writeLine("[rwebview] SDL_ConvertSurface failed for: " & filePath)
    discard JS_SetPropertyStr(ctx, imgObj, "complete", rw_JS_True())
    jsFireImgEvt(ctx, imgObj, "error")
    return rw_JS_Undefined()

  let surf = cast[ptr SDL_Surface](surfPtr)
  let w = surf.w
  let h = surf.h
  let rowBytes = cint(w * 4)  # RGBA32 = 4 bytes per pixel
  stderr.writeLine("[rwebview] Image loaded: " & filePath &
                   " (" & $w & "x" & $h &
                   ", pitch=" & $surf.pitch & ", rowBytes=" & $rowBytes & ")")

  # Copy pixel data row-by-row, stripping any pitch padding
  var pixelData: JSValue
  if surf.pitch == rowBytes:
    # Fast path: pitch matches, copy all at once
    pixelData = rw_JS_NewArrayBufferCopy(ctx, surf.pixels, csize_t(h * rowBytes))
  else:
    # Slow path: pitch has padding; copy row-by-row into a clean buffer
    let totalBytes = int(h) * int(rowBytes)
    var cleanBuf = newSeq[uint8](totalBytes)
    let srcBase = cast[ptr UncheckedArray[uint8]](surf.pixels)
    for row in 0..<int(h):
      let srcOff = row * int(surf.pitch)
      let dstOff = row * int(rowBytes)
      copyMem(addr cleanBuf[dstOff], addr srcBase[srcOff], int(rowBytes))
    pixelData = rw_JS_NewArrayBufferCopy(ctx, addr cleanBuf[0], csize_t(totalBytes))
  SDL_DestroySurface(surfPtr)

  # Set properties on the image object
  discard JS_SetPropertyStr(ctx, imgObj, "__pixelData",   pixelData)
  discard JS_SetPropertyStr(ctx, imgObj, "__pixelWidth",  rw_JS_NewInt32(ctx, int32(w)))
  discard JS_SetPropertyStr(ctx, imgObj, "__pixelHeight", rw_JS_NewInt32(ctx, int32(h)))
  discard JS_SetPropertyStr(ctx, imgObj, "complete",      rw_JS_True())
  discard JS_SetPropertyStr(ctx, imgObj, "naturalWidth",  rw_JS_NewInt32(ctx, int32(w)))
  discard JS_SetPropertyStr(ctx, imgObj, "naturalHeight", rw_JS_NewInt32(ctx, int32(h)))
  discard JS_SetPropertyStr(ctx, imgObj, "width",         rw_JS_NewInt32(ctx, int32(w)))
  discard JS_SetPropertyStr(ctx, imgObj, "height",        rw_JS_NewInt32(ctx, int32(h)))

  jsFireImgEvt(ctx, imgObj, "load")
  rw_JS_Undefined()

# ===========================================================================
# 6.4 — bindXhr / bindFetch — install XHR + Fetch + Image into JS global
# ===========================================================================

proc bindXhr(state: ptr RWebviewState) =
  let ctx    = state.jsCtx
  let global = JS_GetGlobalObject(ctx)

  # ── XMLHttpRequest constructor ────────────────────────────────────────
  # We inject the constructor and Response.prototype.text/json/arrayBuffer
  # as JS code that calls into our native methods.
  let xhrSetup = """
(function() {
  function XMLHttpRequest() {
    this.readyState = 0;
    this.status = 0;
    this.responseText = '';
    this.response = null;
    this.responseType = '';
    this.onload = null;
    this.onerror = null;
    this.onreadystatechange = null;
    this.onprogress = null;
  }
  XMLHttpRequest.prototype.open = function(method, url, async) {
    __rw_xhr_open.call(this, method, url);
  };
  XMLHttpRequest.prototype.send = function(body) {
    __rw_xhr_send.call(this, body);
  };
  XMLHttpRequest.prototype.setRequestHeader = function(k,v) {};
  XMLHttpRequest.prototype.getResponseHeader = function(k) { return null; };
  XMLHttpRequest.prototype.overrideMimeType = function(m) {};
  XMLHttpRequest.prototype.abort = function() {};
  XMLHttpRequest.prototype.getAllResponseHeaders = function() { return ''; };
  XMLHttpRequest.UNSENT = 0;
  XMLHttpRequest.OPENED = 1;
  XMLHttpRequest.HEADERS_RECEIVED = 2;
  XMLHttpRequest.LOADING = 3;
  XMLHttpRequest.DONE = 4;
  window.XMLHttpRequest = XMLHttpRequest;

  // ── Response prototype for fetch() ──────────────────────────────────
  function __RwResponse() {}
  __RwResponse.prototype.text = function() {
    return Promise.resolve(this._data || '');
  };
  __RwResponse.prototype.json = function() {
    return Promise.resolve(JSON.parse(this._data || 'null'));
  };
  __RwResponse.prototype.arrayBuffer = function() {
    return Promise.resolve(this._ab || new ArrayBuffer(0));
  };
  __RwResponse.prototype.blob = function() {
    return Promise.resolve({ size: (this._data||'').length, type: '' });
  };
  __RwResponse.prototype.clone = function() {
    var c = new __RwResponse();
    c.ok = this.ok; c.status = this.status;
    c.statusText = this.statusText;
    c._data = this._data; c._ab = this._ab;
    return c;
  };
  window.__RwResponse = __RwResponse;
})();
"""
  let r = JS_Eval(ctx, cstring(xhrSetup), csize_t(xhrSetup.len),
                  "<xhr-setup>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, r, "<xhr-setup>")

  # Install native XHR methods
  let xhrOpenFn = JS_NewCFunction(ctx, cast[JSCFunction](jsXhrOpen), "__rw_xhr_open", 2)
  discard JS_SetPropertyStr(ctx, global, "__rw_xhr_open", xhrOpenFn)
  let xhrSendFn = JS_NewCFunction(ctx, cast[JSCFunction](jsXhrSend), "__rw_xhr_send", 1)
  discard JS_SetPropertyStr(ctx, global, "__rw_xhr_send", xhrSendFn)

  # Install native fetch — wraps jsFetch + patches Response prototype
  let fetchNative = JS_NewCFunction(ctx, cast[JSCFunction](jsFetch), "__rw_fetch_native", 1)
  discard JS_SetPropertyStr(ctx, global, "__rw_fetch_native", fetchNative)

  let fetchWrap = """
(function() {
  var __RwResponse = window.__RwResponse;
  window.fetch = function(url, opts) {
    var resp = __rw_fetch_native(typeof url === 'string' ? url : (url && url.url ? url.url : String(url)));
    return resp.then(function(r) {
      // Patch the plain object into a __RwResponse instance
      var rr = new __RwResponse();
      rr.ok = r.ok; rr.status = r.status; rr.statusText = r.statusText;
      rr._data = r._data; rr._ab = r._ab;
      rr.headers = { get: function(){ return null; } };
      return rr;
    });
  };
})();
"""
  let r2 = JS_Eval(ctx, cstring(fetchWrap), csize_t(fetchWrap.len),
                   "<fetch-setup>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, r2, "<fetch-setup>")

  # ── Override __rw_loadImage with real SDL3_image loader ────────────────
  let liFn = JS_NewCFunction(ctx, cast[JSCFunction](jsLoadImageReal), "__rw_loadImage", 2)
  discard JS_SetPropertyStr(ctx, global, "__rw_loadImage", liFn)

  # ── URL.createObjectURL / revokeObjectURL stubs ───────────────────────
  let urlStubs = """
(function() {
  if (!window.URL) window.URL = {};
  var _blobCounter = 0;
  window.URL.createObjectURL = function(blob) {
    return 'blob:rwebview/' + (++_blobCounter);
  };
  window.URL.revokeObjectURL = function(url) {};
})();
"""
  let r3 = JS_Eval(ctx, cstring(urlStubs), csize_t(urlStubs.len),
                   "<url-stubs>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, r3, "<url-stubs>")

  # Copy window.* properties to the QuickJS global so bare names work
  let globalizeXhr = """
var XMLHttpRequest = window.XMLHttpRequest;
var fetch = window.fetch;
var URL = window.URL;
"""
  let r4 = JS_Eval(ctx, cstring(globalizeXhr), csize_t(globalizeXhr.len),
                   "<globalize-xhr>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, r4, "<globalize-xhr>")

  rw_JS_FreeValue(ctx, global)
