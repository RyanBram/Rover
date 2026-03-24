# ===========================================================================
# Phase 7 — Web Audio API (AudioContext, decodeAudioData, software mixer)
# ===========================================================================
#
# Included by rwebview.nim after rwebview_xhr.nim.
# Depends on: rwebview_ffi_sdl3_media (SDL3 Audio, SDL_sound),
#             rwebview_ffi_quickjs (JS helpers), rwebview_dom (gState)
#
# Architecture:
#   • Global AudioMixer holds decoded buffers, active sources, gain entries.
#   • Per-frame mixAudioFrame() called from the main loop mixes all active
#     sources into a stereo float32 buffer and pushes it to the SDL audio
#     stream.
#   • JS-level AudioContext / AudioBufferSourceNode / GainNode are thin
#     wrappers that call native helpers to register sources and set gains.

const AUDIO_SAMPLE_RATE = 44100
const AUDIO_CHANNELS    = 2
const MIX_BUFFER_FRAMES = 1024  # Per-push chunk size (samples per channel)
# Target maximum bytes kept in the SDL audio stream = 4 × chunk.
# At 44100 Hz stereo float32 (8 bytes/frame): 4 × 1024 × 8 = 32768 bytes ≈ 93 ms.
# The larger buffer absorbs frame-rate jitter and prevents audio underruns
# (crackling) during frame drops while keeping SE latency acceptable (~4 frames).
const MIX_QUEUE_MAX_BYTES = cint(MIX_BUFFER_FRAMES * 2 * sizeof(float32).int * 4)

# ===========================================================================
# Mixer data structures
# ===========================================================================

type
  AudioBufferEntry = object
    channels: seq[seq[float32]]  # Per-channel deinterleaved PCM
    sampleRate: int
    length: int                  # Samples per channel

  AudioSourceState = object
    bufferId:     int
    position:     float64        # Current sample offset (float for playbackRate)
    gainId:       int            # Index into gains[]
    playbackRate: float32
    loop:         bool
    loopStart:    int            # In samples
    loopEnd:      int            # In samples (0 = end of buffer)
    playing:      bool
    onendedCb:    JSValue        # DupValue'd JS callback
    onendedThis:  JSValue        # DupValue'd JS object

  AudioMixer = object
    device:       SDL_AudioDeviceID
    stream:       ptr SDL_AudioStream
    sampleRate:   int
    buffers:      seq[AudioBufferEntry]
    sources:      seq[AudioSourceState]
    gains:        seq[float32]   # Indexed by gainId
    currentTime:  float64        # Seconds since init
    initialized:  bool
    soundInited:  bool
    mixBuf:       seq[float32]   # Reusable stereo interleaved mix buffer

var audioMixer: AudioMixer

# ===========================================================================
# Mixer initialization
# ===========================================================================

