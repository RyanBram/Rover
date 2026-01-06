import std/[json, os, strformat, strutils, osproc]
import ./webview
import winim/lean
import winim/inc/shellapi  # For ExtractIcon

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
    windowIcon: string  # Path to window icon (PNG, ICO)

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
  
  # Window icon (NW.js format: window.icon)
  if jsonData.hasKey("window") and jsonData["window"].hasKey("icon"):
    result.windowIcon = jsonData["window"]["icon"].getStr("")
  else:
    result.windowIcon = "icon/icon.png"  # Default icon path

proc createDefaultPackageJson(filename: string) =
  ## Create a default package.json file with standard fields
  let defaultConfig = %*{
    "name": "rover-app",
    "main": "index.html",
    "window": {
      "title": "Rover App",
      "icon": "icon/icon.png",
      "width": 960,
      "height": 720
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
  echo ""

  # Build path to main HTML file
  let mainPath = getCurrentDir() / config.main

  if not fileExists(mainPath):
    echo &"[ERROR] Main file not found: {mainPath}"
    quit(1)

  # Create WebView window
  # Pass config size to ensure it opens at correct size and centered immediately
  let w = newWebview(width = config.windowWidth, height = config.windowHeight)
  
  # Get HWND and set icon IMMEDIATELY after window creation
  # This minimizes the visible delay where window has no/default icon
  let hwnd = cast[HWND](w.getWindow())
  
  # Set icon first (priority: package.json > exe fallback)
  # HTML/JS can override this after page loads via auto-sync
  if config.windowIcon.len > 0:
    setWindowIcon(hwnd, config.windowIcon)
  else:
    setWindowIconFromExe(hwnd)
  
  # Now set title and initialize polyfill
  w.title = config.windowTitle
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
