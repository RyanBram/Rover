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
    _id: '',
    get id() { return this._id; },
    set id(v) {
      if (this._id && _elemById[this._id] === this) delete _elemById[this._id];
      this._id = String(v);
      if (v) _elemById[this._id] = this;
    },
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
      for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
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
    })()
  };
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
      // If context already created, notify native immediately
      if (child.__ctxId !== undefined && typeof __rw_setCanvasVisible === 'function') {
        __rw_setCanvasVisible(child.__ctxId, true);
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
      // This makes Graphics.pageToCanvasX/Y work correctly for letterboxed display.
      (function() {
        var _s = {};
        var _ml = '0px', _mt = '0px';
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
        },
        configurable: true, enumerable: true
      });
      el.getContext = function(type) {
        if (type === 'webgl' || type === 'webgl2' || type === 'experimental-webgl') {
          if (typeof __rw_glContext !== 'undefined') {
            __rw_glContext.canvas = el;
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
    for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
  },
  exitFullscreen: function() { return Promise.resolve(); },
  createElementNS: function(ns, tag) { return this.createElement(tag); },
  createTextNode: function(data) {
    var s = String(data == null ? '' : data);
    return {
      nodeType: 3, nodeName: '#text',
      textContent: s, data: s, nodeValue: s,
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
  fonts: {
    // Resolve with an object that includes check() so that Graphics.isFontLoaded
    // can call Graphics._fontLoaded.check('10px "GameFont"') → true.
    ready: Promise.resolve({ forEach: function(){}, size: 0, check: function() { return true; } }),
    check: function() { return true; },
    load: function() { return Promise.resolve([]); },
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
  getGamepads: function() { return []; }
};

/* ── window ─────────────────────────────────────────────────────────────── */

var _winListeners = {};

var window = {
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
  location: { href: '', hash: '', search: '', pathname: '/', hostname: 'localhost', protocol: 'file:',
               assign: function(){}, replace: function(){}, reload: function(){} },
  history:  { pushState: function(){}, replaceState: function(){}, back: function(){}, forward: function(){} },
  screen:   { width: __CANVAS_W__, height: __CANVAS_H__, availWidth: __CANVAS_W__, availHeight: __CANVAS_H__ },
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
    for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
    var handler = window['on' + evt.type];
    if (typeof handler === 'function') { try { handler(evt); } catch(e) {} }
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
  URL: { createObjectURL: function(){ return ''; }, revokeObjectURL: function(){} },
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
  MutationObserver: MutationObserver
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
  for (var i = 0; i < fns.length; i++) { try { fns[i](evt); } catch(e) {} }
  var handler = this['on' + evt.type];
  if (typeof handler === 'function') { try { handler.call(this, evt); } catch(e) {} }
};

/* ── Audio constructor ───────────────────────────────────────────────────── */

function Audio() {
  this.src = '';
  this.volume = 1;
  this.loop = false;
  this.paused = true;
  this.currentTime = 0;
  this.duration = 0;
  this.onended = null;
  this.play  = function() { return Promise.resolve(); };
  this.pause = function() {};
  this.load  = function() {};
  this.addEventListener = function(){};
  // Tell RPG Maker that OGG is supported (SDL_sound handles OGG/Vorbis).
  this.canPlayType = function(type) {
    if (!type) return '';
    var t = type.toLowerCase();
    if (t.indexOf('ogg') >= 0 || t.indexOf('vorbis') >= 0) return 'probably';
    if (t.indexOf('mp4') >= 0 || t.indexOf('aac') >= 0 || t.indexOf('m4a') >= 0) return '';
    return '';
  };
}

/* ── MutationObserver stub ──────────────────────────────────────────────── */
function MutationObserver(callback) {
  this._callback = callback;
}
MutationObserver.prototype.observe = function(target, config) {};
MutationObserver.prototype.disconnect = function() {};
MutationObserver.prototype.takeRecords = function() { return []; };

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
Element.prototype.requestFullscreen        = function() { return Promise.resolve(); };
// RPG Maker MV uses capital-S and vendor-prefixed variants on document.body
Element.prototype.requestFullScreen        = function() {};
Element.prototype.mozRequestFullScreen     = function() {};
Element.prototype.webkitRequestFullScreen  = function() {};
Element.prototype.msRequestFullscreen      = function() {};
Element.ALLOW_KEYBOARD_INPUT = 1;
Element.prototype.getBoundingClientRect = function() {
  return { left:0, top:0, right:0, bottom:0, width:0, height:0 };
};

function HTMLElement() {}
HTMLElement.prototype = Object.create(Element.prototype);

/* ── globals: make window props available at top scope ───────────────────── */

var performance      = window.performance;
var location         = window.location;
var navigator        = window.navigator;
var screen           = window.screen;
var history          = window.history;
var requestAnimationFrame  = function(fn) { return window.requestAnimationFrame(fn); };
var cancelAnimationFrame   = function(id) { return window.cancelAnimationFrame(id); };
var setTimeout   = function(fn,ms)  { return window.setTimeout(fn,ms); };
var clearTimeout = function(id)     { return window.clearTimeout(id); };
var setInterval  = function(fn,ms)  { return window.setInterval(fn,ms); };
var clearInterval = function(id)    { return window.clearInterval(id); };
var matchMedia    = function(q)     { return window.matchMedia(q); };

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
  var evt = { type: type, bubbles: false, cancelable: false,
              preventDefault: function(){}, stopPropagation: function(){} };
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
