# =============================================================================
# rwebview_audio.nim
# Web Audio API (AudioContext, decodeAudioData, software mixer)
# =============================================================================
#
# Author    : Ryan Bramantya
# Copyright : Copyright (c) 2026 Ryan Bramantya
# License   : Apache License 2.0
# Website   : https://github.com/RyanBram/Rover
#
# -----------------------------------------------------------------------------
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied. See the License for the specific language governing
# permissions and limitations under the License.
#
# -----------------------------------------------------------------------------
#
# Description:
#   Web Audio API (AudioContext, decodeAudioData, software mixer).
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rwebview_ffi_sdl3_media  # SDL3 Audio, SDL_sound
#   - rgss_quickjs_ffi         # JS helpers
#   - rwebview_dom             # gState
#
# Used by:
#   - rwebview.nim             # included after rwebview_xhr.nim
#
# =============================================================================
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
# Target maximum bytes kept in the SDL audio stream = 12 × chunk.
# At 44100 Hz stereo float32 (8 bytes/frame): 12 × 1024 × 8 = 98304 bytes ≈ 280 ms.
# 280 ms absorbs worst-case scene transition stalls (200-400 ms) with
# comfortable margin. SE/SFX triggered in a normal 16 ms frame hear at most
# one extra chunk of latency (~23 ms) because the queue rarely sits at max.
const MIX_QUEUE_MAX_BYTES = cint(MIX_BUFFER_FRAMES * 2 * sizeof(float32).int * 12)

# ===========================================================================
# Mixer data structures
# ===========================================================================

type
  AudioBufferEntry = object
    channels: seq[seq[float32]]  # Per-channel deinterleaved PCM
    sampleRate: int
    length: int                  # Samples per channel (may grow when streaming=true)
    streaming: bool              # OPT-STREAMING: true = buffer grows incrementally
    streamComplete: bool         # OPT-STREAMING: all chunks received

  AudioSourceState = object
    bufferId:     int
    position:     float64        # Current sample offset (float for playbackRate)
    gainId:       int            # Index into gains[]
    pannerGainId: int            # Index into gains[] for PannerNode attenuation (-1 = none)
    playbackRate: float32
    loop:         bool
    loopStart:    int            # In samples
    loopEnd:      int            # In samples (0 = end of buffer)
    playing:      bool
    startAt:      float64        # AudioContext.currentTime to start; 0 = immediate
    stopPosition: int            # Sample position to auto-stop; 0 = no limit
    onendedCb:    ScriptValue    # DupValue'd callback
    onendedThis:  ScriptValue    # DupValue'd object

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

# ---------------------------------------------------------------------------
# Mixer thread infrastructure — runs independently from JS/main thread
# ---------------------------------------------------------------------------
var mixerThread: Thread[void]
var mixerLock: Lock            # Protects audioMixer.sources, .buffers, .gains, .currentTime
var mixerShutdown: bool = false
var mixerThreadStarted: bool = false
var endedSourceIds: seq[int]   # Source indices that finished playing (mixer→main)

# ===========================================================================
# Mixer initialization
# ===========================================================================

proc audioMixerThreadProc() {.thread.}  # Forward declaration

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

  # Start the dedicated mixer thread — runs independently from JS/main thread.
  initLock(mixerLock)
  mixerShutdown = false
  endedSourceIds = @[]
  createThread(mixerThread, audioMixerThreadProc)
  mixerThreadStarted = true

  stderr.writeLine("[rwebview] Audio mixer initialized: " & $AUDIO_SAMPLE_RATE & " Hz stereo (separate mixer thread)")
  true

# ===========================================================================
# Dedicated audio mixer thread — completely independent from JS stalls
# ===========================================================================
#
# This thread loops every ~5 ms, mixing all active sources and pushing
# audio data to the SDL stream.  Because it never touches JS values or
# waits for the main thread, audio playback continues smoothly even when
# the main thread is stalled by scene transitions (100-500 ms).
#
# Thread safety contract:
#   • mixerLock guards: audioMixer.sources, .buffers, .gains, .currentTime,
#     endedSourceIds
#   • Main thread (JS callbacks) acquires mixerLock when mutating sources/
#     buffers/gains.  Lock hold time is very short (<0.1 ms for a single
#     source create/start/stop).
#   • Mixer thread acquires mixerLock for one mix chunk (~0.3 ms at 1024
#     samples).  Main thread never blocks perceptibly.
#   • onended JS callbacks are NOT fired from the mixer thread.  Instead,
#     ended source indices are queued into endedSourceIds and picked up by
#     the main thread each frame via processAudioOnended().

proc audioMixerThreadProc() {.thread.} =
  ## Background thread that continuously mixes audio and feeds the SDL stream.
  {.cast(gcsafe).}:
    while true:
      # Check shutdown flag (no lock needed — single writer, relaxed read is fine)
      if mixerShutdown: break

      # Check if mixer is initialized
      if not audioMixer.initialized:
        sleep(5)
        continue

      let frameSamples = MIX_BUFFER_FRAMES
      let bufLen = frameSamples * AUDIO_CHANNELS
      let chunkBytes = cint(bufLen * sizeof(float32).int)

      # Check if the SDL stream needs more data
      let queued = SDL_GetAudioStreamQueued(audioMixer.stream)
      if queued >= MIX_QUEUE_MAX_BYTES:
        # Queue is full — sleep briefly and retry
        sleep(2)
        continue

      # Mix one chunk under lock
      acquire(mixerLock)

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
        let pannerGain =
          if src.pannerGainId >= 0 and src.pannerGainId < audioMixer.gains.len:
            audioMixer.gains[src.pannerGainId]
          else: 1.0'f32
        let effectiveGain = gain * pannerGain

        anyActive = true
        let loopEnd = if src.loopEnd > 0: src.loopEnd else: buf.length

        for i in 0..<frameSamples:
          let pos = int(src.position)

          # Scheduled start: skip if AudioContext.currentTime hasn't reached startAt
          if src.startAt > 0.0 and audioMixer.currentTime < src.startAt:
            break

          # Duration limit: auto-stop at stopPosition
          if src.stopPosition > 0 and pos >= src.stopPosition:
            src.playing = false
            endedSourceIds.add(idx)
            break

          if pos >= loopEnd:
            if src.loop:
              src.position = float64(src.loopStart)
              continue
            else:
              # If the buffer is still being decoded (progressive path), hold
              # position and wait for more data rather than stopping the source.
              if buf.streaming and not buf.streamComplete:
                # Watermark reached — more chunks are arriving from the worker.
                # Hold the last decoded sample; the mixer will retry in ~3ms.
                src.position = float64(loopEnd - 1)
                break  # Skip remainder of this source's mix pass
              src.playing = false
              endedSourceIds.add(idx)
              break

          let leftSample  = if buf.channels.len > 0 and pos < buf.channels[0].len: buf.channels[0][pos] else: 0.0'f32
          let rightSample = if buf.channels.len > 1 and pos < buf.channels[1].len: buf.channels[1][pos] else: leftSample

          audioMixer.mixBuf[i * 2]     += leftSample * effectiveGain
          audioMixer.mixBuf[i * 2 + 1] += rightSample * effectiveGain
          src.position += float64(src.playbackRate) * float64(buf.sampleRate) / float64(audioMixer.sampleRate)

      # Push mixed audio data to the SDL stream
      if anyActive:
        discard SDL_PutAudioStreamData(audioMixer.stream,
                                       addr audioMixer.mixBuf[0], chunkBytes)

      audioMixer.currentTime += float64(frameSamples) / float64(audioMixer.sampleRate)

      release(mixerLock)

      # Brief sleep to prevent busy-spinning (~5 ms = well within latency budget).
      # One mix chunk = 1024/44100 ≈ 23 ms of audio.  Sleeping 3 ms means we can
      # push ~7 chunks per 23 ms window, keeping the queue comfortably full.
      sleep(3)

proc stopMixerThread() =
  ## Stops the dedicated mixer thread.  Called before webview_destroy.
  if not mixerThreadStarted: return
  mixerShutdown = true
  joinThread(mixerThread)
  deinitLock(mixerLock)
  mixerThreadStarted = false
  stderr.writeLine("[rwebview] Mixer thread stopped")

proc processAudioOnended*(ctx: ptr ScriptCtx) =
  ## Called once per frame from the main loop.
  ## Fires onended callbacks for sources that the mixer thread detected
  ## as finished.  This keeps script execution on the main thread.
  if not mixerThreadStarted: return

  # Grab the ended-source list under lock
  var ended: seq[int]
  acquire(mixerLock)
  ended = move(endedSourceIds)
  endedSourceIds = @[]
  release(mixerLock)

  if ended.len == 0:
    # Even without ended sources, check for sources that were stopped from JS
    # (e.g. AudioStreaming.js calling sourceNode.stop()) — they also need onended.
    acquire(mixerLock)
    for idx in 0..<audioMixer.sources.len:
      template src: untyped = audioMixer.sources[idx]
      if not src.playing and ctx.isFunction(src.onendedCb):
        ended.add(idx)
    release(mixerLock)

  for idx in ended:
    if idx < 0 or idx >= audioMixer.sources.len: continue
    template src: untyped = audioMixer.sources[idx]
    if ctx.isFunction(src.onendedCb):
      let r = ctx.callFunction0(src.onendedCb, src.onendedThis)
      discard ctx.checkException(r, "onended")
      ctx.freeValue(src.onendedCb)
      ctx.freeValue(src.onendedThis)
      src.onendedCb  = ctx.newUndefined()
      src.onendedThis = ctx.newUndefined()

# ===========================================================================
# Async audio decode infrastructure
# ===========================================================================
#
# All audio decoding runs on a dedicated worker thread.  decodeAudioData()
# queues a StreamBufferRequest; the main loop calls processStreamBufferResults()
# each frame to pick up decoded chunks and resolve JS Promises.

