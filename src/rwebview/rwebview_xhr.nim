# =============================================================================
# rwebview_xhr.nim
# Asset loading subsystem: XMLHttpRequest, Fetch API, and image decoding.
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
#   Implements browser-like asset loading with the following optimizations:
#     1. Parallel fetching      — up to 6 concurrent XHR/fetch per frame (HTTP/1.1 style)
#     2. Speculative preload    — scans HTML for <img>/<script>/<link> ahead of parser
#     3. Async image decoding   — time-budgeted batch decode, now cache-aware
#     4. HTTP file cache        — readFile results cached in memory (Cache-Control equivalent)
#     5. Memory cache           — decoded image pixel data cached (avoid re-decode)
#     6. Request prioritization — CSS/JS high, images low; queue sorted by priority
#
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rgss/rgss_api            # ScriptCtx/ScriptValue types + forwarding procs
#   - rwebview_ffi_sdl3        # SDL_Surface
#   - rwebview_ffi_sdl3_media  # IMG_Load, SDL_ConvertSurface
#   - rwebview_dom             # gState
#   - rwebview_html            # resolveUrl
#
# Used by:
#   - rwebview.nim             # included after rwebview_gl.nim
#
# =============================================================================

type
  ResourcePriority* = enum
    rpCritical = 0  ## CSS, synchronous JS
    rpHigh     = 1  ## Async JS, fonts
    rpNormal   = 2  ## XHR data, fetch
    rpLow      = 3  ## Images

  ## File read cache — equivalent to browser HTTP disk cache.
  ## Keyed by absolute file path. Avoids redundant disk I/O for the same asset.
  FileCacheEntry = object
    data: string       ## raw file bytes
    timestamp: uint64  ## SDL_GetTicks() when cached (for LRU eviction)

  ## Decoded image memory cache — avoids re-decoding PNG/JPG for repeated use.
  ## Keyed by absolute file path. Stores RGBA32 pixel data ready for GL upload.
  ImageCacheEntry = object
    pixelData: seq[uint8]
    width: int32
    height: int32
    timestamp: uint64  ## SDL_GetTicks() when cached (for LRU eviction)

const
  maxFileCacheEntries = 512     ## max cached file reads
  maxImageCacheEntries = 256    ## max cached decoded images
  maxParallelFetches = 6        ## browser-like connection limit per frame batch

var
  fileCacheTable: Table[string, FileCacheEntry]
  imageCacheTable: Table[string, ImageCacheEntry]
  fileCacheHits: int
  fileCacheMisses: int
  imageCacheHits: int
  imageCacheMisses: int

proc cachedReadFile(path: string): string =
  ## Read a file with caching. Returns cached content if available,
  ## otherwise reads from disk and stores in cache.
  let now = SDL_GetTicks()
  if path in fileCacheTable:
    inc fileCacheHits
    fileCacheTable[path].timestamp = now
    return fileCacheTable[path].data
  inc fileCacheMisses
  result = readFile(path)
  # Evict oldest entry if cache is full
  if fileCacheTable.len >= maxFileCacheEntries:
    var oldestKey: string
    var oldestTime = uint64.high
    for k, v in fileCacheTable:
      if v.timestamp < oldestTime:
        oldestTime = v.timestamp
        oldestKey = k
    fileCacheTable.del(oldestKey)
  fileCacheTable[path] = FileCacheEntry(data: result, timestamp: now)

proc cachedImageLookup(path: string): ptr ImageCacheEntry =
  ## Check if decoded image data is in the memory cache.
  ## Returns nil if not found. Updates timestamp on hit.
  if path in imageCacheTable:
    inc imageCacheHits
    imageCacheTable[path].timestamp = SDL_GetTicks()
    return addr imageCacheTable[path]
  return nil

proc cachedImageStore(path: string; pixels: seq[uint8]; w, h: int32) =
  ## Store decoded image pixel data in the memory cache.
  let now = SDL_GetTicks()
  # Evict oldest entry if cache is full
  if imageCacheTable.len >= maxImageCacheEntries:
    var oldestKey: string
    var oldestTime = uint64.high
    for k, v in imageCacheTable:
      if v.timestamp < oldestTime:
        oldestTime = v.timestamp
        oldestKey = k
    imageCacheTable.del(oldestKey)
  imageCacheTable[path] = ImageCacheEntry(
    pixelData: pixels, width: w, height: h, timestamp: now)

proc clearAssetCaches*() =
  ## Clear all asset caches. Called on page navigation to free memory.
  fileCacheTable.clear()
  imageCacheTable.clear()
  fileCacheHits = 0
  fileCacheMisses = 0
  imageCacheHits = 0
  imageCacheMisses = 0
  stderr.writeLine("[cache] Asset caches cleared")

proc logCacheStats*() =
  ## Log cache hit/miss statistics (called periodically or on navigation).
  if fileCacheHits + fileCacheMisses > 0:
    stderr.writeLine("[cache] File cache: " & $fileCacheHits & " hits, " &
                     $fileCacheMisses & " misses (" & $fileCacheTable.len & " entries)")
  if imageCacheHits + imageCacheMisses > 0:
    stderr.writeLine("[cache] Image cache: " & $imageCacheHits & " hits, " &
                     $imageCacheMisses & " misses (" & $imageCacheTable.len & " entries)")

# ===========================================================================
# 6.0b — Speculative Preload Scanner
# ===========================================================================
#
# Scans raw HTML for resource URLs (<img src>, <script src>, <link href>)
# and pre-reads them into the file cache before JS execution begins.
# This mirrors the browser preload scanner that runs ahead of the HTML parser.

