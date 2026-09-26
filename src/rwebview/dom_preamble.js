/* dom_preamble.js — minimal browser API stubs for rwebview / QuickJS
 *
 * Loaded at runtime via staticRead in rwebview_dom.nim.
 * Placeholder tokens injected by domPreamble(w,h):
 *   __CANVAS_W__  →  window/canvas pixel width
 *   __CANVAS_H__  →  window/canvas pixel height
 */

/* ── helpers ────────────────────────────────────────────────────────────── */

function _makeElement(tag) {
  var el = {
    tagName: tag.toUpperCase(),
    nodeName: tag.toUpperCase(),
    _id: '',
    get id() { return this._id; },
    set id(v) {
      if (this._id && _elemById[this._id] === this) delete _elemById[this._id];
      this._id = String(v);
      if (v) _elemById[this._id] = this;
    },
    // jQuery resolves the document via element.ownerDocument for buildFragment,
    // event dispatch, and other DOM operations. Must be a getter (not a value)
    // because _makeElement is called before `document` is initialized.
    get ownerDocument() { return document; },
    className: '',
    style: {},
    offsetLeft: 0,
    offsetTop:  0,
    offsetWidth: 0,
    offsetHeight: 0,
    children: [],
    _listeners: {},
    innerHTML: '',
    textContent: '',
    nodeType: 1,
    parentNode: null,
    appendChild: function(child) {
      this.children.push(child);
      child.parentNode = this;
      // Register by id into the global id map
      if (child._id) _elemById[child._id] = child;
      return child;
    },
    append: function() {
      for (var i = 0; i < arguments.length; i++) {
        var arg = arguments[i];
        if (typeof arg === 'string') arg = document.createTextNode(arg);
        this.appendChild(arg);
      }
    },
    insertBefore: function(newChild, refChild) {
      if (!refChild) { this.appendChild(newChild); return newChild; }
      var idx = this.children.indexOf(refChild);
      if (idx >= 0) { this.children.splice(idx, 0, newChild); newChild.parentNode = this; }
      else this.appendChild(newChild);
      return newChild;
    },
    removeChild: function(child) {
      var i = this.children.indexOf(child);
      if (i >= 0) this.children.splice(i, 1);
      return child;
    },
    setAttribute: function(k,v) {
      if (k === 'id') { this.id = v; } else { this[k] = v; }
    },
    getAttribute: function(k) { return this[k] !== undefined ? String(this[k]) : null; },
    addEventListener: function(type, fn, opts) {
      if (!this._listeners[type]) this._listeners[type] = [];
      this._listeners[type].push(fn);
    },
    removeEventListener: function(type, fn) {
      if (!this._listeners[type]) return;
      var a = this._listeners[type];
      var i = a.indexOf(fn);
      if (i >= 0) a.splice(i, 1);
    },
    dispatchEvent: function(evt) {
      var fns = this._listeners[evt.type] || [];
      for (var i = 0; i < fns.length; i++) {
        try { fns[i](evt); }
        catch(e) { console.error('[event error] ' + evt.type + ': ' + ((e && e.stack) || e)); }
      }
    },
    getBoundingClientRect: function() {
      return { left:0, top:0, right:this.width||0, bottom:this.height||0,
               width:this.width||0, height:this.height||0 };
    },
    // getElementsByTagName: walk children recursively, collect matching tags
    getElementsByTagName: function(tag) {
      var upper = tag === '*' ? null : tag.toUpperCase();
      var result = [];
      function walk(node) {
        for (var i = 0; i < node.children.length; i++) {
          var c = node.children[i];
          if (!upper || c.tagName === upper) result.push(c);
          walk(c);
        }
      }
      walk(this);
      result.item = function(i) { return result[i] || null; };
      return result;
    },
    getContext: function(type) { return null; },
    focus: function() {},
    blur: function() {},
    // stub sheet for <style> elements
    sheet: { insertRule: function(){}, cssRules: [] },
    classList: (function() {
      var _cl = [];
      return {
        add:      function(c) { if (_cl.indexOf(c) < 0) _cl.push(c); },
        remove:   function(c) { var i = _cl.indexOf(c); if (i >= 0) _cl.splice(i,1); },
        contains: function(c) { return _cl.indexOf(c) >= 0; },
        toggle:   function(c) { if (_cl.indexOf(c) >= 0) _cl.splice(_cl.indexOf(c),1); else _cl.push(c); },
        toString: function()  { return _cl.join(' '); }
      };
    })(),
    cloneNode: function(deep) {
      var cl = _makeElement(this.tagName.toLowerCase());
      cl.className = this.className;
      cl.innerHTML = this.innerHTML;
      // Copy non-function, non-special properties (setAttribute-stored attrs, checked, type, etc.)
      var _skip = {children:1, _listeners:1, parentNode:1, tagName:1, _id:1, id:1, style:1, classList:1,
                   offsetLeft:1, offsetTop:1, offsetWidth:1, offsetHeight:1, sheet:1, cloneNode:1,
                   appendChild:1, removeChild:1, setAttribute:1, getAttribute:1,
                   addEventListener:1, removeEventListener:1, dispatchEvent:1,
                   getBoundingClientRect:1, getElementsByTagName:1, getContext:1,
                   focus:1, blur:1};
      for (var _k in this) {
        if (Object.prototype.hasOwnProperty.call(this, _k) && !_skip[_k]) {
          var _v = this[_k];
          if (typeof _v !== 'function' && typeof _v !== 'object') {
            try { cl[_k] = _v; } catch(e) {}
          }
        }
      }
      if (deep) {
        for (var _i = 0; _i < this.children.length; _i++) {
          var _ch = this.children[_i];
          if (typeof _ch.cloneNode === 'function') cl.appendChild(_ch.cloneNode(true));
        }
      }
      return cl;
    }
  };
  // Tree-navigation getters (needed by jQuery, cannot be in object literal above)
  Object.defineProperty(el, 'firstChild', {
    get: function() { return this.children[0] || null; }, configurable: true });
  Object.defineProperty(el, 'lastChild', {
    get: function() { return this.children[this.children.length - 1] || null; }, configurable: true });
  Object.defineProperty(el, 'nextSibling', {
    get: function() {
      var p = this.parentNode;
      if (!p || !p.children) return null;
      var idx = p.children.indexOf(this);
      return (idx >= 0) ? (p.children[idx + 1] || null) : null;
    }, configurable: true });
  Object.defineProperty(el, 'previousSibling', {
    get: function() {
      var p = this.parentNode;
      if (!p || !p.children) return null;
      var idx = p.children.indexOf(this);
      return (idx > 0) ? (p.children[idx - 1] || null) : null;
    }, configurable: true });
  Object.defineProperty(el, 'childNodes', {
    get: function() {
      var a = this.children.slice();
      a.item = function(i) { return a[i] || null; };
      a.length = this.children.length;
      return a;
    }, configurable: true });
  return el;
}

