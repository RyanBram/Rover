# =============================================================================
# rover.nim
# Main application entry point for the Rover framework
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
#   Main executable for the Rover desktop application framework.
#   Reads package.json from the current working directory to configure the
#   window, selects the rendering engine at runtime, and drives the
#   Win32 message loop for the application lifetime.
#
#   Engine selection (runtime, not compile-time):
#   - "engine": "native"  (default) — uses Edge WebView2 via webview.cc.
#   - "engine": "rgss"              — lazy-loads rgss.dll (SDL3 + QuickJS).
#     If rgss.dll is missing, falls back to WebView2 and shows an error page.
#
#   HTTP layer:
#   - httpServer: false (default) — virtual host mapping via WebView2 API.
#   - httpServer: true            — embedded asynchttpserver on a free port.
#     Required for Unity WebGL builds that use compressed assets (.gz/.br).
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Depends on:
#   - src/webview.nim      (webview_* C ABI — Edge WebView2 or rwebview)
#   - src/rgss_engine.nim  (runtime rgss.dll loader via LoadLibrary)
#   - src/nw_polyfill.js      (JS preamble injected into every loaded page)
#
# Produces:
#   - rover.exe            (Win32 GUI executable)
#
# Build command:
#   nim c -f --threads:on --opt:size --out:src\rover.exe src\rover.nim
#
# =============================================================================

import std/[json, os, strformat, strutils, osproc, asynchttpserver, asyncdispatch, net, uri, base64, times, tables]
import ./webview
import ./rgss_engine
import winim/lean
import winim/inc/shellapi  # For ExtractIcon

const polyfill = staticRead("nw_polyfill.js")

# =============================================================================
# LOW-LEVEL FILE I/O VIA WINDOWS CRT (for PGlite NODEFS support)
# These provide fd-based binary file operations matching Node.js fs behavior.
# =============================================================================
const O_BINARY = 0x8000  # Windows CRT binary mode flag

proc c_open(path: cstring, oflag: cint, mode: cint = 0o666): cint {.importc: "_open", header: "<fcntl.h>".}
proc c_close(fd: cint): cint {.importc: "_close", header: "<io.h>".}
proc c_read(fd: cint, buffer: pointer, count: cuint): cint {.importc: "_read", header: "<io.h>".}
proc c_write(fd: cint, buffer: pointer, count: cuint): cint {.importc: "_write", header: "<io.h>".}
proc c_lseek(fd: cint, offset: int64, origin: cint): int64 {.importc: "_lseeki64", header: "<io.h>".}
proc c_chsize(fd: cint, size: int64): cint {.importc: "_chsize_s", header: "<io.h>".}

# fd tracking table — we track which fds we opened so we can validate
var openFds: Table[int, bool]

proc jsonHeaders(): HttpHeaders =
  newHttpHeaders(@[
    ("Content-Type", "application/json"),
    ("Access-Control-Allow-Origin", "*")
  ])

proc textHeaders(): HttpHeaders =
  newHttpHeaders(@[
    ("Content-Type", "text/plain"),
    ("Access-Control-Allow-Origin", "*")
  ])

proc parseQueryParam(query, paramName: string): string =
  ## Extract a named parameter from a URL query string
  for pair in query.split('&'):
    let parts = pair.split('=', 1)
    if parts.len == 2 and parts[0] == paramName:
      return decodeUrl(parts[1])
  return ""

var savedPlacement: WINDOWPLACEMENT
var isFullscreen = false
var restoreToMaximize = false  # When both maximize+fullscreen are set: exit fullscreen → maximize
var flushAckReceived = false  # Set by /__rover_flush_ack__ binding to signal JS flush complete
var rgssNotFound = false      # Set if engine=rgss but rgss.dll not found; fallback to native + error page

# Dynamic VirtualHost directory mappings — maps arbitrary local directories
# to rover.ext.N hostnames so JS can fetch binary files without base64.
var externalHostMappings: Table[string, string]  # normalized dirPath -> hostName
var nextExtHostIdx = 0

# HTTP Server threading support
var serverThread: Thread[tuple[port: int, baseDir: string]]
var serverRunning = false

# =============================================================================
# HTTP SERVER FOR UNITY WEBGL SUPPORT
# =============================================================================

proc findAvailablePort(preferredPort: int = 8000): int =
  ## Find available port - try preferred port first for faster startup
  # Fast path: try preferred port directly
  try:
    let sock = newSocket()
    sock.setSockOpt(OptReuseAddr, true)
    sock.bindAddr(Port(preferredPort), "127.0.0.1")
    sock.close()
    return preferredPort
  except OSError:
    discard
  
  # Slow path: scan for available port
  for port in (preferredPort + 1)..65535:
    try:
      let sock = newSocket()
      sock.setSockOpt(OptReuseAddr, true)
      sock.bindAddr(Port(port), "127.0.0.1")
      sock.close()
      return port
    except OSError:
      continue
  return 8080 # fallback

proc getCompoundExt(filename: string): string =
  ## Get compound extension for Unity WebGL files (e.g., ".data.gz", ".wasm.br")
  let lowerName = filename.toLowerAscii()
  # Check for Unity compound extensions first (order matters - check longest first)
  const compoundExts = [
    ".symbols.json.gz", ".symbols.json.br", ".symbols.json",
    ".framework.js.gz", ".framework.js.br",
    ".data.gz", ".data.br", ".wasm.gz", ".wasm.br", ".js.gz", ".js.br"
  ]
  for ext in compoundExts:
    if lowerName.endsWith(ext):
      return ext
  # Fall back to simple extension
  return splitFile(filename).ext

proc getMimeType(filename: string): string =
  ## Determine MIME type based on file extension (supports compound extensions)
  let ext = getCompoundExt(filename)
  case ext.toLowerAscii()
  # Unity WebGL compressed files (gzip)
  of ".data.gz": "application/octet-stream"
  of ".wasm.gz": "application/wasm"
  of ".js.gz", ".framework.js.gz": "application/javascript"
  of ".symbols.json.gz": "application/octet-stream"
  # Unity WebGL compressed files (brotli)
  of ".data.br": "application/octet-stream"
  of ".wasm.br": "application/wasm"
  of ".js.br", ".framework.js.br": "application/javascript"
  of ".symbols.json.br": "application/octet-stream"
  # Unity WebGL uncompressed files
  of ".data": "application/octet-stream"
  of ".symbols.json": "application/octet-stream"
  of ".unityweb": "application/octet-stream"
  # Standard web files
  of ".html", ".htm": "text/html"
  of ".css": "text/css"
  of ".js": "application/javascript"
  of ".json": "application/json"
  of ".wasm": "application/wasm"
  of ".png": "image/png"
  of ".jpg", ".jpeg": "image/jpeg"
  of ".gif": "image/gif"
  of ".svg": "image/svg+xml"
  of ".ico": "image/x-icon"
  of ".woff": "font/woff"
  of ".woff2": "font/woff2"
  of ".ttf": "font/ttf"
  of ".mp3": "audio/mpeg"
  of ".wav": "audio/wav"
  of ".ogg": "audio/ogg"
  of ".mp4": "video/mp4"
  of ".webm": "video/webm"
  of ".txt": "text/plain"
  else: "application/octet-stream"

proc getContentEncoding(filename: string): string =
  ## Get Content-Encoding for compressed files (gzip or brotli)
  let lowerName = filename.toLowerAscii()
  if lowerName.endsWith(".gz"):
    return "gzip"
  elif lowerName.endsWith(".br"):
    return "br"
  return ""

