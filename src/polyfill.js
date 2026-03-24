(function () {
  // =========================================================================
  // NW.js COMPATIBILITY FLAGS
  // These flags enable detection by NW.js applications
  // =========================================================================

  // Universal NW.js detection - most apps check: typeof nw !== 'undefined'
  // The nw object itself is defined below

  // Helper to safety call native bindings
  function callNative(name, args) {
    if (typeof window[name] === "function") {
      window[name](args);
    } else {
      console.log("Native binding not found: " + name);
    }
  }

  // =========================================================================
  // NODE.JS GLOBAL POLYFILLS FOR UNITY WEBGL
  // Unity WebGL builds may reference __dirname and __filename
  // =========================================================================

  if (typeof window.__dirname === "undefined") {
    // __dirname represents the directory of the current script
    // For web context, use empty string or current location
    window.__dirname = "";

    // Try to derive from location
    try {
      var pathParts = window.location.pathname.split("/");
      pathParts.pop(); // Remove filename
      window.__dirname = pathParts.join("/") || "/";
    } catch (e) {
      window.__dirname = "/";
    }
  }

  if (typeof window.__filename === "undefined") {
    // __filename represents the filename of the current script
    window.__filename = window.location.pathname || "/index.html";
  }

  // Emulate process object for NW.js compatibility
  if (typeof window.process === "undefined") {
    // Store start time for hrtime calculations
    var _processStartTime = performance.now();

    window.process = {
      platform: "win32",
      versions: {
        node: "12.0.0",
        nw: "0.45.0",
      },
      mainModule: {
        filename: "./index.html", // Updated by initBaseDir() below
      },
      cwd: function () {
        return window.__roverBaseDir || ".";
      },
      on: function () {},
      argv: Array.isArray(window.__roverArgv) ? window.__roverArgv.slice() : [],
      // process.binding("constants") — required by Emscripten NODEFS staticInit.
      // Returns Windows CRT open-mode flags that NODEFS maps to its internal flags.
      binding: function (name) {
        if (name === "constants") {
          return {
            fs: {
              O_RDONLY: 0,
              O_WRONLY: 1,
              O_RDWR: 2,
              O_CREAT: 256, // 0x100  Windows CRT _O_CREAT
              O_EXCL: 1024, // 0x400  Windows CRT _O_EXCL
              O_NOCTTY: 0, // Not meaningful on Windows
              O_TRUNC: 512, // 0x200  Windows CRT _O_TRUNC
              O_APPEND: 8, // 0x008  Windows CRT _O_APPEND
              O_SYNC: 0, // Not supported on Windows CRT
              O_NOFOLLOW: 0, // Not supported on Windows
            },
          };
        }
        return {};
      },
      // hrtime polyfill for Effekseer and other Node.js timing APIs
      // Returns [seconds, nanoseconds] tuple representing high-resolution time
      hrtime: function (previousTimestamp) {
        // Get current time in milliseconds with high precision
        var nowMs = performance.now();

        if (previousTimestamp) {
          // Calculate difference from previous timestamp
          var prevMs = previousTimestamp[0] * 1000 + previousTimestamp[1] / 1e6;
          var diffMs = nowMs - prevMs;
          var diffSeconds = Math.floor(diffMs / 1000);
          var diffNanos = Math.round((diffMs % 1000) * 1e6);
          return [diffSeconds, diffNanos];
        } else {
          // Return time since process start
          var elapsedMs = nowMs - _processStartTime;
          var seconds = Math.floor(elapsedMs / 1000);
          var nanos = Math.round((elapsedMs % 1000) * 1e6);
          return [seconds, nanos];
        }
      },
    };

    // Also add hrtime.bigint for Node.js 10.7.0+ compatibility
    window.process.hrtime.bigint = function () {
      var nowMs = performance.now();
      var elapsedMs = nowMs - _processStartTime;
      // Return nanoseconds as BigInt if supported, otherwise as number
      if (typeof BigInt !== "undefined") {
        return BigInt(Math.round(elapsedMs * 1e6));
      } else {
        return Math.round(elapsedMs * 1e6);
      }
    };
  }

  // __roverBaseDir is injected by the Rover preamble before this polyfill runs.
  // Ensure it exists as a string in case of about:blank / early eval.
  if (typeof window.__roverBaseDir !== "string") {
    window.__roverBaseDir = "";
  }

  (function initBaseDir() {
    // Skip on about:blank / non-HTTP pages.
    if (
      window.location.protocol !== "http:" &&
      window.location.protocol !== "https:"
    )
      return;

    // HTTP server mode fallback: __roverBaseDir may not be in preamble for older builds.
    if (!window.__roverBaseDir &&
        (window.location.hostname === "localhost" ||
         window.location.hostname === "127.0.0.1")) {
      try {
        var xhrBase = new XMLHttpRequest();
        xhrBase.open("GET", window.location.origin + "/__get_base_dir__", false);
        xhrBase.send(null);
        if (xhrBase.status === 200) window.__roverBaseDir = xhrBase.responseText;
      } catch (e) {}
    }

    // Sync process.mainModule.filename from package.json "main" field.
    if (window.__roverBaseDir) {
      var mainEntry = "index.html";
      try {
        var xhrPkg = new XMLHttpRequest();
        xhrPkg.open("GET", window.location.origin + "/package.json", false);
        xhrPkg.send(null);
        if (xhrPkg.status === 200) {
          var pkg = JSON.parse(xhrPkg.responseText);
          if (pkg.main) mainEntry = pkg.main;
        }
      } catch (e) {}
      window.process.mainModule.filename =
        window.__roverBaseDir + "\\" + mainEntry.replace(/\//g, "\\");
    }
  })();

  // =========================================================================
  // BROWSER FULLSCREEN API SHIM
  // WebView2 doesn't support standard browser Fullscreen API like NW.js does
  // This shim redirects fullscreen calls to native toggle_fullscreen binding
  // Both NW.js and WebView2 use Chromium, so only standard API is needed
  // =========================================================================

  // Track fullscreen state internally
  window._roverIsFullScreen = window.__roverInitialFullscreen || false;

  // Track whether the app manages its own fullscreen layout.
  // true  → requestFullscreen was called on document.body, or via nw.Window API
  //         (e.g. RPG Maker) — the app handles canvas resize/centering itself.
  // false → requestFullscreen was called on a specific sub-element (e.g. Unity canvas)
  //         — Rover must stretch that element to fill the screen.
  var _fullscreenManagedByApp = false;

  var _originalFullscreenStyles = null;

  function applyFullscreenLayout() {
    var canvas =
      document.getElementById("unity-canvas") ||
      document.querySelector("canvas");
    var container =
      document.getElementById("unity-container") ||
      (canvas ? canvas.parentElement : null);
    var footer = document.getElementById("unity-footer");

    if (!canvas) return;

    if (!_originalFullscreenStyles) {
      _originalFullscreenStyles = {
        containerClass: container ? container.className : "",
        containerStyle: container ? container.getAttribute("style") || "" : "",
        canvasStyle: canvas.getAttribute("style") || "",
        footerDisplay: footer ? footer.style.display : "",
      };
    }

    if (container) {
      container.style.position = "absolute";
      container.style.left = "0";
      container.style.top = "0";
      container.style.right = "0";
      container.style.bottom = "0";
      container.style.transform = "none";
      container.style.width = "100%";
      container.style.height = "100%";
    }

    canvas.style.width = "100%";
    canvas.style.height = "100%";

    if (footer) {
      footer.style.display = "none";
    }

    document.body.style.overflow = "hidden";
  }

  function restoreNormalLayout() {
    var canvas =
      document.getElementById("unity-canvas") ||
      document.querySelector("canvas");
    var container =
      document.getElementById("unity-container") ||
      (canvas ? canvas.parentElement : null);
    var footer = document.getElementById("unity-footer");

    if (!canvas || !_originalFullscreenStyles) return;

    if (container) {
      container.className = _originalFullscreenStyles.containerClass;
      container.setAttribute("style", _originalFullscreenStyles.containerStyle);
    }

    canvas.setAttribute("style", _originalFullscreenStyles.canvasStyle);

    if (footer) {
      footer.style.display = _originalFullscreenStyles.footerDisplay;
    }

    document.body.style.overflow = "";
  }

  // Helper to check fullscreen based on window size
  function checkFullScreen() {
    return (
      window.innerWidth >= screen.width - 10 &&
      window.innerHeight >= screen.height - 10
    );
  }

  // Helper to dispatch fullscreenchange event and optionally apply layout
  function dispatchFullScreenChange() {
    setTimeout(function () {
      var entering = checkFullScreen();
      window._roverIsFullScreen = entering;
      var event = new Event("fullscreenchange", { bubbles: true });
      document.dispatchEvent(event);
      // Only apply/restore layout when the app does NOT manage it itself
      if (!_fullscreenManagedByApp) {
        if (entering) {
          applyFullscreenLayout();
        } else {
          restoreNormalLayout();
        }
      }
    }, 100);
  }

  // Listen for resize to update fullscreen state
  window.addEventListener("resize", function () {
    var wasFullScreen = window._roverIsFullScreen;
    window._roverIsFullScreen = checkFullScreen();
    if (wasFullScreen !== window._roverIsFullScreen) {
      var event = new Event("fullscreenchange", { bubbles: true });
      document.dispatchEvent(event);
    }
  });

  // Shim document.fullscreenElement
  Object.defineProperty(document, "fullscreenElement", {
    get: function () {
      return window._roverIsFullScreen ? document.body : null;
    },
    configurable: true,
  });

  // Shim Element.prototype.requestFullscreen
  Element.prototype.requestFullscreen = function () {
    if (!window._roverIsFullScreen) {
      // body-level call → app manages its own layout (e.g. RPG Maker)
      // sub-element call → Rover must stretch the element (e.g. Unity canvas)
      _fullscreenManagedByApp = (this === document.body);
      if (typeof window.toggle_fullscreen === "function") {
        window.toggle_fullscreen().then(dispatchFullScreenChange);
      }
    }
    return Promise.resolve();
  };

  // Shim document.exitFullscreen
  document.exitFullscreen = function () {
    if (window._roverIsFullScreen) {
      if (typeof window.toggle_fullscreen === "function") {
        window.toggle_fullscreen().then(dispatchFullScreenChange);
      }
    }
    return Promise.resolve();
  };

  // Emulate global nw object for NW.js compatibility (used by Utils.isOptionValid, etc.)
  if (typeof window.nw === "undefined") {
    window.nw = {
      Window: {
        get: function () {
          return {
            focus: function () {
              if (typeof window.window_focus === "function") {
                window.window_focus();
              }
            },
            blur: function () {
              // Blur window - no-op in most cases
            },
            showDevTools: function () {
              callNative("toggle_devtools");
            },
            toggleFullscreen: function () {
              _fullscreenManagedByApp = true; // NW.js API → app-managed layout
              callNative("toggle_fullscreen");
              dispatchFullScreenChange();
            },
            // NW.js fullscreen API
            enterFullscreen: function () {
              if (!window._roverIsFullScreen) {
                _fullscreenManagedByApp = true; // NW.js API → app-managed layout
                if (typeof window.toggle_fullscreen === "function") {
                  window.toggle_fullscreen().then(dispatchFullScreenChange);
                }
              }
            },
            leaveFullscreen: function () {
              if (window._roverIsFullScreen) {
                _fullscreenManagedByApp = true; // NW.js API → app-managed layout
                if (typeof window.toggle_fullscreen === "function") {
                  window.toggle_fullscreen().then(dispatchFullScreenChange);
                }
              }
            },
            get isFullscreen() {
              return window._roverIsFullScreen;
            },
            on: function () {},
            // Window position/size - getters return actual values, setters call native
            get x() {
              return window.screenX || 0;
            },
            set x(val) {
              if (typeof window.set_window_position === "function") {
                window.set_window_position(val, window.screenY || 0);
              }
            },
            get y() {
              return window.screenY || 0;
            },
            set y(val) {
              if (typeof window.set_window_position === "function") {
                window.set_window_position(window.screenX || 0, val);
              }
            },
            get width() {
              return window.outerWidth || 800;
            },
            set width(val) {
              if (typeof window.set_window_size === "function") {
                window.set_window_size(val, window.outerHeight || 600);
              }
            },
            get height() {
              return window.outerHeight || 600;
            },
            set height(val) {
              if (typeof window.set_window_size === "function") {
                window.set_window_size(window.outerWidth || 800, val);
              }
            },
            get title() {
              return document.title || "";
            },
            set title(val) {
              document.title = val;
              if (typeof window.set_title === "function") {
                window.set_title(val);
              }
            },
            center: function () {
              callNative("center_window");
            },
            minimize: function () {
              if (typeof window.window_minimize === "function") {
                window.window_minimize();
              }
            },
            maximize: function () {
              if (typeof window.window_maximize === "function") {
                window.window_maximize();
              }
            },
            unmaximize: function () {
              if (typeof window.window_restore === "function") {
                window.window_restore();
              }
            },
            restore: function () {
              if (typeof window.window_restore === "function") {
                window.window_restore();
              }
            },
            requestAttention: function (attention) {
              if (typeof window.window_flash === "function") {
                window.window_flash(attention);
              }
            },
            setMaximumSize: function (w, h) {
              if (typeof window.set_window_max_size === "function") {
                window.set_window_max_size(w, h);
              }
            },
            setMinimumSize: function (w, h) {
              if (typeof window.set_window_min_size === "function") {
                window.set_window_min_size(w, h);
              }
            },
            setResizable: function (resizable) {
              if (typeof window.set_window_resizable === "function") {
                window.set_window_resizable(resizable);
              }
            },
            setAlwaysOnTop: function (onTop) {
              if (typeof window.set_always_on_top === "function") {
                window.set_always_on_top(onTop);
              }
            },
          };
        },
      },
      App: {
        quit: function () {
          callNative("exit_app");
        },
        argv: Array.isArray(window.__roverArgv) ? window.__roverArgv.slice() : [],
        fullArgv: Array.isArray(window.__roverArgv) ? window.__roverArgv.slice() : [],
        filteredArgv: [],
        clearCache: function () {
          // Cache clearing - no-op for WebView2
        },
      },
      Shell: {
        openExternal: function (url) {
          window.open(url);
        },
        openItem: function (path) {
          if (typeof window.shell_open_item === "function") {
            window.shell_open_item(path);
          } else {
            console.log("[Rover] shell_open_item not available for:", path);
          }
        },
      },
      Clipboard: {
        get: function () {
          return {
            get: function (type) {
              // Sync clipboard read - returns cached value
              // Real clipboard access is async, so we cache
              if (window._roverClipboardText !== undefined) {
                return window._roverClipboardText;
              }
              // Try to read async and cache for next call
              if (navigator.clipboard && navigator.clipboard.readText) {
                navigator.clipboard
                  .readText()
                  .then(function (text) {
                    window._roverClipboardText = text;
                  })
                  .catch(function () {});
              }
              return "";
            },
            set: function (data, type) {
              window._roverClipboardText = data;
              // Write to system clipboard
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(data).catch(function (err) {
                  console.warn("[Rover] Clipboard write failed:", err);
                });
              } else if (typeof window.clipboard_write === "function") {
                window.clipboard_write(data);
              }
            },
            clear: function () {
              window._roverClipboardText = "";
              if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText("").catch(function () {});
              } else if (typeof window.clipboard_clear === "function") {
                window.clipboard_clear();
              }
            },
          };
        },
      },
      process: window.process || { platform: "win32" },
    };

    // Also set as nwgui for backwards compatibility with older NW.js code
    // c2runtime.js accesses window["nwgui"] directly
    window.nwgui = window.nw;
  }

  // Emulate require function
  if (typeof window.require === "undefined") {
    window.require = function (moduleName) {
      // console.log("Polyfill require: " + moduleName);
      if (moduleName === "nw.gui") {
        return {
          Window: {
            get: function () {
              return {
                focus: function () {},
                showDevTools: function () {
                  callNative("toggle_devtools");
                },
                toggleFullscreen: function () {
                  _fullscreenManagedByApp = true;
                  callNative("toggle_fullscreen");
                  dispatchFullScreenChange();
                },
                enterFullscreen: function () {
                  if (
                    !window._roverIsFullScreen &&
                    typeof window.toggle_fullscreen === "function"
                  ) {
                    _fullscreenManagedByApp = true;
                    window.toggle_fullscreen().then(dispatchFullScreenChange);
                  }
                },
                leaveFullscreen: function () {
                  if (
                    window._roverIsFullScreen &&
                    typeof window.toggle_fullscreen === "function"
                  ) {
                    _fullscreenManagedByApp = true;
                    window.toggle_fullscreen().then(dispatchFullScreenChange);
                  }
                },
                get isFullscreen() {
                  return window._roverIsFullScreen;
                },
                on: function () {},
                x: 0,
                y: 0,
                width: 800,
                height: 600,
                center: function () {
                  callNative("center_window");
                },
              };
            },
          },
          App: {
            quit: function () {
              callNative("exit_app");
            },
            argv: Array.isArray(window.__roverArgv) ? window.__roverArgv.slice() : [],
          },
          Shell: {
            openExternal: function (url) {
              window.open(url);
            },
            openItem: function (path) {
              // Open file with default system application
              if (typeof window.shell_open_item === "function") {
                window.shell_open_item(path);
              } else {
                console.log("[Rover] shell_open_item not available for:", path);
              }
            },
          },
        };
      }
      if (moduleName === "os") {
        return {
          platform: function () {
            return "win32";
          },
          arch: function () {
            return "x64";
          },
          homedir: function () {
            // Return user home directory
            if (typeof window.get_user_home === "function") {
              // Use native binding if available (async, so cache result)
              if (!window._roverUserHome) {
                window
                  .get_user_home()
                  .then(function (dir) {
                    window._roverUserHome = dir;
                  })
                  .catch(function () {
                    window._roverUserHome = "C:\\Users\\User";
                  });
                return "C:\\Users\\User"; // Fallback until async completes
              }
              return window._roverUserHome;
            }
            // Fallback: derive from base dir
            if (window.__roverBaseDir) {
              var parts = window.__roverBaseDir.split("\\");
              if (parts.length >= 3) {
                return parts[0] + "\\" + parts[1] + "\\" + parts[2];
              }
            }
            return "C:\\Users\\User";
          },
        };
      }
      if (moduleName === "path") {
        return {
          sep: "\\",
          dirname: function (p) {
            if (!p || typeof p !== "string") return ".";
            // HTTP URLs — use forward slash
            if (/^https?:\/\//i.test(p)) {
              var lastSlash = p.lastIndexOf("/");
              // Don't strip past the protocol+host
              var afterProto = p.indexOf("//") + 2;
              if (lastSlash <= afterProto) return p;
              return p.substring(0, lastSlash);
            }
            // Local paths — normalize to backslash
            p = p.replace(/\//g, "\\");
            var lastSlash = p.lastIndexOf("\\");
            if (lastSlash === -1) return ".";
            if (lastSlash === 0) return "\\";
            return p.substring(0, lastSlash);
          },
          basename: function (p, ext) {
            if (!p || typeof p !== "string") return "";
            p = p.replace(/\//g, "\\");
            var lastSlash = p.lastIndexOf("\\");
            var base = lastSlash === -1 ? p : p.substring(lastSlash + 1);
            if (ext && base.endsWith(ext)) {
              base = base.substring(0, base.length - ext.length);
            }
            return base;
          },
          extname: function (p) {
            if (!p || typeof p !== "string") return "";
            var base = this.basename(p);
            var dotIndex = base.lastIndexOf(".");
            if (dotIndex <= 0) return "";
            return base.substring(dotIndex);
          },
          join: function () {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              if (arguments[i]) parts.push(arguments[i]);
            }
            return this.normalize(parts.join("\\"));
          },
          normalize: function (p) {
            if (!p || typeof p !== "string") return ".";
            // HTTP URLs — pass through
            if (/^https?:\/\//i.test(p)) return p;
            // Remember if path had a trailing slash
            var hadTrailingSlash = p.endsWith("/") || p.endsWith("\\");
            p = p.replace(/\//g, "\\");
            // Remove duplicate slashes
            p = p.replace(/\\+/g, "\\");
            // Preserve trailing slash if original had one (important for directory paths)
            if (hadTrailingSlash && !p.endsWith("\\")) {
              p = p + "\\";
            }
            return p;
          },
          isAbsolute: function (p) {
            if (!p || typeof p !== "string") return false;
            // HTTP URLs are absolute
            if (/^https?:\/\//i.test(p)) return true;
            // Windows: C:\ or \\
            return /^[a-zA-Z]:[\\/]/.test(p) || p.startsWith("\\\\");
          },
          resolve: function () {
            // Mimics Node.js path.resolve: processes segments right-to-left,
            // stopping at the first absolute path encountered.
            // Prepends cwd (__roverBaseDir) if no absolute path is found.
            var segments = [];
            for (var i = arguments.length - 1; i >= 0; i--) {
              var seg = arguments[i];
              if (!seg || typeof seg !== "string") continue;
              segments.unshift(seg);
              if (this.isAbsolute(seg)) break;
            }
            if (segments.length === 0 || !this.isAbsolute(segments[0])) {
              segments.unshift(window.__roverBaseDir || ".");
            }
            return this.normalize(segments.join("\\"));
          },
        };
      }
      if (moduleName === "url") {
        return {
          // Convert a file:// or http://localhost URL to an absolute filesystem path.
          // PGlite uses this to compute scriptDirectory from import.meta.url.
          fileURLToPath: function (url) {
            var urlStr =
              url && typeof url.href === "string" ? url.href : String(url);
            // file:///C:/path  →  C:\path
            if (urlStr.startsWith("file:///")) {
              return urlStr.slice(8).replace(/\//g, "\\");
            }
            if (urlStr.startsWith("file://")) {
              return urlStr.slice(7).replace(/\//g, "\\");
            }
            // HTTP/HTTPS URLs — pass through as-is.
            // In WebView context, these are valid for both fetch() and readFileSync().
            return urlStr;
          },
          pathToFileURL: function (p) {
            var normalized = p.replace(/\\/g, "/");
            return new URL("file:///" + normalized.replace(/^\//, ""));
          },
          URL: URL,
        };
      }
      if (moduleName === "fs") {
        // =====================================================================
        // COMPREHENSIVE FS MODULE — SYNC XHR TO HTTP SERVER ENDPOINTS
        // Provides full POSIX-like fs API required by PGlite's Emscripten NODEFS.
        // All sync operations use synchronous XMLHttpRequest to Rover's HTTP server.
        // This requires httpServer: true in package.json.
        // =====================================================================

        var _origin = window.location.origin;

        // Detect VirtualHost mode: game served from http://rover.assets/ (not localhost).
        // In VirtualHost mode the HTTP-only endpoints (/__fs_mkdir__ etc.) are unreachable,
        // so we fall back to the native window bindings (fs_mkdir, fs_write_file, etc.)
        // which are always registered by rover.nim regardless of httpServer setting.
        var _isVirtualHostMode = (
          window.location.hostname !== "localhost" &&
          window.location.hostname !== "127.0.0.1"
        );

        // Helper: fire-and-forget native async binding, like the old polyfill did.
        // Path arguments for fs_* bindings are percent-encoded to survive the
        // WebView2 ExecuteScript bridge without corrupting non-ASCII characters
        // (e.g., Japanese directory/file names). The Nim side decodeUrl()s them.
        function _nativeCall(bindingName, args) {
          if (typeof window[bindingName] === "function") {
            var encoded = args.slice();
            if (bindingName.indexOf("fs_") === 0 && encoded.length > 0) {
              encoded[0] = encodeURIComponent(encoded[0]);
              if ((bindingName === "fs_rename" || bindingName === "fs_copy_file") && encoded.length > 1) {
                encoded[1] = encodeURIComponent(encoded[1]);
              }
            }
            return window[bindingName].apply(window, encoded)
              .catch(function(e) { console.warn("[Rover] " + bindingName + " failed:", e); });
          }
          console.warn("[Rover] native binding not available: " + bindingName);
          return Promise.resolve();
        }

        function _syncGet(endpoint) {
          var xhr = new XMLHttpRequest();
          xhr.open("GET", _origin + endpoint, false);
          xhr.send(null);
          return xhr;
        }

        function _syncPost(endpoint, body) {
          var xhr = new XMLHttpRequest();
          xhr.open("POST", _origin + endpoint, false);
          xhr.setRequestHeader("Content-Type", "application/json");
          xhr.send(JSON.stringify(body));
          return xhr;
        }

        // Base64 helpers for binary data transfer
        function _bytesToBase64(bytes, offset, length) {
          var str = "";
          for (var i = 0; i < length; i++) {
            str += String.fromCharCode(bytes[offset + i] & 0xff);
          }
          return btoa(str);
        }

        function _base64ToBytes(base64) {
          var str = atob(base64);
          var bytes = new Uint8Array(str.length);
          for (var i = 0; i < str.length; i++) {
            bytes[i] = str.charCodeAt(i);
          }
          return bytes;
        }

        // Track fd→path mappings for fstatSync
        var _fdPaths = {};

        // =====================================================================
        // Stat cache: avoids redundant sync XHR round-trips for repeated
        // lstatSync / existsSync calls on the same path during PGlite init.
        // Write operations (mkdir, write, unlink, rename, etc.) invalidate
        // affected paths so stale data is never returned.
        // =====================================================================
        var _statCache = {};
        var _statCacheSize = 0;
        var _STAT_CACHE_MAX = 512;

        function _statCacheSet(key, value) {
          if (_statCacheSize >= _STAT_CACHE_MAX) {
            _statCache = {};
            _statCacheSize = 0;
          }
          _statCache[key] = value;
          _statCacheSize++;
        }

        function _statCacheInvalidate(key) {
          if (key in _statCache) {
            delete _statCache[key];
            _statCacheSize--;
          }
        }

        /**
         * Prefetch the entire directory tree stat info into the cache.
         * One HTTP call replaces hundreds of individual lstatSync round-trips.
         * Call this before PGlite init to warm the cache.
         * @param {string} dirPath - absolute path to walk recursively
         */
        function _prefetchTreeStat(dirPath) {
          try {
            var xhr = _syncGet(
              "/__fs_tree_stat__?path=" + encodeURIComponent(dirPath),
            );
            if (xhr.status === 200) {
              var entries = JSON.parse(xhr.responseText);
              for (var i = 0; i < entries.length; i++) {
                var e = entries[i];
                var p = e.p;
                var pBack = p.replace(/\//g, "\\");
                var statObj = {
                  dev: 0,
                  ino: 0,
                  mode: e.m,
                  nlink: e.nl || 1,
                  uid: 0,
                  gid: 0,
                  rdev: 0,
                  size: e.s,
                  atime: new Date(e.at * 1000),
                  mtime: new Date(e.mt * 1000),
                  ctime: new Date(e.ct * 1000),
                  blksize: 4096,
                  blocks: ((e.s + 4095) / 4096) | 0,
                  isFile: (function (m) {
                    return function () {
                      return (m & 0xf000) === 0x8000;
                    };
                  })(e.m),
                  isDirectory: (function (m) {
                    return function () {
                      return (m & 0xf000) === 0x4000;
                    };
                  })(e.m),
                  isSymbolicLink: (function (m) {
                    return function () {
                      return (m & 0xf000) === 0xa000;
                    };
                  })(e.m),
                };
                _statCacheSet(p, statObj);
                if (pBack !== p) _statCacheSet(pBack, statObj);
              }
            }
          } catch (ex) {}
        }

        // Also expose prefetchTreeStat so db.js can call it before PGlite init (legacy compat)
        window.__roverPrefetchTreeStat = _prefetchTreeStat;

        return {
          // =================================================================
          // FILE DESCRIPTOR OPERATIONS (required by Emscripten NODEFS)
          // =================================================================

          openSync: function (filePath, flags, mode) {
            var xhr = _syncPost("/__fs_open__", {
              path: filePath,
              flags: flags || 0,
              mode: mode || 438,
            });
            if (xhr.status === 200) {
              var fd = parseInt(xhr.responseText);
              _fdPaths[fd] = filePath;
              _statCacheInvalidate(filePath);
              return fd;
            }
            var err = new Error("ENOENT: openSync failed: " + filePath + " (flags=" + flags + ")");
            err.code = "ENOENT";
            throw err;
          },

          closeSync: function (fd) {
            _syncPost("/__fs_close__", { fd: fd });
            delete _fdPaths[fd];
          },

          readSync: function (fd, buffer, offset, length, position) {
            var xhr = _syncPost("/__fs_read_fd__", {
              fd: fd,
              length: length,
              position: (position != null) ? position : null,
            });
            if (xhr.status === 200) {
              var result = JSON.parse(xhr.responseText);
              if (result.bytesRead > 0) {
                var decoded = _base64ToBytes(result.data);
                for (var i = 0; i < decoded.length; i++) buffer[offset + i] = decoded[i];
              }
              return result.bytesRead;
            }
            throw new Error("readSync failed: fd=" + fd);
          },

          writeSync: function (fd, buffer, offset, length, position) {
            var base64 = _bytesToBase64(buffer, offset, length);
            var xhr = _syncPost("/__fs_write_fd__", {
              fd: fd,
              position: (position != null) ? position : null,
              data: base64,
            });
            if (xhr.status === 200) {
              var result = JSON.parse(xhr.responseText);
              if (_fdPaths[fd]) _statCacheInvalidate(_fdPaths[fd]);
              return result.bytesWritten;
            }
            throw new Error("writeSync failed: fd=" + fd);
          },

          ftruncateSync: function (fd, length) {
            _syncPost("/__fs_ftruncate__", { fd: fd, length: length || 0 });
            if (_fdPaths[fd]) _statCacheInvalidate(_fdPaths[fd]);
          },

          fstatSync: function (fd) {
            var filePath = _fdPaths[fd];
            if (!filePath) { var e = new Error("EBADF"); e.code = "EBADF"; throw e; }
            return this.lstatSync(filePath);
          },

          fsyncSync: function (fd) {
            // No-op: Nim's CRT handles sync on close
          },

          // =================================================================
          // STAT OPERATIONS
          // =================================================================

          lstatSync: function (filePath) {
            var cached = _statCache[filePath];
            if (cached !== undefined) {
              if (cached === null) { var e = new Error("ENOENT: " + filePath); e.code = "ENOENT"; throw e; }
              return cached;
            }
            var xhr = _syncGet("/__fs_lstat__?path=" + encodeURIComponent(filePath));
            if (xhr.status === 200 && xhr.responseText !== "null") {
              var s = JSON.parse(xhr.responseText);
              var result = {
                dev: s.dev || 0, ino: s.ino || 0, mode: s.mode,
                nlink: s.nlink || 1, uid: 0, gid: 0, rdev: 0, size: s.size,
                atime: new Date(s.atime * 1000), mtime: new Date(s.mtime * 1000), ctime: new Date(s.ctime * 1000),
                blksize: s.blksize || 4096, blocks: s.blocks || 0,
                isFile: function () { return (s.mode & 0xf000) === 0x8000; },
                isDirectory: function () { return (s.mode & 0xf000) === 0x4000; },
                isSymbolicLink: function () { return (s.mode & 0xf000) === 0xa000; },
              };
              _statCacheSet(filePath, result);
              return result;
            }
            _statCacheSet(filePath, null);
            var err = new Error("ENOENT: no such file or directory: " + filePath);
            err.code = "ENOENT";
            throw err;
          },

          statSync: function (filePath) {
            return this.lstatSync(filePath);
          },

          // =================================================================
          // DIRECTORY OPERATIONS
          // =================================================================

          existsSync: function (filePath) {
            if (!filePath) return false;
            var cached = _statCache[filePath];
            if (cached !== undefined) return cached !== null;
            try {
              if (_isVirtualHostMode) {
                // In VirtualHost mode, try HEAD request to rover.assets URL
                var baseDir = window.__roverBaseDir || "";
                var url = filePath;
                if (filePath.indexOf(":") > -1 && baseDir && filePath.indexOf(baseDir) === 0) {
                  url = "http://rover.assets/" + filePath.substring(baseDir.length + 1).replace(/\\/g, "/");
                } else if (!/^https?:\/\//i.test(filePath)) {
                  url = "http://rover.assets/" + filePath.replace(/\\/g, "/");
                }
                var xh = new XMLHttpRequest();
                xh.open("HEAD", url, false);
                xh.send(null);
                return xh.status === 200;
              }
              var xhr = _syncGet("/__exists__?path=" + encodeURIComponent(filePath));
              var exists = xhr.status === 200 && xhr.responseText === "true";
              if (!exists) _statCacheSet(filePath, null);
              return exists;
            } catch (e) { return false; }
          },

          mkdirSync: function (dirPath, options) {
            if (_isVirtualHostMode) {
              // Use native async binding — fire-and-forget, same as veryold_runtime
              _nativeCall("fs_mkdir", [dirPath]);
              return;
            }
            _syncPost("/__fs_mkdir__", { path: dirPath, recursive: options && options.recursive });
            _statCacheInvalidate(dirPath);
          },

          readdirSync: function (dirPath) {
            var xhr = _syncGet("/__fs_readdir__?path=" + encodeURIComponent(dirPath));
            if (xhr.status === 200) return JSON.parse(xhr.responseText);
            var err = new Error("ENOENT: no such file or directory, scandir '" + dirPath + "'");
            err.code = "ENOENT";
            throw err;
          },

          rmdirSync: function (dirPath) {
            if (_isVirtualHostMode) {
              _nativeCall("fs_rmdir", [dirPath]);
              return;
            }
            _syncPost("/__fs_rmdir__", { path: dirPath });
            _statCacheInvalidate(dirPath);
          },

          // =================================================================
          // FILE OPERATIONS
          // =================================================================

          readFileSync: function (filePath, options) {
            var pathStr =
              filePath && typeof filePath.href === "string"
                ? filePath.href
                : String(filePath);
            // HTTP/HTTPS URLs: sync XHR directly
            if (/^https?:\/\//i.test(pathStr)) {
              var xhr2 = new XMLHttpRequest();
              xhr2.open("GET", pathStr, false);
              xhr2.overrideMimeType("text/plain; charset=x-user-defined");
              xhr2.send(null);
              if (xhr2.status === 200) {
                var raw = xhr2.responseText;
                var bytes = new Uint8Array(raw.length);
                for (var i = 0; i < raw.length; i++)
                  bytes[i] = raw.charCodeAt(i) & 0xff;
                return bytes;
              }
              var err = new Error("ENOENT: no such file or directory, open '" + pathStr + "'");
              err.code = "ENOENT";
              throw err;
            }
            var isText =
              options === "utf8" || options === "utf-8" ||
              (options && (options.encoding === "utf8" || options.encoding === "utf-8"));

            var isRelative =
              !/^[a-zA-Z]:[\\\/]/.test(pathStr) &&
              !pathStr.startsWith("/") &&
              !pathStr.startsWith("\\\\");

            // For relative paths (e.g. Emscripten preloader's readFile("pglite.data")),
            // try HTTP fetch FIRST.
            if (isRelative) {
              var candidates = [];
              if (window.__emscriptenScriptDir)
                candidates.push(window.__emscriptenScriptDir + pathStr);
              candidates.push(_origin + "/" + pathStr);
              for (var ci = 0; ci < candidates.length; ci++) {
                var httpXhr = new XMLHttpRequest();
                httpXhr.open("GET", candidates[ci], false);
                httpXhr.overrideMimeType("text/plain; charset=x-user-defined");
                httpXhr.send(null);
                if (httpXhr.status === 200) {
                  if (isText) return httpXhr.responseText;
                  var raw2 = httpXhr.responseText;
                  var bytes2 = new Uint8Array(raw2.length);
                  for (var j = 0; j < raw2.length; j++)
                    bytes2[j] = raw2.charCodeAt(j) & 0xff;
                  return bytes2;
                }
              }
            }

            // Filesystem path — in VirtualHost mode, read via rover.assets URL
            if (_isVirtualHostMode) {
              var baseDir2 = window.__roverBaseDir || "";
              var readUrl = pathStr;
              if (pathStr.indexOf(":") > -1 && baseDir2 && pathStr.indexOf(baseDir2) === 0) {
                readUrl = "http://rover.assets/" + pathStr.substring(baseDir2.length + 1).replace(/\\/g, "/");
              } else if (!/^https?:\/\//i.test(pathStr)) {
                readUrl = "http://rover.assets/" + pathStr.replace(/\\/g, "/");
              }
              var xhrVh = new XMLHttpRequest();
              xhrVh.open("GET", readUrl, false);
              if (!isText) xhrVh.overrideMimeType("text/plain; charset=x-user-defined");
              xhrVh.send(null);
              if (xhrVh.status === 200) {
                if (isText) return xhrVh.responseText;
                var rawVh = xhrVh.responseText;
                var bytesVh = new Uint8Array(rawVh.length);
                for (var vi = 0; vi < rawVh.length; vi++) bytesVh[vi] = rawVh.charCodeAt(vi) & 0xff;
                return bytesVh;
              }
              // File not found — return null for save files (normal for non-existent saves)
              return null;
            }

            // Filesystem path via Nim HTTP server
            var endpoint = "/__fs_read__?path=" + encodeURIComponent(pathStr);
            if (!isText) endpoint += "&b64=1";
            var xhr = _syncGet(endpoint);
            if (xhr.status === 200 && xhr.responseText !== "__ENOENT__") {
              if (isText) return xhr.responseText;
              var b64 = xhr.responseText.trim();
              var binary = atob(b64);
              var bytes3 = new Uint8Array(binary.length);
              for (var k = 0; k < binary.length; k++)
                bytes3[k] = binary.charCodeAt(k);
              return bytes3;
            }

            var err = new Error("ENOENT: no such file or directory, open '" + pathStr + "'");
            err.code = "ENOENT";
            throw err;
          },

          writeFileSync: function (filePath, data) {
            if (_isVirtualHostMode) {
              if (typeof data === "string") {
                _nativeCall("fs_write_file", [filePath, data]);
              } else {
                var bytes = new Uint8Array(data.buffer || data);
                var base64 = _bytesToBase64(bytes, 0, bytes.length);
                _nativeCall("fs_write_binary", [filePath, base64]);
              }
              return;
            }
            if (typeof data === "string") {
              _syncPost("/__fs_write__", { path: filePath, content: data });
            } else {
              var bytes = new Uint8Array(data.buffer || data);
              var base64 = _bytesToBase64(bytes, 0, bytes.length);
              _syncPost("/__fs_write__", { path: filePath, content: base64, binary: true });
            }
            _statCacheInvalidate(filePath);
          },

          unlinkSync: function (filePath) {
            if (_isVirtualHostMode) {
              _nativeCall("fs_unlink", [filePath]);
              return;
            }
            _syncPost("/__fs_unlink__", { path: filePath });
            _statCacheInvalidate(filePath);
          },

          renameSync: function (oldPath, newPath) {
            if (_isVirtualHostMode) {
              _nativeCall("fs_rename", [oldPath, newPath]);
              return;
            }
            _syncPost("/__fs_rename__", { oldPath: oldPath, newPath: newPath });
            _statCacheInvalidate(oldPath);
            _statCacheInvalidate(newPath);
          },

          chmodSync: function (filePath, mode) {
            try {
              _syncPost("/__fs_chmod__", { path: filePath, mode: mode });
            } catch (e) {}
          },

          utimesSync: function (filePath, atime, mtime) {
            _syncPost("/__fs_utimes__", {
              path: filePath,
              atime: typeof atime === "object" ? atime.getTime() / 1000 : atime,
              mtime: typeof mtime === "object" ? mtime.getTime() / 1000 : mtime,
            });
          },

          symlinkSync: function (target, linkPath) {
            _syncPost("/__fs_symlink__", { target: target, path: linkPath });
          },

          readlinkSync: function (filePath) {
            var xhr = _syncGet("/__fs_readlink__?path=" + encodeURIComponent(filePath));
            if (xhr.status === 200) return xhr.responseText;
            var err = new Error("readlinkSync failed: " + filePath);
            err.code = "EINVAL";
            throw err;
          },

          truncateSync: function (filePath, size) {
            var fd = this.openSync(filePath, 2, 438);
            try { this.ftruncateSync(fd, size || 0); }
            finally { this.closeSync(fd); }
          },

          statfsSync: function (filePath) {
            return {
              type: 0x4d44, bsize: 4096, frsize: 4096,
              blocks: 262144, bfree: 131072, bavail: 131072,
              files: 65536, ffree: 32768, fsid: 0, flags: 0, namelen: 255,
            };
          },

          // =================================================================
          // ASYNC VERSIONS (backward compat with RPG Maker / existing code)
          // =================================================================

          writeFile: function (path, data, callback) {
            try {
              this.writeFileSync(path, data);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          readFile: function (path, encoding, callback) {
            if (typeof encoding === "function") {
              callback = encoding;
              encoding = undefined;
            }
            var result, syncErr;
            try {
              result = this.readFileSync(path, encoding);
            } catch (e) {
              syncErr = e;
            }
            // Call callback OUTSIDE try/catch to avoid double-firing
            if (callback) {
              if (syncErr) callback(syncErr);
              else callback(null, result);
            }
          },

          mkdir: function (path, options, callback) {
            if (typeof options === "function") {
              callback = options;
              options = {};
            }
            try {
              this.mkdirSync(path, options);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          unlink: function (path, callback) {
            try {
              this.unlinkSync(path);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          rmdir: function (path, callback) {
            try {
              this.rmdirSync(path);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          exists: function (path, callback) {
            var result = this.existsSync(path);
            if (callback) callback(result);
          },

          readdir: function (dirPath, callback) {
            try {
              var files = this.readdirSync(dirPath);
              if (callback) callback(null, files);
            } catch (err) {
              if (callback) callback(null, []);
            }
          },

          stat: function (path, callback) {
            try {
              var stats = this.statSync(path);
              if (callback) callback(null, stats);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          rename: function (oldPath, newPath, callback) {
            try {
              this.renameSync(oldPath, newPath);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          appendFileSync: function (path, data) {
            if (_isVirtualHostMode) {
              _nativeCall("fs_append_file", [path, data]);
              return;
            }
            _syncPost("/__fs_append__", { path: path, content: data });
          },

          appendFile: function (path, data, options, callback) {
            if (typeof options === "function") {
              callback = options;
            }
            try {
              this.appendFileSync(path, data);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          copyFileSync: function (src, dest) {
            if (_isVirtualHostMode) {
              _nativeCall("fs_copy_file", [src, dest]);
              return;
            }
            _syncPost("/__fs_copy__", { src: src, dest: dest });
          },

          copyFile: function (src, dest, callback) {
            try {
              this.copyFileSync(src, dest);
              if (callback) callback(null);
            } catch (err) {
              if (callback) callback(err);
            }
          },

          // fs.promises (used by PGlite for some async operations)
          promises: {
            readFile: function (path, opts) {
              // Normalise URL objects → string
              var pathStr =
                path && typeof path.href === "string"
                  ? path.href
                  : String(path);
              // HTTP/HTTPS URLs: fetch directly (e.g. pglite.data WASM asset)
              if (/^https?:\/\//i.test(pathStr)) {
                return fetch(pathStr)
                  .then(function (res) {
                    if (!res.ok) throw new Error("File not found: " + pathStr);
                    return res.arrayBuffer();
                  })
                  .then(function (buf) {
                    // Return Uint8Array so .buffer property exists (Node Buffer compat)
                    return new Uint8Array(buf);
                  });
              }
              // Local file via Nim HTTP endpoint
              return new Promise(function (resolve, reject) {
                try {
                  var xhr = new XMLHttpRequest();
                  xhr.open(
                    "GET",
                    "/__fs_read__?path=" +
                      encodeURIComponent(pathStr) +
                      "&b64=1",
                    false,
                  );
                  xhr.send(null);
                  if (xhr.status === 200 && xhr.responseText !== "__ENOENT__") {
                    var b64 = xhr.responseText.trim();
                    var binary = atob(b64);
                    var bytes = new Uint8Array(binary.length);
                    for (var i = 0; i < binary.length; i++)
                      bytes[i] = binary.charCodeAt(i);
                    resolve(bytes);
                  } else {
                    reject(new Error("File not found: " + pathStr));
                  }
                } catch (e) {
                  reject(e);
                }
              });
            },
            writeFile: function (path, data) {
              if (_isVirtualHostMode) {
                if (typeof data === "string") {
                  return _nativeCall("fs_write_file", [path, data]);
                } else {
                  var b = new Uint8Array(data.buffer || data);
                  return _nativeCall("fs_write_binary", [path, _bytesToBase64(b, 0, b.length)]);
                }
              }
              return new Promise(function (resolve, reject) {
                try {
                  _syncPost("/__fs_write__", {
                    path: path,
                    content:
                      typeof data === "string"
                        ? data
                        : _bytesToBase64(
                            new Uint8Array(data.buffer || data),
                            0,
                            data.length,
                          ),
                    binary: typeof data !== "string",
                  });
                  resolve();
                } catch (e) {
                  reject(e);
                }
              });
            },
            mkdir: function (path, opts) {
              if (_isVirtualHostMode) {
                return _nativeCall("fs_mkdir", [path]);
              }
              return new Promise(function (resolve, reject) {
                try {
                  var recursive = opts && opts.recursive ? true : false;
                  _syncPost("/__fs_mkdir__", {
                    path: path,
                    recursive: recursive,
                  });
                  resolve();
                } catch (e) {
                  reject(e);
                }
              });
            },
            readdir: function (path) {
              return new Promise(function (resolve, reject) {
                try {
                  var xhr = _syncGet(
                    "/__fs_readdir__?path=" + encodeURIComponent(path),
                  );
                  if (xhr.status === 200) {
                    var result = JSON.parse(xhr.responseText);
                    // Nim returns plain array ["file1", ...]
                    resolve(
                      Array.isArray(result) ? result : result.entries || [],
                    );
                  } else {
                    reject(new Error("Cannot read dir: " + path));
                  }
                } catch (e) {
                  reject(e);
                }
              });
            },
            stat: function (path) {
              return new Promise(function (resolve, reject) {
                try {
                  var xhr = _syncGet(
                    "/__fs_lstat__?path=" + encodeURIComponent(path),
                  );
                  if (xhr.status === 200) {
                    var s = JSON.parse(xhr.responseText);
                    resolve({
                      dev: s.dev || 0,
                      ino: s.ino || 0,
                      mode: s.mode || 0,
                      nlink: s.nlink || 1,
                      uid: s.uid || 0,
                      gid: s.gid || 0,
                      size: s.size || 0,
                      atime: new Date(s.atime || 0),
                      mtime: new Date(s.mtime || 0),
                      ctime: new Date(s.ctime || 0),
                      isDirectory: function () {
                        return s.isDirectory || false;
                      },
                      isFile: function () {
                        return s.isFile || false;
                      },
                      isSymbolicLink: function () {
                        return s.isSymbolicLink || false;
                      },
                    });
                  } else {
                    reject(
                      new Error(
                        "ENOENT: no such file or directory, stat '" +
                          path +
                          "'",
                      ),
                    );
                  }
                } catch (e) {
                  reject(e);
                }
              });
            },
            unlink: function (path) {
              if (_isVirtualHostMode) {
                return _nativeCall("fs_unlink", [path]);
              }
              return new Promise(function (resolve, reject) {
                try {
                  _syncPost("/__fs_unlink__", { path: path });
                  resolve();
                } catch (e) {
                  reject(e);
                }
              });
            },
            rmdir: function (path) {
              if (_isVirtualHostMode) {
                return _nativeCall("fs_rmdir", [path]);
              }
              return new Promise(function (resolve, reject) {
                try {
                  _syncPost("/__fs_rmdir__", { path: path });
                  resolve();
                } catch (e) {
                  reject(e);
                }
              });
            },
          },
        };
      }
      if (moduleName === "module") {
        return {
          createRequire: function (filename) {
            // Return our polyfilled require, scoped to any filename
            return window.require;
          },
        };
      }
      if (moduleName === "child_process") {
        return {
          exec: function (command, options, callback) {
            if (typeof options === "function") {
              callback = options;
              options = {};
            }
            // Execute command via native binding
            if (typeof window.exec_command === "function") {
              window
                .exec_command(command)
                .then(function (result) {
                  if (callback)
                    callback(null, result.stdout || "", result.stderr || "");
                })
                .catch(function (err) {
                  if (callback) callback(err, "", err.message || "");
                });
            } else {
              console.warn("[Rover] exec_command not available for:", command);
              if (callback)
                callback(new Error("exec_command not available"), "", "");
            }
          },
          execSync: function (command, options) {
            // Sync exec - logs warning as we can't truly do sync
            console.warn(
              "[Rover] execSync called - async alternative used:",
              command,
            );
            if (typeof window.exec_command === "function") {
              window.exec_command(command).catch(function (err) {
                console.error("[Rover] execSync failed:", err);
              });
            }
            return "";
          },
          spawn: function (command, args, options) {
            // Spawn process - simplified implementation
            console.warn("[Rover] spawn called:", command, args);
            return {
              on: function (event, cb) {
                return this;
              },
              stdout: {
                on: function (event, cb) {
                  return this;
                },
              },
              stderr: {
                on: function (event, cb) {
                  return this;
                },
              },
              kill: function () {},
            };
          },
        };
      }
      return {};
    };

    // Bridge nw.require → window.require for NW.js API compatibility.
    // This MUST be after window.require is defined, not inside the window.nw block.
    // Rover's pglite-browser.js uses IndexedDB directly; fs polyfill is only for
    if (window.nw) {
      window.nw.require = window.require;
    }
  }

  // Additional Global Polyfills
  window.global = window;

  // Node.js Buffer polyfill — required by PGlite's Emscripten runtime when
  // ENVIRONMENT_IS_NODE is true (process.versions.node is set).
  if (typeof window.Buffer === "undefined") {
    window.Buffer = {
      from: function (data, encoding) {
        if (typeof data === "string") {
          if (encoding === "base64") {
            var binary = atob(data.replace(/\s/g, ""));
            var bytes = new Uint8Array(binary.length);
            for (var i = 0; i < binary.length; i++)
              bytes[i] = binary.charCodeAt(i);
            return bytes; // Uint8Array has .buffer / .byteOffset / .length
          }
          var enc = new TextEncoder();
          return enc.encode(data);
        }
        if (data instanceof Uint8Array) return data;
        if (data instanceof ArrayBuffer) return new Uint8Array(data);
        return new Uint8Array(data);
      },
      isBuffer: function (obj) {
        return obj instanceof Uint8Array;
      },
      alloc: function (size, fill) {
        var b = new Uint8Array(size);
        if (fill !== undefined)
          b.fill(typeof fill === "string" ? fill.charCodeAt(0) : fill | 0);
        return b;
      },
      concat: function (list, totalLength) {
        if (!totalLength)
          totalLength = list.reduce(function (a, b) {
            return a + b.length;
          }, 0);
        var result = new Uint8Array(totalLength);
        var offset = 0;
        for (var i = 0; i < list.length; i++) {
          result.set(list[i], offset);
          offset += list[i].length;
        }
        return result;
      },
    };
    window.global.Buffer = window.Buffer;
  }

  // Override window.close to ensure app termination
  window.close = function () {
    callNative("exit_app");
  };

  // =========================================================================
  // AUTO-SYNC: HTML title and favicon to native window
  // Priority: JS code > package.json > HTML > executable icon
  // This syncs HTML settings AFTER page loads (overrides package.json)
  // =========================================================================
  (function initAutoSync() {
    var baseDir = window.__roverBaseDir || "";
    var lastSyncedTitle = "";
    var lastSyncedIcon = "";

    // Wait for native bindings to be ready
    function waitForBindings(callback) {
      if (typeof set_title === "function" && typeof set_icon === "function") {
        callback();
      } else {
        setTimeout(function () {
          waitForBindings(callback);
        }, 50);
      }
    }

    // Sync document.title to native window title
    function syncTitle() {
      var title = document.title;
      if (title && title !== lastSyncedTitle) {
        lastSyncedTitle = title;
        if (typeof set_title === "function") {
          set_title(title).catch(function () {});
        }
      }
    }

    // Sync favicon to native window icon (only .ico files)
    function syncFavicon() {
      var iconLink = document.querySelector(
        'link[rel="icon"], link[rel="shortcut icon"]',
      );
      if (!iconLink || !iconLink.href) return;

      var href = iconLink.href;

      // Skip if same as last synced
      if (href === lastSyncedIcon) return;

      // Handle virtual host URLs (http://rover.assets/...)
      if (href.indexOf("rover.assets") !== -1) {
        var match = href.match(/rover\.assets\/(.+)$/);
        if (match) {
          var relativePath = match[1].replace(/\//g, "\\");
          // Use baseDir if available, otherwise try relative
          var localPath = baseDir
            ? baseDir + "\\" + relativePath
            : relativePath;

          // Only set if it's an ICO file
          if (localPath.toLowerCase().endsWith(".ico")) {
            lastSyncedIcon = href;
            if (typeof set_icon === "function") {
              set_icon(localPath).catch(function () {});
            }
          }
        }
      }
      // Handle relative paths (./icon.ico or icon.ico)
      else if (
        !href.startsWith("http") &&
        !href.startsWith("data:") &&
        !href.startsWith("blob:")
      ) {
        var localPath = href;
        if (localPath.toLowerCase().endsWith(".ico")) {
          lastSyncedIcon = href;
          if (typeof set_icon === "function") {
            set_icon(localPath).catch(function () {});
          }
        }
      }
    }

    // Setup observers and initial sync
    function setupAutoSync() {
      // Initial sync after DOM is ready
      if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", function () {
          syncTitle();
          syncFavicon();
        });
      } else {
        // DOM already loaded
        syncTitle();
        syncFavicon();
      }

      // Watch for title changes using MutationObserver
      var headEl = document.head || document.querySelector("head");
      if (headEl) {
        new MutationObserver(function (mutations) {
          syncTitle();
          // Also check favicon on any head mutation
          for (var i = 0; i < mutations.length; i++) {
            var mutation = mutations[i];
            if (
              mutation.type === "childList" ||
              (mutation.type === "attributes" &&
                mutation.target.tagName === "LINK")
            ) {
              syncFavicon();
              break;
            }
          }
        }).observe(headEl, {
          childList: true,
          subtree: true,
          characterData: true,
          attributes: true,
          attributeFilter: ["href", "rel"],
        });
      }

      // MutationObserver already handles document.title changes
      // No need for polling interval as title element mutations are caught
    }

    // Start when bindings are ready and baseDir is set
    function startSync() {
      if (baseDir || window.__roverBaseDir) {
        baseDir = window.__roverBaseDir || baseDir;
        setupAutoSync();
      } else {
        // Wait for baseDir to be set
        setTimeout(startSync, 100);
      }
    }

    waitForBindings(startSync);
  })();
})();