type
  # ── Progressive decodeAudioData decode types ──
  StreamBufferRequest = object
    requestId: int
    data: ptr UncheckedArray[uint8]
    dataSize: int

  StreamBufferChunkResult = object
    requestId: int
    isFirst: bool               ## true = first chunk; create AudioBuffer + resolve Promise
    isComplete: bool            ## true = last chunk (may also be first for short files)
    isError: bool
    channels: seq[seq[float32]] ## deinterleaved chunk data (moved from worker)
    chunkSamples: int           ## samples per channel in this chunk
    totalOggSamples: int        ## full OGG duration in samples (from last-page granule), 0 = unknown
    numChannels: int
    sampleRate: int
    targetBufferId: int         ## -1 on first chunk, assigned by main thread; subsequent chunks use this

  # ── Streaming decode types (stbvorbis API — AudioStreaming.js) ──
  StreamDecodeRequest = object
    decoderId: int
    data: ptr UncheckedArray[uint8]  ## alloc'd copy of OGG data
    dataSize: int

  StreamDecodeChunkResult = object
    decoderId: int
    pcmData: ptr UncheckedArray[float32]  ## interleaved, alloc'd
    pcmBytes: int
    totalSamples: int   ## per channel
    numChannels: int
    sampleRate: int
    isEof: bool         ## true = all data decoded, no PCM
    isError: bool       ## true = decode error

  # ── Active streaming session (worker-private state) ──
  # Multiple sb streams are decoded round-robin so a large BGM never
  # delays a short BGS from resolving its first chunk.
  ActiveSbStream = object
    requestId:         int
    data:              ptr UncheckedArray[uint8]  ## owned; freed when stream completes
    sample:            ptr Sound_Sample
    isFirstChunk:      bool
    knownTotalSamples: int

var adThread: Thread[void]
var adLock: Lock
var sdRequests: seq[StreamDecodeRequest]    # stbvorbis streaming (guarded by adLock)
var sdResults: seq[StreamDecodeChunkResult] # stbvorbis chunks    (guarded by adLock)
var sbRequests: seq[StreamBufferRequest]    # progressive decode  (guarded by adLock)
var sbResults: seq[StreamBufferChunkResult] # progressive chunks  (guarded by adLock)
var adShutdown: bool = false
var adThreadStarted: bool = false

proc oggReadTotalSamples(data: ptr UncheckedArray[uint8]; dataSize: int): int =
  ## Scan the OGG bitstream backward to find the last page and return its
  ## granule position, which equals the total PCM sample count per channel.
  ## Scans at most 65536 bytes from the end — the last page is always there.
  ## Returns 0 if the value cannot be determined (not OGG, corrupt, etc.).
  if dataSize < 27: return 0
  # OGG page capture pattern
  const S0 = 0x4F'u8; const S1 = 0x67'u8; const S2 = 0x67'u8; const S3 = 0x53'u8
  let scanFrom = max(0, dataSize - 65536)
  var i = dataSize - 4
  while i >= scanFrom:
    if data[i] == S0 and data[i+1] == S1 and data[i+2] == S2 and data[i+3] == S3:
      # OGG page header: capture(4) + version(1) + type(1) + granule(8 LE) + ...
      if i + 13 < dataSize:
        # Read 8-byte little-endian granule position (bytes 6..13 relative to sync)
        var gran: int64 = 0
        for b in 0..7:
          gran = gran or (int64(data[i + 6 + b]) shl (b * 8))
        # granule = -1 (0xFFFFFFFFFFFFFFFF) means "not yet determined" in OGG spec
        if gran > 0 and gran != -1'i64:
          return int(gran)
    dec i
  return 0

proc audioDecodeWorker() {.thread.} =
  ## Background worker for two decode paths:
  ## 1. sbRequests (progressive decodeAudioData): decoded round-robin across all
  ##    active streams — one 64 KB chunk per stream per outer iteration.  A large
  ##    BGM (many chunks) never delays a short BGS (one chunk) from resolving its
  ##    first chunk and starting playback.
  ## 2. sdRequests (stbvorbis streaming — AudioStreaming.js): full inner loop.
  {.cast(gcsafe).}:
    const SB_CHUNK_BYTES = 65536'u32  # 64 KB → ~10 ms of audio at 44100 Hz stereo
    const outChannels    = AUDIO_CHANNELS
    const bytesPerSample = 4

    var activeStreams: seq[ActiveSbStream]  # persistent across outer iterations

    while true:
      var sdReq: StreamDecodeRequest
      var foundSd = false

      # ── Acquire lock: check shutdown, drain sbRequests, pick one sdReq ──
      acquire(adLock)
      if adShutdown:
        release(adLock)
        break

      # Drain ALL pending sbRequests into a local list (fast pointer copies only).
      var newSbReqs: seq[StreamBufferRequest]
      while sbRequests.len > 0:
        newSbReqs.add(sbRequests[0])
        sbRequests.delete(0)

      if sdRequests.len > 0:
        sdReq = sdRequests[0]
        sdRequests.delete(0)
        foundSd = true
      release(adLock)

      # ── Open new sb streams outside the lock (SDL_sound init + OGG scan) ──
      for req in newSbReqs:
        let knownTotal = oggReadTotalSamples(req.data, req.dataSize)
        var desired: SDL_AudioSpec
        desired.format   = SDL_AUDIO_F32
        desired.channels = AUDIO_CHANNELS.cint
        desired.freq     = AUDIO_SAMPLE_RATE.cint
        let sample = Sound_NewSampleFromMem(cast[ptr uint8](req.data),
                                             uint32(req.dataSize), nil,
                                             addr desired, SB_CHUNK_BYTES)
        if sample == nil:
          var res: StreamBufferChunkResult
          res.requestId = req.requestId
          res.isError   = true
          dealloc(req.data)
          acquire(adLock)
          sbResults.add(res)
          release(adLock)
        else:
          activeStreams.add(ActiveSbStream(
            requestId:         req.requestId,
            data:              req.data,
            sample:            sample,
            isFirstChunk:      true,
            knownTotalSamples: knownTotal
          ))

      # ── Decode ONE chunk from each active stream (round-robin) ────────────
      # Each 64 KB chunk ≈ 8192 stereo float32 samples ≈ 186 ms decode cost
      # < 1 ms.  With N active streams we spend <N ms per outer iteration,
      # which is well within the 3 ms mixer sleep budget.
      var completedIdx: seq[int]
      for i in 0..<activeStreams.len:
        let stream = addr activeStreams[i]
        let decodedBytes = Sound_Decode(stream.sample)
        let isEof = (stream.sample.flags and SOUND_SAMPLEFLAG_EOF)   != 0
        let isErr = (stream.sample.flags and SOUND_SAMPLEFLAG_ERROR) != 0

        if decodedBytes > 0:
          let chunkSamples = int(decodedBytes) div (bytesPerSample * outChannels)

          var chChannels = newSeq[seq[float32]](outChannels)
          for ch in 0..<outChannels:
            chChannels[ch] = newSeq[float32](chunkSamples)
          let pcmSrc = cast[ptr UncheckedArray[float32]](stream.sample.buffer)
          for s in 0..<chunkSamples:
            for ch in 0..<outChannels:
              chChannels[ch][s] = pcmSrc[s * outChannels + ch]

          var res: StreamBufferChunkResult
          res.requestId       = stream.requestId
          res.isFirst         = stream.isFirstChunk
          res.isComplete      = isEof or isErr
          res.isError         = isErr and (decodedBytes == 0)
          res.channels        = move(chChannels)
          res.chunkSamples    = chunkSamples
          res.totalOggSamples = if stream.isFirstChunk: stream.knownTotalSamples else: 0
          res.numChannels     = outChannels
          res.sampleRate      = AUDIO_SAMPLE_RATE
          res.targetBufferId  = -1

          acquire(adLock)
          sbResults.add(res)
          release(adLock)
          stream.isFirstChunk = false

        elif isEof or isErr:
          # EOF/error with no decoded bytes — send completion marker
          var res: StreamBufferChunkResult
          res.requestId  = stream.requestId
          res.isComplete = true
          res.isError    = isErr
          acquire(adLock)
          sbResults.add(res)
          release(adLock)

        if isEof or isErr or (decodedBytes == 0 and not isEof and not isErr):
          completedIdx.add(i)

      # Cleanup completed streams (reverse order preserves valid indices)
      for i in countdown(completedIdx.high, 0):
        let idx = completedIdx[i]
        Sound_FreeSample(activeStreams[idx].sample)
        dealloc(activeStreams[idx].data)
        activeStreams.delete(idx)

      # ── Streaming stbvorbis path (Sound_Decode chunked) ──
      if foundSd:
        var desired: SDL_AudioSpec
        desired.format   = SDL_AUDIO_F32
        desired.channels = AUDIO_CHANNELS.cint
        desired.freq     = AUDIO_SAMPLE_RATE.cint

        const STREAM_CHUNK_BYTES = 262144'u32  # 256KB per chunk

        let sample = Sound_NewSampleFromMem(cast[ptr uint8](sdReq.data),
                                             uint32(sdReq.dataSize), nil,
                                             addr desired, STREAM_CHUNK_BYTES)
        if sample == nil:
          var chunk: StreamDecodeChunkResult
          chunk.decoderId = sdReq.decoderId
          chunk.isError = true
          dealloc(sdReq.data)
          acquire(adLock)
          sdResults.add(chunk)
          release(adLock)
          continue

        while true:
          acquire(adLock)
          let shuttingDown = adShutdown
          release(adLock)
          if shuttingDown: break

          let decodedBytes = Sound_Decode(sample)
          let isEof   = (sample.flags and SOUND_SAMPLEFLAG_EOF) != 0
          let isError = (sample.flags and SOUND_SAMPLEFLAG_ERROR) != 0

          if decodedBytes > 0:
            let chunkSamples = int(decodedBytes) div (bytesPerSample * outChannels)
            let pcmCopy = cast[ptr UncheckedArray[float32]](alloc(int(decodedBytes)))
            copyMem(pcmCopy, sample.buffer, int(decodedBytes))

            var chunk: StreamDecodeChunkResult
            chunk.decoderId    = sdReq.decoderId
            chunk.pcmData      = pcmCopy
            chunk.pcmBytes     = int(decodedBytes)
            chunk.totalSamples = chunkSamples
            chunk.numChannels  = outChannels
            chunk.sampleRate   = AUDIO_SAMPLE_RATE

            acquire(adLock)
            sdResults.add(chunk)
            release(adLock)

          if isEof or isError:
            var chunk: StreamDecodeChunkResult
            chunk.decoderId = sdReq.decoderId
            chunk.isEof = isEof
            chunk.isError = isError
            acquire(adLock)
            sdResults.add(chunk)
            release(adLock)
            break

          if decodedBytes == 0 and not isEof and not isError:
            # Shouldn't happen, but avoid infinite loop
            var chunk: StreamDecodeChunkResult
            chunk.decoderId = sdReq.decoderId
            chunk.isEof = true
            acquire(adLock)
            sdResults.add(chunk)
            release(adLock)
            break

        Sound_FreeSample(sample)
        dealloc(sdReq.data)

      if not foundSd and activeStreams.len == 0:
        sleep(1)

