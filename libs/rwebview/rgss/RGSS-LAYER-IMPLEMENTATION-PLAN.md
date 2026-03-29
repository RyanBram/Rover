# RGSS LAYER IMPLEMENTATION PLAN

*This document is intended for AI assistants and contributors working on the RGSS (Rover Game Scripting System) abstraction layer in rwebview.*

---

## Table of Contents

1. [Why This Is Needed](#1-why-this-is-needed)
2. [Current Architecture State](#2-current-architecture-state)
3. [Target Architecture Vision](#3-target-architecture-vision)
4. [Implementation Phases](#4-implementation-phases)
5. [Critical Challenges](#5-critical-challenges)
6. [Web API Mapping for Non-JS Languages](#6-web-api-mapping-for-non-js-languages)
7. [Interpreter Target Priorities](#7-interpreter-target-priorities)

---

## 1. Why This Is Needed

### 1.1 QuickJS is not the only optimal choice

Rover currently hard-couples to a single JS engine (QuickJS) throughout the entire codebase. Every module (`rwebview_dom.nim`, `rwebview_xhr.nim`, `rwebview_audio.nim`, `rwebview_canvas2d.nim`, `rwebview_gl.nim`, `rwebview_storage.nim`) calls `JS_Eval`, `JS_NewCFunction2`, `JS_SetPropertyStr`, and uses `JSValue`/`JSContext` types directly. If there is ever a need to switch to the original QuickJS (Bellard) or another JS engine, all binding code must be rewritten.

### 1.2 Other interpreters have great potential for games

Rover is a custom game platform, not a general browser. The current primary target is HTML5-based games (RPG Maker MV, GDevelop, Construct2), but the broader class of games supported can include:

- **RPG Maker XP/VX/Ace** — writing game logic in **Ruby** (RGSS1/2/3)
- **RPG Maker 2000/2003** — legacy engine with **internal scripting**
- **Love2D-style** — games written in **Lua**
- **Python games** — Pygame-style logic on top of Rover rendering

If the RGSS layer is properly abstracted, a Ruby game could call `fetch("data/map.json")`, access the virtual DOM, render to canvas, and play audio — exactly as JavaScript does today. This opens Rover as a universal cross-language runtime for canvas-based games.

### 1.3 Reducing vendor lock-in risk on QuickJS

QuickJS is an active but small project. If there is a breaking change in its C API, all bindings need to be updated at once. With an abstraction layer, only one adaptor needs updating, not all modules.

### 1.4 Enabling hot-swap scripting engines per game

With a clean architecture, a game's `package.json` can specify:

```json
{
  "engine": "rgss",
  "scripting": "quickjs"
}
```

or in the future:

```json
{
  "engine": "rgss",
  "scripting": "lua54"
}
```

Without recompiling Rover.

---

## 2. Current Architecture State

### 2.1 Existing coupling

```
rwebview.nim
    ├── rgss/rgss_quickjs_ffi.nim  → JSRuntime, JSContext, JSValue, JSCFunction
    │                               types are declared here
    ├── rwebview_dom.nim           → ✓ MIGRATED to ScriptCtx/ScriptValue
    ├── rwebview_xhr.nim           → ✓ MIGRATED to ScriptCtx/ScriptValue
    ├── rwebview_audio.nim         → stores JSValue (onendedCb, onendedThis) as
    │                               struct fields (JSValue bycopy, 16 bytes each)
    ├── rwebview_canvas2d.nim      → JSValue as return type for all canvas APIs
    ├── rwebview_gl.nim            → JSValue as return type for all WebGL bindings
    └── rwebview_storage.nim       → ✓ MIGRATED to ScriptCtx/ScriptValue
```

### 2.2 Concrete problems

- `JSValue` (16-byte bycopy struct, QuickJS-specific) appears as a return type in hundreds of `proc` declarations throughout all modules
- `JSCFunction` (callback type with signature `proc(ctx, thisVal, argc, argv)`) is hard-coded in all bindings
- JSValue ownership management (`JS_DupValue`, `JS_FreeValue`) is scattered manually across ~40+ locations in `rwebview_audio.nim` alone
- No interface separates "which language is executing" from "what is being executed"

---

## 3. Target Architecture Vision

### 3.1 Diagram

```
rwebview.nim
    └─
    ├── rgss/
    │   ├── rgss_api.nim          → ABSTRACTION: ScriptEngine, ScriptValue, ScriptCtx
    │   ├── rgss_quickjs.nim    → Adaptor: QuickJS (initial implementation) ✓
    │   ├── rgss_quickjs.nim      → Adaptor: QuickJS original (Bellard)
    │   ├── rgss_lua54.nim        → Adaptor: Lua 5.4 (future phase)
    │   ├── rgss_mruby.nim        → Adaptor: mruby (future phase)
    │   └── rgss_micropython.nim  → Adaptor: MicroPython (future phase)
    │
    ├── rwebview_dom.nim          → Only talks to rgss_api.nim
    ├── rwebview_xhr.nim          → Only talks to rgss_api.nim
    ├── rwebview_audio.nim        → Only talks to rgss_api.nim
    ├── rwebview_canvas2d.nim     → Only talks to rgss_api.nim
    ├── rwebview_gl.nim           → Only talks to rgss_api.nim
    └── rwebview_storage.nim      → Only talks to rgss_api.nim
```

### 3.2 Core Abstract Types

```nim
# rgss/rgss_api.nim

## Opaque wrapper for a value in any scripting engine.
## For QuickJS: wraps JSValue (16-byte struct)
## For Lua: wraps stack index + reference (via luaL_ref)
## For mruby: wraps mrb_value (pointer-sized value)
type
  ScriptValue* = object
    data: array[2, uint64]    # 16 bytes — fits JSValue or pointer

  ScriptCtx* = object
    engine: ptr ScriptEngine
    native: pointer           # ptr JSContext / lua_State* / mrb_state*

  ## Unified callback signature accepted by all engines.
  ## Engine-specific adaptors are responsible for translating
  ## native callback conventions into ScriptNativeProc.
  ScriptNativeProc* = proc(ctx: ptr ScriptCtx;
                           this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue

  ScriptEngine* = object
    # Lifecycle
    init*:      proc(eng: ptr ScriptEngine)
    destroy*:   proc(eng: ptr ScriptEngine)
    # Context
    newCtx*:    proc(eng: ptr ScriptEngine): ptr ScriptCtx
    freeCtx*:   proc(ctx: ptr ScriptCtx)
    # Evaluation
    eval*:      proc(ctx: ptr ScriptCtx; src: cstring; filename: cstring): ScriptValue
    # Value creation
    newString*:      proc(ctx: ptr ScriptCtx; s: string): ScriptValue
    newInt*:         proc(ctx: ptr ScriptCtx; i: int): ScriptValue
    newFloat*:       proc(ctx: ptr ScriptCtx; f: float64): ScriptValue
    newBool*:        proc(ctx: ptr ScriptCtx; b: bool): ScriptValue
    newNull*:        proc(ctx: ptr ScriptCtx): ScriptValue
    newUndefined*:   proc(ctx: ptr ScriptCtx): ScriptValue
    newObject*:      proc(ctx: ptr ScriptCtx): ScriptValue
    newArray*:       proc(ctx: ptr ScriptCtx): ScriptValue
    # Value extraction
    toString*:   proc(ctx: ptr ScriptCtx; val: ScriptValue): string
    toInt*:      proc(ctx: ptr ScriptCtx; val: ScriptValue): int
    toFloat*:    proc(ctx: ptr ScriptCtx; val: ScriptValue): float64
    toBool*:     proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    isString*:   proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    isNumber*:   proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    isNull*:     proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    isObject*:   proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    isFunction*: proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    isException*: proc(ctx: ptr ScriptCtx; val: ScriptValue): bool
    # Object operations
    getProp*:    proc(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring): ScriptValue
    setProp*:    proc(ctx: ptr ScriptCtx; obj: ScriptValue; key: cstring; val: ScriptValue)
    getIndex*:   proc(ctx: ptr ScriptCtx; arr: ScriptValue; idx: int): ScriptValue
    setIndex*:   proc(ctx: ptr ScriptCtx; arr: ScriptValue; idx: int; val: ScriptValue)
    # Function binding
    bindGlobal*:  proc(ctx: ptr ScriptCtx; name: cstring; fn: ScriptNativeProc; arity: int)
    callFunction*: proc(ctx: ptr ScriptCtx; fn: ScriptValue; this: ScriptValue;
                        args: openArray[ScriptValue]): ScriptValue
    # Global
    getGlobalThis*: proc(ctx: ptr ScriptCtx): ScriptValue
    setGlobal*:     proc(ctx: ptr ScriptCtx; name: cstring; val: ScriptValue)
    getGlobalProp*: proc(ctx: ptr ScriptCtx; name: cstring): ScriptValue
    # GC / ownership
    dupValue*:   proc(ctx: ptr ScriptCtx; val: ScriptValue): ScriptValue
    freeValue*:  proc(ctx: ptr ScriptCtx; val: ScriptValue)
    runGC*:      proc(ctx: ptr ScriptCtx)
    runJobs*:    proc(ctx: ptr ScriptCtx)
    # Error handling
    getException*:    proc(ctx: ptr ScriptCtx): ScriptValue
    getExceptionStr*: proc(ctx: ptr ScriptCtx): string
    # TypedArray support (optional; JS engines only)
    newArrayBuffer*:     proc(ctx: ptr ScriptCtx; data: pointer; len: int): ScriptValue
    getArrayBufferData*: proc(ctx: ptr ScriptCtx; val: ScriptValue; outLen: var int): pointer
```

---

## 4. Implementation Phases

### ✓ Phase SL-0 – API Design & Document (COMPLETED)

**Objective:** Finalize `ScriptValue`, `ScriptCtx`, and `ScriptEngine` vtable before touching existing code.

**Output:**
- `rgss/rgss_api.nim` – types and proc signatures only, no implementation; includes ~40 forwarding procs for ergonomic call syntax (`ctx.newString(s)` instead of `ctx.engine.newString(ctx, s)`)
- Smoke test `rgss/rgss_test.nim` for compile-time validation

**Completion criteria met:** ✓ `rgss_api.nim` compiles clean. No existing modules modified.

---

### ✓ Phase SL-1 – QuickJS Adaptor (COMPLETED)

**Objective:** Wrap all existing QuickJS API calls into `rgss_quickjs.nim` which implements the `ScriptEngine` vtable.

**Detailed steps:**

1. Created `rgss/rgss_quickjs.nim`
2. Implemented every vtable proc field using the existing `rgss/rgss_quickjs_ffi.nim`
3. **`ScriptValue` strategy for QuickJS:** `data` in `ScriptValue` stores `JSValue` directly (16 bytes, in-place, no extra heap allocation)
4. **`ScriptNativeProc` strategy:** One generic C adapter function (`qjs_thunk_dispatch` in `rgss_qjs_thunk.c`) converts `(ctx, thisVal, argc, argv: ptr JSValue)` into a call to the stored `ScriptNativeProc` closure; uses `JS_CFUNC_generic_magic` slot table (4096 slots)
5. No changes to `rwebview_dom.nim` or other modules in this phase – they still use QuickJS directly

**Implementation notes:**
- `svFromJsv`/`jsvFromSv`: 16-byte `copyMem` conversions (strict-aliasing safe)
- `gQJSState {.threadvar.}: QJSState` – holds `ptr JSRuntime`
- `qjs_newCtx`: allocates `ScriptCtx` on heap, calls `JS_SetContextOpaque` so C thunk can recover it
- `makeThunkProc`: extracts `{fn, env}` from Nim closure via `NimClosureLayout` cast
- C thunk: `ThunkEntry[4096]` static array; single `qjs_thunk_dispatch` C dispatcher

**Completion criteria met:** ✓ `rgss_quickjs.nim` + `rgss_qjs_thunk.c` compile clean. `rgss_test.nim` smoke test passes.

---

### ✓ Phase SL-2 – Migrate rwebview_storage.nim (COMPLETED)

**Objective:** Migrate the module that uses JSValue least, as proof-of-concept for the refactor pattern.

**Detailed steps:**

1. Add `ScriptCtx` parameter to all binding procs in `rwebview_storage.nim`
2. Replace `JS_NewStringLen`, `JS_ToCStringLen2` etc. with `ctx.newString(...)` etc.
3. Change return types of all procs from `JSValue` to `ScriptValue`
4. Run RPG Maker MV – verify localStorage still works

**Completion criteria met:** ✓ `rwebview_storage.nim` migrated. All 6 callbacks converted to ScriptNativeProc. `bindStorage(ctx)` uses `ctx.bindGlobal`. Passes `nim check`.

---

### ✓ Phase SL-3 – Migrate rwebview_dom.nim (COMPLETED)

**Objective:** Migrate the DOM bindings that form the core of all web APIs.

**Detailed steps:**

1. Replace `JSContext` → `ScriptCtx`, `JSValue` → `ScriptValue` throughout all types
2. `bindDomApi(ctx: ptr ScriptCtx)` becomes the engine-agnostic entry point
3. `dom_preamble.js` remains injected for JS engines; for non-JS engines (Lua, Ruby), dom_preamble is skipped and replaced with a language-appropriate module stub
4. Watch out: `document.createElement`, `addEventListener`, and event dispatch use JS callbacks stored as `ScriptValue` – ensure lifecycle (dup/free) is managed via `ctx.dupValue` / `ctx.freeValue`

**Completion criteria met:** ✓ All 8 callbacks migrated to ScriptNativeProc. `bindDom` uses `ctx.bindGlobal` + `ctx.eval`. `dispatchTimers`/`dispatchRaf` use `state.scriptCtx`. `RAfEntry.fn`/`TimerEntry.fn` changed to ScriptValue. Passes `nim check`.

---

### ✓ Phase SL-4 – Migrate rwebview_xhr.nim (COMPLETED)

**Detailed steps:**

1. `PendingXhr.xhrObj`, `PendingFetch.resolveFn/rejectFn`, `PendingImageLoad.imgObj` changed from JSValue to ScriptValue
2. `jsLoadScript` now calls `ctx.eval(src, filename)` instead of raw `JS_Eval`
3. `fulfillXhr` migrated to use `ctx.setPropSteal`, `ctx.getProp`, `ctx.callFunction1`, `ctx.checkException`
4. All 11 callbacks migrated to ScriptNativeProc: `jsXhrOpen`, `jsXhrSend`, 4 stubs, `jsFetchDataUrl`, `jsFetchQueue`, `jsLoadImageReal`, `jsCreateImageBitmapFromAB`, `jsLoadScript`
5. `processXhrQueue`, `processFetchQueue`, `processImageQueue` use `state.scriptCtx`
6. `bindXhr` uses `ctx.eval` + `ctx.bindGlobal` instead of `JS_NewCFunction` + `JS_SetPropertyStr`
7. `jsFireImgEvt` helper migrated to ScriptCtx

**Challenge for future:** Promises are a native JS construct. For Lua/Ruby, a decision is needed: is `fetch` blocking (simple) or using the language's native coroutine/fiber?

**Completion criteria met:** ✓ `rwebview_xhr.nim` fully migrated. Passes `nim check`.

---

### Phase SL-5 – Migrate rwebview_audio.nim ✅ COMPLETED (March 29, 2026)

**This is the hardest migration.** `rwebview_audio.nim` stores `JSValue` directly in the `AudioSource` struct:

```nim
type AudioSource = object
  onendedCb:   JSValue  # 16 bytes bycopy
  onendedThis: JSValue  # 16 bytes bycopy
```

**Detailed steps:**

1. Replace all `JSValue` fields in `AudioSource`, `AudioBufferSourceNode`, etc. with `ScriptValue`
2. `freeAudioMixer(ctx)` that frees `onendedCb`/`onendedThis` → replace with `ctx.freeValue(src.onendedCb)`
3. `onended` callback invoked from decoder thread → needs an engine-agnostic "post to main thread" mechanism, because some engines (mruby) are not thread-safe
4. Callback invocation: `JS_Call(ctx, cb, this, 0, nil)` → replace with `ctx.callFunction(cb, this, [])`

**Completion criteria:** `rwebview_audio.nim` is engine-agnostic. RPG Maker MV BGM still works.

---

### Phase SL-6 – Migrate rwebview_canvas2d.nim + rwebview_gl.nim ✅ COMPLETED (March 29, 2026)

**Detailed steps:**

1. Both modules have the most procs with `JSValue` return type (~60+ procs)
2. Batch-rename with tools, then check compile errors
3. Watch out: `rwebview_gl.nim` stores JS-side WebGL objects (`WebGLBuffer`, `WebGLTexture`, etc.) as JS objects with properties – ensure `setProp`/`getProp` works correctly through the adaptor

**Runtime validation (March 29, 2026):** Tested with RPG Maker VX Ace player — WebGL rendering, Canvas2D blit, XHR, audio streaming, save file I/O, and image loading all functional. Zero regression.

---

### Phase SL-7 – MicroQuickJS (mquickjs) Adaptor

**Objective:** Add MicroQuickJS as an optional second JS interpreter.
This is the first real validation that the RGSS abstraction layer works with
a different engine behind the same ScriptEngine vtable.

**Background:** QuickJS-NG is "the new QuickJS" — the Bellard original adaptor
is no longer needed. Instead, Phase SL-7 targets MicroQuickJS (`mquickjs`), a
minimal QuickJS fork optimised for small binaries and embedded use.

**Source location:** `libs/rwebview/libs/mquickjs/`

**Compile-time opt-in:**
```
-d:withMQuickJS          # include mquickjs adaptor in the binary
```
When the flag is absent, mquickjs code is not compiled and adds zero overhead.

**Runtime selection via package.json:**
```json
{
  "interpreter": "mquickjs"
}
```
If `"interpreter"` is omitted or `"quickjs"`, the default QuickJS engine is used.

**Detailed steps:**

1. Place mquickjs source in `libs/rwebview/libs/mquickjs/`
2. Create `rgss/rgss_mquickjs_ffi.nim` — FFI bindings for mquickjs C API
3. Create `rgss/rgss_mquickjs.nim` — ScriptEngine vtable implementation
   - Same vtable shape as `rgss_quickjs.nim`
   - Map mquickjs API to each vtable slot (eval, newString, getProp, etc.)
   - Create C thunk file `rgss/rgss_mqjs_thunk.c` (or reuse existing thunk
     if mquickjs JSCFunction signature is identical)
4. Create `c_src/rwebview_mquickjs_wrap.c` — inline function wrappers
   (same pattern as `rwebview_rgss_wrap.c`)
5. Guard everything with `when defined(withMQuickJS):`
6. Update `rwebview.nim` engine selection:
   ```nim
   when defined(withMQuickJS):
     import rgss/rgss_mquickjs
   # In init, read "interpreter" from package.json:
   if interpreterName == "mquickjs":
     when defined(withMQuickJS):
       gScriptEngine = newMQuickJSEngine()
     else:
       quit("mquickjs not compiled — rebuild with -d:withMQuickJS")
   else:
     gScriptEngine = newQuickJSEngine()
   ```
7. Update `build.bat` to accept an optional mquickjs build flag
8. Verify: compile **without** `-d:withMQuickJS` → zero code change, same binary
9. Verify: compile **with** `-d:withMQuickJS` → RPG Maker MV runs on mquickjs

**Key API differences to audit (mquickjs vs QuickJS-NG):**
- JSValue representation (NaN-boxing vs struct?) — must verify `ScriptValue` 16-byte layout
- `JS_SetContextOpaque` / `JS_GetContextOpaque` availability
- Job queue / Promise microtask API
- ArrayBuffer / TypedArray access functions
- CFunction binding signature

**Completion criteria:**
- RPG Maker MV title screen loads with `"interpreter": "mquickjs"`
- Default build (no flag) is completely unaffected
- `[rwebview] Script interpreter: mquickjs vX.Y.Z` appears in log

---

### Phase SL-8 – Lua 5.4 Adaptor (Proof of Concept)

**Objective:** Prove the abstraction works with a genuinely different language.

**Detailed steps:**

1. Clone `lua-5.4.x` to `libs/rwebview/libs/lua`
2. Create `rgss/rgss_lua54.nim`
3. Implement the `ScriptEngine` vtable for Lua:
   - `newCtx` → `luaL_newstate()` + load standard libs
   - `eval` → `luaL_loadstring` + `lua_pcall`
   - `newString` → `lua_pushstring` + `luaL_ref` into registry
   - `ScriptValue.data[0]` = registry reference (int via `luaL_ref`)
   - `bindGlobal` → `lua_pushcclosure` with upvalue to `ScriptNativeProc`
4. Create Web API Lua shim: `rgss/webapi_lua_shim.lua` exposing `fetch`, `console`, `setTimeout` with idiomatic Lua syntax

**Completion criteria:** A simple Lua script can call `fetch("data/test.json")` and receive the result.

---

### Phase SL-9 – mruby Adaptor

**Objective:** Support Ruby for RGSS/RPG Maker XP/VX/Ace compatibility.

**Detailed steps:**

1. Clone mruby to `libs/rwebview/libs/mruby`
2. Create `rgss/rgss_mruby.nim`
3. `mrb_value` is a tagged 8-byte union – fits in `ScriptValue.data[0]`
4. `bindGlobal` → `mrb_define_method` with `MRB_FUNC_T` wrapper
5. Web API Ruby shim: `fetch(url)` as a global method, `$document` as a `Document` object

**Biggest challenge:** mruby has no native Promise/async. All IO like `fetch` must be implemented as blocking calls or using mruby Fibers.

---

### Phase SL-10 – Build System & Runtime Selection

**Objective:** Allow scripting engine selection via `package.json` and compile flags.

**package.json:**
```json
{
  "engine": "rgss",
  "scripting": "quickjs"
}
```

**Compile flags:**
```
-d:withMQuickJS              (opt-in, adds mquickjs)
-d:scriptingEngine=lua54     (swap default to Lua 5.4)
-d:scriptingEngine=mruby     (swap default to mruby)
```

**rwebview.nim orchestration:**

```nim
when defined(withMQuickJS):
  import rgss/rgss_mquickjs

# Default is always QuickJS; "interpreter" in package.json selects at runtime:
case interpreterName
of "mquickjs":
  when defined(withMQuickJS):
    gScriptEngine = newMQuickJSEngine()
  else:
    quit("mquickjs not compiled in")
of "lua54":
  when defined(scriptingEngineLua54):
    gScriptEngine = newLua54Engine()
else:
  gScriptEngine = newQuickJSEngine()
```

**build.bat** will need additional build options for scripting engine selection.

---

## 5. Critical Challenges

### 5.1 Fundamental Ownership/GC Model Differences

| Engine      | GC Model                     | Consequences for ScriptValue                             |
|-------------|------------------------------|----------------------------------------------------------|
| QuickJS     | Ref-count + mark-sweep       | Explicit `dupValue`/`freeValue` required                 |
| QuickJS     | Ref-count + mark-sweep       | Same as QuickJS                                          |
| Lua 5.4     | Incremental mark-sweep       | Values on stack; need `luaL_ref` for long-term storage   |
| mruby       | Stop-the-world mark-sweep    | `mrb_gc_protect` to prevent premature collection         |
| MicroPython | Hybrid ref-count + GC        | Requires `mp_obj_t` pinning                              |

**Recommendation:** `ScriptValue` must always be "owned" (already dup'd/ref'd). Convention: no "borrowed" ScriptValue. Every proc receiving a ScriptValue does not take ownership unless the name explicitly contains "steal" or "take".

### 5.2 Thread Safety

Some engines are not thread-safe:
- **mruby**: A single `mrb_state` must not be accessed from two threads
- **MicroPython**: GIL analog (no concurrent access)
- **QuickJS**: A single `JSContext` is not thread-safe; `JSRuntime` can have multiple contexts in different threads

**Impact on audio thread:** `rwebview_audio.nim` has a decode thread that fires `onended` callbacks into the scripting engine. For thread-unsafe engines, callbacks must not be invoked directly from the decode thread – they must be posted to the main thread's event queue.

**Solution:** Create a `pendingCallbacks: Channel[CallbackEvent]` at engine level. Decode thread only pushes to channel; main loop in `rwebview_run_step` drains channel and invokes callbacks.

### 5.3 TypedArray / ArrayBuffer

`gl.texImage2D`, `gl.bufferData`, `decodeAudioData`, and XHR binary responses all require `ArrayBuffer`/`TypedArray`. These are native JavaScript constructs.

For Lua and Ruby:
- No native TypedArray
- `ScriptEngine.newArrayBuffer` can return `ScriptValue` containing a pointer to Nim-owned memory
- GL and Audio bindings must be able to accept `pointer + len` directly (bypass ScriptValue for data blobs)
- `getArrayBufferData` in the vtable; for non-JS engines, this returns interior pointer to Nim allocation

**Recommendation:** For Lua/Ruby, binary data is represented as Lua strings or Ruby `String` objects (both can contain binary data). `gl.texImage2D` in the adaptor extracts raw bytes via `lua_tolstring` / `mrb_string_value_ptr`.

### 5.4 Callback Signature Convention

Each engine has a different callback convention:

- **QuickJS**: `proc(ctx: ptr JSContext, this: JSValue, argc: cint, argv: ptr JSValue): JSValue`
- **Lua**: `proc(L: ptr lua_State): cint` (return value = number of return values on stack)
- **mruby**: `proc(mrb: ptr mrb_state, self: mrb_value): mrb_value`

`rgss_api.nim` defines the unified `ScriptNativeProc`. Each adaptor must create a **C-level thunk** that:
1. Takes native arguments from the engine
2. Converts them to `openArray[ScriptValue]`
3. Calls `ScriptNativeProc`
4. Converts the return `ScriptValue` back to native representation

The thunk must be able to store a closure (pointer to proc + user data) – for QuickJS use the `magic` slot, for Lua use an upvalue, for mruby use `mrb_define_method_raw`.

### 5.5 `this` / Method Context

- **JavaScript**: `this` is the receiver object passed to every method call
- **Lua**: No implicit `self`; OOP convention via table + colon syntax (`obj:method()` → `method(obj, ...)`)
- **mruby**: `self` exists explicitly in Ruby

The `ScriptNativeProc` signature includes `this: ScriptValue` – for Lua, this will be `args[0]` re-passed by the thunk (the first argument from a colon call).

### 5.6 Promises and Async

`fetch`, `decodeAudioData`, and XHR are all Promise-based in JS. For non-JS engines:

- **Lua**: Use Lua 5.4 Coroutines – `fetch` yields the coroutine, IO completes, resume with result
- **mruby**: Use mruby Fiber (`Fiber.yield` / `Fiber.resume`)

This is a non-trivial architectural change for the XHR module. Recommendation: for the first Lua/mruby iteration, make `fetch` **blocking** (synchronous). Async implementation via coroutines can follow once proof-of-concept is complete.

### 5.7 DOM Preamble and Script Loading

`dom_preamble.js` (a JavaScript file) is currently injected into QuickJS before the game loads. This is not relevant for non-JS engines.

**Per-engine solution:**
- **JS engines**: Continue injecting `dom_preamble.js`
- **Lua**: Create `dom_preamble.lua` – similar, but exposes `window`, `document`, `navigator` as Lua tables
- **mruby**: Create `dom_preamble.rb` – exposes as module/class

`rwebview_html.nim`, which currently parses HTML and extracts `<script>` tags, needs to be extended to determine script type: `<script type="text/javascript">` vs `<script type="text/lua">` vs `<script type="text/ruby">` – or via file extension convention.

---

## 6. Web API Mapping for Non-JS Languages

This is one of the most compelling features of the new architecture. Ruby and Python developers can call Web APIs as though writing a web app.

### 6.1 DOM Access

| Web JS                              | Lua equivalent                         | Ruby (mruby) equivalent              |
|-------------------------------------|----------------------------------------|--------------------------------------|
| `document.getElementById("id")`     | `document:get_element_by_id("id")`     | `document.get_element_by_id("id")`   |
| `document.createElement("canvas")`  | `document:create_element("canvas")`    | `document.create_element("canvas")`  |
| `el.style.width = "100px"`          | `el.style.width = "100px"`             | `el.style.width = "100px"`           |
| `el.addEventListener("click", fn)`  | `el:add_event_listener("click", fn)`   | `el.add_event_listener("click", fn)` |

### 6.2 Fetch API

```lua
-- Lua (blocking fetch)
local json = fetch("data/actors.json")
local data = JSON.decode(json)
```

```ruby
# mruby (blocking fetch)
data = JSON.parse(fetch("data/actors.json"))
```

```python
# MicroPython (blocking fetch)
import json
data = json.loads(fetch("data/actors.json"))
```

### 6.3 Canvas 2D

```lua
-- Lua
local canvas = document:get_element_by_id("canvas")
local ctx = canvas:get_context("2d")
ctx:fill_rect(0, 0, 800, 600)
ctx:draw_image(img, x, y)
```

### 6.4 Web Audio

```ruby
# mruby
ctx = AudioContext.new
source = ctx.create_buffer_source
source.buffer = ctx.decode_audio_data(File.read("audio/bgm.ogg"))
source.connect(ctx.destination)
source.start(0)
```

---

## 7. Interpreter Target Priorities

Implementation order based on impact and feasibility:

| Priority | Engine           | Reason                                                                                  | Difficulty |
|----------|------------------|-----------------------------------------------------------------------------------------|------------|
| 1        | QuickJS          | Already exists; this is a refactor, not a new feature — **COMPLETED** ✓                 | Medium     |
| 2        | QuickJS (Bellard)| API ~95% identical; easy switch once abstraction is complete                            | Low        |
| 3        | Lua 5.4          | Minimal, embeddable, popular for games; LÖVE2D has proven this approach                | Medium     |
| 4        | mruby            | RPG Maker XP/VX/Ace uses Ruby; RGSS compatibility via mruby is extremely valuable       | High       |
| 5        | MicroPython      | Python is familiar to many developers; popular for educational games                    | High       |
| 6        | Wren             | Lightweight scripting language popular for games                                        | Medium     |

---

## 8. Backend Selection: Compile-Time and Runtime Strategies

### 8.1 Current State (March 29, 2026)

**Compile-time (Hardcoded):**
- QuickJS is the only interpreter compiled into binaries
- [rwebview.nim:650](libs/rwebview/rwebview.nim#L650) hardcodes: `gScriptEngine = newQuickJSEngine()`
- No compiler flags exist for choosing alternative backends

**Runtime (Unused):**
- `package.json` has an `"interpreter"` field (e.g., `"interpreter": "mquickjs"`)
- This field is currently **never read** by the Nim code
- [src/rover.nim:858](src/rover.nim#L858) hardcodes: `"interpreter": "quickjs"` in default config
- Runtime selection logic does not exist

**Architecture Assessment:**
The vtable-based `ScriptEngine` abstraction is **fully prepared** to support backend selection. The issue is not architectural capability — it's implementation.

---

### 8.2 Compile-Time Backend Selection

**Question:** Can different backends be selected at compile-time?

**Answer:** ✅ **YES — Low effort, perfectly feasible**

**How it works:**

1. When compiling Rover, pass a compiler flag:
   ```powershell
   nim c -d:withMQuickJS src/rover.nim     # MicroQuickJS backend
   nim c -d:withLua54 src/rover.nim        # Lua 5.4 backend
   nim c src/rover.nim                     # Default: QuickJS
   ```

2. In `rwebview.nim`, guard each backend:
   ```nim
   when defined(withMQuickJS):
     import rgss/rgss_mquickjs
   
   when defined(withLua54):
     import rgss/rgss_lua54
   
   import rgss/rgss_quickjs  # Always available
   ```

3. At initialization, create the appropriate engine:
   ```nim
   # Select backend based on config.interpreter
   let engineFunc = case config.interpreter
     of "mquickjs":
       when defined(withMQuickJS): newMQuickJSEngine
       else: quit("mquickjs not compiled — rebuild with -d:withMQuickJS")
     of "lua54":
       when defined(withLua54): newLua54Engine
       else: quit("lua54 not compiled — rebuild with -d:withLua54")
     else: newQuickJSEngine
   
   gScriptEngine = engineFunc()
   ```

**Pros:**
- Zero runtime overhead when a backend is not compiled
- Binary size only includes selected interpreters
- Each backend can be tested independently
- Matches standard practice (e.g., SQLite compile-time options)

**Cons:**
- Requires recompilation to switch interpreters
- Not practical for distributing a single universal binary

**Effort estimate:** ~100 lines of Nim consolidation (guard statements, runtime selection logic)

---

### 8.3 Runtime Backend Selection via package.json

**Question:** Can backends be hot-swapped at runtime without recompilation?

**Answer:** ⚠️ **PARTIAL — YES, but all backends must be compiled-in**

**Constraint:** Each binary binds one set of interpreter libraries at link-time.

**How it works:**

1. **All desired backends must be compiled into the binary.** Example:
   ```powershell
   nim c -d:withMQuickJS -d:withLua54 -d:withMRuby src/rover.nim
   ```

   This produces one `rover.exe` containing QuickJS, mquickjs, Lua, and mruby.

2. **At runtime, read the `interpreter` field from `package.json`:**
   ```json
   {
     "engine": "rgss",
     "interpreter": "mquickjs"
   }
   ```

3. **Select the engine at run-time:**
   ```nim
   proc loadRgssConfig(pkgPath: string): tuple[engine, interpreter: string] =
     let pkg = parseFile(pkgPath / "package.json")
     return (
       pkg{"engine"}.getStr("native"),
       pkg{"interpreter"}.getStr("quickjs")
     )
   
   proc initScriptEngine(interpreterName: string) =
     gScriptEngine = case interpreterName
       of "mquickjs":
         when defined(withMQuickJS): newMQuickJSEngine()
         else: newQuickJSEngine()  # Fallback if not compiled
       of "lua54":
         when defined(withLua54): newLua54Engine()
         else: newQuickJSEngine()
       else: newQuickJSEngine()
   ```

4. **Call at startup:**
   ```nim
   let (engine, interp) = loadRgssConfig(gameDir)
   initScriptEngine(interp)
   ```

**Pros:**
- No recompilation needed to switch engines
- Users can experiment with multiple interpreters
- `package.json` becomes a runtime configuration file

**Cons:**
- Every interpreter must be linked into every binary → larger executables
- Build system complexity increases (must compile all variants or none)
- Higher chance of library conflicts (multiple JS engine symbols, etc.)

**Effort estimate:** ~150 lines (config reading, engine dispatch logic, fallback handling)

---

### 8.4 Multi-Interpreter Coexistence at Runtime

**Question:** Can Ruby AND JavaScript run simultaneously in the same Rover window?

**Answer:** ✅ **YES — But requires careful multi-instance design**

**Architecture:**

Currently, `gScriptEngine` is a **global singleton**. To support multiple interpreters in parallel:

1. **Maintain separate engine instances:**
   ```nim
   var gQuickJSEngine: ScriptEngine
   var gLuaEngine: ScriptEngine
   var gMRubyEngine: ScriptEngine
   ```

2. **Assign interpreter per context:**
   ```nim
   type ScriptCtx_Extended = object
     interpreterName*: string  # "quickjs", "lua", "mruby"
     engine*: ptr ScriptEngine
     # ... other fields
   ```

3. **Route calls through the correct engine:**
   ```nim
   proc eval(ctx: ptr ScriptCtx; code: string): ScriptValue =
     # Dispatches to ctx.engine.eval — which engine was assigned
     ctx.engine.eval(ctx, code.cstring, "script".cstring)
   ```

4. **Managing separate contexts:** The existing architecture already supports this:
   ```nim
   let ctxQJS = gQuickJSEngine.newCtx()    # QuickJS context
   let ctxLua = gLuaEngine.newCtx()        # Lua context
   
   var result1 = ctxQJS.eval("var x = 5")           # JS
   var result2 = ctxLua.eval("x = 5")               # Lua
   ```

5. **Exposing multiple global objects:**
   ```nim
   # In main script context (JavaScript):
   ctxQJS.eval("""
     window.ruby = {
       eval: function(src) { /* bridge to Lua */ }
     };
   """)
   
   # Then in JS: ruby.eval("puts 'Hello from Ruby'")
   ```

**Architectural requirements:**

- ✅ Already met by vtable design — each `ScriptCtx` has an `engine` pointer
- ✅ Already met by web API design — all bindings work with `ScriptCtx` (engine-agnostic)
- ⚠️ **Needs implementation:** Thread-safety primitives for simultaneous engine access
- ⚠️ **Needs implementation:** Inter-engine communication (JS calls Lua, Lua calls Ruby, etc.)

**Timeline complexity:**

| Feature                          | Difficulty | Prerequisite             |
|----------------------------------|------------|--------------------------|
| Single engine at a time          | ✅ Done    | —                        |
| Two engines with separate contexts | Low       | Thread-safe engine init  |
| JS calling Lua via bridge        | Medium     | JS-Lua FFI layer         |
| Lua calling Ruby via bridge      | Medium     | Lua-Ruby FFI layer       |
| Full bidirectional calling       | High       | All three layers         |

**Effort estimate:**
- Multi-instance engine: ~200 lines
- Thread safety for mruby/Lua: ~300 lines per engine
- JS ↔ Lua bridge: ~500 lines
- Full bidirectional bridges: ~1500 lines total

**Best use case:** Not recommended for typical Rover games. Potentially useful for:
- Polyglot frameworks (e.g., "write UI in Lua, game logic in JS")
- Educational platforms (e.g., teach multiple languages in same environment)
- Legacy game porting (e.g., RPG Maker VX Ace Ruby game with JS extensions)

---

### 8.5 Recommended Phasing

For practical adoption:

**Phase 1 (Immediate):** Keep QuickJS as the only compiled backend.
- Zero complexity
- Proven stable through 8+ phases of migration
- No maintenance burden

**Phase 2 (When needed):** Implement **compile-time selection** (e.g., `-d:withLua54`)
- Add Lua 5.4 as an alternative
- Update `build.bat` with a new menu option: "Build with Lua5.4"
- Test independently (no cross-engine testing yet)
- ~300 lines of Nim + ~800 lines of Lua adaptor

**Phase 3 (Optional):** Enable **runtime selection** in a multi-backend binary
- Recompile `build.bat` option to include multiple `-d:withXxx` flags
- Read `package.json` `"interpreter"` field at startup
- ~150 lines additional Nim
- Game developers can now run `package.json` with `"interpreter": "lua54"` instead of changing build system

**Phase 4 (Advanced, if ever requested):** Multi-interpreter coexistence
- Separate engine initialization for each language
- Create inter-engine FFI bridge (JS ↔ Lua)
- Only justified if a specific game requires it

---

## Implementation Notes for AI

- **Do not modify `src/rover.nim` or `src/webview.nim`.** The C ABI contract (`webview_*`) remains unchanged.
- **Phase SL-0 and SL-1 are complete.** `rgss/rgss_api.nim` and `rgss/rgss_quickjs.nim` exist and compile clean. Do not redo them.
- **Migrate modules one at a time**, starting from the simplest (`rwebview_storage.nim`).
- **Run RPG Maker MV test after each phase** to ensure no regressions.
- **Naming convention:** files in `rgss/` use the prefix `rgss_`. Abstract types in `rgss_api.nim` must not depend on any specific engine.
- **No heap allocation for ScriptValue** — must be stack-allocatable. Size of 16 bytes (two uint64) is sufficient for JSValue and mrb_value.
- **Thread safety** is the primary concern for `rwebview_audio.nim` — implement `pendingCallbacks` channel before migrating the audio module.
- **`{.compile:}` pragma requires string literals** — cannot use runtime `const` with `/` operator. Always use literal relative paths: `{.compile: "rgss_qjs_thunk.c".}`.
- **Single `type` block requirement** — Nim does not allow forward declarations for object types that reference each other. All mutually-referencing types (`ScriptValue`, `ScriptCtx`, `ScriptNativeProc`, `ScriptEngine`) must be declared in one `type` block.