proc handleHttpRequest(req: Request, baseDir: string) {.async.} =
  ## Handle HTTP request
  var path = req.url.path

  # URL decode path (handles %20 for spaces, etc.)
  path = decodeUrl(path)

  # Special endpoint: /__exists__?path=... for sync file existence check
  # This enables NW.js-compatible sync existsSync via XHR
  if path == "/__exists__":
    let query = req.url.query
    # Parse query string for 'path' parameter
    var checkPath = ""
    for pair in query.split('&'):
      let parts = pair.split('=', 1)
      if parts.len == 2 and parts[0] == "path":
        checkPath = decodeUrl(parts[1])
        break
    
    if checkPath.len > 0:
      let exists = fileExists(checkPath) or dirExists(checkPath)
      let headers = @[
        ("Content-Type", "application/json"),
        ("Access-Control-Allow-Origin", "*")
      ]
      await req.respond(Http200, if exists: "true" else: "false", newHttpHeaders(headers))
    else:
      await req.respond(Http400, "Missing path parameter")
    return

  # =========================================================================
  # FILESYSTEM API ENDPOINTS (for PGlite NODEFS + general NW.js compatibility)
  # All operations are synchronous from the JS perspective (sync XHR).
  # The HTTP server runs in a separate thread, so blocking calls are fine.
  # =========================================================================

  if path == "/__get_base_dir__":
    await req.respond(Http200, baseDir, textHeaders())
    return

  # --- File stat ---
  if path == "/__fs_lstat__":
    let filePath = parseQueryParam(req.url.query, "path")
    if filePath.len > 0:
      try:
        let info = getFileInfo(filePath)
        var mode: int
        if info.kind == pcDir:
          mode = 0o40777   # S_IFDIR | rwxrwxrwx
        elif info.kind == pcLinkToFile or info.kind == pcLinkToDir:
          mode = 0o120666  # S_IFLNK | rw-rw-rw-
        else:
          mode = 0o100666  # S_IFREG | rw-rw-rw-
        let result = %*{
          "dev": 0, "ino": 0, "mode": mode,
          "nlink": info.linkCount, "uid": 0, "gid": 0, "rdev": 0,
          "size": info.size,
          "atime": info.lastAccessTime.toUnix(),
          "mtime": info.lastWriteTime.toUnix(),
          "ctime": info.creationTime.toUnix(),
          "blksize": 4096,
          "blocks": (info.size + 4095) div 4096
        }
        await req.respond(Http200, $result, jsonHeaders())
      except:
        # Return 200 with "null" body instead of 404 to avoid console noise.
        # The browser's network layer auto-logs all 404s to the console —
        # since NODEFS probes many non-existent paths, this creates excessive
        # noise. The polyfill checks for "null" body and throws ENOENT.
        await req.respond(Http200, "null", jsonHeaders())
    else:
      await req.respond(Http400, "\"Missing path parameter\"", jsonHeaders())
    return

  # --- Open file (fd-based) ---
  if path == "/__fs_open__":
    try:
      let body = parseJson(req.body)
      let filePath = body["path"].getStr()
      let flags = body["flags"].getInt() or O_BINARY  # Force binary mode
      let mode = body{"mode"}.getInt(0o666)
      let fd = c_open(filePath.cstring, flags.cint, mode.cint)
      if fd >= 0:
        openFds[fd] = true
        await req.respond(Http200, $fd, textHeaders())
      else:
        await req.respond(Http500, "\"Failed to open: " & filePath & "\"", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Close file ---
  if path == "/__fs_close__":
    try:
      let body = parseJson(req.body)
      let fd = body["fd"].getInt()
      discard c_close(fd.cint)
      openFds.del(fd)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      await req.respond(Http200, "true", jsonHeaders())
    return

  # --- Read from fd ---
  if path == "/__fs_read_fd__":
    try:
      let body = parseJson(req.body)
      let fd = body["fd"].getInt()
      let length = body["length"].getInt()
      # position can be null (sequential read — don't seek)
      let posNode = body{"position"}
      if posNode != nil and posNode.kind != JNull:
        discard c_lseek(fd.cint, posNode.getInt().int64, 0)  # SEEK_SET
      var buf = newSeq[byte](length)
      var bytesRead: cint = 0
      if length > 0:
        bytesRead = c_read(fd.cint, addr buf[0], length.cuint)
      if bytesRead >= 0:
        buf.setLen(bytesRead)
        let encoded = encode(buf)
        let result = %*{"data": encoded, "bytesRead": bytesRead}
        await req.respond(Http200, $result, jsonHeaders())
      else:
        let result = %*{"data": "", "bytesRead": 0}
        await req.respond(Http200, $result, jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Write to fd ---
  if path == "/__fs_write_fd__":
    try:
      let body = parseJson(req.body)
      let fd = body["fd"].getInt()
      let data = decode(body["data"].getStr())
      # position can be null (sequential write — don't seek)
      let wPosNode = body{"position"}
      if wPosNode != nil and wPosNode.kind != JNull:
        discard c_lseek(fd.cint, wPosNode.getInt().int64, 0)  # SEEK_SET
      var bytesWritten: cint = 0
      if data.len > 0:
        bytesWritten = c_write(fd.cint, unsafeAddr data[0], data.len.cuint)
      let result = %*{"bytesWritten": bytesWritten}
      await req.respond(Http200, $result, jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Truncate file by fd ---
  if path == "/__fs_ftruncate__":
    try:
      let body = parseJson(req.body)
      let fd = body["fd"].getInt()
      let length = body{"length"}.getInt(0)
      discard c_chsize(fd.cint, length.int64)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      await req.respond(Http200, "true", jsonHeaders())
    return

  # --- MEMFS: Bulk read entire pgdata directory tree ---
  # Returns JSON object mapping relative-path -> base64-content for every file.
  # One HTTP call replaces hundreds of individual readFileSync round-trips at PGlite startup.
  if path == "/__fs_bulk_read__":
    let dirPath = parseQueryParam(req.url.query, "path")
    if dirPath.len > 0 and dirExists(dirPath):
      var files = newJObject()
      proc bulkWalk(dir: string) =
        for kind, p in walkDir(dir, relative = false):
          if kind in {pcDir, pcLinkToDir}:
            bulkWalk(p)
          elif kind in {pcFile, pcLinkToFile}:
            try:
              let rawBytes = readFile(p)
              let rel = p.replace('\\', '/')
              files[rel] = %encode(rawBytes)
            except:
              discard
      bulkWalk(dirPath)
      await req.respond(Http200, $files, jsonHeaders())
    else:
      await req.respond(Http200, "{}", jsonHeaders())
    return

  # --- MEMFS: Bulk write dirty files back to disk ---
  # Accepts JSON array: [ {"path": "abs/path", "data": "<base64>", "isDir": bool, "deleted": bool} ]
  # Used by the polyfill flush mechanism to persist MEMFS changes to disk.
  if path == "/__fs_bulk_write__":
    try:
      let entries = parseJson(req.body)
      for entry in entries:
        let filePath = entry{"path"}.getStr()
        let deleted  = entry{"deleted"}.getBool(false)
        let isDir    = entry{"isDir"}.getBool(false)
        if filePath.len == 0: continue
        if deleted:
          try:
            if isDir: removeDir(filePath)
            else:     removeFile(filePath)
          except: discard
        elif isDir:
          try: createDir(filePath)
          except: discard
        else:
          try:
            let raw = decode(entry{"data"}.getStr())
            createDir(filePath.splitFile().dir)
            writeFile(filePath, raw)
          except:
            discard
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Flush ACK from JS: DB dump complete, safe to close ---
  if path == "/__rover_flush_ack__":
    flushAckReceived = true
    echo "[DUMP] Flush ACK received via HTTP"
    await req.respond(Http200, "true", jsonHeaders())
    return

  # --- IDB↔Disk: Write dump tarball to disk ---
  # Receives base64-encoded gzipped tarball from JS dumpDataDir('gzip').
  # Writes .data/local_db.tar.gz and updates .data/db_version.json.
  if path == "/__fs_dump_write__":
    try:
      let body = parseJson(req.body)
      let b64data = body{"data"}.getStr()
      let timestamp = body{"timestamp"}.getStr()
      if b64data.len > 0:
        let raw = decode(b64data)
        let dataDir = getCurrentDir() / ".data"
        createDir(dataDir)
        writeFile(dataDir / "local_db.tar.gz", raw)
        # Write version file
        let versionJson = %*{"timestamp": timestamp, "size": raw.len}
        writeFile(dataDir / "db_version.json", $versionJson)
        echo &"[DUMP] Wrote {raw.len} bytes to .data/local_db.tar.gz (ts={timestamp})"
        await req.respond(Http200, "true", jsonHeaders())
      else:
        await req.respond(Http400, "\"empty data\"", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      echo &"[DUMP] Write error: {errMsg}"
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- IDB↔Disk: Read dump tarball from disk ---
  # Returns base64-encoded .data/local_db.tar.gz for restoring into IndexedDB.
  if path == "/__fs_dump_read__":
    let dumpPath = getCurrentDir() / ".data" / "local_db.tar.gz"
    if fileExists(dumpPath):
      try:
        let raw = readFile(dumpPath)
        let encoded = encode(raw)
        await req.respond(Http200, encoded, textHeaders())
      except:
        await req.respond(Http500, "", textHeaders())
    else:
      await req.respond(Http404, "", textHeaders())
    return

  # --- IDB↔Disk: Read version file ---
  # Returns .data/db_version.json content (lightweight check for sync decisions).
  if path == "/__fs_dump_version__":
    let versionPath = getCurrentDir() / ".data" / "db_version.json"
    if fileExists(versionPath):
      try:
        let content = readFile(versionPath)
        await req.respond(Http200, content, jsonHeaders())
      except:
        await req.respond(Http200, "{}", jsonHeaders())
    else:
      await req.respond(Http200, "{}", jsonHeaders())
    return

  # --- Bulk tree stat (for prefetching pgdata into stat cache) ---
  # Returns JSON object { entries: [ { path, mode, size, atime, mtime, ctime, nlink, isDir } ] }
  # Recursively walks the directory tree and returns stat info for all entries.
  if path == "/__fs_tree_stat__":
    let dirPath = parseQueryParam(req.url.query, "path")
    if dirPath.len > 0 and dirExists(dirPath):
      var entries = newJArray()
      proc walkTree(dir: string) =
        for kind, p in walkDir(dir):
          try:
            let info = getFileInfo(p)
            var mode: int
            if info.kind == pcDir:
              mode = 0o40777
            elif info.kind == pcLinkToFile or info.kind == pcLinkToDir:
              mode = 0o120666
            else:
              mode = 0o100666
            entries.add(%*{
              "p": p.replace('\\', '/'),  # normalize to forward slashes
              "m": mode,
              "s": info.size,
              "at": info.lastAccessTime.toUnix(),
              "mt": info.lastWriteTime.toUnix(),
              "ct": info.creationTime.toUnix(),
              "nl": info.linkCount
            })
            if info.kind == pcDir:
              walkTree(p)
          except:
            discard
      walkTree(dirPath)
      await req.respond(Http200, $entries, jsonHeaders())
    else:
      await req.respond(Http200, "[]", jsonHeaders())
    return

  # --- Read directory ---
  if path == "/__fs_readdir__":
    let dirPath = parseQueryParam(req.url.query, "path")
    let dirsOnly = parseQueryParam(req.url.query, "dirsonly") == "1"
    if dirPath.len > 0 and dirExists(dirPath):
      var entries: seq[string] = @[]
      for kind, p in walkDir(dirPath):
        if dirsOnly:
          if kind in {pcDir, pcLinkToDir}: entries.add(extractFilename(p))
        else:
          entries.add(extractFilename(p))
      await req.respond(Http200, $(%entries), jsonHeaders())
    else:
      await req.respond(Http200, "[]", jsonHeaders())
    return

  # --- Read file as text ---
  if path == "/__fs_read__":
    let filePath = parseQueryParam(req.url.query, "path")
    let wantB64 = parseQueryParam(req.url.query, "b64") == "1"
    if filePath.len > 0 and fileExists(filePath):
      try:
        let rawBytes = readFile(filePath)  # returns string (seq of bytes)
        if wantB64:
          let encoded = encode(rawBytes)
          await req.respond(Http200, encoded, textHeaders())
        else:
          await req.respond(Http200, rawBytes, textHeaders())
      except:
        await req.respond(Http500, "", textHeaders())
    else:
      # Return 200 with sentinel instead of 404 to avoid console noise
      await req.respond(Http200, "__ENOENT__", textHeaders())
    return

  # --- Write file ---
  if path == "/__fs_write__":
    try:
      let body = parseJson(req.body)
      let filePath = body["path"].getStr()
      let isBinary = body{"binary"}.getBool(false)
      if isBinary:
        let data = decode(body["content"].getStr())
        writeFile(filePath, data)
      else:
        let content = body["content"].getStr()
        writeFile(filePath, content)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Mkdir ---
  if path == "/__fs_mkdir__":
    try:
      let body = parseJson(req.body)
      let dirPath = body["path"].getStr()
      createDir(dirPath)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      await req.respond(Http200, "true", jsonHeaders())  # Dir may exist
    return

  # --- Unlink ---
  if path == "/__fs_unlink__":
    try:
      let body = parseJson(req.body)
      let filePath = body["path"].getStr()
      removeFile(filePath)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Rmdir ---
  if path == "/__fs_rmdir__":
    try:
      let body = parseJson(req.body)
      let dirPath = body["path"].getStr()
      removeDir(dirPath)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Rename ---
  if path == "/__fs_rename__":
    try:
      let body = parseJson(req.body)
      let oldPath = body["oldPath"].getStr()
      let newPath = body["newPath"].getStr()
      moveFile(oldPath, newPath)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Chmod (no-op on Windows, but acknowledge) ---
  if path == "/__fs_chmod__":
    await req.respond(Http200, "true", jsonHeaders())
    return

  # --- Utimes ---
  if path == "/__fs_utimes__":
    try:
      let body = parseJson(req.body)
      let filePath = body["path"].getStr()
      let mtime = body["mtime"].getFloat()
      # setLastModificationTime is available in std/os
      setLastModificationTime(filePath, fromUnix(mtime.int64))
      await req.respond(Http200, "true", jsonHeaders())
    except:
      await req.respond(Http200, "true", jsonHeaders())  # Best-effort
    return

  # --- Symlink ---
  if path == "/__fs_symlink__":
    try:
      let body = parseJson(req.body)
      let target = body["target"].getStr()
      let linkPath = body["path"].getStr()
      createSymlink(target, linkPath)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Readlink ---
  if path == "/__fs_readlink__":
    let filePath = parseQueryParam(req.url.query, "path")
    if filePath.len > 0:
      try:
        let target = expandSymlink(filePath)
        await req.respond(Http200, target, textHeaders())
      except:
        await req.respond(Http500, "\"readlink failed\"", jsonHeaders())
    else:
      await req.respond(Http400, "\"Missing path\"", jsonHeaders())
    return

  # --- Append file ---
  if path == "/__fs_append__":
    try:
      let body = parseJson(req.body)
      let filePath = body["path"].getStr()
      let content = body["content"].getStr()
      let f = open(filePath, fmAppend)
      f.write(content)
      f.close()
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return

  # --- Copy file ---
  if path == "/__fs_copy__":
    try:
      let body = parseJson(req.body)
      let srcPath = body["src"].getStr()
      let destPath = body["dest"].getStr()
      copyFile(srcPath, destPath)
      await req.respond(Http200, "true", jsonHeaders())
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      await req.respond(Http500, "\"" & errMsg & "\"", jsonHeaders())
    return
  if path == "/" or path == "":
    path = "/index.html"

  # Combine with base directory
  let filePath = baseDir / path[1..^1] # Remove leading '/'

  try:
    if fileExists(filePath):
      let content = readFile(filePath)
      let mimeType = getMimeType(filePath)
      let contentEncoding = getContentEncoding(filePath)

      # Build headers with optional Content-Encoding for compressed files
      var headers = @[
        ("Content-Type", mimeType),
        ("Cache-Control", "no-cache"),
        ("Access-Control-Allow-Origin", "*")
      ]
      if contentEncoding.len > 0:
        headers.add(("Content-Encoding", contentEncoding))

      await req.respond(Http200, content, newHttpHeaders(headers))
    else:
      await req.respond(Http404, "404 - File Not Found")
  except:
    await req.respond(Http500, "500 - Internal Server Error")

proc startHttpServer(port: int, baseDir: string) {.async.} =
  ## Start HTTP server for Unity WebGL support
  var server = newAsyncHttpServer()

  proc callback(req: Request) {.async, gcsafe.} =
    {.cast(gcsafe).}:
      await handleHttpRequest(req, baseDir)

  echo &"[SERVER] Starting HTTP server on http://localhost:{port}"
  echo &"[SERVER] Serving files from: {baseDir}"

  # Bind to localhost only to avoid Windows Firewall prompts
  server.listen(Port(port), "127.0.0.1")

  while true:
    if server.shouldAcceptRequest():
      await server.acceptRequest(callback)
    else:
      await sleepAsync(10)

proc serverThreadProc(args: tuple[port: int, baseDir: string]) {.thread.} =
  ## Thread proc that runs HTTP server with its own event loop
  ## This runs completely independently from the main GUI thread
  asyncCheck startHttpServer(args.port, args.baseDir)
  runForever()  # Event loop runs in this thread only

# =============================================================================
# WINDOW MANAGEMENT
# =============================================================================
proc toggleFullscreen(hwnd: HWND) =
  let style = GetWindowLong(hwnd, GWL_STYLE)
  if not isFullscreen:
    savedPlacement.length = sizeof(savedPlacement).UINT
    GetWindowPlacement(hwnd, savedPlacement.addr)
    var mi: MONITORINFO
    mi.cbSize = sizeof(mi).DWORD
    GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), mi.addr)
    SetWindowLong(hwnd, GWL_STYLE, style and not WS_OVERLAPPEDWINDOW)
    SetWindowPos(hwnd, HWND_TOP, mi.rcMonitor.left, mi.rcMonitor.top,
                  mi.rcMonitor.right - mi.rcMonitor.left,
                  mi.rcMonitor.bottom - mi.rcMonitor.top,
                  SWP_NOOWNERZORDER or SWP_FRAMECHANGED)
    isFullscreen = true
  else:
    SetWindowLong(hwnd, GWL_STYLE, style or WS_OVERLAPPEDWINDOW)
    SetWindowPos(hwnd, 0, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOOWNERZORDER or SWP_FRAMECHANGED)
    if restoreToMaximize:
      ShowWindow(hwnd, SW_MAXIMIZE)
    else:
      SetWindowPlacement(hwnd, savedPlacement.addr)
      SetWindowPos(hwnd, 0, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOOWNERZORDER or SWP_FRAMECHANGED)
    isFullscreen = false

proc centerWindow(hwnd: HWND, width, height: int) =
  var mi: MONITORINFO
  mi.cbSize = sizeof(mi).DWORD
  GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTOPRIMARY), mi.addr)
  # let monitorIdx = mi.rcMonitor # Unused
  let workIdx = mi.rcWork
  
  let left = workIdx.left + ((workIdx.right - workIdx.left) - width) div 2
  let top = workIdx.top + ((workIdx.bottom - workIdx.top) - height) div 2
  
  SetWindowPos(hwnd, 0, left.cint, top.cint, width.cint, height.cint, SWP_NOZORDER or SWP_NOOWNERZORDER)

