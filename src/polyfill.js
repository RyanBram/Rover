(function() {
    // Helper to safety call native bindings
    function callNative(name, args) {
        if (typeof window[name] === 'function') {
            window[name](args);
        } else {
            console.log("Native binding not found: " + name);
        }
    }

    // Determine base path from current document URL
    // This works because virtual host mapping maps rover.assets to the game directory
    var basePath = '.';
    try {
        // Extract path from URL like http://rover.assets/index.html
        var url = window.location.href;
        if (url.indexOf('rover.assets') > -1) {
            // We're using virtual host - path is relative to exe directory
            basePath = '.';
        }
    } catch(e) {}

    // Emulate process object for NW.js compatibility
    if (typeof window.process === 'undefined') {
        window.process = {
            platform: 'win32',
            versions: {
                node: '12.0.0',
                nw: '0.45.0'
            },
            mainModule: {
                // This will be updated by native binding
                filename: basePath + '/index.html'
            },
            cwd: function() { return basePath; },
            on: function() {},
            argv: []
        };
    }
    
    // Get actual exe directory from native binding and update process.mainModule.filename
    // This is critical for NW.js save path resolution
    // Run immediately (no delay) to catch it before first save attempt
    window.__roverBaseDir = ''; // Will be set by native binding
    window._roverWrittenFiles = {}; // Cache for known existing files
    window._roverCreatedDirs = {}; // Cache for created directories
    
    (function initMainModuleFilename() {
        if (typeof window.get_exe_directory === 'function') {
            window.get_exe_directory().then(function(dir) {
                window.__roverBaseDir = dir;
                window.process.mainModule.filename = dir + '\\index.html';
                
                // Pre-populate file cache by listing save directory
                if (typeof window.fs_list_dir === 'function') {
                    var saveDir = dir + '\\save';
                    window.fs_list_dir(saveDir).then(function(files) {
                        // Cache all save files
                        for (var i = 0; i < files.length; i++) {
                            var fullPath = saveDir + '\\' + files[i];
                            window._roverWrittenFiles[fullPath] = true;
                        }
                        // Mark save dir as existing if it has files
                        if (files.length > 0) {
                            window._roverCreatedDirs[saveDir + '\\'] = true;
                        }
                    }).catch(function() {
                        // Save directory might not exist yet - that's fine
                    });
                }
            }).catch(function(err) {
                // Silent fail - path will use fallback
            });
        } else {
            // Retry if binding not ready yet
            setTimeout(initMainModuleFilename, 10);
        }
    })();

    // Emulate require function
    if (typeof window.require === 'undefined') {
        window.require = function(moduleName) {
            // console.log("Polyfill require: " + moduleName);
            if (moduleName === 'nw.gui') {
                return {
                    Window: {
                        get: function() {
                            return {
                                focus: function() {},
                                showDevTools: function() { callNative('toggle_devtools'); },
                                toggleFullscreen: function() { callNative('toggle_fullscreen'); },
                                on: function() {},
                                x: 0, y: 0, width: 800, height: 600,
                                // Native extension
                                center: function() { callNative('center_window'); }
                            };
                        }
                    },
                    App: {
                        quit: function() { callNative('exit_app'); },
                        argv: []
                    },
                    Shell: {
                        openExternal: function(url) { window.open(url); }
                    }
                };
            }
            if (moduleName === 'os') {
                return {
                    platform: function() { return 'win32'; },
                    arch: function() { return 'x64'; }
                }
            }
            if (moduleName === 'path') {
                return {
                    sep: '\\',
                    dirname: function(p) {
                        if (!p || typeof p !== 'string') return '.';
                        // Normalize slashes
                        p = p.replace(/\//g, '\\');
                        var lastSlash = p.lastIndexOf('\\');
                        if (lastSlash === -1) return '.';
                        if (lastSlash === 0) return '\\';
                        return p.substring(0, lastSlash);
                    },
                    basename: function(p, ext) {
                        if (!p || typeof p !== 'string') return '';
                        p = p.replace(/\//g, '\\');
                        var lastSlash = p.lastIndexOf('\\');
                        var base = lastSlash === -1 ? p : p.substring(lastSlash + 1);
                        if (ext && base.endsWith(ext)) {
                            base = base.substring(0, base.length - ext.length);
                        }
                        return base;
                    },
                    extname: function(p) {
                        if (!p || typeof p !== 'string') return '';
                        var base = this.basename(p);
                        var dotIndex = base.lastIndexOf('.');
                        if (dotIndex <= 0) return '';
                        return base.substring(dotIndex);
                    },
                    join: function() {
                        var parts = [];
                        for (var i = 0; i < arguments.length; i++) {
                            if (arguments[i]) parts.push(arguments[i]);
                        }
                        return this.normalize(parts.join('\\'));
                    },
                    normalize: function(p) {
                        if (!p || typeof p !== 'string') return '.';
                        // Remember if path had a trailing slash
                        var hadTrailingSlash = p.endsWith('/') || p.endsWith('\\');
                        p = p.replace(/\//g, '\\');
                        // Remove duplicate slashes
                        p = p.replace(/\\+/g, '\\');
                        // Preserve trailing slash if original had one (important for directory paths)
                        if (hadTrailingSlash && !p.endsWith('\\')) {
                            p = p + '\\';
                        }
                        return p;
                    },
                    isAbsolute: function(p) {
                        if (!p || typeof p !== 'string') return false;
                        // Windows: C:\ or \\
                        return /^[a-zA-Z]:[\\/]/.test(p) || p.startsWith('\\\\');
                    }
                };
            }
            if (moduleName === 'fs') {
                // fs module using native bindings for actual file operations
                // Caches are initialized in the startup code above
                
                return {
                    existsSync: function(filePath) {
                        // Pure cache-based check - no XHR means no 404 errors
                        if (!filePath) return false;
                        
                        // If path ends with / or \, it's a directory check
                        if (filePath.endsWith('/') || filePath.endsWith('\\')) {
                            return !!window._roverCreatedDirs[filePath];
                        }
                        
                        // For files, check cache only
                        // Cache is pre-populated on startup via fs_list_dir
                        return !!window._roverWrittenFiles[filePath];
                    },
                    readFileSync: function(filePath, options) {
                        // Silent operation
                        try {
                            var url = filePath;
                            // Convert absolute Windows path to virtual host URL
                            if (filePath.indexOf(':') > -1) {
                                var baseDir = window.__roverBaseDir || '';
                                if (baseDir && filePath.indexOf(baseDir) === 0) {
                                    url = 'http://rover.assets/' + filePath.substring(baseDir.length + 1).replace(/\\/g, '/');
                                }
                            } else {
                                url = 'http://rover.assets/' + filePath.replace(/\\/g, '/');
                            }
                            
                            // Silent read
                            var xhr = new XMLHttpRequest();
                            xhr.open('GET', url, false); // Synchronous request
                            xhr.send(null);
                            
                            if (xhr.status === 200) {
                                // Track that this file exists
                                window._roverWrittenFiles[filePath] = true;
                                return xhr.responseText;
                            } else {
                                // File not found - normal for non-existent saves
                                return null;
                            }
                        } catch(e) {
                            console.error('[Rover] readFileSync error:', e);
                            return null;
                        }
                    },
                    writeFileSync: function(path, data) {
                        // Track this file as written
                        window._roverWrittenFiles[path] = true;
                        
                        // Call native async binding (fire and forget)
                        if (typeof window.fs_write_file === 'function') {
                            window.fs_write_file(path, data).then(function() {
                                // Success - file is now on disk
                            }).catch(function(err) {
                                console.error('[Rover] Failed to write file: ' + path, err);
                                // Remove from tracking on failure
                                delete window._roverWrittenFiles[path];
                            });
                        } else {
                            console.error('[Rover] fs_write_file native binding not available');
                        }
                    },
                    mkdirSync: function(path, options) {
                        // Silent mkdir
                        if (typeof window.fs_mkdir === 'function') {
                            window.fs_mkdir(path).then(function() {
                                window._roverCreatedDirs[path] = true;
                                // Success - silent
                            }).catch(function(err) {
                                // Directory might already exist, that's OK
                                window._roverCreatedDirs[path] = true;
                            });
                        }
                        // Mark as created immediately to avoid duplicate calls
                        window._roverCreatedDirs[path] = true;
                    },
                    unlinkSync: function(path) {
                        if (typeof window.fs_unlink === 'function') {
                            window.fs_unlink(path);
                        }
                    },
                    // Async versions (preferred by RPG Maker)
                    writeFile: function(path, data, callback) {
                        if (typeof window.fs_write_file === 'function') {
                            window.fs_write_file(path, data).then(function() {
                                if (callback) callback(null);
                            }).catch(function(err) {
                                if (callback) callback(err);
                            });
                        } else {
                            if (callback) callback(new Error('fs_write_file not available'));
                        }
                    },
                    readFile: function(path, encoding, callback) {
                        if (typeof callback === 'undefined' && typeof encoding === 'function') {
                            callback = encoding;
                            encoding = 'utf8';
                        }
                        if (typeof window.fs_read_file === 'function') {
                            window.fs_read_file(path).then(function(data) {
                                if (callback) callback(null, data);
                            }).catch(function(err) {
                                if (callback) callback(err);
                            });
                        } else {
                            if (callback) callback(new Error('fs_read_file not available'));
                        }
                    },
                    mkdir: function(path, options, callback) {
                        if (typeof callback === 'undefined' && typeof options === 'function') {
                            callback = options;
                        }
                        if (typeof window.fs_mkdir === 'function') {
                            window.fs_mkdir(path).then(function() {
                                if (callback) callback(null);
                            }).catch(function(err) {
                                if (callback) callback(err);
                            });
                        } else {
                            if (callback) callback(new Error('fs_mkdir not available'));
                        }
                    },
                    unlink: function(path, callback) {
                        if (typeof window.fs_unlink === 'function') {
                            window.fs_unlink(path).then(function() {
                                if (callback) callback(null);
                            }).catch(function(err) {
                                if (callback) callback(err);
                            });
                        } else {
                            if (callback) callback(new Error('fs_unlink not available'));
                        }
                    },
                    exists: function(path, callback) {
                        if (typeof window.fs_exists === 'function') {
                            window.fs_exists(path).then(function(exists) {
                                if (callback) callback(exists);
                            }).catch(function() {
                                if (callback) callback(false);
                            });
                        } else {
                            if (callback) callback(false);
                        }
                    }
                };
            }
            return {};
        };
    }
    
    // Additional Global Polyfills
    window.global = window;

    // Override window.close to ensure app termination (Used by SceneManager.terminate)
    const _originalClose = window.close;
    window.close = function() {
        // console.log("window.close called, redirecting to exit_app");
        callNative('exit_app');
        // Fallback to original if needed? Usually native app handles it.
    };

    // Override Graphics fullscreen methods to use native bindings
    // We wait for load event to ensure Graphics object is defined (from rpg_core.js)
    window.addEventListener('load', function() {
        if (typeof Graphics !== 'undefined') {
            // Override Graphics fullscreen methods silently
            
            // Track fullscreen state internally since we can't query native window state
            window._roverIsFullScreen = false;
            
            // Helper to dispatch fullscreenchange event for rpg_basic.js sync
            function dispatchFullScreenChange() {
                // Small delay to allow window resize to complete
                setTimeout(function() {
                    // Update internal state based on window size
                    window._roverIsFullScreen = (window.innerWidth >= screen.width - 10 && 
                                                   window.innerHeight >= screen.height - 10);
                    // State updated silently
                    
                    // Dispatch the event that rpg_basic.js listens for
                    var event = new Event('fullscreenchange', { bubbles: true });
                    document.dispatchEvent(event);
                }, 100);
            }
            
            Graphics._requestFullScreen = function() {
                // Request fullscreen via native binding
                if (typeof window.toggle_fullscreen === 'function') {
                    window.toggle_fullscreen().then(function() {
                        dispatchFullScreenChange();
                    });
                } else {
                    console.error('[Rover] toggle_fullscreen native binding not found');
                }
            };
            
            Graphics._cancelFullScreen = function() {
                // Cancel fullscreen via native binding
                if (typeof window.toggle_fullscreen === 'function') {
                    window.toggle_fullscreen().then(function() {
                        dispatchFullScreenChange();
                    });
                }
            };
            
            // Override _isFullScreen to use internal tracking
            Graphics._isFullScreen = function() {
                // Check actual window size vs screen size (with tolerance for taskbar, etc)
                return window.innerWidth >= screen.width - 10 && 
                       window.innerHeight >= screen.height - 10;
            };
            
            // Also listen for resize events to update internal state
            window.addEventListener('resize', function() {
                var wasFullScreen = window._roverIsFullScreen;
                window._roverIsFullScreen = Graphics._isFullScreen();
                
                // If state changed, dispatch event
                if (wasFullScreen !== window._roverIsFullScreen) {
                    // State changed - dispatch event silently
                    var event = new Event('fullscreenchange', { bubbles: true });
                    document.dispatchEvent(event);
                }
            });
        }
    });

})();