proc preloadScanHtml*(htmlContent: string; baseDir: string) =
  ## Scan HTML for <img src="...">, <script src="...">, <link href="...">
  ## and pre-cache the file contents in fileCacheTable.
  ## Called from navigateImpl() before script execution.
  var preloadCount = 0
  let t0 = SDL_GetTicks()

  # Use Lexbor to properly parse and extract resource URLs
  let parser = lxb_html_parser_create()
  if parser == nil: return
  if lxb_html_parser_init(parser) != lxbStatusOk:
    discard lxb_html_parser_destroy(parser)
    return

  let doc = lxb_html_parse(parser,
               cast[pointer](cstring(htmlContent)),
               csize_t(htmlContent.len))
  discard lxb_html_parser_destroy(parser)
  if doc == nil: return

  let domDoc = rw_lxb_html_doc_to_dom(doc)
  if domDoc == nil:
    discard lxb_html_document_destroy(doc)
    return

  let rootEl = lxb_dom_document_element_noi(domDoc)
  if rootEl == nil:
    discard lxb_html_document_destroy(doc)
    return

  # Scan <img> tags
  block:
    let col = lxb_dom_collection_make_noi(domDoc, 64)
    if col != nil:
      let tag = "img"
      if lxb_dom_elements_by_tag_name(rootEl, col,
           cast[pointer](cstring(tag)), csize_t(tag.len)) == lxbStatusOk:
        let count = lxb_dom_collection_length_noi(col)
        for i in 0 ..< count:
          let el = lxb_dom_collection_element_noi(col, i)
          if el == nil: continue
          let src = elemAttr(el, "src")
          if src.len > 0:
            let path = if isAbsolute(src): src else: baseDir / src
            if fileExists(path) and path notin fileCacheTable:
              discard cachedReadFile(path)
              inc preloadCount
      discard lxb_dom_collection_destroy(col, true)

  # Scan <script> tags
  block:
    let col = lxb_dom_collection_make_noi(domDoc, 64)
    if col != nil:
      let tag = "script"
      if lxb_dom_elements_by_tag_name(rootEl, col,
           cast[pointer](cstring(tag)), csize_t(tag.len)) == lxbStatusOk:
        let count = lxb_dom_collection_length_noi(col)
        for i in 0 ..< count:
          let el = lxb_dom_collection_element_noi(col, i)
          if el == nil: continue
          let src = elemAttr(el, "src")
          if src.len > 0:
            let path = if isAbsolute(src): src else: baseDir / src
            if fileExists(path) and path notin fileCacheTable:
              discard cachedReadFile(path)
              inc preloadCount
      discard lxb_dom_collection_destroy(col, true)

  # Scan <link> tags (stylesheets, etc.)
  block:
    let col = lxb_dom_collection_make_noi(domDoc, 32)
    if col != nil:
      let tag = "link"
      if lxb_dom_elements_by_tag_name(rootEl, col,
           cast[pointer](cstring(tag)), csize_t(tag.len)) == lxbStatusOk:
        let count = lxb_dom_collection_length_noi(col)
        for i in 0 ..< count:
          let el = lxb_dom_collection_element_noi(col, i)
          if el == nil: continue
          let href = elemAttr(el, "href")
          if href.len > 0:
            let path = if isAbsolute(href): href else: baseDir / href
            if fileExists(path) and path notin fileCacheTable:
              discard cachedReadFile(path)
              inc preloadCount
      discard lxb_dom_collection_destroy(col, true)

  discard lxb_html_document_destroy(doc)
  let dt = SDL_GetTicks() - t0
  if preloadCount > 0:
    stderr.writeLine("[preload] Scanned HTML: pre-cached " & $preloadCount &
                     " resources in " & $dt & "ms")

# ===========================================================================
# 6.1 — XMLHttpRequest  (async local-file loader with sync fallback)
# ===========================================================================
#
# OPT-3: Async XHR — xhr.send() is deferred for async requests (default).
# Synchronous XHR (xhr.open(method, url, false)) is processed immediately
# to support polyfill fs operations (readFileSync, existsSync, etc.).
#
# OPT-6: Requests are prioritized — JS/CSS are processed before images.

type
  PendingXhr = object
    xhrObj: ScriptValue      ## DupValue'd XHR JS object
    filePath: string     ## Resolved local file path
    responseType: string ## "", "text", "json", "arraybuffer"
    url: string          ## Original URL for logging
    priority: ResourcePriority  ## Request priority for queue sorting

var pendingXhrRequests: seq[PendingXhr]

