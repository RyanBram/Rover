# ===========================================================================
# SDL3_ttf FFI  (runtime DLL)
# ===========================================================================

const sdl3TtfDll = binDir / "SDL3_ttf.dll"

type
  TTF_Font = object  # opaque

  SDL_Color {.bycopy.} = object
    r, g, b, a: uint8

proc TTF_Init(): bool
    {.importc: "TTF_Init", dynlib: sdl3TtfDll.}
proc TTF_Quit()
    {.importc: "TTF_Quit", dynlib: sdl3TtfDll.}
proc TTF_OpenFont(file: cstring; ptsize: cfloat): ptr TTF_Font
    {.importc: "TTF_OpenFont", dynlib: sdl3TtfDll.}
proc TTF_CloseFont(font: ptr TTF_Font)
    {.importc: "TTF_CloseFont", dynlib: sdl3TtfDll.}
proc TTF_SetFontSize(font: ptr TTF_Font; ptsize: cfloat): bool
    {.importc: "TTF_SetFontSize", dynlib: sdl3TtfDll.}
proc TTF_RenderText_Blended(font: ptr TTF_Font; text: cstring;
                            length: csize_t; fg: SDL_Color): ptr SDL_Surface
    {.importc: "TTF_RenderText_Blended", dynlib: sdl3TtfDll.}
proc TTF_GetStringSize(font: ptr TTF_Font; text: cstring;
                       length: csize_t; w: ptr cint; h: ptr cint): bool
    {.importc: "TTF_GetStringSize", dynlib: sdl3TtfDll.}

# ===========================================================================
# SDL3_image FFI  (runtime DLL)
# ===========================================================================

const sdl3ImgDll = binDir / "SDL3_image.dll"

proc IMG_Load(file: cstring): ptr SDL_Surface
    {.importc: "IMG_Load", dynlib: sdl3ImgDll.}

# ===========================================================================
# SDL3 Audio FFI  (runtime DLL — uses same sdl3Dll as video)
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
    {.importc: "SDL_OpenAudioDevice", dynlib: sdl3Dll.}
proc SDL_CloseAudioDevice(devid: SDL_AudioDeviceID)
    {.importc: "SDL_CloseAudioDevice", dynlib: sdl3Dll.}
proc SDL_CreateAudioStream(srcSpec: ptr SDL_AudioSpec; dstSpec: ptr SDL_AudioSpec): ptr SDL_AudioStream
    {.importc: "SDL_CreateAudioStream", dynlib: sdl3Dll.}
proc SDL_PutAudioStreamData(stream: ptr SDL_AudioStream; buf: pointer; len: cint): bool
    {.importc: "SDL_PutAudioStreamData", dynlib: sdl3Dll.}
proc SDL_BindAudioStream(devid: SDL_AudioDeviceID; stream: ptr SDL_AudioStream): bool
    {.importc: "SDL_BindAudioStream", dynlib: sdl3Dll.}
proc SDL_GetAudioStreamQueued(stream: ptr SDL_AudioStream): cint
    {.importc: "SDL_GetAudioStreamQueued", dynlib: sdl3Dll.}
proc SDL_DestroyAudioStream(stream: ptr SDL_AudioStream)
    {.importc: "SDL_DestroyAudioStream", dynlib: sdl3Dll.}
proc SDL_ResumeAudioDevice(devid: SDL_AudioDeviceID): bool
    {.importc: "SDL_ResumeAudioDevice", dynlib: sdl3Dll.}
proc SDL_PauseAudioDevice(devid: SDL_AudioDeviceID): bool
    {.importc: "SDL_PauseAudioDevice", dynlib: sdl3Dll.}

# ===========================================================================
# SDL_sound FFI  (runtime DLL)
# ===========================================================================

const sdl3SoundDll = binDir / "SDL3_sound.dll"

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
    {.importc: "Sound_Init", dynlib: sdl3SoundDll.}
proc Sound_Quit(): cint
    {.importc: "Sound_Quit", dynlib: sdl3SoundDll.}
proc Sound_NewSampleFromMem(data: pointer; size: uint32; ext: cstring;
                            desired: ptr SDL_AudioSpec;
                            bufferSize: uint32): ptr Sound_Sample
    {.importc: "Sound_NewSampleFromMem", dynlib: sdl3SoundDll.}
proc Sound_NewSampleFromFile(fname: cstring; desired: ptr SDL_AudioSpec;
                             bufferSize: uint32): ptr Sound_Sample
    {.importc: "Sound_NewSampleFromFile", dynlib: sdl3SoundDll.}
proc Sound_DecodeAll(sample: ptr Sound_Sample): uint32
    {.importc: "Sound_DecodeAll", dynlib: sdl3SoundDll.}
proc Sound_FreeSample(sample: ptr Sound_Sample)
    {.importc: "Sound_FreeSample", dynlib: sdl3SoundDll.}
proc Sound_GetDuration(sample: ptr Sound_Sample): int32
    {.importc: "Sound_GetDuration", dynlib: sdl3SoundDll.}