type
  Config = object
    # NW.js compatible fields
    name: string
    main: string
    windowTitle: string
    windowWidth: int
    windowHeight: int
    windowIcon: string  # Path to window icon (PNG, ICO)
    httpServer: bool    # Use HTTP server (for Unity), default false (VirtualHost for RPG Maker)
    maximize: bool      # Launch window maximized
    fullscreen: bool    # Launch window fullscreen
    forceCanvas: bool   # Set "renderer":"canvas" to disable WebGL and force Canvas2D fallback
    engine: string      # "native" (webview2) or "rgss" (SDL+QuickJS via rgss.dll)

var useRgss* = false  ## Runtime flag: true when engine=rgss and rgss.dll loaded

proc loadConfig(filename: string): Config =
  ## Load configuration from package.json (NW.js compatible)
  let jsonData = parseFile(filename)

  # NW.js fields with defaults
  result.name = jsonData{"name"}.getStr("rover-app")
  result.main = jsonData{"main"}.getStr("index.html")

  # Window config (NW.js format)
  if jsonData.hasKey("window"):
    let window = jsonData["window"]
    result.windowTitle = window{"title"}.getStr("Rover App")
    result.windowWidth = window{"width"}.getInt(960)
    result.windowHeight = window{"height"}.getInt(720)
    result.maximize = window{"maximize"}.getBool(false)
    result.fullscreen = window{"fullscreen"}.getBool(false)
  else:
    result.windowTitle = "Rover App"
    result.windowWidth = 960
    result.windowHeight = 720
  
  # Window icon (NW.js format: window.icon)
  if jsonData.hasKey("window") and jsonData["window"].hasKey("icon"):
    result.windowIcon = jsonData["window"]["icon"].getStr("")
  else:
    result.windowIcon = "icon/icon.png"  # Default icon path
  
  # HTTP Server mode (for Unity WebGL), default false (VirtualHost for RPG Maker)
  result.httpServer = jsonData{"httpServer"}.getBool(false)

  # Force Canvas2D renderer — disables WebGL so engines fall back to their
  # Canvas2D path.  Accepts either  "renderer": "canvas"  or  "forceCanvas": true.
  let renderer = jsonData{"renderer"}.getStr("")
  result.forceCanvas = (renderer.toLowerAscii() == "canvas") or
                       jsonData{"forceCanvas"}.getBool(false)

  # Engine: "native" (webview2, default) or "rgss" (SDL+QuickJS via rgss.dll)
  result.engine = jsonData{"engine"}.getStr("native").toLowerAscii()

