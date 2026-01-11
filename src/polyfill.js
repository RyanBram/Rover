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

  // Determine base path from current document URL
  // This works because virtual host mapping maps rover.assets to the game directory
  var basePath = ".";
  try {
    // Extract path from URL like http://rover.assets/index.html
    var url = window.location.href;
    if (url.indexOf("rover.assets") > -1) {
      // We're using virtual host - path is relative to exe directory
      basePath = ".";
    }
  } catch (e) {}

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
        // This will be updated by native binding
        filename: basePath + "/index.html",
      },
      cwd: function () {
        return basePath;
      },
      on: function () {},
      argv: [],
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

  // Get actual exe directory from native binding and update process.mainModule.filename
  // This is critical for NW.js save path resolution
  // Run immediately (no delay) to catch it before first save attempt
  window.__roverBaseDir = ""; // Will be set by native binding
  window._roverWrittenFiles = {}; // Cache for known existing files
  window._roverCreatedDirs = {}; // Cache for created directories

  (function initMainModuleFilename() {
    if (typeof window.get_exe_directory === "function") {
      window
        .get_exe_directory()
        .then(function (dir) {
          window.__roverBaseDir = dir;
          window.process.mainModule.filename = dir + "\\index.html";

          // Pre-populate file cache by listing save directory
          // This is critical for RPG Maker save file detection
          if (typeof window.fs_list_dir === "function") {
            var saveDir = dir + "\\save";
            window
              .fs_list_dir(saveDir)
              .then(function (files) {
                // Cache all save files
                for (var i = 0; i < files.length; i++) {
                  var fullPath = saveDir + "\\" + files[i];
                  window._roverWrittenFiles[fullPath] = true;
                }
                // Mark save dir as existing if it has files
                if (files.length > 0) {
                  window._roverCreatedDirs[saveDir + "\\"] = true;
                }
              })
              .catch(function () {
                // Save directory might not exist yet - that's fine
              });
          }
        })
        .catch(function (err) {
          // Silent fail - path will use fallback
        });
    } else {
      // Retry if binding not ready yet
      setTimeout(initMainModuleFilename, 10);
    }
  })();

  // Emulate global nw object for NW.js compatibility (used by Utils.isOptionValid, etc.)
  if (typeof window.nw === "undefined") {
    // Track fullscreen state
    window._roverIsFullScreen = false;

    // Helper to check fullscreen based on window size
    function checkFullScreen() {
      return (
        window.innerWidth >= screen.width - 10 &&
        window.innerHeight >= screen.height - 10
      );
    }

    // Helper to dispatch fullscreenchange event
    function dispatchFullScreenChange() {
      setTimeout(function () {
        window._roverIsFullScreen = checkFullScreen();
        var event = new Event("fullscreenchange", { bubbles: true });
        document.dispatchEvent(event);
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
              callNative("toggle_fullscreen");
              dispatchFullScreenChange();
            },
            // NW.js fullscreen API
            enterFullscreen: function () {
              if (!window._roverIsFullScreen) {
                if (typeof window.toggle_fullscreen === "function") {
                  window.toggle_fullscreen().then(dispatchFullScreenChange);
                }
              }
            },
            leaveFullscreen: function () {
              if (window._roverIsFullScreen) {
                if (typeof window.toggle_fullscreen === "function") {
                  window.toggle_fullscreen().then(dispatchFullScreenChange);
                }
              }
            },
            isFullscreen: window._roverIsFullScreen,
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
        argv: [],
        fullArgv: [],
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
                  callNative("toggle_fullscreen");
                },
                enterFullscreen: function () {
                  if (
                    !window._roverIsFullScreen &&
                    typeof window.toggle_fullscreen === "function"
                  ) {
                    window.toggle_fullscreen();
                  }
                },
                leaveFullscreen: function () {
                  if (
                    window._roverIsFullScreen &&
                    typeof window.toggle_fullscreen === "function"
                  ) {
                    window.toggle_fullscreen();
                  }
                },
                isFullscreen: window._roverIsFullScreen,
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
            argv: [],
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
            // Normalize slashes
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
            // Windows: C:\ or \\
            return /^[a-zA-Z]:[\\/]/.test(p) || p.startsWith("\\\\");
          },
        };
      }
      if (moduleName === "fs") {
        // fs module using native bindings for actual file operations
        // Caches are initialized in the startup code above

        return {
          existsSync: function (filePath) {
            // Pure cache-based check - no XHR means no 404 errors
            if (!filePath) return false;

            // If path ends with / or \, it's a directory check
            if (filePath.endsWith("/") || filePath.endsWith("\\")) {
              return !!window._roverCreatedDirs[filePath];
            }

            // For files, check cache only
            // Cache is pre-populated on startup via fs_list_dir
            return !!window._roverWrittenFiles[filePath];
          },
          readFileSync: function (filePath, options) {
            // Silent operation
            try {
              var url = filePath;
              // Convert absolute Windows path to virtual host URL
              if (filePath.indexOf(":") > -1) {
                var baseDir = window.__roverBaseDir || "";
                if (baseDir && filePath.indexOf(baseDir) === 0) {
                  url =
                    "http://rover.assets/" +
                    filePath.substring(baseDir.length + 1).replace(/\\/g, "/");
                }
              } else {
                url = "http://rover.assets/" + filePath.replace(/\\/g, "/");
              }

              // Silent read
              var xhr = new XMLHttpRequest();
              xhr.open("GET", url, false); // Synchronous request
              xhr.send(null);

              if (xhr.status === 200) {
                // Track that this file exists
                window._roverWrittenFiles[filePath] = true;
                return xhr.responseText;
              } else {
                // File not found - normal for non-existent saves
                return null;
              }
            } catch (e) {
              console.error("[Rover] readFileSync error:", e);
              return null;
            }
          },
          writeFileSync: function (path, data) {
            // Track this file as written
            window._roverWrittenFiles[path] = true;

            // Call native async binding (fire and forget)
            if (typeof window.fs_write_file === "function") {
              window
                .fs_write_file(path, data)
                .then(function () {
                  // Success - file is now on disk
                })
                .catch(function (err) {
                  console.error("[Rover] Failed to write file: " + path, err);
                  // Remove from tracking on failure
                  delete window._roverWrittenFiles[path];
                });
            } else {
              console.error(
                "[Rover] fs_write_file native binding not available"
              );
            }
          },
          mkdirSync: function (path, options) {
            // Silent mkdir
            if (typeof window.fs_mkdir === "function") {
              window
                .fs_mkdir(path)
                .then(function () {
                  window._roverCreatedDirs[path] = true;
                  // Success - silent
                })
                .catch(function (err) {
                  // Directory might already exist, that's OK
                  window._roverCreatedDirs[path] = true;
                });
            }
            // Mark as created immediately to avoid duplicate calls
            window._roverCreatedDirs[path] = true;
          },
          unlinkSync: function (path) {
            if (typeof window.fs_unlink === "function") {
              window.fs_unlink(path);
            }
          },
          // Async versions (preferred by RPG Maker)
          writeFile: function (path, data, callback) {
            if (typeof window.fs_write_file === "function") {
              window
                .fs_write_file(path, data)
                .then(function () {
                  if (callback) callback(null);
                })
                .catch(function (err) {
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_write_file not available"));
            }
          },
          readFile: function (path, encoding, callback) {
            if (
              typeof callback === "undefined" &&
              typeof encoding === "function"
            ) {
              callback = encoding;
              encoding = "utf8";
            }
            if (typeof window.fs_read_file === "function") {
              window
                .fs_read_file(path)
                .then(function (data) {
                  if (callback) callback(null, data);
                })
                .catch(function (err) {
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_read_file not available"));
            }
          },
          mkdir: function (path, options, callback) {
            if (
              typeof callback === "undefined" &&
              typeof options === "function"
            ) {
              callback = options;
            }
            if (typeof window.fs_mkdir === "function") {
              window
                .fs_mkdir(path)
                .then(function () {
                  if (callback) callback(null);
                })
                .catch(function (err) {
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_mkdir not available"));
            }
          },
          unlink: function (path, callback) {
            if (typeof window.fs_unlink === "function") {
              window
                .fs_unlink(path)
                .then(function () {
                  if (callback) callback(null);
                })
                .catch(function (err) {
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_unlink not available"));
            }
          },
          exists: function (path, callback) {
            if (typeof window.fs_exists === "function") {
              window
                .fs_exists(path)
                .then(function (exists) {
                  if (callback) callback(exists);
                })
                .catch(function () {
                  if (callback) callback(false);
                });
            } else {
              if (callback) callback(false);
            }
          },
          readdirSync: function (dirPath) {
            // Synchronous directory listing - returns cached or empty array
            // For true sync behavior, we'd need native sync call
            // For now, return files from cache that match this directory
            var files = [];
            var normalizedDir = dirPath.replace(/\//g, "\\");
            if (!normalizedDir.endsWith("\\")) {
              normalizedDir += "\\";
            }

            // Search cache for files in this directory
            for (var filePath in window._roverWrittenFiles) {
              if (filePath.indexOf(normalizedDir) === 0) {
                // Extract just the filename (not subdirectories)
                var relativePath = filePath.substring(normalizedDir.length);
                if (relativePath.indexOf("\\") === -1) {
                  files.push(relativePath);
                }
              }
            }
            return files;
          },
          readdir: function (dirPath, callback) {
            // Async directory listing using native binding
            if (typeof window.fs_list_dir === "function") {
              window
                .fs_list_dir(dirPath)
                .then(function (files) {
                  // Update cache with results
                  var normalizedDir = dirPath.replace(/\//g, "\\");
                  if (!normalizedDir.endsWith("\\")) {
                    normalizedDir += "\\";
                  }
                  for (var i = 0; i < files.length; i++) {
                    window._roverWrittenFiles[normalizedDir + files[i]] = true;
                  }
                  if (callback) callback(null, files);
                })
                .catch(function (err) {
                  if (callback) callback(err, []);
                });
            } else {
              // Fallback to cache-based
              var files = this.readdirSync(dirPath);
              if (callback) callback(null, files);
            }
          },
          // statSync - returns file stats including size
          statSync: function (path) {
            // For sync stats, we return cached info or placeholder
            // Real stats would need native sync binding
            var stats = {
              size: 0,
              isFile: function () {
                return true;
              },
              isDirectory: function () {
                return false;
              },
              mtime: new Date(),
              ctime: new Date(),
              atime: new Date(),
            };
            // Check if it's a known directory
            if (window._roverCreatedDirs && window._roverCreatedDirs[path]) {
              stats.isFile = function () {
                return false;
              };
              stats.isDirectory = function () {
                return true;
              };
            }
            return stats;
          },
          // stat - async version
          stat: function (path, callback) {
            if (typeof window.fs_stat === "function") {
              window
                .fs_stat(path)
                .then(function (stats) {
                  if (callback) callback(null, stats);
                })
                .catch(function (err) {
                  if (callback) callback(err);
                });
            } else {
              // Fallback to sync version
              try {
                var stats = this.statSync(path);
                if (callback) callback(null, stats);
              } catch (e) {
                if (callback) callback(e);
              }
            }
          },
          // renameSync - rename/move file
          renameSync: function (oldPath, newPath) {
            // Track new path and untrack old
            if (window._roverWrittenFiles[oldPath]) {
              window._roverWrittenFiles[newPath] = true;
              delete window._roverWrittenFiles[oldPath];
            }
            if (typeof window.fs_rename === "function") {
              window.fs_rename(oldPath, newPath).catch(function (err) {
                console.error("[Rover] renameSync failed:", err);
                // Revert cache on failure
                delete window._roverWrittenFiles[newPath];
                window._roverWrittenFiles[oldPath] = true;
              });
            } else {
              console.warn("[Rover] fs_rename not available");
            }
          },
          // rename - async version
          rename: function (oldPath, newPath, callback) {
            if (typeof window.fs_rename === "function") {
              window._roverWrittenFiles[newPath] = true;
              delete window._roverWrittenFiles[oldPath];
              window
                .fs_rename(oldPath, newPath)
                .then(function () {
                  if (callback) callback(null);
                })
                .catch(function (err) {
                  // Revert cache on failure
                  delete window._roverWrittenFiles[newPath];
                  window._roverWrittenFiles[oldPath] = true;
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_rename not available"));
            }
          },
          // appendFileSync - append content to file
          appendFileSync: function (path, data, options) {
            window._roverWrittenFiles[path] = true;
            if (typeof window.fs_append_file === "function") {
              window.fs_append_file(path, data).catch(function (err) {
                console.error("[Rover] appendFileSync failed:", err);
              });
            } else {
              console.warn("[Rover] fs_append_file not available");
            }
          },
          // appendFile - async version
          appendFile: function (path, data, options, callback) {
            if (
              typeof callback === "undefined" &&
              typeof options === "function"
            ) {
              callback = options;
              options = {};
            }
            window._roverWrittenFiles[path] = true;
            if (typeof window.fs_append_file === "function") {
              window
                .fs_append_file(path, data)
                .then(function () {
                  if (callback) callback(null);
                })
                .catch(function (err) {
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_append_file not available"));
            }
          },
          // copyFileSync - copy file (used by NodeWebkit CopyFile action)
          copyFileSync: function (src, dest) {
            window._roverWrittenFiles[dest] = true;
            if (typeof window.fs_copy_file === "function") {
              window.fs_copy_file(src, dest).catch(function (err) {
                console.error("[Rover] copyFileSync failed:", err);
                delete window._roverWrittenFiles[dest];
              });
            } else {
              console.warn("[Rover] fs_copy_file not available");
            }
          },
          // copyFile - async version
          copyFile: function (src, dest, callback) {
            window._roverWrittenFiles[dest] = true;
            if (typeof window.fs_copy_file === "function") {
              window
                .fs_copy_file(src, dest)
                .then(function () {
                  if (callback) callback(null);
                })
                .catch(function (err) {
                  delete window._roverWrittenFiles[dest];
                  if (callback) callback(err);
                });
            } else {
              if (callback) callback(new Error("fs_copy_file not available"));
            }
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
              command
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
  }

  // Additional Global Polyfills
  window.global = window;

  // Override window.close to ensure app termination
  const _originalClose = window.close;
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
        'link[rel="icon"], link[rel="shortcut icon"]'
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
