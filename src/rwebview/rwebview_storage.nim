# =============================================================================
# rwebview_storage.nim
# localStorage (JSON file-backed persistent key/value storage)
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
#   localStorage implementation.
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rgss/rgss_api            # ScriptCtx (via rwebview.nim include chain)
#   - rwebview_dom             # gState
#
# Used by:
#   - rwebview.nim             # included after rwebview_audio.nim
#
# =============================================================================
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

proc jsStorageSetItem(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_storage_setItem(key, value)
  if args.len < 2: return ctx.newUndefined()
  loadStorage()
  let key = ctx.toNimString(args[0])
  let val = ctx.toNimString(args[1])
  localStorage.data[key] = val
  saveStorage()
  ctx.newUndefined()

proc jsStorageGetItem(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_storage_getItem(key) → string | null
  if args.len < 1: return ctx.newNull()
  loadStorage()
  let key = ctx.toNimString(args[0])
  if localStorage.data.hasKey(key):
    ctx.newString(cstring(localStorage.data[key]))
  else:
    ctx.newNull()

proc jsStorageRemoveItem(ctx: ptr ScriptCtx; this: ScriptValue;
                          args: openArray[ScriptValue]): ScriptValue =
  ## __rw_storage_removeItem(key)
  if args.len < 1: return ctx.newUndefined()
  loadStorage()
  let key = ctx.toNimString(args[0])
  localStorage.data.del(key)
  saveStorage()
  ctx.newUndefined()

proc jsStorageClear(ctx: ptr ScriptCtx; this: ScriptValue;
                    args: openArray[ScriptValue]): ScriptValue =
  ## __rw_storage_clear()
  loadStorage()
  localStorage.data.clear()
  saveStorage()
  ctx.newUndefined()

proc jsStorageLength(ctx: ptr ScriptCtx; this: ScriptValue;
                     args: openArray[ScriptValue]): ScriptValue =
  ## __rw_storage_length() → int
  loadStorage()
  ctx.newInt(int32(localStorage.data.len))

proc jsStorageKey(ctx: ptr ScriptCtx; this: ScriptValue;
                  args: openArray[ScriptValue]): ScriptValue =
  ## __rw_storage_key(index) → string | null
  if args.len < 1: return ctx.newNull()
  loadStorage()
  let idx = int(ctx.toInt32(args[0]))
  var i = 0
  for key in localStorage.data.keys:
    if i == idx:
      return ctx.newString(cstring(key))
    inc i
  ctx.newNull()

# ===========================================================================
# Binding installer
# ===========================================================================

proc bindStorage*(ctx: ptr ScriptCtx) =
  ## Install localStorage native callbacks into scripting engine global scope.
  ctx.bindGlobal("__rw_storage_setItem",    jsStorageSetItem,    2)
  ctx.bindGlobal("__rw_storage_getItem",    jsStorageGetItem,    1)
  ctx.bindGlobal("__rw_storage_removeItem", jsStorageRemoveItem, 1)
  ctx.bindGlobal("__rw_storage_clear",      jsStorageClear,      0)
  ctx.bindGlobal("__rw_storage_length",     jsStorageLength,     0)
  ctx.bindGlobal("__rw_storage_key",        jsStorageKey,        1)