proc createDefaultPackageJson(filename: string) =
  ## Create a default package.json file with standard fields
  let defaultConfig = %*{
    "name": "rover-app",
    "main": "index.html",
    "engine": "native",
    "httpServer": false,
    "renderer": "webgl",
    "interpreter": "quickjs",
    "window": {
      "title": "Rover App",
      "icon": "icon/icon.png",
      "width": 960,
      "height": 720,
      "maximize": false,
      "fullscreen": false
    }
  }
  writeFile(filename, defaultConfig.pretty())

# =============================================================================
# ENGINE DISPATCH WRAPPERS
# When useRgss=true, calls go to rgss.dll; otherwise to native webview2.
# =============================================================================

proc engineCreate(width, height: cint; initialState: cint = 0): Webview =
  if useRgss:
    cast[Webview](rgss.webviewCreate(1, nil, width, height, initialState))
  else:
    create(cint(true), nil, width, height, initialState)

proc engineDestroy(w: Webview) =
  if useRgss: discard rgss.webviewDestroy(w)
  else: discard w.destroy()

proc engineRunStep(w: Webview): cint =
  if useRgss: rgss.webviewRunStep(w)
  else: 0  # native mode uses Sleep(1), never calls runStep

proc engineNavigate(w: Webview; url: cstring) =
  if useRgss: discard rgss.webviewNavigate(w, url)
  else: discard w.navigate(url)

proc engineInit(w: Webview; js: cstring) =
  if useRgss: discard rgss.webviewInit(w, js)
  else: discard w.init(js)

proc engineEval(w: Webview; js: cstring) =
  if useRgss: discard rgss.webviewEval(w, js)
  else: discard w.eval(js)

proc engineSetTitle(w: Webview; title: cstring) =
  if useRgss: discard rgss.webviewSetTitle(w, title)
  else: discard w.setTitle(title)

proc engineSetSize(w: Webview; width, height: cint; hints: cint = 0) =
  if useRgss: discard rgss.webviewSetSize(w, width, height, hints)
  else: discard w.setSize(width, height, WebviewHint(hints))

proc engineGetWindow(w: Webview): pointer =
  if useRgss: rgss.webviewGetWindow(w)
  else: w.getWindow()