proc startAudioDecodeThread() =
  if adThreadStarted: return
  initLock(adLock)
  sdRequests = @[]
  sdResults  = @[]
  sbRequests = @[]
  sbResults  = @[]
  adShutdown = false
  createThread(adThread, audioDecodeWorker)
  adThreadStarted = true
  stderr.writeLine("[rwebview] Audio decode worker thread started (progressive decode)")

proc stopAudioDecodeThread() =
  if not adThreadStarted: return
  acquire(adLock)
  adShutdown = true
  release(adLock)
  joinThread(adThread)
  for chunk in sdResults:
    if chunk.pcmData != nil: dealloc(chunk.pcmData)
  sdResults = @[]
  sbRequests = @[]
  sbResults  = @[]
  deinitLock(adLock)
  adThreadStarted = false
  stderr.writeLine("[rwebview] Audio decode worker thread stopped")

# ===========================================================================
# Streaming decode results → stbvorbis.js callbacks (OPT-5b)
# ===========================================================================

proc processStreamDecodeResults*(ctx: ptr ScriptCtx) =
  ## Called once per frame from the main loop.
  ## Delivers at most CHUNKS_PER_FRAME decoded chunks to JS per RAF tick.
  ##
  ## Worker thread decodes the entire OGG continuously in the background
  ## (256 KB per iteration). Without throttling, hundreds of results land in
  ## one frame — all _onDecode callbacks fire simultaneously, stalling the
  ## main thread for 5-20 ms.  With CHUNKS_PER_FRAME = 1:
  ##   • BGM first chunk ready in ~1-2 frames → _isReady = true → zero delay
  ##   • Main thread cost per frame: 1 _onDecode + 1 createBuffer ≈ <0.1 ms
  ##   • Rest of song decoded over subsequent frames by background worker
  if not adThreadStarted: return
  const CHUNKS_PER_FRAME = 1
  var chunks: seq[StreamDecodeChunkResult]
  acquire(adLock)
  if sdResults.len > 0:
    let n = min(CHUNKS_PER_FRAME, sdResults.len)
    chunks = sdResults[0 ..< n]
    sdResults = sdResults[n .. ^1]
  release(adLock)

  if chunks.len == 0: return

  for chunk in chunks:
    let global = ctx.getGlobal()

    if chunk.isError:
      # Error result
      let errObj = ctx.newObject()
      ctx.setPropSteal(errObj, "error", ctx.newString("stbvorbis decode error"))
      ctx.setPropSteal(global, "__rw_sdChunkInfo", errObj)
      ctx.freeValue(global)
      let js = "__rw_stbvorbis_chunk(" & $chunk.decoderId & ")"
      let r = ctx.eval(cstring(js), "<stb-chunk>")
      discard ctx.checkException(r, "<stb-chunk>")
      if chunk.pcmData != nil: dealloc(chunk.pcmData)
      continue

    if chunk.isEof:
      # EOF marker — signal end of stream
      let eofObj = ctx.newObject()
      ctx.setPropSteal(eofObj, "eof", ctx.newInt(1))
      ctx.setPropSteal(global, "__rw_sdChunkInfo", eofObj)
      ctx.freeValue(global)
      let js = "__rw_stbvorbis_chunk(" & $chunk.decoderId & ")"
      let r = ctx.eval(cstring(js), "<stb-chunk>")
      discard ctx.checkException(r, "<stb-chunk>")
      continue

    if chunk.pcmData != nil and chunk.totalSamples > 0:
      # Data chunk — pass interleaved PCM as Float32Array + metadata
      let byteLen = chunk.totalSamples * chunk.numChannels * sizeof(float32)
      let ab = ctx.newArrayBufferCopy(cast[pointer](chunk.pcmData), byteLen)
      # Construct Float32Array via temporary global + eval (engine-agnostic)
      ctx.setPropSteal(global, "__rw_tmpAB", ab)
      let f32 = ctx.eval("new Float32Array(__rw_tmpAB)", "<stb-f32>")

      let resultObj = ctx.newObject()
      ctx.setPropSteal(resultObj, "pcm", f32)
      ctx.setPropSteal(resultObj, "sampleRate", ctx.newInt(int32(chunk.sampleRate)))
      ctx.setPropSteal(resultObj, "channels", ctx.newInt(int32(chunk.numChannels)))
      ctx.setPropSteal(resultObj, "samples", ctx.newInt(int32(chunk.totalSamples)))
      ctx.setPropSteal(global, "__rw_sdChunkInfo", resultObj)
      dealloc(chunk.pcmData)
    else:
      if chunk.pcmData != nil: dealloc(chunk.pcmData)
      ctx.freeValue(global)
      continue

    ctx.freeValue(global)
    let js = "__rw_stbvorbis_chunk(" & $chunk.decoderId & ")"
    let r = ctx.eval(cstring(js), "<stb-chunk>")
    discard ctx.checkException(r, "<stb-chunk>")

  # Flush microtasks
  ctx.flushJobs()

# ===========================================================================
# OPT-STREAMING: streaming buffer results → native AudioBuffer (growing)
# ===========================================================================
# requestId → bufferId: tracks which native buffer collects each stream's chunks.
var sbBufferMap: Table[int, int]

proc processStreamBufferResults*(ctx: ptr ScriptCtx) =
    ## Called once per frame from the main loop.
    ##
    ## THROTTLED: processes at most CHUNKS_PER_FRAME chunks per call.
    ## At 60fps and 8192 samples/chunk this delivers 8×8192/44100 × 60 ≈ 89×
    ## real-time — far ahead of the mixer — while keeping per-frame cost
    ## bounded.  Without throttling the worker fills sbResults with 300+
    ## chunks for a 4 MB BGM before the first rAF tick, causing 500–1200 ms
    ## frame spikes.
    ##
    ## Structure per call:
    ##   Pass 1 — first-chunks: create AudioBufferEntry + resolve JS Promise
    ##            (eval must happen outside mixerLock)
    ##   Pass 2 — extend-chunks + completions: single mixerLock acquire for
    ##            all extend operations, eliminating per-chunk lock round-trips.
    if not adThreadStarted: return

    # Throttle: take at most N chunks this frame.
    const CHUNKS_PER_FRAME = 8  # 89× real-time at 60fps; never starves mixer
    var chunks: seq[StreamBufferChunkResult]
    acquire(adLock)
    if sbResults.len > 0:
      let n = min(CHUNKS_PER_FRAME, sbResults.len)
      chunks = sbResults[0 ..< n]
      sbResults = sbResults[n .. ^1]
    release(adLock)
    if chunks.len == 0: return

    # ── Pass 1: first-chunk handling (eval, no mixerLock) ────────────
    for chunk in chunks:
      if chunk.isError and chunk.channels.len == 0:
        let global = ctx.getGlobal()
        ctx.setPropSteal(global, "__rw_adResultInfo", ctx.newNull())
        ctx.freeValue(global)
        let js = "__rw_adComplete(" & $chunk.requestId & ")"
        let r = ctx.eval(cstring(js), "<sb-chunk>")
        discard ctx.checkException(r, "<sb-chunk>")
        sbBufferMap.del(chunk.requestId)
        continue

      if not chunk.isFirst: continue

      if chunk.channels.len == 0: continue

      var bufEntry: AudioBufferEntry
      bufEntry.sampleRate     = chunk.sampleRate
      bufEntry.channels       = chunk.channels
      bufEntry.length         = chunk.chunkSamples
      bufEntry.streaming      = true
      bufEntry.streamComplete = chunk.isComplete

      acquire(mixerLock)
      let bufferId = audioMixer.buffers.len
      audioMixer.buffers.add(bufEntry)
      release(mixerLock)

      sbBufferMap[chunk.requestId] = bufferId

      # Use the full OGG duration if known (from last-page granule position),
      # otherwise fall back to the first-chunk size.  This is critical for
      # RPG Maker MV: it captures _totalTime = buffer.duration once at resolve
      # time and then calls source.start(when, offset, _totalTime - offset).
      # If we report only the first-chunk duration (~186 ms for 8192 samples)
      # RPG Maker sets stopPosition = 8192 and the SE cuts off after 186 ms.
      let fullSamples = if chunk.totalOggSamples > 0: chunk.totalOggSamples
                        else: chunk.chunkSamples
      let duration = float64(fullSamples) / float64(chunk.sampleRate)
      stderr.writeLine("[rwebview] sb-stream: id=" & $chunk.requestId &
        " bufferId=" & $bufferId & " first=" & $chunk.chunkSamples &
        " total=" & $fullSamples & " complete=" & $chunk.isComplete)

      let global = ctx.getGlobal()
      let infoObj = ctx.newObject()
      ctx.setPropSteal(infoObj, "__bufferId", ctx.newInt(int32(bufferId)))
      ctx.setPropSteal(infoObj, "duration", ctx.newFloat(duration))
      ctx.setPropSteal(infoObj, "sampleRate", ctx.newInt(int32(chunk.sampleRate)))
      ctx.setPropSteal(infoObj, "numberOfChannels", ctx.newInt(int32(chunk.numChannels)))
      ctx.setPropSteal(infoObj, "length", ctx.newInt(int32(fullSamples)))
      ctx.setPropSteal(global, "__rw_adResultInfo", infoObj)
      ctx.freeValue(global)

      # Resolve via the standard __rw_adComplete callback (same as processAudioResults).
      # __rw_adComplete reads __rw_adResultInfo and resolves the Promise.
      let js = "__rw_adComplete(" & $chunk.requestId & ")"
      let r = ctx.eval(cstring(js), "<sb-chunk>")
      discard ctx.checkException(r, "<sb-chunk>")

      if chunk.isComplete:
        sbBufferMap.del(chunk.requestId)

    # ── Pass 2: extend existing buffers under a SINGLE mixerLock acquire ──
    # Acquiring once for all extend-ops eliminates per-chunk lock round-trips
    # and reduces contention with the mixer thread to a single brief hold.
    var needLock = false
    for chunk in chunks:
      if not chunk.isFirst:
        needLock = true
        break

    if needLock:
      acquire(mixerLock)
      for chunk in chunks:
        if chunk.isFirst: continue  # handled in Pass 1

        let bufferId = sbBufferMap.getOrDefault(chunk.requestId, -1)
        if bufferId < 0 or bufferId >= audioMixer.buffers.len: continue
        var buf = addr audioMixer.buffers[bufferId]

        if chunk.channels.len > 0 and chunk.chunkSamples > 0:
          for ch in 0 ..< chunk.channels.len:
            if ch < buf.channels.len:
              buf.channels[ch].add(chunk.channels[ch])
          buf.length += chunk.chunkSamples

        if chunk.isComplete:
          buf.streamComplete = true
      release(mixerLock)

      # Remove completed streams from the map (outside lock).
      for chunk in chunks:
        if not chunk.isFirst and chunk.isComplete:
          sbBufferMap.del(chunk.requestId)