/* ── document ───────────────────────────────────────────────────────────── */

var _body = _makeElement('body');
_body.style = { background: '#000', margin: '0', padding: '0', overflow: 'hidden' };
_body.offsetWidth = __CANVAS_W__;
_body.offsetHeight = __CANVAS_H__;
// Override appendChild on body: mark canvas elements appended to the document
// as "display canvases" so the native renderer knows to present them on screen.
// (getContext('2d') may not have been called yet at this point, so we use a flag.)
(function() {
  var _origAppend = _body.appendChild.bind(_body);
  _body.appendChild = function(child) {
    _origAppend(child);
    if (child && typeof child.getContext === 'function') {
      child._isDisplayCanvas = true;
      // If a Canvas2D context was already created, notify native immediately
      if (child.__ctxId !== undefined && typeof __rw_setCanvasVisible === 'function') {
        __rw_setCanvasVisible(child.__ctxId, true);
      }
      // If a WebGL context was already claimed, activate WebGL compositing mode.
      // This must be deferred to here (not in getContext) so that throwaway
      // detection canvases (e.g. GPU vendor query) don't flip the flag early.
      if (child.__hasWebGL && typeof __rw_setWebGLActive === 'function') {
        __rw_setWebGLActive();
      }
    }
    // Runtime <script> loading: when a script element with src is appended,
    // fetch and execute it synchronously (like a real browser with async=false).
    if (child && child.tagName && child.tagName.toLowerCase() === 'script' && child.src) {
      try {
        if (typeof __rw_loadScript === 'function') {
          __rw_loadScript(child.src);
        }
      } catch(e) {
        if (child.onerror) child.onerror({ target: child });
      }
    }
    return child;
  };
})();

var _docEl = _makeElement('html');
var _head  = _makeElement('head');
_docEl.appendChild(_head);
_docEl.appendChild(_body);

var _elemById = {};
var _docListeners = {};