proc engineGetSavedPlacement(w: Webview; placement: pointer) =
  if useRgss:
    if rgss.webviewGetSavedPlacement != nil:
      rgss.webviewGetSavedPlacement(w, placement)
  else:
    w.getSavedPlacement(placement)

proc engineBind(w: Webview; name: cstring;
                fn: proc(id: cstring; req: cstring; arg: pointer) {.cdecl.};
                arg: pointer) =
  if useRgss: discard rgss.webviewBind(w, name, fn, arg)
  else: discard w.webviewBind(name, fn, arg)

proc engineReturn(w: Webview; id: cstring; status: cint; result: cstring) =
  if useRgss: discard rgss.webviewReturn(w, id, status, result)
  else: discard w.webviewReturn(id, status, result)

proc engineOpenDevTools(w: Webview) =
  if useRgss:
    if rgss.webviewOpenDevTools != nil:
      rgss.webviewOpenDevTools(w)
  else:
    w.openDevTools()

proc engineSetVHMapping(w: Webview; hostName: cstring; folderPath: cstring; accessKind: cint) =
  if useRgss:
    if rgss.webviewSetVHMapping != nil:
      rgss.webviewSetVHMapping(w, hostName, folderPath, accessKind)
  else:
    w.setVirtualHostNameToFolderMapping(hostName, folderPath, accessKind)

proc setWindowIconFromExe(hwnd: HWND) =
  ## Extract and set icon from executable's RC resources
  let hInstance = GetModuleHandle(nil)
  
  # Try to load icon from executable resources (index 0 = first icon)
  let hIcon = ExtractIcon(hInstance, getAppFilename(), 0)
  
  if hIcon != 0 and hIcon != cast[HICON](1):
    SendMessage(hwnd, WM_SETICON, ICON_BIG, cast[LPARAM](hIcon))
    SendMessage(hwnd, WM_SETICON, ICON_SMALL, cast[LPARAM](hIcon))
    echo "[ICON] Using icon from executable resources"
  else:
    echo "[ICON] No icon in executable resources"

proc setWindowIcon(hwnd: HWND, iconPath: string) =
  ## Set window icon from file (ICO), fallback to executable's RC icon
  
  # If iconPath is empty, use executable icon
  if iconPath.len == 0:
    echo "[ICON] No icon path specified, using executable icon"
    setWindowIconFromExe(hwnd)
    return
  
  # Try to load from file
  if not fileExists(iconPath):
    echo &"[ICON] Icon file not found: {iconPath}, using executable icon"
    setWindowIconFromExe(hwnd)
    return
  
  let absPath = absolutePath(iconPath)
  echo &"[ICON] Loading icon from: {absPath}"
  
  # Determine icon type based on extension
  let ext = splitFile(iconPath).ext.toLowerAscii()
  
  var iconLoaded = false
  
  if ext == ".ico":
    # Load ICO file directly using LoadImage
    let hIconBig = LoadImage(0, absPath, IMAGE_ICON, 32, 32, LR_LOADFROMFILE)
    let hIconSmall = LoadImage(0, absPath, IMAGE_ICON, 16, 16, LR_LOADFROMFILE)
    
    if hIconBig != 0:
      SendMessage(hwnd, WM_SETICON, ICON_BIG, hIconBig)
      echo "[ICON] Set big icon (32x32)"
      iconLoaded = true
    
    if hIconSmall != 0:
      SendMessage(hwnd, WM_SETICON, ICON_SMALL, hIconSmall)
      echo "[ICON] Set small icon (16x16)"
      iconLoaded = true
  else:
    # For PNG and other formats, try to load as icon
    echo &"[ICON] Warning: {ext} format may not be supported. Consider using .ico format."
    let hIcon = LoadImage(0, absPath, IMAGE_ICON, 0, 0, LR_LOADFROMFILE or LR_DEFAULTSIZE)
    if hIcon != 0:
      SendMessage(hwnd, WM_SETICON, ICON_BIG, hIcon)
      SendMessage(hwnd, WM_SETICON, ICON_SMALL, hIcon)
      echo "[ICON] Icon loaded successfully"
      iconLoaded = true
  
  # Fallback to executable icon if loading failed
  if not iconLoaded:
    echo "[ICON] Failed to load icon file, using executable icon"
    setWindowIconFromExe(hwnd)