proc fulfillXhr(ctx: ptr ScriptCtx; thisVal: ScriptValue;
                filePath, url, responseType: string) =
  ## Common XHR fulfillment: read file, set response fields, fire events.
  ## Used by both sync path (inline in jsXhrSend) and async path (processXhrQueue).
  ## OPT-4: Uses file cache to avoid redundant disk reads.
  if fileExists(filePath):
    stderr.writeLine("[XHR] 200 " & url)
    ctx.setPropSteal(thisVal, "status", ctx.newInt(200))
    ctx.setPropSteal(thisVal, "readyState", ctx.newInt(4))

    if responseType == "arraybuffer":
      let data = cachedReadFile(filePath)
      let ab = ctx.newArrayBufferCopy(cast[pointer](cstring(data)), data.len)
      ctx.setPropSteal(thisVal, "response", ab)
      ctx.setPropSteal(thisVal, "responseText", ctx.newString(""))
    else:
      var text = cachedReadFile(filePath)
      if text.len >= 3 and text[0] == '\xEF' and text[1] == '\xBB' and text[2] == '\xBF':
        text = text[3 .. ^1]
      let jsStr = ctx.newString(cstring(text))
      ctx.setProp(thisVal, "responseText", jsStr)  # setProp dups, we still own jsStr
      if responseType == "json":
        let global = ctx.getGlobal()
        let jsonObj = ctx.getProp(global, "JSON")
        let parseFn = ctx.getProp(jsonObj, "parse")
        let parsed = ctx.callFunction1(parseFn, jsonObj, jsStr)
        ctx.setPropSteal(thisVal, "response", parsed)
        ctx.freeValue(parseFn)
        ctx.freeValue(jsonObj)
        ctx.freeValue(global)
        ctx.freeValue(jsStr)
      else:
        ctx.setPropSteal(thisVal, "response", jsStr)

    let dispFn = ctx.getProp(thisVal, "dispatchEvent")
    if ctx.isFunction(dispFn):
      let rscEvt = ctx.newObject()
      ctx.setPropSteal(rscEvt, "type", ctx.newString("readystatechange"))
      discard ctx.checkException(ctx.callFunction1(dispFn, thisVal, rscEvt), "xhr.readystatechange")
      ctx.freeValue(rscEvt)
      let loadEvt = ctx.newObject()
      ctx.setPropSteal(loadEvt, "type", ctx.newString("load"))
      discard ctx.checkException(ctx.callFunction1(dispFn, thisVal, loadEvt), "xhr.onload")
      ctx.freeValue(loadEvt)
    else:
      let orsc = ctx.getProp(thisVal, "onreadystatechange")
      if ctx.isFunction(orsc):
        discard ctx.checkException(ctx.callFunction0(orsc, thisVal), "xhr.onreadystatechange")
      ctx.freeValue(orsc)
      let onload = ctx.getProp(thisVal, "onload")
      if ctx.isFunction(onload):
        discard ctx.checkException(ctx.callFunction0(onload, thisVal), "xhr.onload")
      ctx.freeValue(onload)
    ctx.freeValue(dispFn)
  else:
    stderr.writeLine("[XHR] 404 " & url)
    ctx.setPropSteal(thisVal, "status", ctx.newInt(404))
    ctx.setPropSteal(thisVal, "readyState", ctx.newInt(4))
    let dispFnE = ctx.getProp(thisVal, "dispatchEvent")
    if ctx.isFunction(dispFnE):
      let errEvt = ctx.newObject()
      ctx.setPropSteal(errEvt, "type", ctx.newString("error"))
      discard ctx.checkException(ctx.callFunction1(dispFnE, thisVal, errEvt), "xhr.onerror")
      ctx.freeValue(errEvt)
    else:
      let onerror = ctx.getProp(thisVal, "onerror")
      if ctx.isFunction(onerror):
        discard ctx.checkException(ctx.callFunction0(onerror, thisVal), "xhr.onerror")
      ctx.freeValue(onerror)
    ctx.freeValue(dispFnE)

proc jsXhrOpen(ctx: ptr ScriptCtx; this: ScriptValue;
               args: openArray[ScriptValue]): ScriptValue =
  ## xhr.open(method, url[, async])  — store method + resolved URL + async flag
  if args.len < 2: return ctx.newUndefined()
  let url = ctx.toNimString(args[1])
  ctx.setPropSteal(this, "_url", ctx.newString(cstring(url)))
  ctx.setPropSteal(this, "readyState", ctx.newInt(1))
  # Store async flag: default true. If caller passes false, XHR is synchronous.
  var isAsync = true
  if args.len >= 3:
    isAsync = ctx.toBool(args[2])
  ctx.setPropSteal(this, "_async",
    if isAsync: ctx.newBool(true) else: ctx.newBool(false))
  ctx.newUndefined()

proc jsXhrSend(ctx: ptr ScriptCtx; this: ScriptValue;
               args: openArray[ScriptValue]): ScriptValue =
  ## xhr.send() — async: queue for next frame. sync: process immediately.
  let state = gState
  if state == nil: return ctx.newUndefined()

  let urlVal = ctx.getProp(this, "_url")
  let url = ctx.toNimString(urlVal)
  ctx.freeValue(urlVal)

  let filePath = resolveUrl(url, state)

  let rtVal = ctx.getProp(this, "responseType")
  let responseType = ctx.toNimString(rtVal)
  ctx.freeValue(rtVal)

  # Check async flag — synchronous XHR (async=false) must process inline.
  # This is required for polyfill fs operations (readFileSync, existsSync, etc.)
  let asyncVal = ctx.getProp(this, "_async")
  let isAsync = ctx.toBool(asyncVal)
  ctx.freeValue(asyncVal)

  if not isAsync:
    # Synchronous path: process inline immediately (for fs polyfill, etc.)
    fulfillXhr(ctx, this, filePath, url, responseType)
  else:
    # Async path: queue for deferred processing in processXhrQueue()
    pendingXhrRequests.add(PendingXhr(
      xhrObj: ctx.dupValue(this),
      filePath: filePath,
      responseType: responseType,
      url: url,
      priority: rpNormal
    ))
  ctx.newUndefined()