# ===========================================================================
# Native callbacks (ScriptNativeProc signature)
# ===========================================================================

proc jsAudioInit(ctx: ptr ScriptCtx; this: ScriptValue;
                 args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_init() → sampleRate (int) or 0 on failure
  if initAudioMixer():
    startAudioDecodeThread()
    ctx.newInt(int32(audioMixer.sampleRate))
  else:
    ctx.newInt(0)

proc jsAudioDecodeStart(ctx: ptr ScriptCtx; this: ScriptValue;
                        args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_decode_start(requestId, arrayBuffer) → undefined
  ## Copies ArrayBuffer data and queues decode request to worker thread.
  if args.len < 2: return ctx.newUndefined()

  let reqId = ctx.toInt32(args[0])

  var abSize: int
  let abPtr = ctx.getArrayBufferData(args[1], abSize)
  if abPtr == nil or abSize == 0:
    stderr.writeLine("[rwebview] decodeAudioData: invalid ArrayBuffer")
    # Immediately signal failure
    let global = ctx.getGlobal()
    ctx.setPropSteal(global, "__rw_adResultInfo", ctx.newNull())
    ctx.freeValue(global)
    let js = "__rw_adComplete(" & $reqId & ")"
    let r = ctx.eval(cstring(js), "<audio-complete>")
    discard ctx.checkException(r, "<audio-complete>")
    return ctx.newUndefined()

  # Copy ArrayBuffer data to heap (worker thread will own and dealloc it)
  let copy = cast[ptr UncheckedArray[uint8]](alloc(abSize))
  copyMem(copy, abPtr, abSize)

  stderr.writeLine("[rwebview] decodeAudioData async: id=" & $reqId &
                   " size=" & $abSize)

  # Route through the streaming (chunked) decode path so the JS Promise
  # resolves after the first ~64 KB chunk — same behaviour as Chrome/Firefox.
  # The native mixer keeps playing as subsequent chunks extend the buffer.
  acquire(adLock)
  sbRequests.add(StreamBufferRequest(
    requestId: int(reqId),
    data: copy,
    dataSize: int(abSize)
  ))
  release(adLock)

  ctx.newUndefined()

proc jsAudioGetChannelData(ctx: ptr ScriptCtx; this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_getChannelData(bufferId, channel) → Float32Array
  if args.len < 2: return ctx.newNull()
  let bufferId = ctx.toInt32(args[0])
  let channel = ctx.toInt32(args[1])

  if bufferId < 0 or bufferId >= int32(audioMixer.buffers.len):
    return ctx.newNull()
  let buf = addr audioMixer.buffers[bufferId]
  if channel < 0 or channel >= int32(buf.channels.len):
    return ctx.newNull()

  let chData = addr buf.channels[channel]
  let byteLen = chData[].len * sizeof(float32)

  # Create ArrayBuffer from channel data, then Float32Array via eval
  let ab = ctx.newArrayBufferCopy(cast[pointer](addr chData[][0]), byteLen)
  let global = ctx.getGlobal()
  ctx.setPropSteal(global, "__rw_tmpAB", ab)
  ctx.freeValue(global)
  ctx.eval("new Float32Array(__rw_tmpAB)", "<audio-getChannelData>")

proc jsAudioNewGain(ctx: ptr ScriptCtx; this: ScriptValue;
                    args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_newGain() → gainId (int)
  acquire(mixerLock)
  let gainId = audioMixer.gains.len
  audioMixer.gains.add(1.0'f32)
  release(mixerLock)
  ctx.newInt(int32(gainId))

proc jsAudioSetGain(ctx: ptr ScriptCtx; this: ScriptValue;
                    args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_setGain(gainId, value)
  if args.len < 2: return ctx.newUndefined()
  let gainId = ctx.toInt32(args[0])
  let value = ctx.toFloat64(args[1])
  if gainId >= 0 and gainId < int32(audioMixer.gains.len):
    acquire(mixerLock)
    audioMixer.gains[gainId] = float32(value)
    release(mixerLock)
  ctx.newUndefined()

proc jsAudioSourceStart(ctx: ptr ScriptCtx; this: ScriptValue;
                        args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_sourceStart(srcId, when, offsetSamples, durationSamples)
  if args.len < 1: return ctx.newUndefined()
  let srcId = ctx.toInt32(args[0])
  if srcId >= 0 and srcId < int32(audioMixer.sources.len):
    var whenTime: float64 = 0.0
    var offsetSamples: float64 = 0.0
    var durationSamples: float64 = 0.0
    if args.len >= 2: whenTime = ctx.toFloat64(args[1])
    if args.len >= 3: offsetSamples = ctx.toFloat64(args[2])
    if args.len >= 4: durationSamples = ctx.toFloat64(args[3])
    acquire(mixerLock)
    audioMixer.sources[srcId].position = offsetSamples
    audioMixer.sources[srcId].startAt = whenTime
    if durationSamples > 0.0:
      audioMixer.sources[srcId].stopPosition = int(offsetSamples + durationSamples)
    audioMixer.sources[srcId].playing  = true
    release(mixerLock)
  ctx.newUndefined()

proc jsAudioSourceStop(ctx: ptr ScriptCtx; this: ScriptValue;
                       args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_sourceStop(srcId)
  if args.len < 1: return ctx.newUndefined()
  let srcId = ctx.toInt32(args[0])
  if srcId >= 0 and srcId < int32(audioMixer.sources.len):
    acquire(mixerLock)
    audioMixer.sources[srcId].playing = false
    release(mixerLock)
  ctx.newUndefined()

proc jsAudioSourceCreate(ctx: ptr ScriptCtx; this: ScriptValue;
                         args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_sourceCreate(bufferId, gainId, loop, playbackRate, loopStartSamples, loopEndSamples, pannerGainId) → srcId
  if args.len < 4: return ctx.newInt(-1)
  let bufferId = ctx.toInt32(args[0])
  let gainId = ctx.toInt32(args[1])
  let loopInt = ctx.toInt32(args[2])
  let rate = ctx.toFloat64(args[3])

  var loopStartSamples: int32 = 0
  var loopEndSamples: int32 = 0
  var pannerGainIdVal: int32 = -1
  if args.len >= 5: loopStartSamples = ctx.toInt32(args[4])
  if args.len >= 6: loopEndSamples = ctx.toInt32(args[5])
  if args.len >= 7: pannerGainIdVal = ctx.toInt32(args[6])

  var src: AudioSourceState
  src.bufferId     = int(bufferId)
  src.gainId       = int(gainId)
  src.pannerGainId = int(pannerGainIdVal)
  src.loop         = loopInt != 0
  src.playbackRate = float32(rate)
  src.loopStart    = int(loopStartSamples)
  src.loopEnd      = int(loopEndSamples)
  src.playing      = false
  src.position     = 0.0
  src.onendedCb    = ctx.newUndefined()
  src.onendedThis  = ctx.newUndefined()

  acquire(mixerLock)
  let srcId = audioMixer.sources.len
  audioMixer.sources.add(src)
  release(mixerLock)
  ctx.newInt(int32(srcId))

proc jsAudioSourceSetOnended(ctx: ptr ScriptCtx; this: ScriptValue;
                             args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_sourceSetOnended(srcId, callback, thisObj)
  if args.len < 3: return ctx.newUndefined()
  let srcId = ctx.toInt32(args[0])
  if srcId >= 0 and srcId < int32(audioMixer.sources.len):
    audioMixer.sources[srcId].onendedCb  = ctx.dupValue(args[1])
    audioMixer.sources[srcId].onendedThis = ctx.dupValue(args[2])
  ctx.newUndefined()

proc jsAudioSourceSetProp(ctx: ptr ScriptCtx; this: ScriptValue;
                          args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_sourceSetProp(srcId, propName, value)
  ## propName: "loop", "loopStart", "loopEnd", "playbackRate"
  if args.len < 3: return ctx.newUndefined()
  let srcId = ctx.toInt32(args[0])
  if srcId < 0 or srcId >= int32(audioMixer.sources.len):
    return ctx.newUndefined()
  let prop = ctx.toNimString(args[1])
  let fval = ctx.toFloat64(args[2])
  acquire(mixerLock)
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
  release(mixerLock)
  ctx.newUndefined()

proc jsAudioGetCurrentTime(ctx: ptr ScriptCtx; this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_getCurrentTime() → float64 seconds
  ctx.newFloat(audioMixer.currentTime)

proc jsAudioCreateBuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                         args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_createBuffer(numChannels, length, sampleRate) → bufferId
  ## Allocates a zeroed AudioBufferEntry in the mixer for writable use.
  if args.len < 3: return ctx.newInt(-1'i32)
  let numChannels = ctx.toInt32(args[0])
  let length = ctx.toInt32(args[1])
  let sampleRate = ctx.toInt32(args[2])
  if numChannels <= 0 or length <= 0 or sampleRate <= 0:
    return ctx.newInt(-1'i32)
  var entry: AudioBufferEntry
  entry.channels = newSeq[seq[float32]](numChannels)
  for ch in 0..<numChannels:
    entry.channels[ch] = newSeq[float32](length)
  entry.sampleRate = int(sampleRate)
  entry.length = int(length)
  acquire(mixerLock)
  let bufferId = audioMixer.buffers.len
  audioMixer.buffers.add(entry)
  release(mixerLock)
  ctx.newInt(int32(bufferId))

proc jsAudioSetChannelData(ctx: ptr ScriptCtx; this: ScriptValue;
                           args: openArray[ScriptValue]): ScriptValue =
  ## __rw_audio_setChannelData(bufferId, channel, arrayBuffer, byteOffset, sampleCount, startInChannel)
  ## Copies float32 samples from an ArrayBuffer into a native AudioBufferEntry channel.
  if args.len < 6: return ctx.newUndefined()
  let bufferId = ctx.toInt32(args[0])
  let channel = ctx.toInt32(args[1])
  let abVal = args[2]
  let byteOffset = ctx.toInt32(args[3])
  let sampleCount = ctx.toInt32(args[4])
  let startInChannel = ctx.toInt32(args[5])
  if bufferId < 0 or bufferId >= int32(audioMixer.buffers.len):
    return ctx.newUndefined()
  let buf = addr audioMixer.buffers[bufferId]
  if channel < 0 or channel >= int32(buf.channels.len):
    return ctx.newUndefined()
  var abSize: int
  let abPtr = ctx.getArrayBufferData(abVal, abSize)
  if abPtr == nil: return ctx.newUndefined()
  let floatPtr = cast[ptr UncheckedArray[float32]](cast[uint](abPtr) + uint(byteOffset))
  let maxSamples = min(int(sampleCount), buf.channels[channel].len - int(startInChannel))
  if maxSamples <= 0: return ctx.newUndefined()
  acquire(mixerLock)
  for i in 0..<maxSamples:
    buf.channels[channel][int(startInChannel) + i] = floatPtr[i]
  release(mixerLock)
  ctx.newUndefined()

proc jsStbvorbisDecodeStart(ctx: ptr ScriptCtx; this: ScriptValue;
                            args: openArray[ScriptValue]): ScriptValue =
  ## __rw_stbvorbis_decode(decoderId, arrayBuffer)
  ## Queues a streaming decode request to the worker thread.
  if args.len < 2: return ctx.newUndefined()
  let decoderId = ctx.toInt32(args[0])
  let abVal = args[1]
  var abSize: int
  let abPtr = ctx.getArrayBufferData(abVal, abSize)
  if abPtr == nil or abSize == 0:
    stderr.writeLine("[rwebview] stbvorbis_decode: invalid data for id=" & $decoderId)
    # Signal error immediately
    let global = ctx.getGlobal()
    let errObj = ctx.newObject()
    ctx.setPropSteal(errObj, "error", ctx.newString("invalid data"))
    ctx.setPropSteal(global, "__rw_sdChunkInfo", errObj)
    ctx.freeValue(global)
    let js = "__rw_stbvorbis_chunk(" & $decoderId & ")"
    let r = ctx.eval(cstring(js), "<stb-err>")
    discard ctx.checkException(r, "<stb-err>")
    return ctx.newUndefined()

  let copy = cast[ptr UncheckedArray[uint8]](alloc(int(abSize)))
  copyMem(copy, abPtr, int(abSize))

  stderr.writeLine("[rwebview] stbvorbis_decode async: id=" & $decoderId &
                   " size=" & $abSize)

  acquire(adLock)
  sdRequests.add(StreamDecodeRequest(
    decoderId: int(decoderId),
    data: copy,
    dataSize: int(abSize)
  ))
  release(adLock)
  ctx.newUndefined()

# ===========================================================================
# HTML Audio file loading — direct read for Audio.src (bypasses XHR queue)
# ===========================================================================

proc jsHtmlAudioLoadFile(ctx: ptr ScriptCtx; this: ScriptValue;
                         args: openArray[ScriptValue]): ScriptValue =
  ## __rw_htmlaudio_loadfile(url) → ArrayBuffer of file bytes, or null if not found.
  ## Used by the Audio() constructor's src setter to load audio files directly
  ## from disk without going through the XHR request queue.
  if args.len < 1: return ctx.newNull()
  let url = ctx.toNimString(args[0])
  let state = gState
  if state == nil: return ctx.newNull()
  let filePath = resolveUrl(url, state)
  if filePath.len == 0 or not fileExists(filePath):
    stderr.writeLine("[htmlaudio] file not found: " & url)
    return ctx.newNull()
  let data = cachedReadFile(filePath)
  stderr.writeLine("[htmlaudio] loaded: " & filePath & " (" & $data.len & " bytes)")
  ctx.newArrayBufferCopy(cast[pointer](cstring(data)), data.len)

# ===========================================================================
# bindAudio — install AudioContext + supporting classes into JS global
# ===========================================================================

proc bindAudio*(ctx: ptr ScriptCtx) =
  ctx.bindGlobal("__rw_audio_init", jsAudioInit, 0)
  ctx.bindGlobal("__rw_audio_decode_start", jsAudioDecodeStart, 2)
  ctx.bindGlobal("__rw_audio_getChannelData", jsAudioGetChannelData, 2)
  ctx.bindGlobal("__rw_audio_newGain", jsAudioNewGain, 0)
  ctx.bindGlobal("__rw_audio_setGain", jsAudioSetGain, 2)
  ctx.bindGlobal("__rw_audio_sourceCreate", jsAudioSourceCreate, 7)
  ctx.bindGlobal("__rw_audio_sourceStart", jsAudioSourceStart, 4)
  ctx.bindGlobal("__rw_audio_sourceStop", jsAudioSourceStop, 1)
  ctx.bindGlobal("__rw_audio_sourceSetOnended", jsAudioSourceSetOnended, 3)
  ctx.bindGlobal("__rw_audio_sourceSetProp", jsAudioSourceSetProp, 3)
  ctx.bindGlobal("__rw_audio_getCurrentTime", jsAudioGetCurrentTime, 0)
  ctx.bindGlobal("__rw_audio_createBuffer", jsAudioCreateBuffer, 3)
  ctx.bindGlobal("__rw_audio_setChannelData", jsAudioSetChannelData, 6)
  ctx.bindGlobal("__rw_stbvorbis_decode", jsStbvorbisDecodeStart, 2)
  ctx.bindGlobal("__rw_htmlaudio_loadfile", jsHtmlAudioLoadFile, 1)

  # JS-level classes: AudioContext, AudioBuffer, AudioBufferSourceNode, GainNode,
  # PannerNode, AnalyserNode, ConvolverNode, DynamicsCompressorNode,
  # BiquadFilterNode, StereoPannerNode, OscillatorNode,
  # MediaElementAudioSourceNode, Audio (HTMLAudioElement)
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
  AudioParam.prototype.setValueAtTime = function(v, t) { this.value = v; return this; };
  AudioParam.prototype.linearRampToValueAtTime = function(v, t) { this.value = v; return this; };
  AudioParam.prototype.exponentialRampToValueAtTime = function(v, t) { this.value = Math.max(v,0.0001); return this; };
  AudioParam.prototype.setTargetAtTime = function(v, t, tc) { this.value = v; return this; };
  AudioParam.prototype.cancelScheduledValues = function(t) { return this; };
  AudioParam.prototype.cancelAndHoldAtTime = function(t) { return this; };

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
  AudioBuffer.prototype.copyToChannel = function(source, channelNumber, startInChannel) {
    if (this.__bufferId < 0) return;
    __rw_audio_setChannelData(this.__bufferId, channelNumber,
      source.buffer, source.byteOffset || 0, source.length, startInChannel || 0);
  };

  // ── AudioDestinationNode ────────────────────────────────────────────
  function AudioDestinationNode() {
    this.numberOfInputs = 1;
    this.numberOfOutputs = 0;
    this.__isDestination = true;
    this.channelCount = 2;
    this.channelCountMode = 'explicit';
    this.channelInterpretation = 'speakers';
    this.maxChannelCount = 2;
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
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'max';
    this.channelInterpretation = 'speakers';
  }
  GainNode.prototype.connect = function(node) {
    this.__output = node;
    return node;
  };
  GainNode.prototype.disconnect = function() { this.__output = null; };

  // ── PannerNode ──────────────────────────────────────────────────────
  // Full distance model implementation: inverse, linear, exponential.
  // Computes distance-based gain attenuation and updates native gain slot.

  // Global panner registry so listener updates can recompute all panners.
  var __rwPannerNodes = [];
  var __rwListenerX = 0, __rwListenerY = 0, __rwListenerZ = 0;

  function PannerNode(ctx) {
    this.context = ctx;
    this.__pannerGainId = __rw_audio_newGain();
    this._x = 0; this._y = 0; this._z = 0;
    this._ox = 1; this._oy = 0; this._oz = 0;
    this.panningModel = 'HRTF';
    this.distanceModel = 'inverse';
    this._distanceModelIndex = 1;  // 0=linear, 1=inverse, 2=exponential
    this.refDistance = 1;
    this.maxDistance = 10000;
    this.rolloffFactor = 1;
    this.coneInnerAngle = 360;
    this.coneOuterAngle = 0;
    this.coneOuterGain = 0;
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'clamped-max';
    this.channelInterpretation = 'speakers';
    // positionX/Y/Z as AudioParam (Web Audio spec)
    var self = this;
    this.positionX = new AudioParam(0, function(v) { self._x = v; self._updateGain(); });
    this.positionY = new AudioParam(0, function(v) { self._y = v; self._updateGain(); });
    this.positionZ = new AudioParam(0, function(v) { self._z = v; self._updateGain(); });
    this.orientationX = new AudioParam(1, function(v) { self._ox = v; });
    this.orientationY = new AudioParam(0, function(v) { self._oy = v; });
    this.orientationZ = new AudioParam(0, function(v) { self._oz = v; });
    __rwPannerNodes.push(this);
  }
  PannerNode.prototype.connect = function(node) { this._output = node; return node; };
  PannerNode.prototype.disconnect = function() { this._output = null; };
  PannerNode.prototype.setPosition = function(x, y, z) {
    this._x = x; this._y = y; this._z = z;
    this._updateGain();
  };
  PannerNode.prototype.setOrientation = function(x, y, z) {
    this._ox = x; this._oy = y; this._oz = z;
  };
  PannerNode.prototype._updateGain = function() {
    var dx = this._x - __rwListenerX;
    var dy = this._y - __rwListenerY;
    var dz = this._z - __rwListenerZ;
    var distance = Math.sqrt(dx*dx + dy*dy + dz*dz);
    var ref = this.refDistance;
    var max = this.maxDistance;
    var roll = this.rolloffFactor;
    var gain = 1.0;
    // Parse distanceModel string if set by C2 (which may set it as string or int)
    var dm = this._distanceModelIndex;
    if (typeof this.distanceModel === 'string') {
      if (this.distanceModel === 'linear') dm = 0;
      else if (this.distanceModel === 'inverse') dm = 1;
      else if (this.distanceModel === 'exponential') dm = 2;
    } else if (typeof this.distanceModel === 'number') {
      dm = this.distanceModel;
    }
    distance = Math.max(distance, ref);
    if (dm !== 0) distance = Math.min(distance, max);  // linear clamps differently
    switch (dm) {
      case 0: // linear
        distance = Math.min(distance, max);
        if (max !== ref) {
          gain = 1.0 - roll * (distance - ref) / (max - ref);
        }
        break;
      case 1: // inverse
        gain = ref / (ref + roll * (distance - ref));
        break;
      case 2: // exponential
        if (ref > 0) gain = Math.pow(distance / ref, -roll);
        break;
    }
    gain = Math.max(0, Math.min(1, gain));
    // Cone attenuation (simplified)
    if (this.coneOuterAngle > 0 && this.coneOuterAngle < 360) {
      var dot = dx * this._ox + dy * this._oy + dz * this._oz;
      var dist = Math.sqrt(dx*dx + dy*dy + dz*dz);
      if (dist > 0.001) {
        var angle = Math.acos(dot / dist) * (180 / Math.PI);
        var halfInner = this.coneInnerAngle / 2;
        var halfOuter = this.coneOuterAngle / 2;
        if (angle > halfOuter) {
          gain *= this.coneOuterGain;
        } else if (angle > halfInner && halfOuter > halfInner) {
          var t = (angle - halfInner) / (halfOuter - halfInner);
          gain *= (1.0 - t) + t * this.coneOuterGain;
        }
      }
    }
    __rw_audio_setGain(this.__pannerGainId, gain);
  };

  // ── AnalyserNode ─────────────────────────────────────────────────────
  function AnalyserNode(ctx) {
    this.context = ctx;
    this.fftSize = 2048;
    this.frequencyBinCount = 1024;
    this.minDecibels = -100;
    this.maxDecibels = -30;
    this.smoothingTimeConstant = 0.8;
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'max';
    this.channelInterpretation = 'speakers';
  }
  AnalyserNode.prototype.connect = function(node) { this._output = node; return node; };
  AnalyserNode.prototype.disconnect = function() { this._output = null; };
  AnalyserNode.prototype.getByteFrequencyData = function(arr) {
    for (var i = 0; i < arr.length; i++) arr[i] = 0;
  };
  AnalyserNode.prototype.getFloatFrequencyData = function(arr) {
    for (var i = 0; i < arr.length; i++) arr[i] = -100;
  };
  AnalyserNode.prototype.getByteTimeDomainData = function(arr) {
    for (var i = 0; i < arr.length; i++) arr[i] = 128;
  };
  AnalyserNode.prototype.getFloatTimeDomainData = function(arr) {
    for (var i = 0; i < arr.length; i++) arr[i] = 0;
  };

  // ── ConvolverNode ────────────────────────────────────────────────────
  function ConvolverNode(ctx) {
    this.context = ctx;
    this.buffer = null;
    this.normalize = true;
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'clamped-max';
    this.channelInterpretation = 'speakers';
  }
  ConvolverNode.prototype.connect = function(node) { this._output = node; return node; };
  ConvolverNode.prototype.disconnect = function() { this._output = null; };

  // ── DynamicsCompressorNode ───────────────────────────────────────────
  function DynamicsCompressorNode(ctx) {
    this.context = ctx;
    this.threshold = new AudioParam(-24, function(){});
    this.knee      = new AudioParam(30, function(){});
    this.ratio     = new AudioParam(12, function(){});
    this.attack    = new AudioParam(0.003, function(){});
    this.release   = new AudioParam(0.25, function(){});
    this.reduction = 0;
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'clamped-max';
    this.channelInterpretation = 'speakers';
  }
  DynamicsCompressorNode.prototype.connect = function(node) { this._output = node; return node; };
  DynamicsCompressorNode.prototype.disconnect = function() { this._output = null; };

  // ── BiquadFilterNode ─────────────────────────────────────────────────
  function BiquadFilterNode(ctx) {
    this.context = ctx;
    this.type = 'lowpass';
    this.frequency = new AudioParam(350, function(){});
    this.detune    = new AudioParam(0, function(){});
    this.Q         = new AudioParam(1, function(){});
    this.gain      = new AudioParam(0, function(){});
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'max';
    this.channelInterpretation = 'speakers';
  }
  BiquadFilterNode.prototype.connect = function(node) { this._output = node; return node; };
  BiquadFilterNode.prototype.disconnect = function() { this._output = null; };
  BiquadFilterNode.prototype.getFrequencyResponse = function(freq, mag, phase) {
    if (mag) for (var i = 0; i < mag.length; i++) mag[i] = 1;
    if (phase) for (var i = 0; i < phase.length; i++) phase[i] = 0;
  };

  // ── StereoPannerNode ─────────────────────────────────────────────────
  function StereoPannerNode(ctx) {
    this.context = ctx;
    this.pan = new AudioParam(0, function(){});
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
    this.channelCount = 2;
    this.channelCountMode = 'clamped-max';
    this.channelInterpretation = 'speakers';
  }
  StereoPannerNode.prototype.connect = function(node) { this._output = node; return node; };
  StereoPannerNode.prototype.disconnect = function() { this._output = null; };

  // ── WaveShaperNode ───────────────────────────────────────────────────
  function WaveShaperNode(ctx) {
    this.context = ctx;
    this.curve = null;
    this.oversample = 'none';
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
  }
  WaveShaperNode.prototype.connect = function(node) { this._output = node; return node; };
  WaveShaperNode.prototype.disconnect = function() { this._output = null; };

  // ── DelayNode ────────────────────────────────────────────────────────
  function DelayNode(ctx, maxDelay) {
    this.context = ctx;
    this.delayTime = new AudioParam(0, function(){});
    this._output = null;
    this.numberOfInputs = 1;
    this.numberOfOutputs = 1;
  }
  DelayNode.prototype.connect = function(node) { this._output = node; return node; };
  DelayNode.prototype.disconnect = function() { this._output = null; };

  // ── ChannelSplitterNode / ChannelMergerNode ──────────────────────────
  function ChannelSplitterNode(ctx, outputs) {
    this.context = ctx;
    this.numberOfInputs = 1;
    this.numberOfOutputs = outputs || 6;
    this._output = null;
  }
  ChannelSplitterNode.prototype.connect = function(node) { this._output = node; return node; };
  ChannelSplitterNode.prototype.disconnect = function() { this._output = null; };

  function ChannelMergerNode(ctx, inputs) {
    this.context = ctx;
    this.numberOfInputs = inputs || 6;
    this.numberOfOutputs = 1;
    this._output = null;
  }
  ChannelMergerNode.prototype.connect = function(node) { this._output = node; return node; };
  ChannelMergerNode.prototype.disconnect = function() { this._output = null; };

  // ── OscillatorNode ───────────────────────────────────────────────────
  function OscillatorNode(ctx) {
    this.context = ctx;
    this.type = 'sine';
    this.frequency = new AudioParam(440, function(){});
    this.detune    = new AudioParam(0, function(){});
    this._output = null;
    this._started = false;
    this.onended = null;
    this.numberOfInputs = 0;
    this.numberOfOutputs = 1;
  }
  OscillatorNode.prototype.connect = function(node) { this._output = node; return node; };
  OscillatorNode.prototype.disconnect = function() { this._output = null; };
  OscillatorNode.prototype.start = function(when) { this._started = true; };
  OscillatorNode.prototype.stop = function(when) {
    this._started = false;
    if (typeof this.onended === 'function') { try { this.onended(); } catch(e){} }
  };
  OscillatorNode.prototype.setPeriodicWave = function(wave) {};

  // ── PeriodicWave ─────────────────────────────────────────────────────
  function PeriodicWave() {}

  // ── MediaElementAudioSourceNode ──────────────────────────────────────
  // Routes HTML Audio element output through the WebAudio gain chain.
  // The Audio element's __haGainId is set to match the connected gain node.
  function MediaElementAudioSourceNode(ctx, audioElement) {
    this.context = ctx;
    this.mediaElement = audioElement;
    this._output = null;
    this.numberOfInputs = 0;
    this.numberOfOutputs = 1;
  }
  MediaElementAudioSourceNode.prototype.connect = function(node) {
    this._output = node;
    // When connected to a GainNode, bind the Audio element's gain to it
    if (this.mediaElement && node && node.__gainId !== undefined) {
      this.mediaElement.__haGainId = node.__gainId;
    }
    return node;
  };
  MediaElementAudioSourceNode.prototype.disconnect = function() {
    if (this.mediaElement) this.mediaElement.__haGainId = -1;
    this._output = null;
  };

  // ── AudioContext ────────────────────────────────────────────────────
  function AudioContext() {
    this.sampleRate = __rw_audio_init() || 44100;
    this.state = 'running';
    this.destination = new AudioDestinationNode();
    // Expose this instance so Audio() elements can use decodeAudioData.
    window.__rwAudioContext = this;
    // AudioListener — full implementation with position tracking for PannerNode.
    var listener = {
      _x: 0, _y: 0, _z: 0,
      _fx: 0, _fy: 0, _fz: -1,
      _ux: 0, _uy: 1, _uz: 0,
      setPosition: function(x, y, z) {
        this._x = x; this._y = y; this._z = z;
        __rwListenerX = x; __rwListenerY = y; __rwListenerZ = z;
        // Recompute all active panner gains
        for (var i = 0; i < __rwPannerNodes.length; i++) {
          __rwPannerNodes[i]._updateGain();
        }
      },
      setOrientation: function(x, y, z, xUp, yUp, zUp) {
        this._fx = x; this._fy = y; this._fz = z;
        this._ux = xUp || 0; this._uy = yUp || 1; this._uz = zUp || 0;
      },
      positionX: new AudioParam(0, function(v) { listener.setPosition(v, listener._y, listener._z); }),
      positionY: new AudioParam(0, function(v) { listener.setPosition(listener._x, v, listener._z); }),
      positionZ: new AudioParam(0, function(v) { listener.setPosition(listener._x, listener._y, v); }),
      forwardX:  new AudioParam(0, function(){}),
      forwardY:  new AudioParam(0, function(){}),
      forwardZ:  new AudioParam(-1, function(){}),
      upX: new AudioParam(0, function(){}),
      upY: new AudioParam(1, function(){}),
      upZ: new AudioParam(0, function(){})
    };
    this.listener = listener;
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
  AudioContext.prototype.createPanner = function() {
    return new PannerNode(this);
  };
  AudioContext.prototype.createAnalyser = function() {
    return new AnalyserNode(this);
  };
  AudioContext.prototype.createConvolver = function() {
    return new ConvolverNode(this);
  };
  AudioContext.prototype.createDynamicsCompressor = function() {
    return new DynamicsCompressorNode(this);
  };
  AudioContext.prototype.createBiquadFilter = function() {
    return new BiquadFilterNode(this);
  };
  AudioContext.prototype.createStereoPanner = function() {
    return new StereoPannerNode(this);
  };
  AudioContext.prototype.createWaveShaper = function() {
    return new WaveShaperNode(this);
  };
  AudioContext.prototype.createDelay = function(maxDelay) {
    return new DelayNode(this, maxDelay || 1);
  };
  AudioContext.prototype.createChannelSplitter = function(outputs) {
    return new ChannelSplitterNode(this, outputs);
  };
  AudioContext.prototype.createChannelMerger = function(inputs) {
    return new ChannelMergerNode(this, inputs);
  };
  AudioContext.prototype.createOscillator = function() {
    return new OscillatorNode(this);
  };
  AudioContext.prototype.createPeriodicWave = function(real, imag, constraints) {
    return new PeriodicWave();
  };
  AudioContext.prototype.createMediaElementSource = function(audioElement) {
    return new MediaElementAudioSourceNode(this, audioElement);
  };
  AudioContext.prototype.createBuffer = function(numChannels, length, sampleRate) {
    var bufferId = __rw_audio_createBuffer(numChannels, length, sampleRate);
    return new AudioBuffer({
      __bufferId: bufferId,
      duration: length / sampleRate,
      sampleRate: sampleRate,
      numberOfChannels: numChannels,
      length: length
    });
  };
  AudioContext.prototype.decodeAudioData = function(arrayBuffer, onSuccess, onError) {
    // All formats use the progressive chunked decode path — same architecture
    // as Chrome/Firefox.  The Promise resolves after the FIRST ~64 KB chunk
    // (~10 ms); subsequent chunks extend the native buffer while the mixer
    // keeps playing.  No format-specific detection needed.
    var id = ++window.__rw_adNextId;
    var resolve, reject;
    var promise = new Promise(function(res, rej) {
      resolve = res;
      reject = rej;
    });
    window.__rw_adPromises[id] = { resolve: resolve, reject: reject, onSuccess: onSuccess || null, onError: onError || null };
    __rw_audio_decode_start(id, arrayBuffer);
    return promise;
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
    this.numberOfInputs = 0;
    this.numberOfOutputs = 1;
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
    var pannerGainId = -1;
    if (this.__gainNode && this.__gainNode.__gainId !== undefined) {
      gainId = this.__gainNode.__gainId;
      // Check if gainNode is connected to a PannerNode
      var out = this.__gainNode.__output;
      if (out && out.__pannerGainId !== undefined) {
        pannerGainId = out.__pannerGainId;
      }
    }
    var offsetSamples = Math.floor((offset || 0) * this.buffer.sampleRate);
    var loopStartSamples = Math.floor(this.loopStart * this.buffer.sampleRate);
    var loopEndSamples = this.loopEnd > 0 ? Math.floor(this.loopEnd * this.buffer.sampleRate) : 0;
    this.__srcId = __rw_audio_sourceCreate(
      this.buffer.__bufferId, gainId,
      this.loop ? 1 : 0, this.playbackRate.value,
      loopStartSamples, loopEndSamples, pannerGainId
    );
    var durationSamples = (duration && duration > 0) ? Math.floor(duration * this.buffer.sampleRate) : 0;
    __rw_audio_sourceStart(this.__srcId, when || 0, offsetSamples, durationSamples);
    if (this.onended) {
      __rw_audio_sourceSetOnended(this.__srcId, this.onended, this);
    }
  };
  AudioBufferSourceNode.prototype.stop = function() {
    if (this.__srcId >= 0) {
      __rw_audio_sourceStop(this.__srcId);
    }
  };

  // ── Async decode infrastructure ─────────────────────────────────────
  window.__rw_adPromises = {};
  window.__rw_adNextId = 0;
  window.__rw_adComplete = function(id) {
    var p = window.__rw_adPromises[id];
    if (!p) return;
    delete window.__rw_adPromises[id];
    var info = window.__rw_adResultInfo;
    window.__rw_adResultInfo = undefined;
    if (info === null || info === undefined) {
      var err = new Error('decodeAudioData failed');
      if (p.onError) try { p.onError(err); } catch(e) {}
      p.reject(err);
    } else {
      var buf = new AudioBuffer(info);
      if (p.onSuccess) try { p.onSuccess(buf); } catch(e) {}
      p.resolve(buf);
    }
  };

  // ── stbvorbis streaming decode polyfill ─────────────────────────────
  window.__rw_sd_decoders = {};
  window.__rw_sd_nextId = 0;

  window.stbvorbis = {
    decodeStream: function(onDecode) {
      var decoderId = ++window.__rw_sd_nextId;
      var buffers = [];
      window.__rw_sd_decoders[decoderId] = { onDecode: onDecode };
      return function(input) {
        if (input.data) {
          buffers.push(new Uint8Array(input.data.buffer ? input.data : input.data));
        }
        if (input.eof) {
          var total = 0;
          for (var i = 0; i < buffers.length; i++) total += buffers[i].length;
          var combined = new Uint8Array(total);
          var off = 0;
          for (var i = 0; i < buffers.length; i++) {
            combined.set(buffers[i], off);
            off += buffers[i].length;
          }
          buffers = [];
          __rw_stbvorbis_decode(decoderId, combined.buffer);
        }
      };
    }
  };

  window.__rw_stbvorbis_chunk = function(decoderId) {
    var dec = window.__rw_sd_decoders[decoderId];
    if (!dec) return;
    var info = window.__rw_sdChunkInfo;
    window.__rw_sdChunkInfo = undefined;
    if (!info) return;
    if (info.eof) {
      dec.onDecode({ eof: true });
      delete window.__rw_sd_decoders[decoderId];
      return;
    }
    if (info.error) {
      dec.onDecode({ error: info.error });
      delete window.__rw_sd_decoders[decoderId];
      return;
    }
    var pcm = info.pcm;
    var nch = info.channels;
    var ns = info.samples;
    var data = [];
    for (var ch = 0; ch < nch; ch++) {
      data[ch] = new Float32Array(ns);
      for (var i = 0; i < ns; i++) {
        data[ch][i] = pcm[i * nch + ch];
      }
    }
    dec.onDecode({ data: data, sampleRate: info.sampleRate });
  };

  // ══════════════════════════════════════════════════════════════════════
  // Audio() — HTMLAudioElement implementation
  // ══════════════════════════════════════════════════════════════════════
  // Used by Construct 2's HTML5 music path (is_music=true) and any game
  // that creates Audio elements directly. Decodes audio via the native
  // decodeAudioData pipeline, plays through the native mixer using
  // AudioBufferSourceNode under the hood.

  function Audio(srcArg) {
    var self = this;
    this._src = '';
    this._listeners = {};
    this._audioBuffer = null;    // decoded AudioBuffer
    this._sourceNode  = null;    // current AudioBufferSourceNode
    this._gainNode    = null;    // per-element GainNode
    this.__haGainId   = -1;      // gain id set by MediaElementAudioSourceNode
    this._startCtxTime = 0;      // AudioContext.currentTime when play() called
    this._playOffset   = 0;      // offset (seconds) into buffer at play() start
    this._playing      = false;
    this._volume       = 1;
    this._muted        = false;
    this._loop         = false;
    this._playbackRate = 1;
    this._currentTime  = 0;
    this._duration     = 0;
    this._readyState   = 0;
    this._ended        = false;
    this._paused       = true;
    this._error        = null;
    this.autoplay       = false;
    this.preload        = 'auto';
    this.crossOrigin    = null;
    this.defaultMuted   = false;
    this.defaultPlaybackRate = 1;
    this.disableRemotePlayback = false;
    this.preservesPitch = true;
    // Event handlers (direct on-* style)
    this.oncanplay = null;
    this.oncanplaythrough = null;
    this.ondurationchange = null;
    this.onemptied = null;
    this.onended = null;
    this.onerror = null;
    this.onloadeddata = null;
    this.onloadedmetadata = null;
    this.onloadstart = null;
    this.onpause = null;
    this.onplay = null;
    this.onplaying = null;
    this.onprogress = null;
    this.onratechange = null;
    this.onseeked = null;
    this.onseeking = null;
    this.onstalled = null;
    this.onsuspend = null;
    this.ontimeupdate = null;
    this.onvolumechange = null;
    this.onwaiting = null;

    if (srcArg) {
      // Defer so addEventListener can be called before load starts
      var s = srcArg;
      setTimeout(function() { self.src = s; }, 0);
    }
  }

  Audio.prototype.addEventListener = function(type, fn) {
    if (!this._listeners[type]) this._listeners[type] = [];
    this._listeners[type].push(fn);
  };
  Audio.prototype.removeEventListener = function(type, fn) {
    var a = this._listeners[type]; if (!a) return;
    var i = a.indexOf(fn); if (i >= 0) a.splice(i, 1);
  };
  Audio.prototype.dispatchEvent = function(evt) {
    var type = evt.type || evt;
    var fns = this._listeners[type] || [];
    var evtObj = (typeof evt === 'string') ? { type: type, target: this } : evt;
    for (var i = 0; i < fns.length; i++) {
      try { fns[i].call(this, evtObj); } catch(e) {
        console.error('[Audio event error] ' + type + ': ' + ((e && e.stack) || e));
      }
    }
    var h = this['on' + type];
    if (typeof h === 'function') {
      try { h.call(this, evtObj); } catch(e) {
        console.error('[Audio on* error] ' + type + ': ' + ((e && e.stack) || e));
      }
    }
  };

  // — src property: loading and decoding ——————————————————————————————
  Object.defineProperty(Audio.prototype, 'src', {
    get: function() { return this._src; },
    set: function(v) {
      var self = this;
      self._src = v;
      if (!v) return;
      self._readyState = 0;
      self._audioBuffer = null;
      self._ended = false;
      self._error = null;
      self.dispatchEvent('loadstart');

      // Load file directly from disk (bypass XHR queue)
      var ab = __rw_htmlaudio_loadfile(v);
      if (!ab) {
        self._error = { code: 4, message: 'MEDIA_ERR_SRC_NOT_SUPPORTED' };
        self.dispatchEvent('error');
        return;
      }
      // Decode asynchronously
      var ac = window.__rwAudioContext;
      if (!ac) {
        self._error = { code: 4, message: 'No AudioContext' };
        self.dispatchEvent('error');
        return;
      }
      ac.decodeAudioData(ab, function(buf) {
        self._audioBuffer = buf;
        self._duration = buf.duration;
        self._readyState = 4;  // HAVE_ENOUGH_DATA
        self.dispatchEvent('loadedmetadata');
        self.dispatchEvent('loadeddata');
        self.dispatchEvent('canplay');
        self.dispatchEvent('canplaythrough');
        self.dispatchEvent('durationchange');
        if (self.autoplay) self.play();
      }, function(err) {
        self._error = { code: 4, message: 'decode failed' };
        self.dispatchEvent('error');
      });
    }
  });

  // — play / pause / load ————————————————————————————————————————————
  Audio.prototype.play = function() {
    var self = this;
    if (!self._audioBuffer) {
      return new Promise(function(resolve, reject) {
        reject(new Error('no audio loaded'));
      });
    }
    var ac = window.__rwAudioContext;
    if (!ac) return Promise.resolve();

    // Stop current source if any
    if (self._sourceNode) {
      try { self._sourceNode.stop(); } catch(e) {}
      self._sourceNode = null;
    }

    // Create per-element gain node (for volume control)
    if (!self._gainNode) {
      self._gainNode = ac.createGain();
      self._gainNode.connect(ac.destination);
    }
    // Update gain: use the external gain chain (from MediaElementSource) or own volume
    var effectiveVol = self._muted ? 0 : self._volume;
    self._gainNode.gain.value = effectiveVol;

    var src = ac.createBufferSource();
    src.buffer = self._audioBuffer;
    src.loop   = self._loop;
    src.playbackRate.value = self._playbackRate;

    // If connected via MediaElementAudioSourceNode, connect through that gain
    if (self.__haGainId >= 0) {
      // Find appropriate node - walk from _gainNode
      src.connect(self._gainNode);
    } else {
      src.connect(self._gainNode);
    }

    var offset = self._currentTime || 0;
    if (offset >= self._duration && !self._loop) offset = 0;

    src.onended = function() {
      self._playing = false;
      self._paused  = true;
      self._ended   = !self._loop;
      if (self._ended) {
        self._currentTime = self._duration;
        self.dispatchEvent('ended');
      }
    };

    src.start(0, offset);
    self._sourceNode  = src;
    self._startCtxTime = ac.currentTime;
    self._playOffset  = offset;
    self._playing     = true;
    self._paused      = false;
    self._ended       = false;
    self.dispatchEvent('play');
    self.dispatchEvent('playing');
    return Promise.resolve();
  };

  Audio.prototype.pause = function() {
    if (!this._playing) return;
    var ac = window.__rwAudioContext;
    if (ac) {
      this._currentTime = this._playOffset +
        (ac.currentTime - this._startCtxTime) * this._playbackRate;
      if (this._currentTime > this._duration)
        this._currentTime = this._loop ? (this._currentTime % this._duration) : this._duration;
    }
    if (this._sourceNode) {
      try { this._sourceNode.stop(); } catch(e) {}
      this._sourceNode = null;
    }
    this._playing = false;
    this._paused  = true;
    this.dispatchEvent('pause');
  };

  Audio.prototype.load = function() {
    // Re-trigger loading from current src
    if (this._src) this.src = this._src;
  };

  Audio.prototype.canPlayType = function(type) {
    if (!type) return '';
    var t = type.toLowerCase();
    if (t.indexOf('ogg') >= 0 || t.indexOf('vorbis') >= 0) return 'probably';
    if (t.indexOf('wav') >= 0) return 'probably';
    if (t.indexOf('mp3') >= 0 || t.indexOf('mpeg') >= 0) return 'maybe';
    if (t.indexOf('flac') >= 0) return 'maybe';
    if (t.indexOf('webm') >= 0) return 'maybe';
    if (t.indexOf('mp4') >= 0 || t.indexOf('aac') >= 0 || t.indexOf('m4a') >= 0) return '';
    return '';
  };

  Audio.prototype.cloneNode = function() {
    var a = new Audio();
    a._src = this._src;
    a._audioBuffer = this._audioBuffer;
    a._duration = this._duration;
    a._readyState = this._readyState;
    return a;
  };

  // Stub methods for compatibility
  Audio.prototype.fastSeek = function(t) { this.currentTime = t; };
  Audio.prototype.captureStream = function() { return null; };

  // — Property getters/setters ———————————————————————————————————————
  Object.defineProperty(Audio.prototype, 'volume', {
    get: function() { return this._volume; },
    set: function(v) {
      this._volume = Math.max(0, Math.min(1, v));
      if (this._gainNode) {
        this._gainNode.gain.value = this._muted ? 0 : this._volume;
      }
      this.dispatchEvent('volumechange');
    }
  });
  Object.defineProperty(Audio.prototype, 'muted', {
    get: function() { return this._muted; },
    set: function(v) {
      this._muted = !!v;
      if (this._gainNode) {
        this._gainNode.gain.value = this._muted ? 0 : this._volume;
      }
      this.dispatchEvent('volumechange');
    }
  });
  Object.defineProperty(Audio.prototype, 'loop', {
    get: function() { return this._loop; },
    set: function(v) {
      this._loop = !!v;
      if (this._sourceNode) this._sourceNode.loop = this._loop;
    }
  });
  Object.defineProperty(Audio.prototype, 'playbackRate', {
    get: function() { return this._playbackRate; },
    set: function(v) {
      this._playbackRate = v;
      if (this._sourceNode) this._sourceNode.playbackRate.value = v;
      this.dispatchEvent('ratechange');
    }
  });
  Object.defineProperty(Audio.prototype, 'currentTime', {
    get: function() {
      if (this._playing) {
        var ac = window.__rwAudioContext;
        if (ac) {
          var t = this._playOffset + (ac.currentTime - this._startCtxTime) * this._playbackRate;
          if (this._duration > 0) {
            if (this._loop) t = t % this._duration;
            else t = Math.min(t, this._duration);
          }
          return t;
        }
      }
      return this._currentTime;
    },
    set: function(v) {
      this._currentTime = Math.max(0, v);
      if (this._playing) {
        // Restart playback from new position
        this.pause();
        this.play();
      }
    }
  });
  Object.defineProperty(Audio.prototype, 'duration', {
    get: function() { return this._duration || 0; }
  });
  Object.defineProperty(Audio.prototype, 'readyState', {
    get: function() { return this._readyState; },
    set: function(v) { this._readyState = v; }
  });
  Object.defineProperty(Audio.prototype, 'paused', {
    get: function() { return this._paused; },
    set: function(v) { this._paused = !!v; }
  });
  Object.defineProperty(Audio.prototype, 'ended', {
    get: function() { return this._ended; },
    set: function(v) { this._ended = !!v; }
  });
  Object.defineProperty(Audio.prototype, 'error', {
    get: function() { return this._error; },
    set: function(v) { this._error = v; }
  });
  Object.defineProperty(Audio.prototype, 'buffered', {
    get: function() {
      var dur = this._duration || 0;
      return {
        length: dur > 0 ? 1 : 0,
        start: function(i) { return 0; },
        end: function(i) { return dur; }
      };
    }
  });
  Object.defineProperty(Audio.prototype, 'seekable', {
    get: function() {
      var dur = this._duration || 0;
      return {
        length: dur > 0 ? 1 : 0,
        start: function(i) { return 0; },
        end: function(i) { return dur; }
      };
    }
  });
  Object.defineProperty(Audio.prototype, 'played', {
    get: function() {
      return { length: 0, start: function(){ return 0; }, end: function(){ return 0; } };
    }
  });
  Object.defineProperty(Audio.prototype, 'networkState', {
    get: function() { return this._readyState >= 4 ? 1 : 0; }
  });

  // ── OfflineAudioContext (minimal stub) ───────────────────────────────
  function OfflineAudioContext(channels, length, sampleRate) {
    AudioContext.call(this);
    this.length = length || 0;
  }
  OfflineAudioContext.prototype = Object.create(AudioContext.prototype);
  OfflineAudioContext.prototype.constructor = OfflineAudioContext;
  OfflineAudioContext.prototype.startRendering = function() {
    var self = this;
    return new Promise(function(resolve) {
      var buf = self.createBuffer(2, self.length || 1, self.sampleRate);
      resolve(buf);
    });
  };
  OfflineAudioContext.prototype.oncomplete = null;

  // ── Export to window ────────────────────────────────────────────────
  window.AudioContext = AudioContext;
  window.webkitAudioContext = AudioContext;
  window.OfflineAudioContext = OfflineAudioContext;
  window.webkitOfflineAudioContext = OfflineAudioContext;
  window.AudioBuffer = AudioBuffer;
  window.AudioBufferSourceNode = AudioBufferSourceNode;
  window.GainNode = GainNode;
  window.PannerNode = PannerNode;
  window.AnalyserNode = AnalyserNode;
  window.ConvolverNode = ConvolverNode;
  window.DynamicsCompressorNode = DynamicsCompressorNode;
  window.BiquadFilterNode = BiquadFilterNode;
  window.StereoPannerNode = StereoPannerNode;
  window.WaveShaperNode = WaveShaperNode;
  window.DelayNode = DelayNode;
  window.ChannelSplitterNode = ChannelSplitterNode;
  window.ChannelMergerNode = ChannelMergerNode;
  window.OscillatorNode = OscillatorNode;
  window.PeriodicWave = PeriodicWave;
  window.MediaElementAudioSourceNode = MediaElementAudioSourceNode;
  window.AudioParam = AudioParam;
  window.AudioDestinationNode = AudioDestinationNode;
  window.Audio = Audio;
  window.HTMLAudioElement = Audio;
  window.AudioListener = function() {};
})();
"""
  let r = ctx.eval(cstring(audioJs), "<audio-setup>")
  discard ctx.checkException(r, "<audio-setup>")

  # Copy window.* audio classes to the QuickJS global so bare names work
  let globalizeAudio = """
var AudioContext = window.AudioContext;
var webkitAudioContext = window.webkitAudioContext;
var OfflineAudioContext = window.OfflineAudioContext;
var webkitOfflineAudioContext = window.webkitOfflineAudioContext;
var AudioBuffer = window.AudioBuffer;
var AudioBufferSourceNode = window.AudioBufferSourceNode;
var GainNode = window.GainNode;
var PannerNode = window.PannerNode;
var AnalyserNode = window.AnalyserNode;
var ConvolverNode = window.ConvolverNode;
var DynamicsCompressorNode = window.DynamicsCompressorNode;
var BiquadFilterNode = window.BiquadFilterNode;
var StereoPannerNode = window.StereoPannerNode;
var WaveShaperNode = window.WaveShaperNode;
var DelayNode = window.DelayNode;
var ChannelSplitterNode = window.ChannelSplitterNode;
var ChannelMergerNode = window.ChannelMergerNode;
var OscillatorNode = window.OscillatorNode;
var PeriodicWave = window.PeriodicWave;
var MediaElementAudioSourceNode = window.MediaElementAudioSourceNode;
var AudioParam = window.AudioParam;
var AudioDestinationNode = window.AudioDestinationNode;
var Audio = window.Audio;
var HTMLAudioElement = window.HTMLAudioElement;
"""
  let r2 = ctx.eval(cstring(globalizeAudio), "<globalize-audio>")
  discard ctx.checkException(r2, "<globalize-audio>")