proc main() =
  # Always run from the executable's own directory so that package.json,
  # index.html, and assets are resolved correctly regardless of how Rover
  # was launched (drag-drop, file association, shortcut without working dir).
  setCurrentDir(getAppDir())

  # Find package.json in current directory
  let configFile = getCurrentDir() / "package.json"

  if not fileExists(configFile):
    echo "[CONFIG] package.json not found, creating default..."
    createDefaultPackageJson(configFile)
    echo "[CONFIG] Created package.json with default settings"

  # Load configuration
  echo "[CONFIG] Loading configuration from package.json..."
  let config = loadConfig(configFile)

  echo &"[CONFIG] App: {config.name}"
  echo &"[CONFIG] Main: {config.main}"
  echo &"[CONFIG] Title: {config.windowTitle}"
  echo &"[CONFIG] Icon: {config.windowIcon}"
  echo &"[CONFIG] Window Size: {config.windowWidth}x{config.windowHeight}"
  if config.maximize:
    echo "[CONFIG] Window State: Maximized"
  elif config.fullscreen:
    echo "[CONFIG] Window State: Fullscreen"
  if config.forceCanvas:
    echo "[CONFIG] Render Mode: Canvas (forced)"
  else:
    echo "[CONFIG] Render Mode: WebGL"

  # Engine detection — "rgss" loads rgss.dll for SDL+QuickJS rendering
  echo &"[CONFIG] Engine: {config.engine}"
  if config.engine == "rgss":
    let dllPath = getCurrentDir() / "rgss.dll"
    if not fileExists(dllPath):
      echo "[WARN] engine=rgss but rgss.dll not found in: " & getCurrentDir()
      echo "[WARN] Falling back to native webview2 mode and showing error page"
      rgssNotFound = true
      useRgss = false
    elif not loadRgssEngine(dllPath):
      echo "[WARN] Failed to load rgss.dll, falling back to native mode"
      rgssNotFound = true
      useRgss = false
    else:
      useRgss = true

  echo ""

  # Build path to main HTML file
  let mainPath = getCurrentDir() / config.main

  if not fileExists(mainPath):
    echo &"[ERROR] Main file not found: {mainPath}"
    quit(1)

  # Determine initial window state: 0=normal, 1=maximize, 2=fullscreen
  var initialState = 0
  if config.fullscreen:
    initialState = 2
  elif config.maximize:
    initialState = 1

  # Create WebView window (native webview2 or rgss.dll depending on engine)
  let w = engineCreate(cint(config.windowWidth), cint(config.windowHeight), cint(initialState))
  
  # Get HWND and set icon IMMEDIATELY after window creation
  # This minimizes the visible delay where window has no/default icon
  let hwnd = cast[HWND](engineGetWindow(w))
  
  # Set icon first (priority: package.json > exe fallback)
  # HTML/JS can override this after page loads via auto-sync
  if config.windowIcon.len > 0:
    setWindowIcon(hwnd, config.windowIcon)
  else:
    setWindowIconFromExe(hwnd)
  
  # Handle initial window state tracking variables
  if config.fullscreen:
    isFullscreen = true
    # Retrieve the normal-state placement saved by webview.h before it applied fullscreen
    engineGetSavedPlacement(w, savedPlacement.addr)
  if config.fullscreen and config.maximize:
    restoreToMaximize = true
  
  # Now set title and initialize polyfill
  engineSetTitle(w, cstring(config.windowTitle))

  # Get current directory as base for serving
  let baseDir = getCurrentDir()

  # Inject __roverBaseDir directly into the polyfill preamble so it is available
  # immediately when the polyfill script runs — no HTTP round-trip needed.
  var preamble = "window.__roverBaseDir = " & $newJString(baseDir) & ";\n"
  if config.fullscreen:
    preamble &= "window.__roverInitialFullscreen = true;\n"
  if config.maximize:
    preamble &= "window.__roverInitialMaximize = true;\n"
  if config.fullscreen and config.maximize:
    preamble &= "window.__roverRestoreToMaximize = true;\n"
  if config.forceCanvas:
    echo "[CONFIG] renderer=canvas: WebGL disabled, forcing Canvas2D fallback"
    # Neutralise every WebGL entry-point that game engines probe before
    # choosing a renderer.  The Canvas2D context ("2d") is left intact.
    preamble &= """window.__roverForceCanvas = true;
(function(){
  // HTMLCanvasElement.prototype only exists in real browsers (webview2 backend).
  // In rwebview the canvas is a plain object; dom_preamble.js already checks
  // window.__roverForceCanvas inside the per-instance getContext stub.
  if (typeof HTMLCanvasElement !== 'undefined') {
    var _origGCC = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function(type, opts) {
      if (type === 'webgl' || type === 'webgl2' ||
          type === 'experimental-webgl' || type === 'experimental-webgl2') {
        return null;
      }
      return _origGCC ? _origGCC.call(this, type, opts) : null;
    };
  }
  // Also kill the global constructors engines sometimes use as capability flags
  window.WebGLRenderingContext       = undefined;
  window.WebGL2RenderingContext      = undefined;
  // Notify rwebview native layer so the F2 overlay shows "Canvas (forced)"
  if (typeof __rw_setForceCanvas === 'function') __rw_setForceCanvas();
})();
"""

  # Inject command-line arguments so the app can open files passed via drag-and-drop
  # or file association (e.g. rover.exe "C:\books\manga.cbz").
  let cliArgs = commandLineParams()
  if cliArgs.len > 0:
    var argvJson = newJArray()
    for a in cliArgs:
      argvJson.add(newJString(a))
    preamble &= "window.__roverArgv = " & $argvJson & ";\n"

  let fullPolyfill = preamble & polyfill
  engineInit(w, cstring(fullPolyfill))

  # Configure Virtual Host Mapping to bypass CORS (always enabled)
  # This is used by RPG Maker for CORS access and as default navigation
  let hostName = "rover.assets"
  # AccessKind: 1 = Allow (COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW)
  engineSetVHMapping(w, cstring(hostName), cstring(baseDir), 1)
  echo &"[WEBVIEW] Virtual Host: {hostName} -> {baseDir}"

  # Determine navigation URL based on httpServer config
  var url: string
  
  if rgssNotFound:
    # RGSS was requested but DLL not found - show error page instead
    let errorHtml = """
<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <title>RGSS Engine Error</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'Segoe UI', Arial, sans-serif;
      background: #0d0d0d;
      color: #ccc;
      display: flex;
      align-items: center;
      justify-content: center;
      min-height: 100vh;
      padding: 24px;
    }

    .container {
      max-width: 580px;
      width: 100%;
      text-align: center;
    }

    .icon {
      font-size: 52px;
      line-height: 1;
      margin-bottom: 20px;
    }

    h1 {
      font-size: 22px;
      font-weight: 700;
      color: #f5a623;
      letter-spacing: 0.03em;
      margin-bottom: 12px;
    }

    .divider {
      border: none;
      border-top: 1px solid #2a2a2a;
      margin: 16px 0;
    }

    .desc {
      font-size: 14px;
      line-height: 1.7;
      color: #aaa;
      margin-bottom: 20px;
    }

    code {
      font-family: 'Consolas', 'Courier New', monospace;
      font-size: 13px;
      color: #7ec8e8;
      background: #161616;
      padding: 1px 6px;
      border-radius: 3px;
    }

    .solution {
      background: #111;
      border: 1px solid #222;
      border-left: 3px solid #f5a623;
      padding: 14px 16px;
      margin-bottom: 12px;
      text-align: left;
      font-family: 'Consolas', 'Courier New', monospace;
      font-size: 13px;
      line-height: 1.8;
      color: #bbb;
    }

    .solution strong {
      color: #f5a623;
      font-weight: 600;
    }


  </style>
</head>
<body>
  <div class="container">
    <div class="icon">⚠️</div>
    <h1>RGSS Engine Not Found</h1>
    <hr class="divider">
    <p class="desc">
      You configured <code>"engine": "rgss"</code> in your <code>package.json</code>,
      but the required <code>rgss.dll</code> file was not found in the expected location.
    </p>

    <div class="solution">
      <strong>Option 1 —</strong> Place the DLL in the current directory<br>
      Expected: <code>C:\your\project\dir\rgss.dll</code>
    </div>

    <div class="solution">
      <strong>Option 2 —</strong> Switch to native mode in <code>package.json</code><br>
      Set <code>"engine": "native"</code> or remove the field entirely.
    </div>


  </div>
</body>
</html>
"""
    # Use base64 encoding for data URL to preserve styling and special characters
    let encodedHtml = base64.encode(errorHtml)
    url = "data:text/html;base64," & encodedHtml
  elif config.httpServer:
    # HTTP Server mode - required for Unity WebGL compressed builds (.gz, .br files)
    let port = findAvailablePort()
    # Start HTTP server in dedicated thread for maximum performance
    createThread(serverThread, serverThreadProc, (port: port, baseDir: baseDir))
    serverRunning = true
    url = &"http://localhost:{port}/{config.main}"
    echo &"[SERVER] HTTP Server on port: {port} (threaded)"
  else:
    # VirtualHost mode (default) - faster for RPG Maker and standard web apps
    url = &"http://{hostName}/{config.main}"
    echo &"[MODE] VirtualHost mode (no HTTP server)"
  
  if rgssNotFound:
    echo "[ERROR] Displaying error page instead of app: rgss.dll not found"
  echo &"[WEBVIEW] Loading: {url}"
  engineNavigate(w, cstring(url))

  # Implement Native Bindings
  # We pass 'w' (Webview instance) as the argument to all bindings
  # so we can call w.webviewReturn and w.getWindow inside the C-compatible procs.
  
  let wPtr = cast[pointer](w)

  engineBind(w, "exit_app", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    # Send WM_CLOSE to trigger standard window closing mechanism
    PostMessage(hwnd, WM_CLOSE, 0, 0)
    engineReturn(w, id, 0, "")
  , wPtr)

  engineBind(w, "center_window", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    var rect: RECT
    GetWindowRect(hwnd, rect.addr)
    let width = rect.right - rect.left
    let height = rect.bottom - rect.top
    centerWindow(hwnd, width, height)
    engineReturn(w, id, 0, "")
  , wPtr)

  engineBind(w, "toggle_fullscreen", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    toggleFullscreen(hwnd)
    engineReturn(w, id, 0, "")
  , wPtr)

  engineBind(w, "toggle_devtools", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    engineOpenDevTools(w)
    engineReturn(w, id, 0, "")
  , wPtr)

  engineBind(w, "get_exe_directory", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    # Return JSON string of current directory
    let dir = getCurrentDir().replace("\\", "\\\\")
    let jsonResult = &"\"{dir}\""
    engineReturn(w, id, 0, cstring(jsonResult))
  , wPtr)

  # File System Bindings for RPG Maker save functionality
  
  engineBind(w, "fs_write_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      # Parse JSON array: [path, content]
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      let content = args[1].getStr()
      writeFile(filePath, content)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # Write binary file from base64-encoded string (used for thumbnail caching in VirtualHost mode)
  engineBind(w, "fs_write_binary", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      let b64Content = args[1].getStr()
      let binaryData = decode(b64Content)
      writeFile(filePath, binaryData)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_read_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      let content = readFile(filePath).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
      engineReturn(w, id, 0, cstring(&"\"{content}\""))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_exists", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      let exists = fileExists(filePath) or dirExists(filePath)
      engineReturn(w, id, 0, cstring(if exists: "true" else: "false"))
    except:
      engineReturn(w, id, 0, cstring("false"))
  , wPtr)

  engineBind(w, "fs_mkdir", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = decodeUrl(args[0].getStr())
      createDir(dirPath)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_unlink", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      removeFile(filePath)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_rmdir", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = decodeUrl(args[0].getStr())
      removeDir(dirPath)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_list_dir", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = decodeUrl(args[0].getStr())
      var files: seq[string] = @[]
      
      if dirExists(dirPath):
        for kind, path in walkDir(dirPath):
          if kind in {pcFile, pcLinkToFile}:
            # Percent-encode filenames to survive the WebView2 binding bridge
            files.add(encodeUrl(extractFilename(path), usePlus=false))
      
      # Return as JSON array
      let jsonResult = $(%files)
      engineReturn(w, id, 0, cstring(jsonResult))
    except:
      # Return empty array on error
      engineReturn(w, id, 0, "[]")
  , wPtr)

  # List only subdirectories inside a directory (for ebook group discovery)
  engineBind(w, "fs_list_subdirs", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = decodeUrl(args[0].getStr())
      var dirs: seq[string] = @[]
      if dirExists(dirPath):
        for kind, path in walkDir(dirPath):
          if kind in {pcDir, pcLinkToDir}:
            # Percent-encode directory names to survive the WebView2 binding bridge
            dirs.add(encodeUrl(extractFilename(path), usePlus=false))
      let jsonResult = $(%dirs)
      engineReturn(w, id, 0, cstring(jsonResult))
    except:
      engineReturn(w, id, 0, "[]")
  , wPtr)

  # Read a file as base64-encoded binary (for opening ebooks outside the app dir)
  engineBind(w, "fs_read_file_binary", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      if not fileExists(filePath):
        engineReturn(w, id, 1, "\"ENOENT\"")
        return
      let rawBytes = readFile(filePath)
      let encoded = encode(rawBytes)
      engineReturn(w, id, 0, cstring("\"" & encoded & "\""))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # Add set_title binding for programmatic title changes from JS
  engineBind(w, "set_title", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let newTitle = args[0].getStr()
      engineSetTitle(w, cstring(newTitle))
      engineReturn(w, id, 0, "true")
    except:
      engineReturn(w, id, 1, "\"Failed to set title\"")
  , wPtr)

  # Add set_icon binding for programmatic icon changes from JS
  engineBind(w, "set_icon", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let iconPath = args[0].getStr()
      let hwnd = cast[HWND](engineGetWindow(w))
      setWindowIcon(hwnd, iconPath)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # =========================================================================
  # ADDITIONAL FILE SYSTEM BINDINGS (for full NW.js compatibility)
  # =========================================================================

  engineBind(w, "fs_rename", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let oldPath = decodeUrl(args[0].getStr())
      let newPath = decodeUrl(args[1].getStr())
      moveFile(oldPath, newPath)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_append_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      let content = args[1].getStr()
      let f = open(filePath, fmAppend)
      f.write(content)
      f.close()
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_copy_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let srcPath = decodeUrl(args[0].getStr())
      let destPath = decodeUrl(args[1].getStr())
      copyFile(srcPath, destPath)
      engineReturn(w, id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "fs_stat", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = decodeUrl(args[0].getStr())
      let info = getFileInfo(filePath)
      let jsonResult = %*{
        "size": info.size,
        "isFile": info.kind == pcFile,
        "isDirectory": info.kind == pcDir
      }
      engineReturn(w, id, 0, cstring($jsonResult))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # =========================================================================
  # DYNAMIC VIRTUALHOST MAPPING (binary-safe file I/O without base64)
  # Maps an arbitrary local directory to a rover.ext.N virtual hostname so
  # JS can fetch binary files directly via HTTP — zero base64 overhead.
  # =========================================================================

  engineBind(w, "fs_map_dir", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = decodeUrl(args[0].getStr())

      # Normalize path: use native separators, remove trailing slash
      var normPath = dirPath.replace('/', '\\')
      while normPath.endsWith("\\") and normPath.len > 3:  # keep "C:\"
        normPath = normPath[0..^2]

      if not dirExists(normPath):
        engineReturn(w, id, 1, "\"Directory not found\"")
        return

      # Reuse existing mapping for the same directory
      if normPath in externalHostMappings:
        let host = externalHostMappings[normPath]
        let url = "http://" & host & "/"
        engineReturn(w, id, 0, cstring("\"" & url & "\""))
        return

      # Create new VirtualHost mapping
      let hostName = "rover.ext." & $nextExtHostIdx
      inc nextExtHostIdx
      engineSetVHMapping(w, cstring(hostName), cstring(normPath), 1)
      externalHostMappings[normPath] = hostName
      echo &"[VHOST] Mapped {normPath} -> http://{hostName}/"

      let url = "http://" & hostName & "/"
      engineReturn(w, id, 0, cstring("\"" & url & "\""))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # =========================================================================
  # SHELL AND PROCESS BINDINGS
  # =========================================================================

  engineBind(w, "shell_open_item", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      # Use ShellExecute to open with default application
      discard ShellExecute(0, "open", filePath, nil, nil, SW_SHOWNORMAL)
      engineReturn(w, id, 0, "true")
    except:
      engineReturn(w, id, 1, "\"Failed to open item\"")
  , wPtr)

  engineBind(w, "exec_command", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let command = args[0].getStr()
      # Execute command using osproc.execCmd
      let exitCode = osproc.execCmd(command)
      let jsonResult = %*{"exitCode": exitCode, "stdout": "", "stderr": ""}
      engineReturn(w, id, 0, cstring($jsonResult))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      engineReturn(w, id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  engineBind(w, "get_user_home", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let homeDir = getHomeDir().replace("\\", "\\\\")
      engineReturn(w, id, 0, cstring(&"\"{homeDir}\""))
    except:
      engineReturn(w, id, 1, "\"Failed to get home directory\"")
  , wPtr)

  # =========================================================================
  # WINDOW MANAGEMENT BINDINGS
  # =========================================================================

  engineBind(w, "window_minimize", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    ShowWindow(hwnd, SW_MINIMIZE)
    engineReturn(w, id, 0, "true")
  , wPtr)

  engineBind(w, "window_maximize", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    ShowWindow(hwnd, SW_MAXIMIZE)
    engineReturn(w, id, 0, "true")
  , wPtr)

  engineBind(w, "window_restore", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    ShowWindow(hwnd, SW_RESTORE)
    engineReturn(w, id, 0, "true")
  , wPtr)

  engineBind(w, "window_focus", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](engineGetWindow(w))
    SetForegroundWindow(hwnd)
    engineReturn(w, id, 0, "true")
  , wPtr)

  engineBind(w, "window_flash", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let attention = args[0].getInt()
      let hwnd = cast[HWND](engineGetWindow(w))
      if attention > 0:
        FlashWindow(hwnd, TRUE)
      else:
        FlashWindow(hwnd, FALSE)
      engineReturn(w, id, 0, "true")
    except:
      engineReturn(w, id, 0, "true")
  , wPtr)

  engineBind(w, "set_window_position", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let x = args[0].getInt()
      let y = args[1].getInt()
      let hwnd = cast[HWND](engineGetWindow(w))
      SetWindowPos(hwnd, 0, x.cint, y.cint, 0, 0, SWP_NOSIZE or SWP_NOZORDER)
      engineReturn(w, id, 0, "true")
    except:
      engineReturn(w, id, 1, "\"Failed to set position\"")
  , wPtr)

  engineBind(w, "set_window_size", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let width = args[0].getInt()
      let height = args[1].getInt()
      let hwnd = cast[HWND](engineGetWindow(w))
      SetWindowPos(hwnd, 0, 0, 0, width.cint, height.cint, SWP_NOMOVE or SWP_NOZORDER)
      engineReturn(w, id, 0, "true")
    except:
      engineReturn(w, id, 1, "\"Failed to set size\"")
  , wPtr)

  engineBind(w, "set_always_on_top", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let onTop = args[0].getBool()
      let hwnd = cast[HWND](engineGetWindow(w))
      if onTop:
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
      else:
        SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
      engineReturn(w, id, 0, "true")
    except:
      engineReturn(w, id, 1, "\"Failed to set always on top\"")
  , wPtr)

  echo ""
  echo "================================================"
  echo "  Rover - Application Running"
  if config.forceCanvas:
    echo "  Running in Canvas Mode (forced)"
  else:
    echo "  Running in WebGL Mode"
  echo "------------------------------------------------"
  echo "  Close the window to exit"
  echo "================================================"
  echo ""

  # Centering is already handled in webview.h constructor
  # hwnd already obtained above for icon setting
  
  # Register Hotkeys
  RegisterHotKey(hwnd, 2, MOD_NOREPEAT, VK_F12)

  # Bind __rover_set_flush_ack so JS can signal that the final MEMFS flush completed
  engineBind(w, "__rover_set_flush_ack", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    flushAckReceived = true
    engineReturn(w, id, 0, "true")
  , wPtr)

  var msg: MSG
  var isClosing = false
  var closeStartTick: DWORD = 0  # GetTickCount() when close was initiated
  while true:
    # Process Windows messages (non-blocking)
    while PeekMessage(msg.addr, 0, 0, 0, PM_REMOVE) != 0:
      if msg.message == WM_QUIT:
        break
      if msg.message == WM_CLOSE and not isClosing:
        # Intercept WM_CLOSE: signal JS to run async DB dump, then return
        # to the event loop immediately so JS can actually execute.
        # We must NOT block here (no Sleep loops) — the JS async dump
        # needs the WebView event loop to keep running for IndexedDB / fetch.
        isClosing = true
        flushAckReceived = false
        closeStartTick = GetTickCount()
        echo "[DUMP] WM_CLOSE — signalling JS for final DB dump..."
        engineEval(w, "if(typeof window.__roverOnClose==='function'){window.__roverOnClose();}else{window.__rover_set_flush_ack();}".cstring)
        continue  # Return control to event loop — do NOT block
      if msg.message == WM_HOTKEY:
        if msg.wParam == 2:
          engineOpenDevTools(w)
      TranslateMessage(msg.addr)
      DispatchMessage(msg.addr)

    # Check if quit message was received
    if msg.message == WM_QUIT:
      break

    # Non-blocking close: poll for ACK or timeout on every tick.
    # DestroyWindow is called from here, not from inside the message handler,
    # so the JS event loop is never blocked and async dump can complete.
    if isClosing:
      if flushAckReceived:
        echo "[DUMP] Flush ACK received — closing cleanly"
        isClosing = false
        DestroyWindow(hwnd)
        if useRgss: PostQuitMessage(0)  # SDL doesn't call PostQuitMessage
      elif GetTickCount() - closeStartTick >= 5000:
        echo "[DUMP] Flush timeout (5s) — closing anyway"
        isClosing = false
        DestroyWindow(hwnd)
        if useRgss: PostQuitMessage(0)  # SDL doesn't call PostQuitMessage

    # Drive the engine event loop.
    # rgss: webview_run_step polls SDL events, renders one frame, returns 1 on close.
    # native: WebView2 drives its own rendering; Sleep(1) prevents spin.
    if useRgss:
      discard engineRunStep(w)
    else:
      Sleep(1)

  engineDestroy(w)

  echo "[INFO] Application closed"

when isMainModule:
  main()


# =============================================================================
# [Documentation]
# =============================================================================
#
# Configuration  (package.json fields)
# -------------------------------------
#   name           string  — App identifier; used as fallback window title.
#   main           string  — Relative path to the entry-point HTML file.
#   engine         string  — "native" (default) or "rgss".
#   httpServer     bool    — false: VirtualHost mode; true: embedded HTTP server.
#   renderer       string  — "webgl" (default) or "canvas" (disables WebGL).
#   window.title   string  — Window title (overrides name).
#   window.icon    string  — Relative path to a .ico or .png icon file.
#   window.width   int     — Initial window width in pixels.
#   window.height  int     — Initial window height in pixels.
#   window.maximize    bool  — Open window maximized.
#   window.fullscreen  bool  — Open window borderless-fullscreen.
#
# Engine Selection Flow
# ---------------------
#   1. loadConfig() reads package.json from getCurrentDir().
#   2. If engine == "rgss":
#        a. Check fileExists(getCurrentDir() / "rgss.dll").
#        b. loadRgssEngine(dllPath) resolves all webview_* proc pointers.
#        c. useRgss = true; all engineXxx() wrappers route to rgss.* procs.
#        d. If DLL missing or fails: rgssNotFound = true, fall back to native
#           and display an error page via base64 data URI in WebView2.
#   3. If engine == "native" (default):
#        useRgss = false; engineXxx() wrappers call w.method() (webview.cc).
#
# Engine Dispatch Wrappers
# ------------------------
#   All webview calls are routed through runtime-selected procs:
#   engineCreate, engineDestroy, engineRunStep, engineNavigate, engineInit,
#   engineEval, engineSetTitle, engineSetSize, engineGetWindow,
#   engineGetSavedPlacement, engineBind, engineReturn,
#   engineOpenDevTools, engineSetVHMapping.
#
# Main Loop
# ---------
#   Win32 PeekMessage loop; not webview_run() — rover drives the loop directly.
#   - Native mode : Sleep(1) per tick (WebView2 renders independently).
#   - RGSS mode   : engineRunStep(w) per tick (SDL polls + renders one frame).
#   F12 hotkey    : RegisterHotKey + WM_HOTKEY → engineOpenDevTools.
#
# Close / Flush Flow
# ------------------
#   On WM_CLOSE:
#     1. isClosing = true; JS is called via window.__roverOnClose().
#     2. JS runs async IndexedDB/MEMFS dump, then calls
#        window.__rover_set_flush_ack() to signal completion.
#     3. Rover polls for ACK each tick; calls DestroyWindow when received
#        or after a 5-second hard timeout.
#     4. If useRgss: PostQuitMessage(0) (SDL does not auto-post it).
#
# JS Native Bindings  (webview_bind names visible from JavaScript)
# ----------------------------------------------------------------
#   exit_app               — Close the application.
#   center_window          — Center window on the current monitor.
#   toggle_fullscreen      — Toggle borderless fullscreen.
#   toggle_devtools        — Open WebView2 / rwebview DevTools.
#   get_exe_directory      — Returns the directory containing rover.exe.
#   read_file              — Read a local file; returns base64-encoded bytes.
#   write_file             — Write base64 bytes to a local file.
#   delete_file            — Delete a local file.
#   file_exists            — Check whether a file path exists.
#   list_files             — Return directory listing as a JSON array.
#   get_file_info          — File metadata (size, mtime, isDir).
#   make_dir               — Create a directory tree (mkdirAll).
#   remove_dir             — Remove a directory tree (rmdir -r).
#   open_external          — Open a URL in the system default browser.
#   map_directory          — Map a local dir to a rover.ext.N VirtualHost.
#   set_window_title       — Update the OS window title at runtime.
#   set_window_icon        — Load and apply an icon from a file path.
#   set_window_size        — Resize the window programmatically.
#   set_window_position    — Move the window to an (x, y) position.
#   get_window_rect        — Return current window bounding rect as JSON.
#   set_always_on_top      — Pin / unpin window above all others.
#   __rover_set_flush_ack  — Internal: signal that JS async flush completed.
#   fd_open, fd_read, fd_write, fd_close, fd_lseek, fd_fsize, fd_ftruncate
#                          — CRT fd bindings for PGlite NODEFS support.
#
# Polyfill Preamble  (injected before page scripts via webview_init)
# ------------------------------------------------------------------
#   window.__roverBaseDir          — Absolute path to the game directory.
#   window.__roverInitialFullscreen — true if fullscreen at launch.
#   window.__roverInitialMaximize   — true if maximized at launch.
#   window.__roverRestoreToMaximize — true if fullscreen→maximize on exit.
#   window.__roverForceCanvas       — true if renderer=canvas.
#   window.__roverArgv              — Array of CLI arguments passed to exe.
#
# =============================================================================
