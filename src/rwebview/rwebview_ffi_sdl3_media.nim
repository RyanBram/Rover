# ===========================================================================
# SDL3_image FFI
# With -d:sdlStatic, links statically. Otherwise loads DLL at runtime.
# ===========================================================================

when defined(sdlStatic):
  const sdlImgStaticLibPath = rwebviewRoot / "bin" / "staticlib" / "lib" / "libSDL3_image.a"
  {.passL: sdlImgStaticLibPath.}
  # SDL3_image static needs these (for PNG/JPEG decoders built-in)
  {.passL: "-lshlwapi".}

proc IMG_Load(file: cstring): ptr SDL_Surface
    {.importc: "IMG_Load".}
proc IMG_Load_IO(src: pointer; closeio: cint): ptr SDL_Surface
    {.importc: "IMG_Load_IO".}
proc SDL_IOFromMem(mem: pointer; size: csize_t): pointer
    {.importc: "SDL_IOFromMem".}

# ===========================================================================
# SDL3 Audio FFI  (uses same SDL3 lib as video — already linked)
# ===========================================================================

type
  SDL_AudioDeviceID = uint32
  SDL_AudioFormat   = uint32
  SDL_AudioStream   = object  # opaque

  SDL_AudioSpec {.bycopy.} = object
    format:   SDL_AudioFormat
    channels: cint
    freq:     cint

const
  SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK = 0xFFFFFFFF'u32
  SDL_AUDIO_F32* = 0x8120'u32   # IEEE float32 LE (= SDL_AUDIO_F32LE on x86)

proc SDL_OpenAudioDevice(devid: SDL_AudioDeviceID; spec: ptr SDL_AudioSpec): SDL_AudioDeviceID
    {.importc: "SDL_OpenAudioDevice".}
proc SDL_CloseAudioDevice(devid: SDL_AudioDeviceID)
    {.importc: "SDL_CloseAudioDevice".}
proc SDL_CreateAudioStream(srcSpec: ptr SDL_AudioSpec; dstSpec: ptr SDL_AudioSpec): ptr SDL_AudioStream
    {.importc: "SDL_CreateAudioStream".}
proc SDL_PutAudioStreamData(stream: ptr SDL_AudioStream; buf: pointer; len: cint): bool
    {.importc: "SDL_PutAudioStreamData".}
proc SDL_BindAudioStream(devid: SDL_AudioDeviceID; stream: ptr SDL_AudioStream): bool
    {.importc: "SDL_BindAudioStream".}
proc SDL_GetAudioStreamQueued(stream: ptr SDL_AudioStream): cint
    {.importc: "SDL_GetAudioStreamQueued".}
proc SDL_DestroyAudioStream(stream: ptr SDL_AudioStream)
    {.importc: "SDL_DestroyAudioStream".}
proc SDL_ResumeAudioDevice(devid: SDL_AudioDeviceID): bool
    {.importc: "SDL_ResumeAudioDevice".}
proc SDL_PauseAudioDevice(devid: SDL_AudioDeviceID): bool
    {.importc: "SDL_PauseAudioDevice".}

# ===========================================================================
# SDL_sound FFI
# With -d:sdlStatic, links statically. Otherwise loads DLL at runtime.
# ===========================================================================

when defined(sdlStatic):
  const sdlSoundStaticLibPath = rwebviewRoot / "bin" / "lib" / "libSDL3_sound.a"
  {.passL: sdlSoundStaticLibPath.}

# SDL_sound sample flags
const
  SOUND_SAMPLEFLAG_NONE    = 0u32
  SOUND_SAMPLEFLAG_CANSEEK = 1u32
  SOUND_SAMPLEFLAG_EOF     = 1u32 shl 29
  SOUND_SAMPLEFLAG_ERROR   = 1u32 shl 30
  SOUND_SAMPLEFLAG_EAGAIN  = 1u32 shl 31

type
  Sound_SampleFlags = uint32

  Sound_DecoderInfo {.bycopy.} = object
    extensions:  ptr cstring
    description: cstring
    author:      cstring
    url:         cstring

  Sound_Sample {.bycopy.} = object
    opaque:      pointer
    decoder:     ptr Sound_DecoderInfo
    desired:     SDL_AudioSpec
    actual:      SDL_AudioSpec
    buffer:      pointer
    buffer_size: uint32
    flags:       Sound_SampleFlags

proc Sound_Init(): cint
    {.importc: "Sound_Init".}
proc Sound_Quit(): cint
    {.importc: "Sound_Quit".}
proc Sound_NewSampleFromMem(data: pointer; size: uint32; ext: cstring;
                            desired: ptr SDL_AudioSpec;
                            bufferSize: uint32): ptr Sound_Sample
    {.importc: "Sound_NewSampleFromMem".}
proc Sound_NewSampleFromFile(fname: cstring; desired: ptr SDL_AudioSpec;
                             bufferSize: uint32): ptr Sound_Sample
    {.importc: "Sound_NewSampleFromFile".}
proc Sound_DecodeAll(sample: ptr Sound_Sample): uint32
    {.importc: "Sound_DecodeAll".}
proc Sound_Decode(sample: ptr Sound_Sample): uint32
    {.importc: "Sound_Decode".}
proc Sound_FreeSample(sample: ptr Sound_Sample)
    {.importc: "Sound_FreeSample".}
proc Sound_GetDuration(sample: ptr Sound_Sample): int32
    {.importc: "Sound_GetDuration".}