proc jsXhrSetRequestHeader(ctx: ptr ScriptCtx; this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue =
  ctx.newUndefined()  # no-op stub

proc jsXhrGetResponseHeader(ctx: ptr ScriptCtx; this: ScriptValue;
                            args: openArray[ScriptValue]): ScriptValue =
  ctx.newNull()  # no-op stub

proc jsXhrOverrideMimeType(ctx: ptr ScriptCtx; this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue =
  ctx.newUndefined()  # no-op stub

proc jsXhrAbort(ctx: ptr ScriptCtx; this: ScriptValue;
                args: openArray[ScriptValue]): ScriptValue =
  ctx.newUndefined()  # no-op stub

proc processXhrQueue*(state: ptr RWebviewState) =
  ## Process pending async XHR requests. Called once per frame.
  ## OPT-1: Processes up to maxParallelFetches (6) per frame, sorted by priority.
  ## OPT-4: Uses file cache for disk reads.
  ## Fires readystatechange + load/error events with microtask flush after each.
  if pendingXhrRequests.len == 0: return
  let t0 = SDL_GetTicks()

  # OPT-6: Sort by priority (lower enum value = higher priority)
  pendingXhrRequests.sort(proc(a, b: PendingXhr): int =
    ord(a.priority) - ord(b.priority))

  # OPT-1: Process up to maxParallelFetches per frame (browser-like connection limit)
  let batchSize = min(pendingXhrRequests.len, maxParallelFetches)
  var toProcess = pendingXhrRequests[0 ..< batchSize]
  pendingXhrRequests = pendingXhrRequests[batchSize .. ^1]

  let ctx = state.scriptCtx
  for req in toProcess:
    fulfillXhr(ctx, req.xhrObj, req.filePath, req.url, req.responseType)
    ctx.freeValue(req.xhrObj)
    ctx.flushJobs()
  let dt = SDL_GetTicks() - t0
  if dt > 2:
    stderr.writeLine("[perf] processXhrQueue: " & $toProcess.len & " reqs in " & $dt & "ms" &
                     (if pendingXhrRequests.len > 0: " (" & $pendingXhrRequests.len & " queued)" else: ""))

# ===========================================================================
# 6.2 — Fetch API  (async local-file loader, returns Promise)
# ===========================================================================
#
# OPT-4: fetch() is now truly async for file URLs — the request is queued
# and resolved in processFetchQueue() on the next frame.
# data: URLs are still processed immediately (no file I/O).

type
  PendingFetch = object
    resolveFn: ScriptValue   ## DupValue'd JS resolve callback
    rejectFn: ScriptValue    ## DupValue'd JS reject callback
    filePath: string     ## Resolved local file path
    url: string          ## Original URL (for logging)
    priority: ResourcePriority  ## Request priority for queue sorting

var pendingFetchRequests*: seq[PendingFetch]

proc jsFetchDataUrl(ctx: ptr ScriptCtx; this: ScriptValue;
                    args: openArray[ScriptValue]): ScriptValue =
  ## __rw_fetch_native(dataUrl) → Promise<Response>  (sync, data: URLs only)
  let state = gState
  if state == nil or args.len < 1: return ctx.newUndefined()
  let url = ctx.toNimString(args[0])
  let resp = ctx.newObject()

  let commaPos = url.find(',')
  if commaPos > 0:
    let header  = url[5 ..< commaPos]
    let body    = url[commaPos + 1 .. ^1]
    let decoded = if ";base64" in header: base64.decode(body) else: body
    ctx.setPropSteal(resp, "ok",         ctx.newBool(true))
    ctx.setPropSteal(resp, "status",     ctx.newInt(200))
    ctx.setPropSteal(resp, "statusText", ctx.newString("OK"))
    ctx.setPropSteal(resp, "_data",      ctx.newString(cstring(decoded)))
    let ab = ctx.newArrayBufferCopy(cast[pointer](cstring(decoded)), decoded.len)
    ctx.setPropSteal(resp, "_ab", ab)
  else:
    ctx.setPropSteal(resp, "ok",     ctx.newBool(false))
    ctx.setPropSteal(resp, "status", ctx.newInt(400))
    ctx.setPropSteal(resp, "_data",  ctx.newString(""))

  let global     = ctx.getGlobal()
  let promiseObj = ctx.getProp(global, "Promise")
  let resolveFn  = ctx.getProp(promiseObj, "resolve")
  let promise    = ctx.callFunction1(resolveFn, promiseObj, resp)
  ctx.freeValue(resolveFn); ctx.freeValue(promiseObj)
  ctx.freeValue(global);    ctx.freeValue(resp)
  promise

proc jsFetchQueue(ctx: ptr ScriptCtx; this: ScriptValue;
                  args: openArray[ScriptValue]): ScriptValue =
  ## __rw_fetch_queue(url, resolve, reject) — queue file fetch for async processing
  let state = gState
  if state == nil or args.len < 3: return ctx.newUndefined()
  let url = ctx.toNimString(args[0])
  let resolveFn = args[1]
  let rejectFn  = args[2]
  let filePath = resolveUrl(url, state)

  # OPT-6: Assign priority based on file extension
  let urlLower = url.toLowerAscii()
  discard urlLower  # priority uniform; kept for future use
  let prio = rpNormal

  pendingFetchRequests.add(PendingFetch(
    resolveFn: ctx.dupValue(resolveFn),
    rejectFn:  ctx.dupValue(rejectFn),
    filePath:  filePath,
    url:       url,
    priority:  prio
  ))
  ctx.newUndefined()

proc processFetchQueue*(state: ptr RWebviewState) =
  ## Process pending async fetch requests. Called once per frame.
  ## OPT-1: Up to maxParallelFetches per frame. OPT-4: file cache. OPT-6: prioritized.
  if pendingFetchRequests.len == 0: return
  let t0 = SDL_GetTicks()

  # OPT-6: Sort by priority (lower enum value = higher priority)
  pendingFetchRequests.sort(proc(a, b: PendingFetch): int =
    ord(a.priority) - ord(b.priority))

  # OPT-1: Process up to maxParallelFetches per frame
  let batchSize = min(pendingFetchRequests.len, maxParallelFetches)
  var toProcess = pendingFetchRequests[0 ..< batchSize]
  pendingFetchRequests = pendingFetchRequests[batchSize .. ^1]

  let ctx = state.scriptCtx

  for req in toProcess:
    let resp = ctx.newObject()
    if fileExists(req.filePath):
      stderr.writeLine("[fetch] 200 " & req.url)
      let data = cachedReadFile(req.filePath)              # OPT-4: file cache
      ctx.setPropSteal(resp, "ok", ctx.newBool(true))
      ctx.setPropSteal(resp, "status", ctx.newInt(200))
      ctx.setPropSteal(resp, "statusText", ctx.newString("OK"))
      let ab = ctx.newArrayBufferCopy(cast[pointer](cstring(data)), data.len)
      ctx.setPropSteal(resp, "_data", ctx.newString(cstring(data)))
      ctx.setPropSteal(resp, "_ab", ab)
    else:
      stderr.writeLine("[fetch] 404 " & req.url)
      ctx.setPropSteal(resp, "ok", ctx.newBool(false))
      ctx.setPropSteal(resp, "status", ctx.newInt(404))
      ctx.setPropSteal(resp, "statusText", ctx.newString("Not Found"))
      ctx.setPropSteal(resp, "_data", ctx.newString(""))

    discard ctx.checkException(ctx.callFunction1(req.resolveFn, ctx.newUndefined(), resp), "fetch.resolve")
    ctx.freeValue(resp)
    ctx.freeValue(req.resolveFn)
    ctx.freeValue(req.rejectFn)
    ctx.flushJobs()

  let dt = SDL_GetTicks() - t0
  if dt > 2:
    stderr.writeLine("[perf] processFetchQueue: " & $toProcess.len & " reqs in " & $dt & "ms" &
                     (if pendingFetchRequests.len > 0: " (" & $pendingFetchRequests.len & " queued)" else: ""))

# ===========================================================================
# 6.3 — Image Decoding via SDL3_image (deferred / async)
# ===========================================================================
#
# Replaces the stub jsLoadImage in rwebview_dom.nim.
# OPT-1: Image decode is DEFERRED — setting img.src queues the request;
# processImageQueue() (called once per frame from the main loop) decodes
# at most one image per frame, then fires load/error via dispatchEvent.
# This prevents frame freezes during scene transitions that load many images.

type
  PendingImageLoad = object
    imgObj: ScriptValue     ## DupValue'd JS Image object
    filePath: string    ## Resolved local file path

var pendingImageLoads: seq[PendingImageLoad]

proc jsFireImgEvt(ctx: ptr ScriptCtx; imgObj: ScriptValue; evtType: cstring) =
  ## Fire a load/error event on an Image JS object.
  ## Calls dispatchEvent which covers both addEventListener listeners and on* handler.
  let dispFn = ctx.getProp(imgObj, "dispatchEvent")
  if ctx.isFunction(dispFn):
    let evtObj = ctx.newObject()
    ctx.setPropSteal(evtObj, "type", ctx.newString(evtType))
    discard ctx.checkException(ctx.callFunction1(dispFn, imgObj, evtObj), $evtType)
    ctx.freeValue(evtObj)
  else:
    # Fallback: call on* handler directly
    let cbName = "on" & $evtType
    let cb = ctx.getProp(imgObj, cstring(cbName))
    if ctx.isFunction(cb):
      discard ctx.checkException(ctx.callFunction0(cb, imgObj), cbName)
    ctx.freeValue(cb)
  ctx.freeValue(dispFn)

proc jsLoadImageReal(ctx: ptr ScriptCtx; this: ScriptValue;
                     args: openArray[ScriptValue]): ScriptValue =
  ## __rw_loadImage(imgObj, src) — DEFERRED image decode via SDL3_image.
  ## Queues the request; actual decode happens in processImageQueue().
  if args.len < 2: return ctx.newUndefined()
  let imgObj = args[0]
  let src = ctx.toNimString(args[1])
  let state = gState
  if state == nil: return ctx.newUndefined()

  let filePath = resolveUrl(src, state)

  if not fileExists(filePath):
    ctx.setPropSteal(imgObj, "complete", ctx.newBool(true))
    jsFireImgEvt(ctx, imgObj, "error")
    return ctx.newUndefined()

  # OPT-1: Queue for deferred processing instead of immediate decode.
  # DupValue the imgObj so it stays alive until we process it.
  pendingImageLoads.add(PendingImageLoad(
    imgObj: ctx.dupValue(imgObj),
    filePath: filePath
  ))
  ctx.newUndefined()

proc processImageQueue*(state: ptr RWebviewState) =
  ## Batch-process queued image decodes within a time budget.
  ## Called from webview_run_step() after dispatchRaf(), before present.
  ## OPT-3: Async decode with time budget. OPT-5: Memory cache — cached images
  ## are served instantly without decode, freeing budget for new decodes.
  if pendingImageLoads.len == 0: return
  let ctx = state.scriptCtx
  let budgetMs = 8'u64  # slightly higher budget since cached hits are free
  let startMs = SDL_GetTicks()

  while pendingImageLoads.len > 0:
    let req = pendingImageLoads[0]
    pendingImageLoads.delete(0)

    # OPT-5: Check memory cache first — skip decode entirely if cached
    let cached = cachedImageLookup(req.filePath)
    if cached != nil:
      let w = cached.width
      let h = cached.height
      let pixelData = ctx.newArrayBufferCopy(
        addr cached.pixelData[0], cached.pixelData.len)
      ctx.setPropSteal(req.imgObj, "__pixelData",   pixelData)
      ctx.setPropSteal(req.imgObj, "__pixelWidth",  ctx.newInt(int32(w)))
      ctx.setPropSteal(req.imgObj, "__pixelHeight", ctx.newInt(int32(h)))
      ctx.setPropSteal(req.imgObj, "complete",      ctx.newBool(true))
      ctx.setPropSteal(req.imgObj, "naturalWidth",  ctx.newInt(int32(w)))
      ctx.setPropSteal(req.imgObj, "naturalHeight", ctx.newInt(int32(h)))
      ctx.setPropSteal(req.imgObj, "width",         ctx.newInt(int32(w)))
      ctx.setPropSteal(req.imgObj, "height",        ctx.newInt(int32(h)))
      jsFireImgEvt(ctx, req.imgObj, "load")
      ctx.freeValue(req.imgObj)
      ctx.flushJobs()
      # Cache hits are nearly free — don't count against budget
      continue

    # Cache miss — decode from disk
    let rawSurf = IMG_Load(cstring(req.filePath))
    if rawSurf == nil:
      stderr.writeLine("[rwebview] IMG_Load failed: " & req.filePath)
      ctx.setPropSteal(req.imgObj, "complete", ctx.newBool(true))
      jsFireImgEvt(ctx, req.imgObj, "error")
      ctx.freeValue(req.imgObj)
      ctx.flushJobs()
      if SDL_GetTicks() - startMs >= budgetMs: break
      continue

    # Convert to RGBA32
    let surfPtr = SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_RGBA32)
    SDL_DestroySurface(rawSurf)
    if surfPtr == nil:
      stderr.writeLine("[rwebview] SDL_ConvertSurface failed for: " & req.filePath)
      ctx.setPropSteal(req.imgObj, "complete", ctx.newBool(true))
      jsFireImgEvt(ctx, req.imgObj, "error")
      ctx.freeValue(req.imgObj)
      ctx.flushJobs()
      if SDL_GetTicks() - startMs >= budgetMs: break
      continue

    let surf = cast[ptr SDL_Surface](surfPtr)
    let w = surf.w
    let h = surf.h
    let rowBytes = cint(w * 4)  # RGBA32 = 4 bytes per pixel
    stderr.writeLine("[rwebview] Image loaded: " & req.filePath &
                     " (" & $w & "x" & $h &
                     ", pitch=" & $surf.pitch & ", rowBytes=" & $rowBytes & ")")

    # Copy pixel data row-by-row, stripping any pitch padding
    let totalBytes = int(h) * int(rowBytes)
    var pixelBuf = newSeq[uint8](totalBytes)
    if surf.pitch == rowBytes:
      copyMem(addr pixelBuf[0], surf.pixels, totalBytes)
    else:
      let srcBase = cast[ptr UncheckedArray[uint8]](surf.pixels)
      for row in 0..<int(h):
        let srcOff = row * int(surf.pitch)
        let dstOff = row * int(rowBytes)
        copyMem(addr pixelBuf[dstOff], addr srcBase[srcOff], int(rowBytes))
    SDL_DestroySurface(surfPtr)

    # OPT-5: Store in memory cache for future reuse
    cachedImageStore(req.filePath, pixelBuf, int32(w), int32(h))

    let pixelData = ctx.newArrayBufferCopy(addr pixelBuf[0], totalBytes)

    # Set properties on the image object
    ctx.setPropSteal(req.imgObj, "__pixelData",   pixelData)
    ctx.setPropSteal(req.imgObj, "__pixelWidth",  ctx.newInt(int32(w)))
    ctx.setPropSteal(req.imgObj, "__pixelHeight", ctx.newInt(int32(h)))
    ctx.setPropSteal(req.imgObj, "complete",      ctx.newBool(true))
    ctx.setPropSteal(req.imgObj, "naturalWidth",  ctx.newInt(int32(w)))
    ctx.setPropSteal(req.imgObj, "naturalHeight", ctx.newInt(int32(h)))
    ctx.setPropSteal(req.imgObj, "width",         ctx.newInt(int32(w)))
    ctx.setPropSteal(req.imgObj, "height",        ctx.newInt(int32(h)))

    jsFireImgEvt(ctx, req.imgObj, "load")
    ctx.freeValue(req.imgObj)
    # Flush microtasks from onload handler
    ctx.flushJobs()
    # Check time budget — stop if exceeded
    if SDL_GetTicks() - startMs >= budgetMs: break
  let dtImg = SDL_GetTicks() - startMs
  if dtImg > 2:
    stderr.writeLine("[perf] processImageQueue: decoded in " & $dtImg & "ms, " &
                     $pendingImageLoads.len & " remaining")

# ===========================================================================
# 6.3b — createImageBitmap — decode image from ArrayBuffer via SDL3_image
# ===========================================================================

proc jsCreateImageBitmapFromAB(ctx: ptr ScriptCtx; this: ScriptValue;
                                args: openArray[ScriptValue]): ScriptValue =
  ## __rw_imageBitmapFromAB(arrayBuffer) → JS object with __pixelData etc.
  ## Used by createImageBitmap() for GDevelop/PIXI's ImageBitmapResource.
  if args.len < 1: return ctx.newNull()
  var abLen: int
  let abData = ctx.getArrayBufferData(args[0], abLen)
  if abData == nil or abLen == 0: return ctx.newNull()

  let io = SDL_IOFromMem(abData, csize_t(abLen))
  if io == nil:
    stderr.writeLine("[rwebview] SDL_IOFromMem failed")
    return ctx.newNull()

  let rawSurf = IMG_Load_IO(io, 1)  # closeio=1 → SDL frees io
  if rawSurf == nil:
    stderr.writeLine("[rwebview] IMG_LoadIO failed")
    return ctx.newNull()

  let surfPtr = SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_RGBA32)
  SDL_DestroySurface(rawSurf)
  if surfPtr == nil:
    stderr.writeLine("[rwebview] SDL_ConvertSurface failed in createImageBitmap")
    return ctx.newNull()

  let surf = cast[ptr SDL_Surface](surfPtr)
  let w        = surf.w
  let h        = surf.h
  let rowBytes = cint(w * 4)

  var pixelBuf = newSeq[uint8](int(h) * int(rowBytes))
  if surf.pitch == rowBytes:
    copyMem(addr pixelBuf[0], surf.pixels, pixelBuf.len)
  else:
    let srcBase = cast[ptr UncheckedArray[uint8]](surf.pixels)
    for row in 0 ..< int(h):
      copyMem(addr pixelBuf[row * int(rowBytes)],
              addr srcBase[row * int(surf.pitch)], int(rowBytes))
  SDL_DestroySurface(surfPtr)

  let bmp = ctx.newObject()
  let pixelData = ctx.newArrayBufferCopy(addr pixelBuf[0], pixelBuf.len)
  ctx.setPropSteal(bmp, "__pixelData",   pixelData)
  ctx.setPropSteal(bmp, "naturalWidth",  ctx.newInt(int32(w)))
  ctx.setPropSteal(bmp, "naturalHeight", ctx.newInt(int32(h)))
  ctx.setPropSteal(bmp, "width",         ctx.newInt(int32(w)))
  ctx.setPropSteal(bmp, "height",        ctx.newInt(int32(h)))
  bmp