proc initAudioMixer(): bool =
  if audioMixer.initialized: return true

  # Init SDL_sound for format decoding
  if Sound_Init() == 0:
    stderr.writeLine("[rwebview] Sound_Init failed")
  else:
    audioMixer.soundInited = true

  # Open default playback device with stereo float32
  var spec: SDL_AudioSpec
  spec.format   = SDL_AUDIO_F32
  spec.channels = AUDIO_CHANNELS.cint
  spec.freq     = AUDIO_SAMPLE_RATE.cint

  audioMixer.device = SDL_OpenAudioDevice(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, addr spec)
  if audioMixer.device == 0:
    stderr.writeLine("[rwebview] SDL_OpenAudioDevice failed: " & $SDL_GetError())
    return false

  # Create audio stream matching our mix format → device format
  var srcSpec: SDL_AudioSpec
  srcSpec.format   = SDL_AUDIO_F32
  srcSpec.channels = AUDIO_CHANNELS.cint
  srcSpec.freq     = AUDIO_SAMPLE_RATE.cint

  audioMixer.stream = SDL_CreateAudioStream(addr srcSpec, addr spec)
  if audioMixer.stream == nil:
    stderr.writeLine("[rwebview] SDL_CreateAudioStream failed: " & $SDL_GetError())
    SDL_CloseAudioDevice(audioMixer.device)
    return false

  if not SDL_BindAudioStream(audioMixer.device, audioMixer.stream):
    stderr.writeLine("[rwebview] SDL_BindAudioStream failed: " & $SDL_GetError())

  discard SDL_ResumeAudioDevice(audioMixer.device)

  audioMixer.sampleRate  = AUDIO_SAMPLE_RATE
  audioMixer.currentTime = 0.0
  audioMixer.initialized = true
  audioMixer.mixBuf      = newSeq[float32](MIX_BUFFER_FRAMES * AUDIO_CHANNELS)

  # Gain slot 0 = master gain (always 1.0)
  audioMixer.gains = @[1.0'f32]

  stderr.writeLine("[rwebview] Audio mixer initialized: " & $AUDIO_SAMPLE_RATE & " Hz stereo")
  true

# ===========================================================================
# Per-frame software mixer
# ===========================================================================

proc mixAudioFrame*() =
  ## Called once per frame from the main event loop.
  ## Mixes all active sources and pushes audio to the SDL stream.
  ## Pushes multiple chunks per call if the queue is low, absorbing frame jitter.
  if not audioMixer.initialized: return

  let frameSamples = MIX_BUFFER_FRAMES
  let bufLen = frameSamples * AUDIO_CHANNELS
  let chunkBytes = cint(bufLen * sizeof(float32).int)

  # Mix up to 3 chunks per call to keep the queue filled.
  # This absorbs frame-rate jitter — if a frame takes 32ms instead of 16ms,
  # we push 2 chunks to catch up rather than letting the queue underrun.
  for chunkPass in 0..2:
    let queued = SDL_GetAudioStreamQueued(audioMixer.stream)
    if queued >= MIX_QUEUE_MAX_BYTES: break

    # Zero the mix buffer
    for i in 0..<bufLen:
      audioMixer.mixBuf[i] = 0.0'f32

    var anyActive = false

    for idx in 0..<audioMixer.sources.len:
      template src: untyped = audioMixer.sources[idx]
      if not src.playing: continue
      if src.bufferId < 0 or src.bufferId >= audioMixer.buffers.len: continue

      let buf = addr audioMixer.buffers[src.bufferId]
      if buf.length == 0: continue

      let gain =
        if src.gainId >= 0 and src.gainId < audioMixer.gains.len:
          audioMixer.gains[src.gainId]
        else: 1.0'f32

      anyActive = true
      let loopEnd = if src.loopEnd > 0: src.loopEnd else: buf.length

      for i in 0..<frameSamples:
        let pos = int(src.position)
        if pos >= loopEnd:
          if src.loop:
            src.position = float64(src.loopStart)
            continue
          else:
            src.playing = false
            break

        let leftSample  = if buf.channels.len > 0 and pos < buf.channels[0].len: buf.channels[0][pos] else: 0.0'f32
        let rightSample = if buf.channels.len > 1 and pos < buf.channels[1].len: buf.channels[1][pos] else: leftSample

        audioMixer.mixBuf[i * 2]     += leftSample * gain
        audioMixer.mixBuf[i * 2 + 1] += rightSample * gain
        src.position += float64(src.playbackRate)

    # Push mixed audio data to the SDL stream
    if anyActive:
      discard SDL_PutAudioStreamData(audioMixer.stream,
                                     addr audioMixer.mixBuf[0], chunkBytes)

    audioMixer.currentTime += float64(frameSamples) / float64(audioMixer.sampleRate)

  # Fire onended for stopped sources (outside mix loop — once per frame)
  let state = gState
  if state != nil:
    for idx in 0..<audioMixer.sources.len:
      template src: untyped = audioMixer.sources[idx]
      if not src.playing and rw_JS_VALUE_GET_TAG(src.onendedCb) != 0:
        # Tag != JS_TAG_UNDEFINED (0 is undefined tag — need exact check)
        if JS_IsFunction(state.jsCtx, src.onendedCb) != 0:
          let r = JS_Call(state.jsCtx, src.onendedCb, src.onendedThis, 0, nil)
          discard jsCheck(state.jsCtx, r, "onended")
          rw_JS_FreeValue(state.jsCtx, src.onendedCb)
          rw_JS_FreeValue(state.jsCtx, src.onendedThis)
          src.onendedCb  = rw_JS_Undefined()
          src.onendedThis = rw_JS_Undefined()

# ===========================================================================
# Native JS callbacks
# ===========================================================================

proc jsAudioInit(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_init() → sampleRate (int) or 0 on failure
  if initAudioMixer():
    rw_JS_NewInt32(ctx, int32(audioMixer.sampleRate))
  else:
    rw_JS_NewInt32(ctx, 0)

proc jsAudioDecode(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_decode(arrayBuffer, ext) → { __bufferId, duration, sampleRate, numberOfChannels, length }
  ## Decodes audio data from an ArrayBuffer using SDL_sound.
  if argc < 1: return rw_JS_Null()

  let abVal = cast[ptr JSValue](argv)[]
  var abSize: csize_t
  let abPtr = JS_GetArrayBuffer(ctx, addr abSize, abVal)
  if abPtr == nil or abSize == 0:
    stderr.writeLine("[rwebview] decodeAudioData: invalid ArrayBuffer")
    return rw_JS_Null()

  # Get optional extension hint — only use if arg is actually a string,
  # not null/undefined (passing "null" as ext causes SDL_sound to fail).
  var extBuf: string
  var ext: cstring = nil
  if argc >= 2:
    let extTag = rw_JS_VALUE_GET_TAG(arg(argv, 1))
    if extTag != JS_TAG_NULL_C and extTag != JS_TAG_UNDEFINED_C:
      extBuf = argStr(ctx, argv, 1)
      if extBuf.len > 0:
        ext = cstring(extBuf)

  # Desired output: stereo float32 at our mix rate
  var desired: SDL_AudioSpec
  desired.format   = SDL_AUDIO_F32
  desired.channels = AUDIO_CHANNELS.cint
  desired.freq     = AUDIO_SAMPLE_RATE.cint

  stderr.writeLine("[rwebview] decodeAudioData: size=" & $abSize &
                   " ext=" & (if ext != nil: $ext else: "(auto-detect)"))
  let sample = Sound_NewSampleFromMem(abPtr, uint32(abSize), ext,
                                       addr desired, 65536)
  if sample == nil:
    stderr.writeLine("[rwebview] Sound_NewSampleFromMem failed (size=" & $abSize & ")")
    return rw_JS_Null()

  # Decode all data
  let decodedBytes = Sound_DecodeAll(sample)
  if decodedBytes == 0:
    stderr.writeLine("[rwebview] Sound_DecodeAll returned 0 bytes")
    Sound_FreeSample(sample)
    return rw_JS_Null()

  let actualChannels = int(sample.actual.channels)
  let actualRate     = int(sample.actual.freq)
  let bytesPerSample = 4  # float32
  let totalSamples   = int(decodedBytes) div (bytesPerSample * actualChannels)
  let srcPtr         = cast[ptr UncheckedArray[float32]](sample.buffer)

  # Deinterleave into per-channel seq[float32]
  var entry: AudioBufferEntry
  entry.sampleRate = actualRate
  entry.length     = totalSamples
  entry.channels   = newSeq[seq[float32]](actualChannels)
  for ch in 0..<actualChannels:
    entry.channels[ch] = newSeq[float32](totalSamples)
  for i in 0..<totalSamples:
    for ch in 0..<actualChannels:
      entry.channels[ch][i] = srcPtr[i * actualChannels + ch]

  Sound_FreeSample(sample)

  let bufferId = audioMixer.buffers.len
  audioMixer.buffers.add(entry)

  let duration = float64(totalSamples) / float64(actualRate)

  # Build JS result object
  let res = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, res, "__bufferId",
                            rw_JS_NewInt32(ctx, int32(bufferId)))
  discard JS_SetPropertyStr(ctx, res, "duration",
                            rw_JS_NewFloat64(ctx, duration))
  discard JS_SetPropertyStr(ctx, res, "sampleRate",
                            rw_JS_NewInt32(ctx, int32(actualRate)))
  discard JS_SetPropertyStr(ctx, res, "numberOfChannels",
                            rw_JS_NewInt32(ctx, int32(actualChannels)))
  discard JS_SetPropertyStr(ctx, res, "length",
                            rw_JS_NewInt32(ctx, int32(totalSamples)))
  res

proc jsAudioGetChannelData(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_getChannelData(bufferId, channel) → Float32Array
  if argc < 2: return rw_JS_Null()
  var bufferId, channel: int32
  discard JS_ToInt32(ctx, addr bufferId, cast[ptr JSValue](argv)[])
  discard JS_ToInt32(ctx, addr channel,
                     cast[ptr JSValue](cast[uint](argv) + uint(sizeof(JSValue)))[])

  if bufferId < 0 or bufferId >= int32(audioMixer.buffers.len):
    return rw_JS_Null()
  let buf = addr audioMixer.buffers[bufferId]
  if channel < 0 or channel >= int32(buf.channels.len):
    return rw_JS_Null()

  let chData = addr buf.channels[channel]
  let byteLen = csize_t(chData[].len * sizeof(float32))

  # Create ArrayBuffer from channel data
  let ab = rw_JS_NewArrayBufferCopy(ctx,
             cast[pointer](addr chData[][0]), byteLen)

  # Create Float32Array from ArrayBuffer (must use constructor call)
  let global  = JS_GetGlobalObject(ctx)
  let f32Ctor = JS_GetPropertyStr(ctx, global, "Float32Array")
  var abArg = ab
  let f32Arr = JS_CallConstructor(ctx, f32Ctor, 1, addr abArg)
  rw_JS_FreeValue(ctx, ab)
  rw_JS_FreeValue(ctx, f32Ctor)
  rw_JS_FreeValue(ctx, global)
  f32Arr

proc jsAudioNewGain(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_newGain() → gainId (int)
  let gainId = audioMixer.gains.len
  audioMixer.gains.add(1.0'f32)
  rw_JS_NewInt32(ctx, int32(gainId))

proc jsAudioSetGain(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_setGain(gainId, value)
  if argc < 2: return rw_JS_Undefined()
  var gainId: int32
  discard JS_ToInt32(ctx, addr gainId, cast[ptr JSValue](argv)[])
  var value: float64
  discard JS_ToFloat64(ctx, addr value,
                       cast[ptr JSValue](cast[uint](argv) + uint(sizeof(JSValue)))[])
  if gainId >= 0 and gainId < int32(audioMixer.gains.len):
    audioMixer.gains[gainId] = float32(value)
  rw_JS_Undefined()

proc jsAudioSourceStart(ctx: ptr JSContext; thisVal: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_sourceStart(srcId, when, offsetSamples)
  if argc < 1: return rw_JS_Undefined()
  var srcId: int32
  discard JS_ToInt32(ctx, addr srcId, cast[ptr JSValue](argv)[])
  if srcId >= 0 and srcId < int32(audioMixer.sources.len):
    var offsetSamples: float64 = 0.0
    if argc >= 3:
      discard JS_ToFloat64(ctx, addr offsetSamples,
                           cast[ptr JSValue](cast[uint](argv) + 2'u * uint(sizeof(JSValue)))[])
    audioMixer.sources[srcId].position = offsetSamples
    audioMixer.sources[srcId].playing  = true
  rw_JS_Undefined()

proc jsAudioSourceStop(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_sourceStop(srcId)
  if argc < 1: return rw_JS_Undefined()
  var srcId: int32
  discard JS_ToInt32(ctx, addr srcId, cast[ptr JSValue](argv)[])
  if srcId >= 0 and srcId < int32(audioMixer.sources.len):
    audioMixer.sources[srcId].playing = false
  rw_JS_Undefined()

proc jsAudioSourceCreate(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_sourceCreate(bufferId, gainId, loop, playbackRate, loopStartSamples, loopEndSamples) → srcId
  if argc < 4: return rw_JS_NewInt32(ctx, -1)
  var bufferId, gainId: int32
  var loopInt: int32
  var rate: float64
  discard JS_ToInt32(ctx, addr bufferId, cast[ptr JSValue](argv)[])
  discard JS_ToInt32(ctx, addr gainId,
                     cast[ptr JSValue](cast[uint](argv) + 1'u * uint(sizeof(JSValue)))[])
  discard JS_ToInt32(ctx, addr loopInt,
                     cast[ptr JSValue](cast[uint](argv) + 2'u * uint(sizeof(JSValue)))[])
  discard JS_ToFloat64(ctx, addr rate,
                      cast[ptr JSValue](cast[uint](argv) + 3'u * uint(sizeof(JSValue)))[])

  var loopStartSamples: int32 = 0
  var loopEndSamples: int32 = 0
  if argc >= 5:
    discard JS_ToInt32(ctx, addr loopStartSamples,
                       cast[ptr JSValue](cast[uint](argv) + 4'u * uint(sizeof(JSValue)))[])
  if argc >= 6:
    discard JS_ToInt32(ctx, addr loopEndSamples,
                       cast[ptr JSValue](cast[uint](argv) + 5'u * uint(sizeof(JSValue)))[])

  var src: AudioSourceState
  src.bufferId     = int(bufferId)
  src.gainId       = int(gainId)
  src.loop         = loopInt != 0
  src.playbackRate = float32(rate)
  src.loopStart    = int(loopStartSamples)
  src.loopEnd      = int(loopEndSamples)
  src.playing      = false
  src.position     = 0.0
  src.onendedCb    = rw_JS_Undefined()
  src.onendedThis  = rw_JS_Undefined()

  let srcId = audioMixer.sources.len
  audioMixer.sources.add(src)
  rw_JS_NewInt32(ctx, int32(srcId))

proc jsAudioSourceSetOnended(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_sourceSetOnended(srcId, callback, thisObj)
  if argc < 3: return rw_JS_Undefined()
  var srcId: int32
  discard JS_ToInt32(ctx, addr srcId, cast[ptr JSValue](argv)[])
  if srcId >= 0 and srcId < int32(audioMixer.sources.len):
    let cb   = cast[ptr JSValue](cast[uint](argv) + 1'u * uint(sizeof(JSValue)))[]
    let this2 = cast[ptr JSValue](cast[uint](argv) + 2'u * uint(sizeof(JSValue)))[]
    audioMixer.sources[srcId].onendedCb  = rw_JS_DupValue(ctx, cb)
    audioMixer.sources[srcId].onendedThis = rw_JS_DupValue(ctx, this2)
  rw_JS_Undefined()

proc jsAudioSourceSetProp(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_sourceSetProp(srcId, propName, value)
  ## propName: "loop", "loopStart", "loopEnd", "playbackRate"
  if argc < 3: return rw_JS_Undefined()
  var srcId: int32
  discard JS_ToInt32(ctx, addr srcId, cast[ptr JSValue](argv)[])
  if srcId < 0 or srcId >= int32(audioMixer.sources.len):
    return rw_JS_Undefined()
  let prop = argStr(ctx, argv, 1)
  var fval: float64
  discard JS_ToFloat64(ctx, addr fval,
                       cast[ptr JSValue](cast[uint](argv) + 2'u * uint(sizeof(JSValue)))[])
  template src: untyped = audioMixer.sources[srcId]
  case prop
  of "loop": src.loop = fval != 0.0
  of "loopStart":
    let rate = if src.bufferId >= 0 and src.bufferId < audioMixer.buffers.len:
                 float64(audioMixer.buffers[src.bufferId].sampleRate)
               else: float64(AUDIO_SAMPLE_RATE)
    src.loopStart = int(fval * rate)
  of "loopEnd":
    let rate = if src.bufferId >= 0 and src.bufferId < audioMixer.buffers.len:
                 float64(audioMixer.buffers[src.bufferId].sampleRate)
               else: float64(AUDIO_SAMPLE_RATE)
    src.loopEnd = int(fval * rate)
  of "playbackRate": src.playbackRate = float32(fval)
  else: discard
  rw_JS_Undefined()

proc jsAudioGetCurrentTime(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  ## __rw_audio_getCurrentTime() → float64 seconds
  rw_JS_NewFloat64(ctx, audioMixer.currentTime)

# ===========================================================================
# bindAudio — install AudioContext + supporting classes into JS global
# ===========================================================================

proc bindAudio(state: ptr RWebviewState) =
  let ctx    = state.jsCtx
  let global = JS_GetGlobalObject(ctx)

  # Install native functions
  template setFn(name: string; fn: JSCFunction; arity: int) =
    let f = JS_NewCFunction(ctx, fn, cstring(name), cint(arity))
    discard JS_SetPropertyStr(ctx, global, cstring(name), f)

  setFn("__rw_audio_init",            cast[JSCFunction](jsAudioInit), 0)
  setFn("__rw_audio_decode",          cast[JSCFunction](jsAudioDecode), 2)
  setFn("__rw_audio_getChannelData",  cast[JSCFunction](jsAudioGetChannelData), 2)
  setFn("__rw_audio_newGain",         cast[JSCFunction](jsAudioNewGain), 0)
  setFn("__rw_audio_setGain",         cast[JSCFunction](jsAudioSetGain), 2)
  setFn("__rw_audio_sourceCreate",    cast[JSCFunction](jsAudioSourceCreate), 6)
  setFn("__rw_audio_sourceStart",     cast[JSCFunction](jsAudioSourceStart), 3)
  setFn("__rw_audio_sourceStop",      cast[JSCFunction](jsAudioSourceStop), 1)
  setFn("__rw_audio_sourceSetOnended",cast[JSCFunction](jsAudioSourceSetOnended), 3)
  setFn("__rw_audio_sourceSetProp",   cast[JSCFunction](jsAudioSourceSetProp), 3)
  setFn("__rw_audio_getCurrentTime",  cast[JSCFunction](jsAudioGetCurrentTime), 0)

  # JS-level classes: AudioContext, AudioBuffer, AudioBufferSourceNode, GainNode
  let audioJs = """
(function() {
  // ── AudioParam ──────────────────────────────────────────────────────
  function AudioParam(defaultValue, setter) {
    this._value = defaultValue;
    this._setter = setter;
  }
  Object.defineProperty(AudioParam.prototype, 'value', {
    get: function() { return this._value; },
    set: function(v) { this._value = v; if (this._setter) this._setter(v); }
  });
  AudioParam.prototype.setValueAtTime = function(v) { this.value = v; return this; };
  AudioParam.prototype.linearRampToValueAtTime = function(v) { this.value = v; return this; };
  AudioParam.prototype.exponentialRampToValueAtTime = function(v) { this.value = Math.max(v,0.0001); return this; };
  AudioParam.prototype.setTargetAtTime = function(v) { this.value = v; return this; };
  AudioParam.prototype.cancelScheduledValues = function() { return this; };

  // ── AudioBuffer ─────────────────────────────────────────────────────
  function AudioBuffer(info) {
    this.__bufferId = info.__bufferId;
    this.duration = info.duration;
    this.sampleRate = info.sampleRate;
    this.numberOfChannels = info.numberOfChannels;
    this.length = info.length;
  }
  AudioBuffer.prototype.getChannelData = function(ch) {
    return __rw_audio_getChannelData(this.__bufferId, ch);
  };
  AudioBuffer.prototype.copyFromChannel = function(dest, ch, startInChannel) {
    var src = this.getChannelData(ch);
    var off = startInChannel || 0;
    for (var i = 0; i < dest.length && (off+i) < src.length; i++) dest[i] = src[off+i];
  };

  // ── AudioDestinationNode ────────────────────────────────────────────
  function AudioDestinationNode() {
    this.numberOfInputs = 1;
    this.numberOfOutputs = 0;
    this.__isDestination = true;
  }
  AudioDestinationNode.prototype.connect = function() { return this; };
  AudioDestinationNode.prototype.disconnect = function() {};

  // ── GainNode ────────────────────────────────────────────────────────
  function GainNode(ctx) {
    this.context = ctx;
    this.__gainId = __rw_audio_newGain();
    var self = this;
    this.gain = new AudioParam(1.0, function(v) {
      __rw_audio_setGain(self.__gainId, v);
    });
    this.__output = null;
  }
  GainNode.prototype.connect = function(node) {
    this.__output = node;
    return node;
  };
  GainNode.prototype.disconnect = function() { this.__output = null; };

  // ── AudioBufferSourceNode ───────────────────────────────────────────
  function AudioBufferSourceNode(ctx) {
    this.context = ctx;
    this.buffer = null;
    this.loop = false;
    this.loopStart = 0;
    this.loopEnd = 0;
    this.__srcId = -1;
    this.__gainNode = null;
    this.onended = null;
    var self = this;
    this.playbackRate = new AudioParam(1.0, function(v) {
      if (self.__srcId >= 0) __rw_audio_sourceSetProp(self.__srcId, 'playbackRate', v);
    });
  }
  AudioBufferSourceNode.prototype.connect = function(node) {
    this.__gainNode = node;
    return node;
  };
  AudioBufferSourceNode.prototype.disconnect = function() { this.__gainNode = null; };
  AudioBufferSourceNode.prototype.start = function(when, offset, duration) {
    if (!this.buffer || this.buffer.__bufferId < 0) return;
    // Find effective gainId by walking the chain
    var gainId = 0; // master gain
    if (this.__gainNode && this.__gainNode.__gainId !== undefined) {
      gainId = this.__gainNode.__gainId;
    }
    var offsetSamples = Math.floor((offset || 0) * this.buffer.sampleRate);
    var loopStartSamples = Math.floor(this.loopStart * this.buffer.sampleRate);
    var loopEndSamples = this.loopEnd > 0 ? Math.floor(this.loopEnd * this.buffer.sampleRate) : 0;
    this.__srcId = __rw_audio_sourceCreate(
      this.buffer.__bufferId, gainId,
      this.loop ? 1 : 0, this.playbackRate.value,
      loopStartSamples, loopEndSamples
    );
    __rw_audio_sourceStart(this.__srcId, 0, offsetSamples);
    if (this.onended) {
      __rw_audio_sourceSetOnended(this.__srcId, this.onended, this);
    }
  };
  AudioBufferSourceNode.prototype.stop = function() {
    if (this.__srcId >= 0) {
      __rw_audio_sourceStop(this.__srcId);
    }
  };

  // ── AudioContext ────────────────────────────────────────────────────
  function AudioContext() {
    this.sampleRate = __rw_audio_init() || 44100;
    this.state = 'running';
    this.destination = new AudioDestinationNode();
  }
  Object.defineProperty(AudioContext.prototype, 'currentTime', {
    get: function() { return __rw_audio_getCurrentTime(); }
  });
  AudioContext.prototype.createBufferSource = function() {
    return new AudioBufferSourceNode(this);
  };
  AudioContext.prototype.createGain = function() {
    return new GainNode(this);
  };
  // ── PannerNode ──────────────────────────────────────────────────────
  // Spatial audio is not implemented; this is a transparent passthrough
  // needed so RPG Maker's sourceNode→gainNode→pannerNode→destination chain works.
  function PannerNode(ctx) {
    this.context = ctx;
    this.panningModel = 'equalpower';
    this.distanceModel = 'inverse';
    this._output = null;
  }
  PannerNode.prototype.connect = function(node) { this._output = node; return node; };
  PannerNode.prototype.disconnect = function() { this._output = null; };
  PannerNode.prototype.setPosition = function(x, y, z) {};
  PannerNode.prototype.setOrientation = function(x, y, z) {};
  AudioContext.prototype.createPanner = function() {
    return new PannerNode(this);
  };
  AudioContext.prototype.createBuffer = function(numChannels, length, sampleRate) {
    return new AudioBuffer({
      __bufferId: -1,
      duration: length / sampleRate,
      sampleRate: sampleRate,
      numberOfChannels: numChannels,
      length: length
    });
  };
  AudioContext.prototype.decodeAudioData = function(arrayBuffer, onSuccess, onError) {
    try {
      var info = __rw_audio_decode(arrayBuffer, null);
      if (info === null) {
        if (onError) onError(new Error('decodeAudioData failed'));
        return Promise.reject(new Error('decodeAudioData failed'));
      }
      var buf = new AudioBuffer(info);
      if (onSuccess) onSuccess(buf);
      return Promise.resolve(buf);
    } catch(e) {
      if (onError) onError(e);
      return Promise.reject(e);
    }
  };
  AudioContext.prototype.resume = function() {
    this.state = 'running';
    return Promise.resolve();
  };
  AudioContext.prototype.suspend = function() {
    this.state = 'suspended';
    return Promise.resolve();
  };
  AudioContext.prototype.close = function() {
    this.state = 'closed';
    return Promise.resolve();
  };
  AudioContext.prototype.createOscillator = function() {
    return { connect:function(){}, start:function(){}, stop:function(){},
             frequency: new AudioParam(440, function(){}),
             type: 'sine' };
  };
  AudioContext.prototype.createDynamicsCompressor = function() {
    return { connect:function(n){return n;}, disconnect:function(){},
             threshold: new AudioParam(-24, function(){}),
             knee: new AudioParam(30, function(){}),
             ratio: new AudioParam(12, function(){}),
             attack: new AudioParam(0.003, function(){}),
             release: new AudioParam(0.25, function(){}) };
  };

  window.AudioContext = AudioContext;
  window.webkitAudioContext = AudioContext;
  window.AudioBuffer = AudioBuffer;
  window.AudioBufferSourceNode = AudioBufferSourceNode;
  window.GainNode = GainNode;
})();
"""
  let r = JS_Eval(ctx, cstring(audioJs), csize_t(audioJs.len),
                  "<audio-setup>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, r, "<audio-setup>")

  # Copy window.* audio classes to the QuickJS global so bare names work
  let globalizeAudio = """
var AudioContext = window.AudioContext;
var webkitAudioContext = window.webkitAudioContext;
var AudioBuffer = window.AudioBuffer;
var AudioBufferSourceNode = window.AudioBufferSourceNode;
var GainNode = window.GainNode;
"""
  let r2 = JS_Eval(ctx, cstring(globalizeAudio), csize_t(globalizeAudio.len),
                   "<globalize-audio>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, r2, "<globalize-audio>")

  rw_JS_FreeValue(ctx, global)
