import std/[json, os, strformat, strutils]
import ./webview
import winim/lean

const polyfill = staticRead("polyfill.js")

var savedPlacement: WINDOWPLACEMENT
var isFullscreen = false

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
    SetWindowPlacement(hwnd, savedPlacement.addr)
    SetWindowPos(hwnd, 0, 0, 0, 0, 0, SWP_NOMOVE or SWP_NOSIZE or SWP_NOZORDER or SWP_NOOWNERZORDER or SWP_FRAMECHANGED)
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
  else:
    result.windowTitle = "Rover App"
    result.windowWidth = 960
    result.windowHeight = 720

proc main() =
  # Find package.json in current directory
  let configFile = getCurrentDir() / "package.json"

  if not fileExists(configFile):
    echo "[ERROR] package.json not found!"
    echo "[ERROR] Please create package.json in the same directory"
    quit(1)

  # Load configuration
  echo "[CONFIG] Loading configuration from package.json..."
  let config = loadConfig(configFile)

  echo &"[CONFIG] App: {config.name}"
  echo &"[CONFIG] Main: {config.main}"
  echo &"[CONFIG] Title: {config.windowTitle}"
  echo &"[CONFIG] Window Size: {config.windowWidth}x{config.windowHeight}"
  echo ""

  # Build path to main HTML file
  let mainPath = getCurrentDir() / config.main

  if not fileExists(mainPath):
    echo &"[ERROR] Main file not found: {mainPath}"
    quit(1)

  # Create WebView window
  # Pass config size to ensure it opens at correct size and centered immediately
  let w = newWebview(width = config.windowWidth, height = config.windowHeight)
  w.title = config.windowTitle
  # Size is already set correctly in newWebview, no need to call w.size again
  w.init(polyfill)

  # Configure Virtual Host Mapping to bypass CORS
  # We map the current directory to "http://rover.assets/"
  let hostName = "rover.assets"
  let mappingPath = getCurrentDir()
  
  # AccessKind: 1 = Allow (COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW)
  # This enables CORS access which is critical for RPG Maker
  w.setVirtualHostNameToFolderMapping(cstring(hostName), cstring(mappingPath), 1)

  # Navigate to the virtual host URL
  # Note: mappingPath is mapped to the root of hostName
  # config.main is relative to mappingPath
  let url = &"http://{hostName}/{config.main}"
  echo &"[WEBVIEW] Virtual Host: {hostName} -> {mappingPath}"
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
          if kind == pcFile:
            files.add(extractFilename(path))
      
      # Return as JSON array
      let jsonResult = $(%files)
      w.webviewReturn(id, 0, cstring(jsonResult))
    except:
      # Return empty array on error
      w.webviewReturn(id, 0, "[]")
  , wPtr)

  echo ""
  echo "================================================"
  echo "  Rover - WebView2 Application Running"
  echo "  Close the window to exit"
  echo "================================================"
  echo ""

  # Centering is already handled in webview.h constructor
  # No need to call centerWindow here
  let hwnd = cast[HWND](w.getWindow())
  
  # Register Hotkeys
  RegisterHotKey(hwnd, 1, MOD_NOREPEAT, VK_F4)
  RegisterHotKey(hwnd, 2, MOD_NOREPEAT, VK_F12)

  var msg: MSG
  while GetMessage(msg.addr, 0, 0, 0) != 0:
    if msg.message == WM_HOTKEY:
      if msg.wParam == 1:
        toggleFullscreen(hwnd)
      elif msg.wParam == 2:
        w.openDevTools()
    TranslateMessage(msg.addr)
    DispatchMessage(msg.addr)

  w.destroy()

  echo "[INFO] Application closed"

when isMainModule:
  main()