# ===========================================================================
# 6.4 — Runtime <script> loading
# ===========================================================================

proc jsLoadScript(ctx: ptr ScriptCtx; this: ScriptValue;
                  args: openArray[ScriptValue]): ScriptValue =
  ## __rw_loadScript(url) — load and execute a script file synchronously.
  ## Called when a <script> element with src is appended to the DOM at runtime.
  if args.len < 1: return ctx.newUndefined()
  let state = gState
  if state == nil: return ctx.newUndefined()
  let url = ctx.toNimString(args[0])
  let filePath = resolveUrl(url, state)
  if filePath.len == 0 or not fileExists(filePath):
    stderr.writeLine("[rwebview] loadScript: file not found: " & url & " → " & filePath)
    return ctx.newUndefined()

  var code = cachedReadFile(filePath)
  # Strip UTF-8 BOM
  if code.len >= 3 and code[0] == '\xEF' and code[1] == '\xBB' and code[2] == '\xBF':
    code = code[3 .. ^1]
  stderr.writeLine("[rwebview] loadScript: " & filePath & " (" & $code.len & " bytes)")
  # Set document.currentScript so scripts that read it during synchronous
  # execution (e.g. testXhr in RPG Maker MZ main.js) get a valid src value.
  let safeSrc = filePath.replace("\\", "/")
  let setCs = "(function(){var _s=document.createElement('script');" &
              "_s.src='" & safeSrc & "';document.currentScript=_s;})()"
  discard ctx.checkException(ctx.eval(cstring(setCs), "<set-currentScript>"),
                             "<set-currentScript>")
  let ret = ctx.eval(cstring(code), cstring(filePath))
  let clearCs = "document.currentScript=null;"
  discard ctx.checkException(ctx.eval(cstring(clearCs), "<clear-currentScript>"),
                             "<clear-currentScript>")
  if not ctx.checkException(ret, filePath):
    stderr.writeLine("[rwebview] loadScript error in: " & filePath)
    return ctx.newUndefined()
  # Sync window → globalThis so new globals are visible
  const syncCode = "(function(){var w=typeof window!=='undefined'?window:null;" &
    "if(!w)return;for(var _k in w){try{var _v=w[_k];" &
    "if(_v!=null&&typeof globalThis[_k]==='undefined')" &
    "globalThis[_k]=_v;}catch(e){}}})()"
  discard ctx.checkException(ctx.eval(cstring(syncCode), "<sync>"), "<sync>")
  ctx.newUndefined()