var document = {
  body: _body,
  documentElement: _docEl,
  head: _head,
  nodeType: 9,
  nodeName: '#document',
  ownerDocument: null,   // document itself has no ownerDocument (is the root)
  currentScript: null,
  readyState: 'complete',
  visibilityState: 'visible',
  hidden: false,
  fullscreenElement: null,
  fullScreenElement: null,      // RPG Maker uses capital-S variant
  mozFullScreen: false,
  webkitFullscreenElement: null,
  msFullscreenElement: null,
  cancelFullScreen: function() {},
  mozCancelFullScreen: function() {},
  webkitCancelFullScreen: function() {},
  msExitFullscreen: function() {},
  _title: '',
  get title() { return this._title; },
  set title(v) { this._title = String(v); },
  createElement: function(tag) {
    var el = _makeElement(tag);
    if (tag.toLowerCase() === 'canvas') {
      var _cw = __CANVAS_W__;
      var _ch = __CANVAS_H__;
      // Override style so that marginLeft/marginTop assignments (from
      // RPG Maker's _centerElement) automatically update offsetLeft/offsetTop.
      // Also handles margin:'auto' with explicit width/height (CSS auto-centering),
      // which is what _centerElement actually uses.
      (function() {
        var _s = {};
        var _ml = '0px', _mt = '0px';
        var _margin = '';
        var _width = '', _height = '';
        function _recalcOffset() {
          if (_margin === 'auto' && _width) {
            var w = parseFloat(_width) || 0;
            var h = parseFloat(_height) || 0;
            el.offsetLeft = Math.max(0, Math.round((window.innerWidth - w) / 2));
            el.offsetTop  = Math.max(0, Math.round((window.innerHeight - h) / 2));
          }
        }
        Object.defineProperty(_s, 'marginLeft', {
          get: function() { return _ml; },
          set: function(v) { _ml = String(v); el.offsetLeft = parseFloat(v) || 0; },
          configurable: true, enumerable: true
        });
        Object.defineProperty(_s, 'marginTop', {
          get: function() { return _mt; },
          set: function(v) { _mt = String(v); el.offsetTop = parseFloat(v) || 0; },
          configurable: true, enumerable: true
        });
        Object.defineProperty(_s, 'margin', {
          get: function() { return _margin; },
          set: function(v) { _margin = String(v); _recalcOffset(); },
          configurable: true, enumerable: true
        });
        Object.defineProperty(_s, 'width', {
          get: function() { return _width; },
          set: function(v) { _width = String(v); _recalcOffset(); },
          configurable: true, enumerable: true
        });
        Object.defineProperty(_s, 'height', {
          get: function() { return _height; },
          set: function(v) { _height = String(v); _recalcOffset(); },
          configurable: true, enumerable: true
        });
        el.style = _s;
      })();
      Object.defineProperty(el, 'width', {
        get: function() { return _cw; },
        set: function(v) {
          var nw = Math.max(v | 0, 1);
          _cw = nw;
          if (el.__ctxId !== undefined && typeof __rw_resizeCanvas2D === 'function') {
            __rw_resizeCanvas2D(el.__ctxId, _cw, _ch);
          }
          if (el.__hasWebGL && typeof __rw_resizeDrawingBuffer === 'function') {
            __rw_resizeDrawingBuffer(_cw, _ch);
            if (typeof __rw_glContext !== 'undefined') {
              __rw_glContext.drawingBufferWidth = _cw;
              __rw_glContext.drawingBufferHeight = _ch;
            }
          }
        },
        configurable: true, enumerable: true
      });
      Object.defineProperty(el, 'height', {
        get: function() { return _ch; },
        set: function(v) {
          var nh = Math.max(v | 0, 1);
          _ch = nh;
          if (el.__ctxId !== undefined && typeof __rw_resizeCanvas2D === 'function') {
            __rw_resizeCanvas2D(el.__ctxId, _cw, _ch);
          }
          if (el.__hasWebGL && typeof __rw_resizeDrawingBuffer === 'function') {
            __rw_resizeDrawingBuffer(_cw, _ch);
            if (typeof __rw_glContext !== 'undefined') {
              __rw_glContext.drawingBufferWidth = _cw;
              __rw_glContext.drawingBufferHeight = _ch;
            }
          }
        },
        configurable: true, enumerable: true
      });
      el.getContext = function(type) {
        // Intentionally do NOT accept 'webgl2': rwebview implements OpenGL 3.3
        // core mapped to the WebGL 1.0 API surface only.  Returning our context
        // for 'webgl2' makes PIXI (and similar engines) believe the context is a
        // real WebGL2 context and then call WebGL2-only methods (e.g.
        // getInternalformatParameter) that we don't implement, causing crashes.
        // Returning null here forces PIXI to fall back to getContext('webgl') and
        // use the WebGL1 code path which we support correctly.
        if (type === 'webgl' || type === 'experimental-webgl') {
          // When renderer=canvas is set, block WebGL at the canvas level too
          // so game engines that probe the instance method (not the prototype)
          // still see no WebGL and fall back to their Canvas2D renderer.
          if (window.__roverForceCanvas) return null;
          if (typeof __rw_glContext !== 'undefined') {
            __rw_glContext.canvas = el;
            el.__hasWebGL = true;
            // If the canvas was already appended to body (e.g. PIXI/RPG Maker appends
            // before calling getContext), activate WebGL compositing mode right here.
            if (el._isDisplayCanvas && typeof __rw_setWebGLActive === 'function') {
              __rw_setWebGLActive();
            }
            // Resize FBO to match canvas dimensions (may differ from window size)
            if (typeof __rw_resizeDrawingBuffer === 'function') {
              __rw_resizeDrawingBuffer(_cw, _ch);
              __rw_glContext.drawingBufferWidth = _cw;
              __rw_glContext.drawingBufferHeight = _ch;
            }
            return __rw_glContext;
          }
        }
        if (type === '2d') {
          if (el.__ctx2d) return el.__ctx2d;
          var ctx2d = __rw_createCanvas2D(el);
          ctx2d.canvas = el;
          // Wrap properties with setters that call native
          var _font = '10px sans-serif';
          var _fillStyle = '#000000';
          var _globalAlpha = 1.0;
          var _globalCompositeOp = 'source-over';
          var _textBaseline = 'alphabetic';
          var _textAlign = 'start';
          var _strokeStyle = '#000000';
          var _lineWidth = 1;
          var _lineCap = 'butt';
          var _lineJoin = 'miter';
          var _shadowColor = 'rgba(0,0,0,0)';
          var _shadowBlur = 0;
          var _shadowOffsetX = 0;
          var _shadowOffsetY = 0;
          var _imageSmoothingEnabled = true;
          Object.defineProperty(ctx2d, 'font', {
            get: function() { return _font; },
            set: function(v) { _font = v; ctx2d.__rw_setFont(v); }
          });
          Object.defineProperty(ctx2d, 'fillStyle', {
            get: function() { return _fillStyle; },
            set: function(v) {
              _fillStyle = v;
              if (typeof v === 'string') {
                ctx2d.__rw_setFillStyle(v);
              } else if (v && v.__isGradient) {
                ctx2d.__rw_setFillStyleGradient(v);
              } else if (v && v.__isPattern) {
                ctx2d.__rw_setFillStylePattern(v);
              }
            }
          });
          Object.defineProperty(ctx2d, 'globalAlpha', {
            get: function() { return _globalAlpha; },
            set: function(v) { _globalAlpha = v; ctx2d.__rw_setGlobalAlpha(v); }
          });
          Object.defineProperty(ctx2d, 'globalCompositeOperation', {
            get: function() { return _globalCompositeOp; },
            set: function(v) { _globalCompositeOp = v; ctx2d.__rw_setCompositeOp(v); }
          });
          Object.defineProperty(ctx2d, 'textBaseline', {
            get: function() { return _textBaseline; },
            set: function(v) { _textBaseline = v; ctx2d.__rw_setTextBaseline(v); }
          });
          Object.defineProperty(ctx2d, 'textAlign', {
            get: function() { return _textAlign; },
            set: function(v) { _textAlign = v; ctx2d.__rw_setTextAlign(v); }
          });
          Object.defineProperty(ctx2d, 'strokeStyle', {
            get: function() { return _strokeStyle; },
            set: function(v) { _strokeStyle = v; if (typeof v === 'string') ctx2d.__rw_setStrokeStyle(v); }
          });
          Object.defineProperty(ctx2d, 'lineWidth', {
            get: function() { return _lineWidth; },
            set: function(v) { _lineWidth = v; ctx2d.__rw_setLineWidth(v); }
          });
          Object.defineProperty(ctx2d, 'lineCap', {
            get: function() { return _lineCap; },
            set: function(v) { _lineCap = v; }
          });
          Object.defineProperty(ctx2d, 'lineJoin', {
            get: function() { return _lineJoin; },
            set: function(v) { _lineJoin = v; }
          });
          Object.defineProperty(ctx2d, 'shadowColor', {
            get: function() { return _shadowColor; },
            set: function(v) { _shadowColor = v; }
          });
          Object.defineProperty(ctx2d, 'shadowBlur', {
            get: function() { return _shadowBlur; },
            set: function(v) { _shadowBlur = v; }
          });
          Object.defineProperty(ctx2d, 'shadowOffsetX', {
            get: function() { return _shadowOffsetX; },
            set: function(v) { _shadowOffsetX = v; }
          });
          Object.defineProperty(ctx2d, 'shadowOffsetY', {
            get: function() { return _shadowOffsetY; },
            set: function(v) { _shadowOffsetY = v; }
          });
          Object.defineProperty(ctx2d, 'imageSmoothingEnabled', {
            get: function() { return _imageSmoothingEnabled; },
            set: function(v) { _imageSmoothingEnabled = v; }
          });
          el.__ctx2d = ctx2d;
          return ctx2d;
        }
        return null;
      };
    }
    // Audio/video elements need canPlayType for codec detection
    if (tag.toLowerCase() === 'audio' || tag.toLowerCase() === 'video') {
      el.canPlayType = function(type) {
        if (!type) return '';
        var t = type.toLowerCase();
        if (t.indexOf('ogg') >= 0 || t.indexOf('vorbis') >= 0) return 'probably';
        return '';
      };
      el.play = function() { return Promise.resolve(); };
      el.pause = function() {};
      el.load = function() {};
      el.volume = 1;
      el.src = '';
    }
    if (tag.toLowerCase() === 'img') {
      el.onload = null;
      el.onerror = null;
      el.complete = false;
      el.naturalWidth = 0;
      el.naturalHeight = 0;
      el.width = 0;
      el.height = 0;
      el.crossOrigin = null;
      Object.defineProperty(el, 'src', {
        get: function() { return el._src || ''; },
        set: function(v) {
          el._src = v;
          el.complete = false;
          var self = el;
          setTimeout(function() { if (typeof __rw_loadImage === 'function') __rw_loadImage(self, v); }, 0);
        },
        configurable: true, enumerable: true
      });
    }
    return el;
  },
  getElementById: function(id) { return _elemById[id] || null; },
  querySelector: function(sel) {
    // Very minimal: handle '#id' and 'tag' only.
    if (sel.charAt(0) === '#') return _elemById[sel.slice(1)] || null;
    return null;
  },
  querySelectorAll: function(sel) { return []; },
  addEventListener: function(type, fn, opts) {
    if (!_docListeners[type]) _docListeners[type] = [];
    _docListeners[type].push(fn);
  },
  removeEventListener: function(type, fn) {
    if (!_docListeners[type]) return;
    var a = _docListeners[type];
    var i = a.indexOf(fn);
    if (i >= 0) a.splice(i, 1);
  },
  dispatchEvent: function(evt) {
    var fns = _docListeners[evt.type] || [];
    for (var i = 0; i < fns.length; i++) {
      try { fns[i](evt); }
      catch(e) { console.error('[event error] doc.' + evt.type + ': ' + ((e && e.stack) || e)); }
    }
  },
  exitFullscreen: function() { return Promise.resolve(); },
  createElementNS: function(ns, tag) { return this.createElement(tag); },
  defaultView: null,  // set to window after window is defined (below)
  implementation: {
    createHTMLDocument: function(title) {
      // Minimal document fragment for jQuery's HTML parsing (buildFragment)
      var d = {
        body: _makeElement('body'),
        createElement: function(tag) { return _makeElement(tag); },
        createDocumentFragment: function() { return _makeElement('#document-fragment'); },
        createTextNode: function(data) { return document.createTextNode(data); },
        createComment: function(data) { return document.createComment(data); }
      };
      return d;
    },
    hasFeature: function() { return true; }
  },
  createTextNode: function(data) {
    var s = String(data == null ? '' : data);
    return {
      nodeType: 3, nodeName: '#text',
      textContent: s, data: s, nodeValue: s,
      get ownerDocument() { return document; },
      parentNode: null, children: [],
      appendChild: function(c) { return c; },
      addEventListener: function(){},
      removeEventListener: function(){},
      dispatchEvent: function(){},
      getBoundingClientRect: function() {
        return { left:0,top:0,right:0,bottom:0,width:0,height:0 };
      }
    };
  },
  createDocumentFragment: function() { return _makeElement('#document-fragment'); },
  createComment: function(data) {
    return {
      nodeType: 8, nodeName: '#comment',
      data: String(data == null ? '' : data),
      textContent: String(data == null ? '' : data),
      get ownerDocument() { return document; },
      parentNode: null, children: [],
      appendChild: function(c) { return c; },
      addEventListener: function(){},
      removeEventListener: function(){},
      dispatchEvent: function(){}
    };
  },
  fonts: {
    // Resolve with an object that includes check() so that Graphics.isFontLoaded
    // can call Graphics._fontLoaded.check('10px "GameFont"') → true.
    ready: Promise.resolve({ forEach: function(){}, size: 0, check: function() { return true; } }),
    check: function() { return true; },
    load: function() {
      // FontFaceObserver checks `1 <= result.length`; returning an object with
      // length=1 satisfies the check and avoids a 3-second polling timeout.
      return Promise.resolve([{family:'', style:'normal', weight:'normal', stretch:'normal',
                               unicodeRange:'', variant:'', featureSettings:''}]);
    },
    add: function() {},
    forEach: function(){}
  },
  getElementsByTagName: function(tag) {
    var result = this.documentElement.getElementsByTagName(tag);
    // Also include the documentElement itself if it matches
    var upper = tag === '*' ? null : tag.toUpperCase();
    if (!upper || this.documentElement.tagName === upper) {
      var arr = [this.documentElement].concat(Array.prototype.slice.call(result));
      arr.item = function(i) { return arr[i] || null; };
      return arr;
    }
    return result;
  }
};

