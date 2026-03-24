# ===========================================================================
# Phase 8 — localStorage (JSON file-backed persistent key/value storage)
# ===========================================================================
#
# Included by rwebview.nim after rwebview_audio.nim.
# Depends on: rwebview_ffi_quickjs (JS helpers), rwebview_dom (gState)
#
# Architecture:
#   • On first access, load <baseDir>/rwebview_localStorage.json into memory.
#   • setItem/removeItem/clear write the JSON file atomically (write .tmp,
#     then rename to final path) to prevent corruption on crash/power loss.
#   • All operations are synchronous (matches browser localStorage behavior).

import std/json as stdJson

# ===========================================================================
# In-memory storage + file I/O
# ===========================================================================

type
  LocalStorageState = object
    data:     OrderedTable[string, string]
    filePath: string
    loaded:   bool

var localStorage: LocalStorageState

proc storageFilePath(): string =
  ## Compute the storage file path from the current baseDir.
  if gState != nil and gState.baseDir.len > 0:
    gState.baseDir / "rwebview_localStorage.json"
  else:
    "rwebview_localStorage.json"

proc loadStorage() =
  ## Load storage from JSON file into memory. Called once on first access.
  if localStorage.loaded: return
  localStorage.loaded = true
  localStorage.filePath = storageFilePath()

  if fileExists(localStorage.filePath):
    try:
      let content = readFile(localStorage.filePath)
      let j = stdJson.parseJson(content)
      if j.kind == JObject:
        for key, val in j.pairs:
          if val.kind == JString:
            localStorage.data[key] = val.getStr()
          else:
            localStorage.data[key] = $val
      stderr.writeLine("[rwebview] localStorage loaded: " &
                       $localStorage.data.len & " keys from " &
                       localStorage.filePath)
    except:
      stderr.writeLine("[rwebview] localStorage load failed: " &
                       getCurrentExceptionMsg())
      localStorage.data = initOrderedTable[string, string]()
  else:
    localStorage.data = initOrderedTable[string, string]()

proc saveStorage() =
  ## Write storage atomically: write to .tmp, then rename.
  localStorage.filePath = storageFilePath()
  let tmpPath = localStorage.filePath & ".tmp"
  try:
    var j = newJObject()
    for key, val in localStorage.data.pairs:
      j[key] = newJString(val)
    writeFile(tmpPath, $j)
    moveFile(tmpPath, localStorage.filePath)
  except:
    stderr.writeLine("[rwebview] localStorage save failed: " &
                     getCurrentExceptionMsg())
    # Try to clean up tmp file
    try:
      if fileExists(tmpPath): removeFile(tmpPath)
    except: discard

# ===========================================================================
# QuickJS native callbacks
# ===========================================================================

proc jsStorageSetItem(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_storage_setItem(key, value)
  if argc < 2: return rw_JS_Undefined()
  loadStorage()
  let key = argStr(ctx, argv, 0)
  let val = argStr(ctx, argv, 1)
  localStorage.data[key] = val
  saveStorage()
  rw_JS_Undefined()

proc jsStorageGetItem(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_storage_getItem(key) → string | null
  if argc < 1: return rw_JS_Null()
  loadStorage()
  let key = argStr(ctx, argv, 0)
  if localStorage.data.hasKey(key):
    rw_JS_NewString(ctx, cstring(localStorage.data[key]))
  else:
    rw_JS_Null()

proc jsStorageRemoveItem(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_storage_removeItem(key)
  if argc < 1: return rw_JS_Undefined()
  loadStorage()
  let key = argStr(ctx, argv, 0)
  localStorage.data.del(key)
  saveStorage()
  rw_JS_Undefined()

proc jsStorageClear(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_storage_clear()
  loadStorage()
  localStorage.data.clear()
  saveStorage()
  rw_JS_Undefined()

proc jsStorageLength(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_storage_length() → int
  loadStorage()
  rw_JS_NewInt32(ctx, int32(localStorage.data.len))

proc jsStorageKey(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_storage_key(index) → string | null
  if argc < 1: return rw_JS_Null()
  loadStorage()
  let idx = int(argI32(ctx, argv, 0))
  var i = 0
  for key in localStorage.data.keys:
    if i == idx:
      return rw_JS_NewString(ctx, cstring(key))
    inc i
  rw_JS_Null()

# ===========================================================================
# Binding installer
# ===========================================================================

proc bindStorage*(state: ptr RWebviewState) =
  ## Install localStorage native callbacks into QuickJS global scope.
  let ctx    = state.jsCtx
  let global = JS_GetGlobalObject(ctx)

  let setFn    = JS_NewCFunction(ctx, jsStorageSetItem,    "__rw_storage_setItem",    2)
  let getFn    = JS_NewCFunction(ctx, jsStorageGetItem,    "__rw_storage_getItem",    1)
  let rmFn     = JS_NewCFunction(ctx, jsStorageRemoveItem, "__rw_storage_removeItem", 1)
  let clearFn  = JS_NewCFunction(ctx, jsStorageClear,      "__rw_storage_clear",      0)
  let lenFn    = JS_NewCFunction(ctx, jsStorageLength,     "__rw_storage_length",     0)
  let keyFn    = JS_NewCFunction(ctx, jsStorageKey,        "__rw_storage_key",        1)

  discard JS_SetPropertyStr(ctx, global, "__rw_storage_setItem",    setFn)
  discard JS_SetPropertyStr(ctx, global, "__rw_storage_getItem",    getFn)
  discard JS_SetPropertyStr(ctx, global, "__rw_storage_removeItem", rmFn)
  discard JS_SetPropertyStr(ctx, global, "__rw_storage_clear",      clearFn)
  discard JS_SetPropertyStr(ctx, global, "__rw_storage_length",     lenFn)
  discard JS_SetPropertyStr(ctx, global, "__rw_storage_key",        keyFn)

  rw_JS_FreeValue(ctx, global)