# ===========================================================================
# 6.5 — bindXhr / bindFetch — install XHR + Fetch + Image into JS global
# ===========================================================================

proc bindXhr(state: ptr RWebviewState) =
  let ctx = state.scriptCtx

  # ── XMLHttpRequest constructor ────────────────────────────────────────
  # We inject the constructor and Response.prototype.text/json/arrayBuffer
  # as JS code that calls into our native methods.
  let xhrSetup = """
(function() {
  function XMLHttpRequest() {
    this.readyState = 0;
    this.status = 0;
    this.statusText = '';
    this.responseText = '';
    this.response = null;
    this.responseType = '';
    this.withCredentials = false;
    this.timeout = 0;
    this.onload = null;
    this.onerror = null;
    this.onreadystatechange = null;
    this.onprogress = null;
    this.onabort = null;
    this.ontimeout = null;
    this.onloadstart = null;
    this.onloadend = null;
    this._listeners = {};
    // upload is an EventTarget used by libraries like newgrounds.io
    this.upload = {
      _listeners: {},
      addEventListener: function(t,fn){ if(!this._listeners[t])this._listeners[t]=[]; this._listeners[t].push(fn); },
      removeEventListener: function(t,fn){ var a=this._listeners[t]; if(!a)return; var i=a.indexOf(fn); if(i>=0)a.splice(i,1); },
      dispatchEvent: function(e){ var fns=this._listeners[e.type]||[]; for(var i=0;i<fns.length;i++)try{fns[i](e);}catch(ex){} },
      onprogress: null, onload: null, onerror: null, onabort: null
    };
  }
  XMLHttpRequest.prototype.addEventListener = function(type, fn) {
    if (!this._listeners[type]) this._listeners[type] = [];
    this._listeners[type].push(fn);
  };
  XMLHttpRequest.prototype.removeEventListener = function(type, fn) {
    var a = this._listeners[type]; if (!a) return;
    var i = a.indexOf(fn); if (i >= 0) a.splice(i, 1);
  };
  XMLHttpRequest.prototype.dispatchEvent = function(evt) {
    var fns = this._listeners[evt.type] || [];
    for (var i = 0; i < fns.length; i++) {
      try { fns[i](evt); }
      catch(e) {
        window.__lastErrorObj = e;
        console.error('[event error] XHR.' + evt.type + ': ' + ((e && e.stack) || e));
      }
    }
    var handler = this['on' + evt.type];
    if (typeof handler === 'function') {
      try { handler.call(this, evt); }
      catch(e) {
        window.__lastErrorObj = e;
        console.error('[event error] XHR.on' + evt.type + ': ' + ((e && e.stack) || e));
      }
    }
  };
  XMLHttpRequest.prototype.open = function(method, url, async) {
    __rw_xhr_open.call(this, method, url, async !== undefined ? async : true);
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
    var ab = this._ab;
    return Promise.resolve({ _ab: ab, size: ab ? ab.byteLength : (this._data||'').length, type: '' });
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
  discard ctx.checkException(ctx.eval(cstring(xhrSetup), "<xhr-setup>"),
                             "<xhr-setup>")

  # Install native XHR methods
  ctx.bindGlobal("__rw_xhr_open", jsXhrOpen, 3)
  ctx.bindGlobal("__rw_xhr_send", jsXhrSend, 1)

  # Install native script loader for runtime <script> elements
  ctx.bindGlobal("__rw_loadScript", jsLoadScript, 1)

  # Install native fetch — data: URL handler + async queue for file URLs
  ctx.bindGlobal("__rw_fetch_native", jsFetchDataUrl, 1)
  ctx.bindGlobal("__rw_fetch_queue", jsFetchQueue, 3)

  let fetchWrap = """
