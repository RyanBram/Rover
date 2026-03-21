import std/[json, os, strformat, strutils, osproc, asynchttpserver, asyncdispatch, net, uri, base64, times, tables]
import ./webview
import winim/lean
import winim/inc/shellapi  # For ExtractIcon

const polyfill = staticRead("polyfill.js")

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

proc createDefaultPackageJson(filename: string) =
  ## Create a default package.json file with standard fields
  let defaultConfig = %*{
    "name": "rover-app",
    "main": "index.html",
    "httpServer": false,
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

  # Create WebView window
  # Pass config size to ensure it opens at correct size and centered immediately
  let w = newWebview(width = config.windowWidth, height = config.windowHeight, initialState = initialState)
  
  # Get HWND and set icon IMMEDIATELY after window creation
  # This minimizes the visible delay where window has no/default icon
  let hwnd = cast[HWND](w.getWindow())
  
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
    w.getSavedPlacement(savedPlacement.addr)
  if config.fullscreen and config.maximize:
    restoreToMaximize = true
  
  # Now set title and initialize polyfill
  w.title = config.windowTitle

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

  # Inject command-line arguments so the app can open files passed via drag-and-drop
  # or file association (e.g. rover.exe "C:\books\manga.cbz").
  let cliArgs = commandLineParams()
  if cliArgs.len > 0:
    var argvJson = newJArray()
    for a in cliArgs:
      argvJson.add(newJString(a))
    preamble &= "window.__roverArgv = " & $argvJson & ";\n"

  let fullPolyfill = preamble & polyfill
  w.init(cstring(fullPolyfill))

  # Configure Virtual Host Mapping to bypass CORS (always enabled)
  # This is used by RPG Maker for CORS access and as default navigation
  let hostName = "rover.assets"
  # AccessKind: 1 = Allow (COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW)
  w.setVirtualHostNameToFolderMapping(cstring(hostName), cstring(baseDir), 1)
  echo &"[WEBVIEW] Virtual Host: {hostName} -> {baseDir}"

  # Determine navigation URL based on httpServer config
  var url: string
  if config.httpServer:
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
  
  echo &"[WEBVIEW] Loading: {url}"
  w.navigate(cstring(url))

  # Implement Native Bindings
  # We pass 'w' (Webview instance) as the argument to all bindings
  # so we can call w.webviewReturn and w.getWindow inside the C-compatible procs.
  
  let wPtr = cast[pointer](w)

  w.webviewBind("exit_app", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    # Send WM_CLOSE to trigger standard window closing mechanism
    PostMessage(hwnd, WM_CLOSE, 0, 0)
    w.webviewReturn(id, 0, "")
  , wPtr)

  w.webviewBind("center_window", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    var rect: RECT
    GetWindowRect(hwnd, rect.addr)
    let width = rect.right - rect.left
    let height = rect.bottom - rect.top
    centerWindow(hwnd, width, height)
    w.webviewReturn(id, 0, "")
  , wPtr)

  w.webviewBind("toggle_fullscreen", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    toggleFullscreen(hwnd)
    w.webviewReturn(id, 0, "")
  , wPtr)

  w.webviewBind("toggle_devtools", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    w.openDevTools()
    w.webviewReturn(id, 0, "")
  , wPtr)

  w.webviewBind("get_exe_directory", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    # Return JSON string of current directory
    let dir = getCurrentDir().replace("\\", "\\\\")
    let jsonResult = &"\"{dir}\""
    w.webviewReturn(id, 0, cstring(jsonResult))
  , wPtr)

  # File System Bindings for RPG Maker save functionality
  
  w.webviewBind("fs_write_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      # Parse JSON array: [path, content]
      let args = parseJson($req)
      let filePath = args[0].getStr()
      let content = args[1].getStr()
      writeFile(filePath, content)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # Write binary file from base64-encoded string (used for thumbnail caching in VirtualHost mode)
  w.webviewBind("fs_write_binary", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      let b64Content = args[1].getStr()
      let binaryData = decode(b64Content)
      writeFile(filePath, binaryData)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_read_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      let content = readFile(filePath).replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r")
      w.webviewReturn(id, 0, cstring(&"\"{content}\""))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_exists", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      let exists = fileExists(filePath) or dirExists(filePath)
      w.webviewReturn(id, 0, cstring(if exists: "true" else: "false"))
    except:
      w.webviewReturn(id, 0, cstring("false"))
  , wPtr)

  w.webviewBind("fs_mkdir", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = args[0].getStr()
      createDir(dirPath)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_unlink", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      removeFile(filePath)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_list_dir", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = args[0].getStr()
      var files: seq[string] = @[]
      
      if dirExists(dirPath):
        for kind, path in walkDir(dirPath):
          if kind in {pcFile, pcLinkToFile}:
            files.add(extractFilename(path))
      
      # Return as JSON array
      let jsonResult = $(%files)
      w.webviewReturn(id, 0, cstring(jsonResult))
    except:
      # Return empty array on error
      w.webviewReturn(id, 0, "[]")
  , wPtr)

  # List only subdirectories inside a directory (for ebook group discovery)
  w.webviewBind("fs_list_subdirs", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let dirPath = args[0].getStr()
      var dirs: seq[string] = @[]
      if dirExists(dirPath):
        for kind, path in walkDir(dirPath):
          if kind in {pcDir, pcLinkToDir}:
            dirs.add(extractFilename(path))
      let jsonResult = $(%dirs)
      w.webviewReturn(id, 0, cstring(jsonResult))
    except:
      w.webviewReturn(id, 0, "[]")
  , wPtr)

  # Read a file as base64-encoded binary (for opening ebooks outside the app dir)
  w.webviewBind("fs_read_file_binary", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      if not fileExists(filePath):
        w.webviewReturn(id, 1, "\"ENOENT\"")
        return
      let rawBytes = readFile(filePath)
      let encoded = encode(rawBytes)
      w.webviewReturn(id, 0, cstring("\"" & encoded & "\""))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # Add set_title binding for programmatic title changes from JS
  w.webviewBind("set_title", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let newTitle = args[0].getStr()
      w.setTitle(cstring(newTitle))
      w.webviewReturn(id, 0, "true")
    except:
      w.webviewReturn(id, 1, "\"Failed to set title\"")
  , wPtr)

  # Add set_icon binding for programmatic icon changes from JS
  w.webviewBind("set_icon", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let iconPath = args[0].getStr()
      let hwnd = cast[HWND](w.getWindow())
      setWindowIcon(hwnd, iconPath)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # =========================================================================
  # ADDITIONAL FILE SYSTEM BINDINGS (for full NW.js compatibility)
  # =========================================================================

  w.webviewBind("fs_rename", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let oldPath = args[0].getStr()
      let newPath = args[1].getStr()
      moveFile(oldPath, newPath)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_append_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      let content = args[1].getStr()
      let f = open(filePath, fmAppend)
      f.write(content)
      f.close()
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_copy_file", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let srcPath = args[0].getStr()
      let destPath = args[1].getStr()
      copyFile(srcPath, destPath)
      w.webviewReturn(id, 0, "true")
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("fs_stat", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      let info = getFileInfo(filePath)
      let jsonResult = %*{
        "size": info.size,
        "isFile": info.kind == pcFile,
        "isDirectory": info.kind == pcDir
      }
      w.webviewReturn(id, 0, cstring($jsonResult))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  # =========================================================================
  # SHELL AND PROCESS BINDINGS
  # =========================================================================

  w.webviewBind("shell_open_item", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let filePath = args[0].getStr()
      # Use ShellExecute to open with default application
      discard ShellExecute(0, "open", filePath, nil, nil, SW_SHOWNORMAL)
      w.webviewReturn(id, 0, "true")
    except:
      w.webviewReturn(id, 1, "\"Failed to open item\"")
  , wPtr)

  w.webviewBind("exec_command", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let command = args[0].getStr()
      # Execute command using osproc.execCmd
      let exitCode = osproc.execCmd(command)
      let jsonResult = %*{"exitCode": exitCode, "stdout": "", "stderr": ""}
      w.webviewReturn(id, 0, cstring($jsonResult))
    except:
      let errMsg = getCurrentExceptionMsg().replace("\"", "\\\"")
      w.webviewReturn(id, 1, cstring(&"\"{errMsg}\""))
  , wPtr)

  w.webviewBind("get_user_home", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let homeDir = getHomeDir().replace("\\", "\\\\")
      w.webviewReturn(id, 0, cstring(&"\"{homeDir}\""))
    except:
      w.webviewReturn(id, 1, "\"Failed to get home directory\"")
  , wPtr)

  # =========================================================================
  # WINDOW MANAGEMENT BINDINGS
  # =========================================================================

  w.webviewBind("window_minimize", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    ShowWindow(hwnd, SW_MINIMIZE)
    w.webviewReturn(id, 0, "true")
  , wPtr)

  w.webviewBind("window_maximize", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    ShowWindow(hwnd, SW_MAXIMIZE)
    w.webviewReturn(id, 0, "true")
  , wPtr)

  w.webviewBind("window_restore", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    ShowWindow(hwnd, SW_RESTORE)
    w.webviewReturn(id, 0, "true")
  , wPtr)

  w.webviewBind("window_focus", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    let hwnd = cast[HWND](w.getWindow())
    SetForegroundWindow(hwnd)
    w.webviewReturn(id, 0, "true")
  , wPtr)

  w.webviewBind("window_flash", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let attention = args[0].getInt()
      let hwnd = cast[HWND](w.getWindow())
      if attention > 0:
        FlashWindow(hwnd, TRUE)
      else:
        FlashWindow(hwnd, FALSE)
      w.webviewReturn(id, 0, "true")
    except:
      w.webviewReturn(id, 0, "true")
  , wPtr)

  w.webviewBind("set_window_position", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let x = args[0].getInt()
      let y = args[1].getInt()
      let hwnd = cast[HWND](w.getWindow())
      SetWindowPos(hwnd, 0, x.cint, y.cint, 0, 0, SWP_NOSIZE or SWP_NOZORDER)
      w.webviewReturn(id, 0, "true")
    except:
      w.webviewReturn(id, 1, "\"Failed to set position\"")
  , wPtr)

  w.webviewBind("set_window_size", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let width = args[0].getInt()
      let height = args[1].getInt()
      let hwnd = cast[HWND](w.getWindow())
      SetWindowPos(hwnd, 0, 0, 0, width.cint, height.cint, SWP_NOMOVE or SWP_NOZORDER)
      w.webviewReturn(id, 0, "true")
    except:
      w.webviewReturn(id, 1, "\"Failed to set size\"")
  , wPtr)

  w.webviewBind("set_always_on_top", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    try:
      let args = parseJson($req)
      let onTop = args[0].getBool()
      let hwnd = cast[HWND](w.getWindow())
      if onTop:
        SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
      else:
        SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE)
      w.webviewReturn(id, 0, "true")
    except:
      w.webviewReturn(id, 1, "\"Failed to set always on top\"")
  , wPtr)

  echo ""
  echo "================================================"
  echo "  Rover - WebView2 Application Running"
  echo "  Close the window to exit"
  echo "================================================"
  echo ""

  # Centering is already handled in webview.h constructor
  # hwnd already obtained above for icon setting
  
  # Register Hotkeys
  RegisterHotKey(hwnd, 1, MOD_NOREPEAT, VK_F4)
  RegisterHotKey(hwnd, 2, MOD_NOREPEAT, VK_F12)

  # Bind __rover_set_flush_ack so JS can signal that the final MEMFS flush completed
  w.webviewBind("__rover_set_flush_ack", proc (id, req: cstring, arg: pointer) {.cdecl.} =
    let w = cast[Webview](arg)
    flushAckReceived = true
    w.webviewReturn(id, 0, "true")
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
        w.eval("if(typeof window.__roverOnClose==='function'){window.__roverOnClose();}else{window.__rover_set_flush_ack();}".cstring)
        continue  # Return control to event loop — do NOT block
      if msg.message == WM_HOTKEY:
        if msg.wParam == 1:
          toggleFullscreen(hwnd)
        elif msg.wParam == 2:
          w.openDevTools()
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
      elif GetTickCount() - closeStartTick >= 5000:
        echo "[DUMP] Flush timeout (5s) — closing anyway"
        isClosing = false
        DestroyWindow(hwnd)

    # Sleep to prevent CPU spinning
    # No poll() needed - HTTP server runs in its own thread with its own event loop
    Sleep(1)

  w.destroy()

  echo "[INFO] Application closed"

when isMainModule:
  main()