/* ── navigator ───────────────────────────────────────────────────────────── */

var navigator = {
  userAgent: 'Mozilla/5.0 rwebview/1.0',
  platform: 'Win32',
  language: 'en',
  onLine: true,
  maxTouchPoints: 0,
  connection: { bandwidth: Infinity, downlinkMax: Infinity, metered: false,
                type: 'unknown', downlink: Infinity, effectiveType: '4g' },
  getGamepads: function() { return []; }
};

/* ── window ─────────────────────────────────────────────────────────────── */

var _winListeners = {};

var window = {
  // Identity flag — lets JS code detect rwebview at runtime.
  // Native stbvorbis, __rw_loadScript, etc. are only available here.
  __rw_isRwebview: true,
  innerWidth:  __CANVAS_W__,
  innerHeight: __CANVAS_H__,
  outerWidth:  __CANVAS_W__,
  outerHeight: __CANVAS_H__,
  devicePixelRatio: 1,
  scrollX: 0,
  scrollY: 0,
  pageXOffset: 0,
  pageYOffset: 0,
  onload:   null,
  onerror:  null,
  onresize: null,
  onblur:   null,
  onfocus:  null,
  document: document,
  navigator: navigator,
  location: { href: '__LOCATION_HREF__', hash: '', search: '', pathname: '__LOCATION_PATHNAME__',
               hostname: '__LOCATION_HOSTNAME__', protocol: '__LOCATION_PROTOCOL__',
               origin: '__LOCATION_ORIGIN__',
               assign: function(){}, replace: function(){}, reload: function(){} },
  history:  { pushState: function(){}, replaceState: function(){}, back: function(){}, forward: function(){} },
  screen:   { width: __SCREEN_W__, height: __SCREEN_H__, availWidth: __SCREEN_W__, availHeight: __SCREEN_H__,
              orientation: { type: 'landscape-primary', angle: 0, lock: function() { return Promise.resolve(); }, unlock: function() {} } },
  performance: {
    now: function() { return __rw_getTicksMs(); }
  },
  console: console,
  // rAF / timer — native implementations installed by bindDom
  requestAnimationFrame: null,
  cancelAnimationFrame:  null,
  setTimeout:   null,
  clearTimeout: null,
  setInterval:  null,
  clearInterval:null,
  addEventListener: function(type, fn, opts) {
    if (!_winListeners[type]) _winListeners[type] = [];
    _winListeners[type].push(fn);
    if (type === 'load' && window.onload == null) window.onload = fn;
  },
  removeEventListener: function(type, fn) {
    if (!_winListeners[type]) return;
    var a = _winListeners[type];
    var i = a.indexOf(fn);
    if (i >= 0) a.splice(i, 1);
  },
  dispatchEvent: function(evt) {
    var fns = _winListeners[evt.type] || [];
    for (var i = 0; i < fns.length; i++) {
      try { fns[i](evt); }
      catch(e) { console.error('[event error] win.' + evt.type + ': ' + ((e && e.stack) || e)); }
    }
    var handler = window['on' + evt.type];
    if (typeof handler === 'function') {
      try { handler(evt); }
      catch(e) { console.error('[event error] win.on' + evt.type + ': ' + ((e && e.stack) || e)); }
    }
  },
  open:  function() { return null; },
  close: function() {},
  focus: function() {},
  blur:  function() {},
  alert:   function(msg) { console.log('[alert] ' + msg); },
  confirm: function(msg) { console.log('[confirm] ' + msg); return false; },
  prompt:  function(msg) { console.log('[prompt] ' + msg); return ''; },
  clearImmediate: function(){},
  setImmediate: function(fn){ return window.setTimeout(fn, 0); },
  URL: (function() {
    function _URL(input, base) {
      var s = String(input);
      this.href = s;
      this.origin = '';
      this.protocol = '';
      this.host = '';
      this.hostname = '';
      this.port = '';
      this.pathname = '/';
      this.search = '';
      this.hash = '';
      this.searchParams = {
        _params: {},
        set: function(k, v) { this._params[k] = v; },
        get: function(k) { return this._params[k] || null; },
        toString: function() {
          var parts = [];
          for (var k in this._params) parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(this._params[k]));
          return parts.length ? '?' + parts.join('&') : '';
        }
      };
      var m = s.match(/^(https?:)\/\/([^/:]+)(:\d+)?(\/[^?#]*)?(\?[^#]*)?(#.*)?$/);
      if (m) {
        this.protocol = m[1]; this.hostname = m[2]; this.port = m[3] ? m[3].slice(1) : '';
        this.host = this.hostname + (m[3] || ''); this.pathname = m[4] || '/';
        this.search = m[5] || ''; this.hash = m[6] || '';
        this.origin = this.protocol + '//' + this.host;
      }
    }
    _URL.createObjectURL = function() { return ''; };
    _URL.revokeObjectURL = function() {};
    return _URL;
  })(),
  Blob: function(){},
  matchMedia: function(query) {
    return { matches: false, media: query, onchange: null,
             addListener: function(){}, removeListener: function(){},
             addEventListener: function(){}, removeEventListener: function(){} };
  },
  Worker: function(){ return { postMessage:function(){}, terminate:function(){}, onmessage:null }; },
  XMLHttpRequest: function(){
    return {
      open:function(){}, send:function(){}, setRequestHeader:function(){},
      abort:function(){},
      onload:null, onerror:null, onprogress:null,
      readyState:0, status:0, responseText:'', response:null
    };
  },
  /* DOM interface constructors — polyfills augment these */
  EventTarget:      EventTarget,
  Node:             Node,
  Element:          Element,
  HTMLElement:      HTMLElement,
  HTMLImageElement: Image,
  MutationObserver: MutationObserver,
  ResizeObserver:   function(cb) { this._cb = cb; this.observe = function(){}; this.unobserve = function(){}; this.disconnect = function(){}; },
  crypto:           { getRandomValues: function(arr) { for (var i = 0; i < arr.length; i++) arr[i] = (Math.random() * 256) | 0; return arr; } }
};

/* ── Image constructor ───────────────────────────────────────────────────── */

function Image() {
  this._src = '';
  this.onload  = null;
  this.onerror = null;
  this.complete = false;
  this.naturalWidth  = 0;
  this.naturalHeight = 0;
  this.width  = 0;
  this.height = 0;
  this._listeners = {};
}
Object.defineProperty(Image.prototype, 'src', {
  get: function() { return this._src; },
  set: function(v) {
    this._src = v;
    this.complete = false;
    // Defer __rw_loadImage so addEventListener('load',...) can be registered
    // before the event fires — real browsers load images asynchronously.
    var self = this;
    setTimeout(function() { __rw_loadImage(self, v); }, 0);
  }
});
Image.prototype.addEventListener = function(type, fn) {
  if (!this._listeners[type]) this._listeners[type] = [];
  this._listeners[type].push(fn);
};
Image.prototype.removeEventListener = function(type, fn) {
  var a = this._listeners[type]; if (!a) return;
  var i = a.indexOf(fn); if (i >= 0) a.splice(i, 1);
};
Image.prototype.dispatchEvent = function(evt) {
  var fns = this._listeners[evt.type] || [];
  for (var i = 0; i < fns.length; i++) {
    try { fns[i](evt); }
    catch(e) { console.error('[event error] Image.' + evt.type + ': ' + ((e && e.stack) || e)); }
  }
  var handler = this['on' + evt.type];
  if (typeof handler === 'function') {
    try { handler.call(this, evt); }
    catch(e) { console.error('[event error] Image.on' + evt.type + ': ' + ((e && e.stack) || e)); }
  }
};

/* ── Audio constructor ───────────────────────────────────────────────────── */
/* Used by Construct 2's HTML5 music path (is_music=true, myapi=API_HTML5).  */
/* Minimal Audio() pre-stub — overridden by the full implementation in       */
/* rwebview_audio.nim's bindAudio() which runs before any user scripts.      */
/* This stub only exists so createElement('audio') has a constructor and     */
/* canPlayType works even if referenced before bindAudio runs.               */

function Audio(src) {
  this._src = src || '';
  this._listeners = {};
  this.volume = 1;
  this.loop = false;
  this.paused = true;
  this.muted = false;
  this.currentTime = 0;
  this.duration = 0;
  this.readyState = 0;
  this.ended = false;
  this.error = null;
  this.playbackRate = 1;
  this.autoplay = false;
  this.preload = 'auto';
}
Audio.prototype.addEventListener = function(t, fn) {
  if (!this._listeners[t]) this._listeners[t] = [];
  this._listeners[t].push(fn);
};
Audio.prototype.removeEventListener = function(t, fn) {
  var a = this._listeners[t]; if (!a) return;
  var i = a.indexOf(fn); if (i >= 0) a.splice(i, 1);
};
Audio.prototype.dispatchEvent = function() {};
Audio.prototype.play  = function() { return Promise.resolve(); };
Audio.prototype.pause = function() {};
Audio.prototype.load  = function() {};
Audio.prototype.canPlayType = function(type) {
  if (!type) return '';
  var t = type.toLowerCase();
  if (t.indexOf('ogg') >= 0 || t.indexOf('vorbis') >= 0) return 'probably';
  if (t.indexOf('wav') >= 0) return 'probably';
  if (t.indexOf('mp3') >= 0 || t.indexOf('mpeg') >= 0) return 'maybe';
  if (t.indexOf('mp4') >= 0 || t.indexOf('aac') >= 0 || t.indexOf('m4a') >= 0) return '';
  return '';
};

/* ── XPathResult constants stub ─────────────────────────────────────────── */
/* C2's XML plugin references XPathResult.STRING_TYPE etc. as numeric        */
/* constants passed to document.evaluate().  The xpath_eval_* helpers        */
/* already wrap evaluate() in try/catch, so we only need the constants.      */
var XPathResult = {
  ANY_TYPE:                     0,
  NUMBER_TYPE:                  1,
  STRING_TYPE:                  2,
  BOOLEAN_TYPE:                 3,
  UNORDERED_NODE_ITERATOR_TYPE: 4,
  ORDERED_NODE_ITERATOR_TYPE:   5,
  UNORDERED_NODE_SNAPSHOT_TYPE: 6,
  ORDERED_NODE_SNAPSHOT_TYPE:   7,
  ANY_UNORDERED_NODE_TYPE:      8,
  FIRST_ORDERED_NODE_TYPE:      9
};

/* ── MutationObserver stub ──────────────────────────────────────────────── */
function MutationObserver(callback) {
  this._callback = callback;
}
MutationObserver.prototype.observe = function(target, config) {};
MutationObserver.prototype.disconnect = function() {};
MutationObserver.prototype.takeRecords = function() { return []; };

/* ── Event constructor ───────────────────────────────────────────────────── */
/* Polyfill.js creates `new Event('fullscreenchange', {bubbles:true})` when   */
/* toggling fullscreen.  Without this, QuickJS throws ReferenceError.         */
// Input event constructors — PIXI's InteractionManager calls
// `event instanceof MouseEvent` / `TouchEvent` / `PointerEvent` for
// normalizeToPointerData.  Without these, ReferenceError is thrown.
function MouseEvent(type, options) {
  Event.call(this, type, options);
  this.clientX = (options && options.clientX) || 0;
  this.clientY = (options && options.clientY) || 0;
  this.button  = (options && options.button)  || 0;
  this.buttons = (options && options.buttons) || 0;
}
function TouchEvent(type, options) {
  Event.call(this, type, options);
  this.changedTouches = (options && options.changedTouches) || [];
  this.touches = (options && options.touches) || [];
}
function PointerEvent(type, options) {
  MouseEvent.call(this, type, options);
  this.pointerId   = (options && options.pointerId)   || 0;
  this.pointerType = (options && options.pointerType) || 'mouse';
}

function Event(type, options) {
  this.type = String(type);
  this.bubbles = options && options.bubbles ? true : false;
  this.cancelable = options && options.cancelable ? true : false;
  this.defaultPrevented = false;
  this.target = null;
  this.currentTarget = null;
}
Event.prototype.preventDefault  = function() { this.defaultPrevented = true; };
Event.prototype.stopPropagation = function() {};
Event.prototype.stopImmediatePropagation = function() {};

function CustomEvent(type, options) {
  Event.call(this, type, options);
  this.detail = options && options.detail !== undefined ? options.detail : null;
}
CustomEvent.prototype = Object.create(Event.prototype);
CustomEvent.prototype.constructor = CustomEvent;

/* ── DOM interface constructors ─────────────────────────────────────────── */
/* Polyfills (e.g. polyfill.js) augment Element.prototype, Node.prototype, etc.
 * These stubs ensure those augmentations don't throw ReferenceError.         */
function EventTarget() {}
EventTarget.prototype.addEventListener    = function() {};
EventTarget.prototype.removeEventListener = function() {};
EventTarget.prototype.dispatchEvent       = function() { return true; };

function Node() {}
Node.prototype = Object.create(EventTarget.prototype);
Node.prototype.nodeType = 1;

function Element() {}
Element.prototype = Object.create(Node.prototype);
Element.prototype.requestFullscreen        = Element.prototype.requestFullscreen || function() { return Promise.resolve(); };
// RPG Maker MV uses capital-S and vendor-prefixed variants on document.body
Element.prototype.requestFullScreen        = Element.prototype.requestFullScreen || function() {};
Element.prototype.mozRequestFullScreen     = Element.prototype.mozRequestFullScreen || function() {};
Element.prototype.webkitRequestFullScreen  = Element.prototype.webkitRequestFullScreen || function() {};
Element.prototype.msRequestFullscreen      = Element.prototype.msRequestFullscreen || function() {};
Element.ALLOW_KEYBOARD_INPUT = 1;
Element.prototype.getBoundingClientRect = function() {
  return { left:0, top:0, right:0, bottom:0, width:0, height:0 };
};

// document.body is a plain object (not an instance of Element) so it does NOT
// inherit from Element.prototype.  Polyfill.js overrides Element.prototype.
// requestFullscreen with the real toggle_fullscreen handler, but that override
// would never be reached via document.body.requestFullscreen() without these
// explicit delegating shims.  By delegating through the prototype at call-time,
// polyfill.js's override is picked up automatically after it runs.
document.body.requestFullscreen       = function() { return Element.prototype.requestFullscreen.call(this); };
document.body.requestFullScreen       = function() { return Element.prototype.requestFullScreen.call(this); };
document.body.webkitRequestFullScreen = function() { return Element.prototype.webkitRequestFullScreen.call(this); };
document.body.mozRequestFullScreen    = function() { return Element.prototype.mozRequestFullScreen.call(this); };
document.body.msRequestFullscreen     = function() { return Element.prototype.msRequestFullscreen.call(this); };

function HTMLElement() {}
HTMLElement.prototype = Object.create(Element.prototype);

/* ── globals: make window props available at top scope ───────────────────── */

var performance      = window.performance;
var location         = window.location;
var navigator        = window.navigator;
var screen           = window.screen;
var history          = window.history;
var ResizeObserver   = window.ResizeObserver;
var crypto           = window.crypto;
var URL              = window.URL;
var HTMLImageElement  = window.HTMLImageElement;
// WebGL / Canvas rendering context constructors — needed by PIXI's capability
// detection: `N.ADAPTER.getWebGLRenderingContext()` returns this global and
// checks it is truthy before attempting WebGL initialisation.
var WebGLRenderingContext    = function WebGLRenderingContext(){};
var WebGL2RenderingContext   = function WebGL2RenderingContext(){};
var CanvasRenderingContext2D = function CanvasRenderingContext2D(){};
window.WebGLRenderingContext    = WebGLRenderingContext;
window.WebGL2RenderingContext   = WebGL2RenderingContext;
window.CanvasRenderingContext2D = CanvasRenderingContext2D;
window.MouseEvent   = MouseEvent;
window.TouchEvent   = TouchEvent;
window.PointerEvent = PointerEvent;
// FormData stub — required by third-party libs (e.g. newgroundsio) that call
// `new FormData()` and `.append()` even when no actual form POST is needed.
function FormData(form) { this._entries = []; }
FormData.prototype.append = function(n, v) { this._entries.push([n, v]); };
FormData.prototype.set = function(n, v) {
  this._entries = this._entries.filter(function(e) { return e[0] !== n; });
  this._entries.push([n, v]);
};
FormData.prototype.get = function(n) {
  var e = this._entries.find(function(e) { return e[0] === n; });
  return e ? e[1] : null;
};
FormData.prototype.has = function(n) {
  return this._entries.some(function(e) { return e[0] === n; });
};
FormData.prototype.delete = function(n) {
  this._entries = this._entries.filter(function(e) { return e[0] !== n; });
};
FormData.prototype.getAll = function(n) {
  return this._entries.filter(function(e) { return e[0] === n; })
                      .map(function(e) { return e[1]; });
};
window.FormData = FormData;
// Backfill document.defaultView and document.location now that window is fully defined
document.defaultView = window;
document.location   = window.location;

/* ── Intl stub ──────────────────────────────────────────────────────────── */
/* GDevelop's pixi.js accesses Intl.Segmenter for grapheme segmentation.     */
/* The safe-check `typeof (Intl==null?void 0:Intl.Segmenter)` still throws   */
/* a ReferenceError if `Intl` itself is undeclared.  Providing a minimal stub */
/* lets the feature-detection fall through to the array-spread fallback.      */
var Intl = {
  Collator: function(locales, opts) { this.compare = function(a, b) { return a < b ? -1 : a > b ? 1 : 0; }; },
  DateTimeFormat: function() { this.format = function(d) { return String(d); }; },
  NumberFormat: function() { this.format = function(n) { return String(n); }; }
  // Intl.Segmenter intentionally omitted — pixi.js checks typeof and falls back
};
window.Intl = Intl;
var requestAnimationFrame  = function(fn) { return window.requestAnimationFrame(fn); };
var cancelAnimationFrame   = function(id) { return window.cancelAnimationFrame(id); };
var setTimeout   = function(fn,ms)  { return window.setTimeout(fn,ms); };
var clearTimeout = function(id)     { return window.clearTimeout(id); };
var setInterval  = function(fn,ms)  { return window.setInterval(fn,ms); };
var clearInterval = function(id)    { return window.clearInterval(id); };
var matchMedia    = function(q)     { return window.matchMedia(q); };
var getComputedStyle = function(el) {
  // Return a minimal CSSStyleDeclaration-like object.
  // Reads from el.style properties when available, falls back to defaults.
  var s = (el && el.style) || {};
  return {
    display: s.display || 'block',
    visibility: s.visibility || 'visible',
    width: s.width || 'auto',
    height: s.height || 'auto',
    position: s.position || 'static',
    overflow: s.overflow || 'visible',
    opacity: s.opacity !== undefined ? String(s.opacity) : '1',
    margin: s.margin || '0px',
    padding: s.padding || '0px',
    getPropertyValue: function(prop) { return this[prop] || ''; }
  };
};
window.getComputedStyle = getComputedStyle;

/* ── localStorage (backed by native JSON file I/O) ──────────────────────── */

var localStorage = {
  getItem:    function(key)       { return __rw_storage_getItem(String(key)); },
  setItem:    function(key, val)  { __rw_storage_setItem(String(key), String(val)); },
  removeItem: function(key)       { __rw_storage_removeItem(String(key)); },
  clear:      function()          { __rw_storage_clear(); },
  get length()                    { return __rw_storage_length(); },
  key:        function(idx)       { return __rw_storage_key(idx); }
};
window.localStorage = localStorage;

/* ── internal event dispatch helper ─────────────────────────────────────── */

function __rw_dispatchEvent(target, type, props) {
  // Create the appropriate event type so that `instanceof` checks work
  // (e.g. PIXI's normalizeToPointerData checks `event instanceof MouseEvent`).
  var evt;
  if (type.indexOf('mouse') === 0 || type === 'click' || type === 'dblclick' || type === 'contextmenu' || type === 'wheel') {
    evt = new MouseEvent(type, props || {});
  } else if (type.indexOf('touch') === 0) {
    evt = new TouchEvent(type, props || {});
  } else if (type.indexOf('pointer') === 0) {
    evt = new PointerEvent(type, props || {});
  } else {
    evt = new Event(type, props || {});
  }
  if (props) {
    for (var k in props) evt[k] = props[k];
  }
  if (target && typeof target.dispatchEvent === 'function') {
    target.dispatchEvent(evt);
  }
}

/* ── window ≡ globalThis ─────────────────────────────────────────────────── */
/* In every real browser, window IS the global object.  Without this, UMD    */
/* bundles that do  window.Foo = exports  then reference bare  Foo  in the   */
/* same file (e.g. fpsmeter.js, pixi-tilemap.js) would throw ReferenceError. */
(function() {
  var _w = window;
  /* Copy our custom window properties onto globalThis first. */
  for (var _k in _w) {
    if (_k === 'window') continue;
    try { if (typeof globalThis[_k] === 'undefined') globalThis[_k] = _w[_k]; } catch(e) {}
  }
  /* Make globalThis.window a circular self-reference (real browser behaviour). */
  globalThis.window = globalThis;
})();
/* Top-level var reassigns globalThis.window = globalThis. */
var window = globalThis;

/* ── Debugging: catch uncaught JS exceptions & unhandled rejections ──────── */
/* These make silent JS errors visible in the console so we can diagnose      */
/* black-screen / hang issues without a real browser DevTools.                */
var __lastErrorObj = null;  // Store last caught error for console.error to reference
window.onerror = function(msg, src, line, col, err) {
  __lastErrorObj = err;  // Save error object for console.error to access
  var location = String(src || '') + ':' + line + ':' + col;
  var stack = (err && err.stack) ? '\n' + err.stack : '';
  console.error('[onerror] ' + String(msg) + ' @ ' + location + stack);
  return false; // do not suppress default behaviour
};
// Patch console.error so that when Construct2/RPG Maker's error handler
// calls console.error(e.stack), the error name+message is also printed.
// (Graphics.printError writes to DOM which is invisible in rwebview.)
(function() {
  var _orig = console.error;
  console.error = function() {
    if (arguments.length === 1 && typeof arguments[0] === 'string') {
      var s = arguments[0];
      // Case 1: [event error] from XHR/timer wrapper — __lastErrorObj was set
      // just before this call. Print error name:message as a header line.
      if (s.indexOf('[event error]') === 0) {
        if (__lastErrorObj) {
          var ename = __lastErrorObj.name || 'Error';
          var emsg = __lastErrorObj.message || '(no message)';
          _orig.call(console, '[ERR-info] ' + ename + ': ' + emsg);
        }
        // fall through — also print the full [event error] stack line
      }
      // Case 2: bare stack trace — string starts directly with "    at ".
      // Do NOT match on \n    at (that fires falsely on [event error] strings).
      else if (s.indexOf('    at ') === 0) {
        if (__lastErrorObj) {
          var ename = __lastErrorObj.name || 'Error';
          var emsg = __lastErrorObj.message || '(no message)';
          _orig.call(console, '[ERR-stack] ' + ename + ': ' + emsg);
        } else {
          _orig.call(console, '[ERR-stack] (error name/message not available)');
        }
        // fall through — also print the bare stack
      }
    }
    _orig.apply(console, arguments);
  };
})();
window.addEventListener('unhandledrejection', function(e) {
  var reason = e && e.reason;
  var msg = (reason && reason.stack) ? reason.stack
            : (reason instanceof Error) ? reason.message
            : String(reason);
  console.error('[PromiseRejection] ' + msg);
});