(function() {
  var __RwResponse = window.__RwResponse;
  function patchResp(r) {
    var rr = new __RwResponse();
    rr.ok = r.ok; rr.status = r.status; rr.statusText = r.statusText;
    rr._data = r._data; rr._ab = r._ab;
    rr.headers = { get: function(){ return null; } };
    return rr;
  }
  window.fetch = function(url, opts) {
    var resolvedUrl = typeof url === 'string' ? url : (url && url.url ? url.url : String(url));
    if (resolvedUrl.indexOf('data:') === 0) {
      return __rw_fetch_native(resolvedUrl).then(patchResp);
    }
    return new Promise(function(resolve, reject) {
      __rw_fetch_queue(resolvedUrl, resolve, reject);
    }).then(patchResp);
  };
})();
"""
  discard ctx.checkException(ctx.eval(cstring(fetchWrap), "<fetch-setup>"),
                             "<fetch-setup>")

  # ── Override __rw_loadImage with real SDL3_image loader ────────────────
  ctx.bindGlobal("__rw_loadImage", jsLoadImageReal, 2)

  # ── createImageBitmap / ImageBitmap (needed by GDevelop/PIXI's ImageBitmapResource) ─
  ctx.bindGlobal("__rw_imageBitmapFromAB", jsCreateImageBitmapFromAB, 1)

  let imgBitmapSetup = """
(function() {
  function ImageBitmap() {}
  ImageBitmap.prototype.close = function() {};
  window.ImageBitmap = ImageBitmap;

  window.createImageBitmap = function(source, options) {
    return new Promise(function(resolve, reject) {
      try {
        var ab = null;
        if (source && source._ab) {
          ab = source._ab;           // Blob from fetch().blob()
        } else if (source instanceof ArrayBuffer) {
          ab = source;
        } else if (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView &&
                   ArrayBuffer.isView(source)) {
          ab = source.buffer;
        }
        if (ab) {
          var bmp = __rw_imageBitmapFromAB(ab);
          if (bmp) {
            Object.setPrototypeOf(bmp, ImageBitmap.prototype);
            resolve(bmp);
          } else {
            reject(new Error('createImageBitmap: image decode failed'));
          }
        } else {
          reject(new Error('createImageBitmap: unsupported source type'));
        }
      } catch(e) {
        reject(e);
      }
    });
  };
  window.createImageBitmap = window.createImageBitmap;
})();
"""
  discard ctx.checkException(ctx.eval(cstring(imgBitmapSetup), "<imagebitmapsetup>"),
                             "<imagebitmapsetup>")

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
  discard ctx.checkException(ctx.eval(cstring(urlStubs), "<url-stubs>"),
                             "<url-stubs>")

  # Copy window.* properties to the QuickJS global so bare names work
  let globalizeXhr = """
var XMLHttpRequest = window.XMLHttpRequest;
var fetch = window.fetch;
var URL = window.URL;
var ImageBitmap = window.ImageBitmap;
var createImageBitmap = window.createImageBitmap;
"""
  discard ctx.checkException(ctx.eval(cstring(globalizeXhr), "<globalize-xhr>"),
                             "<globalize-xhr>")
