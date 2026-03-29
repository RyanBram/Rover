# =============================================================================
# rwebview_gl.nim
# OpenGL types, function pointers, and loader
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
#   OpenGL types, function pointers, and WebGL JSCFunction callbacks.
#
# Documentation:
#   See [Documentation] section at the bottom of this file.
#
# -----------------------------------------------------------------------------
#
# Included by:
#   - rgss_quickjs_ffi         # JS helpers
#   - rwebview_canvas2d        # Canvas2D state variables
#   - rwebview_ffi_sdl3        # SDL_GL_GetProcAddress
#
# Used by:
#   - rwebview.nim             # included after rwebview_canvas2d.nim
#
# =============================================================================

type
  GLenum     = uint32
  GLuint     = uint32
  GLint      = int32
  GLsizei    = int32
  GLfloat    = float32
  GLboolean  = uint8
  GLbitfield = uint32
  GLclampf   = float32
  GLubyte    = uint8

# -- OpenGL function pointer variables (loaded via SDL_GL_GetProcAddress) ----

var
  # State
  glViewport:        proc(x, y: GLint; w, h: GLsizei) {.cdecl.}
  glClearColor:      proc(r, g, b, a: GLclampf) {.cdecl.}
  glClear:           proc(mask: GLbitfield) {.cdecl.}
  glEnable:          proc(cap: GLenum) {.cdecl.}
  glDisable:         proc(cap: GLenum) {.cdecl.}
  glBlendFunc:       proc(sfactor, dfactor: GLenum) {.cdecl.}
  glBlendFuncSeparate: proc(srcRGB, dstRGB, srcAlpha, dstAlpha: GLenum) {.cdecl.}
  glBlendEquation:   proc(mode: GLenum) {.cdecl.}
  glBlendEquationSeparate: proc(modeRGB, modeAlpha: GLenum) {.cdecl.}
  glBlendColor:      proc(r, g, b, a: GLclampf) {.cdecl.}
  glDepthFunc:       proc(fn: GLenum) {.cdecl.}
  glDepthMask:       proc(flag: GLboolean) {.cdecl.}
  glDepthRange:      proc(n, f: float64) {.cdecl.}
  glClearDepth:      proc(d: float64) {.cdecl.}
  glCullFace:        proc(mode: GLenum) {.cdecl.}
  glFrontFace:       proc(mode: GLenum) {.cdecl.}
  glScissor:         proc(x, y: GLint; w, h: GLsizei) {.cdecl.}
  glLineWidth:       proc(width: GLfloat) {.cdecl.}
  glColorMask:       proc(r, g, b, a: GLboolean) {.cdecl.}
  glStencilFunc:     proc(fn: GLenum; refVal: GLint; mask: GLuint) {.cdecl.}
  glStencilFuncSeparate: proc(face, fn: GLenum; refVal: GLint; mask: GLuint) {.cdecl.}
  glStencilOp:       proc(fail, zfail, zpass: GLenum) {.cdecl.}
  glStencilOpSeparate: proc(face, fail, zfail, zpass: GLenum) {.cdecl.}
  glStencilMask:     proc(mask: GLuint) {.cdecl.}
  glStencilMaskSeparate: proc(face: GLenum; mask: GLuint) {.cdecl.}
  glClearStencil:    proc(s: GLint) {.cdecl.}
  glPixelStorei:     proc(pname: GLenum; param: GLint) {.cdecl.}
  glFlush:           proc() {.cdecl.}
  glFinish:          proc() {.cdecl.}
  glGetError:        proc(): GLenum {.cdecl.}
  glGetIntegerv:     proc(pname: GLenum; params: ptr GLint) {.cdecl.}
  glGetFloatv:       proc(pname: GLenum; params: ptr GLfloat) {.cdecl.}
  glGetBooleanv:     proc(pname: GLenum; params: ptr GLboolean) {.cdecl.}
  glGetString:       proc(name: GLenum): ptr GLubyte {.cdecl.}
  glIsEnabled:       proc(cap: GLenum): GLboolean {.cdecl.}
  # Shaders
  glCreateShader:    proc(typ: GLenum): GLuint {.cdecl.}
  glDeleteShader:    proc(shader: GLuint) {.cdecl.}
  glShaderSource:    proc(shader: GLuint; count: GLsizei; strings: ptr cstring; lengths: ptr GLint) {.cdecl.}
  glCompileShader:   proc(shader: GLuint) {.cdecl.}
  glGetShaderiv:     proc(shader: GLuint; pname: GLenum; params: ptr GLint) {.cdecl.}
  glGetShaderInfoLog: proc(shader: GLuint; maxLen: GLsizei; length: ptr GLsizei; log: cstring) {.cdecl.}
  glGetShaderSource:  proc(shader: GLuint; maxLen: GLsizei; length: ptr GLsizei; source: cstring) {.cdecl.}
  glCreateProgram:   proc(): GLuint {.cdecl.}
  glDeleteProgram:   proc(program: GLuint) {.cdecl.}
  glAttachShader:    proc(program, shader: GLuint) {.cdecl.}
  glDetachShader:    proc(program, shader: GLuint) {.cdecl.}
  glLinkProgram:     proc(program: GLuint) {.cdecl.}
  glGetProgramiv:    proc(program: GLuint; pname: GLenum; params: ptr GLint) {.cdecl.}
  glGetProgramInfoLog: proc(program: GLuint; maxLen: GLsizei; length: ptr GLsizei; log: cstring) {.cdecl.}
  glUseProgram:      proc(program: GLuint) {.cdecl.}
  glValidateProgram: proc(program: GLuint) {.cdecl.}
  glGetAttribLocation: proc(program: GLuint; name: cstring): GLint {.cdecl.}
  glGetUniformLocation: proc(program: GLuint; name: cstring): GLint {.cdecl.}
  glBindAttribLocation: proc(program: GLuint; index: GLuint; name: cstring) {.cdecl.}
  glGetActiveAttrib: proc(program: GLuint; index: GLuint; bufSize: GLsizei;
                          length: ptr GLsizei; size: ptr GLint; typ: ptr GLenum; name: cstring) {.cdecl.}
  glGetActiveUniform: proc(program: GLuint; index: GLuint; bufSize: GLsizei;
                           length: ptr GLsizei; size: ptr GLint; typ: ptr GLenum; name: cstring) {.cdecl.}
  # Buffers
  glGenBuffers:      proc(n: GLsizei; buffers: ptr GLuint) {.cdecl.}
  glDeleteBuffers:   proc(n: GLsizei; buffers: ptr GLuint) {.cdecl.}
  glBindBuffer:      proc(target: GLenum; buffer: GLuint) {.cdecl.}
  glBufferData:      proc(target: GLenum; size: int; data: pointer; usage: GLenum) {.cdecl.}
  glBufferSubData:   proc(target: GLenum; offset: int; size: int; data: pointer) {.cdecl.}
  glVertexAttribPointer: proc(index: GLuint; size: GLint; typ: GLenum;
                              normalized: GLboolean; stride: GLsizei; offset: pointer) {.cdecl.}
  glEnableVertexAttribArray:  proc(index: GLuint) {.cdecl.}
  glDisableVertexAttribArray: proc(index: GLuint) {.cdecl.}
  # Textures
  glGenTextures:     proc(n: GLsizei; textures: ptr GLuint) {.cdecl.}
  glDeleteTextures:  proc(n: GLsizei; textures: ptr GLuint) {.cdecl.}
  glBindTexture:     proc(target: GLenum; texture: GLuint) {.cdecl.}
  glActiveTexture:   proc(texture: GLenum) {.cdecl.}
  glTexImage2D:      proc(target: GLenum; level: GLint; internalformat: GLint;
                          width, height: GLsizei; border: GLint;
                          format: GLenum; typ: GLenum; pixels: pointer) {.cdecl.}
  glTexSubImage2D:   proc(target: GLenum; level: GLint; xoffset, yoffset: GLint;
                          width, height: GLsizei; format: GLenum; typ: GLenum; pixels: pointer) {.cdecl.}
  glTexParameteri:   proc(target, pname: GLenum; param: GLint) {.cdecl.}
  glTexParameterf:   proc(target, pname: GLenum; param: GLfloat) {.cdecl.}
  glGenerateMipmap:  proc(target: GLenum) {.cdecl.}
  glCopyTexImage2D:  proc(target: GLenum; level: GLint; internalfmt: GLenum;
                          x, y: GLint; w, h: GLsizei; border: GLint) {.cdecl.}
  glCopyTexSubImage2D: proc(target: GLenum; level: GLint; xoff, yoff: GLint;
                            x, y: GLint; w, h: GLsizei) {.cdecl.}
  # Framebuffers
  glGenFramebuffers:      proc(n: GLsizei; fbs: ptr GLuint) {.cdecl.}
  glDeleteFramebuffers:   proc(n: GLsizei; fbs: ptr GLuint) {.cdecl.}
  glBindFramebuffer:      proc(target: GLenum; fb: GLuint) {.cdecl.}
  glFramebufferTexture2D: proc(target, attachment, textarget: GLenum;
                               texture: GLuint; level: GLint) {.cdecl.}
  glFramebufferRenderbuffer: proc(target, attachment, rbtarget: GLenum;
                                  rb: GLuint) {.cdecl.}
  glCheckFramebufferStatus: proc(target: GLenum): GLenum {.cdecl.}
  # Renderbuffers
  glGenRenderbuffers:    proc(n: GLsizei; rbs: ptr GLuint) {.cdecl.}
  glDeleteRenderbuffers: proc(n: GLsizei; rbs: ptr GLuint) {.cdecl.}
  glBindRenderbuffer:    proc(target: GLenum; rb: GLuint) {.cdecl.}
  glRenderbufferStorage: proc(target, internalfmt: GLenum; w, h: GLsizei) {.cdecl.}
  glGetRenderbufferParameteriv: proc(target, pname: GLenum; params: ptr GLint) {.cdecl.}
  # Drawing
  glDrawArrays:      proc(mode: GLenum; first: GLint; count: GLsizei) {.cdecl.}
  glDrawElements:    proc(mode: GLenum; count: GLsizei; typ: GLenum; indices: pointer) {.cdecl.}
  # Uniforms
  glUniform1f: proc(loc: GLint; v0: GLfloat) {.cdecl.}
  glUniform2f: proc(loc: GLint; v0, v1: GLfloat) {.cdecl.}
  glUniform3f: proc(loc: GLint; v0, v1, v2: GLfloat) {.cdecl.}
  glUniform4f: proc(loc: GLint; v0, v1, v2, v3: GLfloat) {.cdecl.}
  glUniform1i: proc(loc: GLint; v0: GLint) {.cdecl.}
  glUniform2i: proc(loc: GLint; v0, v1: GLint) {.cdecl.}
  glUniform3i: proc(loc: GLint; v0, v1, v2: GLint) {.cdecl.}
  glUniform4i: proc(loc: GLint; v0, v1, v2, v3: GLint) {.cdecl.}
  glUniform1fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform2fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform3fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform4fv: proc(loc: GLint; count: GLsizei; v: ptr GLfloat) {.cdecl.}
  glUniform1iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniform2iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniform3iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniform4iv: proc(loc: GLint; count: GLsizei; v: ptr GLint) {.cdecl.}
  glUniformMatrix2fv: proc(loc: GLint; count: GLsizei; transpose: GLboolean; v: ptr GLfloat) {.cdecl.}
  glUniformMatrix3fv: proc(loc: GLint; count: GLsizei; transpose: GLboolean; v: ptr GLfloat) {.cdecl.}
  glUniformMatrix4fv: proc(loc: GLint; count: GLsizei; transpose: GLboolean; v: ptr GLfloat) {.cdecl.}
  # Reading
  glReadPixels: proc(x, y: GLint; w, h: GLsizei; format, typ: GLenum; pixels: pointer) {.cdecl.}
  # Vertex Array Objects (Core Profile requires a VAO to be bound)
  glGenVertexArrays:    proc(n: GLsizei; arrays: ptr GLuint) {.cdecl.}
  glDeleteVertexArrays: proc(n: GLsizei; arrays: ptr GLuint) {.cdecl.}
  glBindVertexArray:    proc(arr: GLuint) {.cdecl.}
  # Instanced rendering (for ANGLE_instanced_arrays extension)
  glDrawArraysInstanced:   proc(mode: GLenum; first: GLint; count, instanceCount: GLsizei) {.cdecl.}
  glDrawElementsInstanced: proc(mode: GLenum; count: GLsizei; typ: GLenum;
                                indices: pointer; instanceCount: GLsizei) {.cdecl.}
  glVertexAttribDivisor:   proc(index: GLuint; divisor: GLuint) {.cdecl.}
  # Shader precision (GL 4.1 / GL ES 2.0; may be nil on GL 3.3)
  glGetShaderPrecisionFormat: proc(shaderType, precisionType: GLenum;
                                   range: ptr GLint; precision: ptr GLint) {.cdecl.}

# Default VAO handle (Core Profile requires a VAO to be bound at all times)
var glDefaultVAO: GLuint = 0

# WebGL drawing buffer (off-screen FBO) — emulates the browser's canvas
# drawing buffer.  WebGL apps render to this FBO; we composite it to the
# actual window with letterboxing each frame.
var glDrawingFBO: GLuint = 0
var glDrawingColorTex: GLuint = 0
var glDrawingDepthStencilRBO: GLuint = 0
var glDrawingBufW*: int = 0
var glDrawingBufH*: int = 0
var glJSBoundFBO: GLuint = 0   # FBO that JS *thinks* is bound (0 = default)
var gWebGLActive*: bool = false  # true once WebGL drawing buffer is ready
var gForceCanvasMode*: bool = false  # set by __rw_setForceCanvas() when renderer=canvas

# WebGL-specific pixelStorei state (no OpenGL equivalent)
var glUnpackFlipY: bool = false
var glUnpackPremultiplyAlpha: bool = false

# ── WebGL State Cache ──────────────────────────────────────────────────
# Shadows GL state to skip redundant driver calls.  Every real browser
# (Chrome, Firefox, Safari) maintains an identical shadow cache — when JS
# calls gl.bindTexture() with the already-bound texture, the browser skips
# the actual driver call.  This is standard WebGL implementation behaviour,
# not an application-specific hack.

const glCacheSentinel = 0xFFFFFFFF'u32  # "unknown / not yet set"

# Capability enable/disable  (-1 = unknown, 0 = disabled, 1 = enabled)
var glCapState: array[10, int8]

proc glCapIndex(cap: GLenum): int {.inline.} =
  case uint32(cap)
  of 0x0BE2'u32: 0   # GL_BLEND
  of 0x0B44'u32: 1   # GL_CULL_FACE
  of 0x0B71'u32: 2   # GL_DEPTH_TEST
  of 0x0BD0'u32: 3   # GL_DITHER
  of 0x8037'u32: 4   # GL_POLYGON_OFFSET_FILL
  of 0x809E'u32: 5   # GL_SAMPLE_ALPHA_TO_COVERAGE
  of 0x80A0'u32: 6   # GL_SAMPLE_COVERAGE
  of 0x0C11'u32: 7   # GL_SCISSOR_TEST
  of 0x0B90'u32: 8   # GL_STENCIL_TEST
  of 0x8C89'u32: 9   # GL_RASTERIZER_DISCARD
  else: -1

# Program
var glCacheProgram: GLuint = 0

# Texture binding (per unit, max 16 units tracked)
var glCacheActiveTexUnit: GLenum = 0x84C0.GLenum   # GL_TEXTURE0
var glCacheBoundTex2D: array[16, GLuint]

# Blend
var glCacheBlendSrcRGB: GLenum = GLenum(glCacheSentinel)
var glCacheBlendDstRGB: GLenum = GLenum(glCacheSentinel)
var glCacheBlendSrcA:   GLenum = GLenum(glCacheSentinel)
var glCacheBlendDstA:   GLenum = GLenum(glCacheSentinel)
var glCacheBlendEqRGB:  GLenum = GLenum(glCacheSentinel)
var glCacheBlendEqA:    GLenum = GLenum(glCacheSentinel)

# Viewport
var glCacheVpX: GLint = -1
var glCacheVpY: GLint = -1
var glCacheVpW: GLsizei = -1
var glCacheVpH: GLsizei = -1

# Scissor
var glCacheScX: GLint = -1
var glCacheScY: GLint = -1
var glCacheScW: GLsizei = -1
var glCacheScH: GLsizei = -1

# Buffer binding
var glCacheArrayBuf:   GLuint = 0
var glCacheElementBuf: GLuint = 0

# Depth / Color mask
var glCacheDepthMask: int8 = -1   # -1 = unknown, 0 = false, 1 = true
var glCacheColorMask: array[4, int8]  # per component

proc resetGLStateCache*() =
  ## Reset all shadow state to "unknown".  Called at init time.
  for i in 0..<glCapState.len: glCapState[i] = -1
  glCacheProgram = 0
  glCacheActiveTexUnit = 0x84C0.GLenum
  for i in 0..<glCacheBoundTex2D.len: glCacheBoundTex2D[i] = 0
  glCacheBlendSrcRGB = GLenum(glCacheSentinel)
  glCacheBlendDstRGB = GLenum(glCacheSentinel)
  glCacheBlendSrcA   = GLenum(glCacheSentinel)
  glCacheBlendDstA   = GLenum(glCacheSentinel)
  glCacheBlendEqRGB  = GLenum(glCacheSentinel)
  glCacheBlendEqA    = GLenum(glCacheSentinel)
  glCacheVpX = -1; glCacheVpY = -1; glCacheVpW = -1; glCacheVpH = -1
  glCacheScX = -1; glCacheScY = -1; glCacheScW = -1; glCacheScH = -1
  glCacheArrayBuf = 0; glCacheElementBuf = 0
  glCacheDepthMask = -1
  for i in 0..<glCacheColorMask.len: glCacheColorMask[i] = -1

# -- Helper: apply WebGL UNPACK pixel transformations -------------------------

proc applyUnpackTransform(srcData: pointer; w, h: int): seq[uint8] =
  ## Copy pixel data, applying UNPACK_PREMULTIPLY_ALPHA and/or UNPACK_FLIP_Y.
  ## Returns the transformed copy (RGBA, UNSIGNED_BYTE assumed).
  ## Only call when at least one flag is true.
  let rowBytes = w * 4
  let total = rowBytes * h
  result = newSeq[uint8](total)
  let src = cast[ptr UncheckedArray[uint8]](srcData)
  for y in 0..<h:
    let srcY = if glUnpackFlipY: h - 1 - y else: y
    let srcOff = srcY * rowBytes
    let dstOff = y * rowBytes
    if glUnpackPremultiplyAlpha:
      for x in 0..<w:
        let si = srcOff + x * 4
        let di = dstOff + x * 4
        let a = int(src[si + 3])
        if a == 255:
          # Fully opaque — no change needed (R * 255/255 = R)
          result[di]     = src[si]
          result[di + 1] = src[si + 1]
          result[di + 2] = src[si + 2]
          result[di + 3] = 255
        elif a == 0:
          # Fully transparent — RGB must be zeroed (R * 0/255 = 0)
          result[di]     = 0
          result[di + 1] = 0
          result[di + 2] = 0
          result[di + 3] = 0
        else:
          result[di]     = uint8((int(src[si])     * a + 127) div 255)
          result[di + 1] = uint8((int(src[si + 1]) * a + 127) div 255)
          result[di + 2] = uint8((int(src[si + 2]) * a + 127) div 255)
          result[di + 3] = uint8(a)
    else:
      copyMem(addr result[dstOff], unsafeAddr src[srcOff], rowBytes)

proc glUploadTexImage(target: GLenum; level: GLint; ifmt: GLint;
                      width, height: GLsizei; border: GLint;
                      fmt: GLenum; typ: GLenum; srcData: pointer) =
  ## texImage2D wrapper that applies UNPACK transformations when needed.
  if srcData == nil:
    glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, nil)
    return
  if not glUnpackPremultiplyAlpha and not glUnpackFlipY:
    glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, srcData)
    return
  var tmp = applyUnpackTransform(srcData, int(width), int(height))
  glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, addr tmp[0])

proc glUploadTexSub(target: GLenum; level: GLint;
                    xoff, yoff: GLint; width, height: GLsizei;
                    fmt: GLenum; typ: GLenum; srcData: pointer) =
  ## texSubImage2D wrapper that applies UNPACK transformations when needed.
  if srcData == nil: return
  if not glUnpackPremultiplyAlpha and not glUnpackFlipY:
    glTexSubImage2D(target, level, xoff, yoff, width, height, fmt, typ, srcData)
    return
  var tmp = applyUnpackTransform(srcData, int(width), int(height))
  glTexSubImage2D(target, level, xoff, yoff, width, height, fmt, typ, addr tmp[0])

# -- Drawing buffer FBO management -------------------------------------------

proc initDrawingBuffer*(w, h: int) =
  ## Create or resize the WebGL drawing buffer FBO (color + depth/stencil).
  if w <= 0 or h <= 0: return
  if w == glDrawingBufW and h == glDrawingBufH and glDrawingFBO != 0: return
  if glDrawingFBO == 0:
    glGenFramebuffers(1, addr glDrawingFBO)
    glGenTextures(1, addr glDrawingColorTex)
    glGenRenderbuffers(1, addr glDrawingDepthStencilRBO)
  # Color texture
  glBindTexture(0x0DE1.GLenum, glDrawingColorTex)   # GL_TEXTURE_2D
  glTexImage2D(0x0DE1.GLenum, 0, 0x8058.GLint,      # GL_RGBA8
               GLsizei(w), GLsizei(h), 0,
               0x1908.GLenum, 0x1401.GLenum, nil)    # RGBA, UNSIGNED_BYTE
  glTexParameteri(0x0DE1.GLenum, 0x2800.GLenum, 0x2601.GLint)  # MAG=LINEAR
  glTexParameteri(0x0DE1.GLenum, 0x2801.GLenum, 0x2601.GLint)  # MIN=LINEAR
  glTexParameteri(0x0DE1.GLenum, 0x2802.GLenum, 0x812F.GLint)  # WRAP_S=CLAMP
  glTexParameteri(0x0DE1.GLenum, 0x2803.GLenum, 0x812F.GLint)  # WRAP_T=CLAMP
  # Depth + stencil renderbuffer
  glBindRenderbuffer(0x8D41.GLenum, glDrawingDepthStencilRBO)   # GL_RENDERBUFFER
  glRenderbufferStorage(0x8D41.GLenum, 0x88F0.GLenum,          # GL_DEPTH24_STENCIL8
                        GLsizei(w), GLsizei(h))
  # Attach to FBO
  glBindFramebuffer(0x8D40.GLenum, glDrawingFBO)                # GL_FRAMEBUFFER
  glFramebufferTexture2D(0x8D40.GLenum, 0x8CE0.GLenum,         # COLOR_ATTACHMENT0
                         0x0DE1.GLenum, glDrawingColorTex, 0)
  glFramebufferRenderbuffer(0x8D40.GLenum, 0x821A.GLenum,      # DEPTH_STENCIL_ATTACHMENT
                            0x8D41.GLenum, glDrawingDepthStencilRBO)
  let status = glCheckFramebufferStatus(0x8D40.GLenum)
  if status != 0x8CD5.GLenum:   # GL_FRAMEBUFFER_COMPLETE
    stderr.writeLine("[webgl] Drawing buffer FBO incomplete: 0x" &
                     toHex(int(status), 4))
  else:
    stderr.writeLine("[webgl] Drawing buffer FBO " & $w & "x" & $h & " OK")
  glDrawingBufW = w
  glDrawingBufH = h
  # Clear FBO to defined state so compositing shows clean content
  glClearColor(0.0f, 0.0f, 0.0f, 0.0f)
  glClear(0x4000.GLbitfield or 0x0100.GLbitfield or 0x0400.GLbitfield)  # COLOR | DEPTH | STENCIL
  # NOTE: do NOT set gWebGLActive here.  The FBO is created on the first
  # getContext('webgl') call — which may come from a throwaway detection
  # canvas (e.g. GPU vendor query), not from the real display canvas.
  # gWebGLActive is set later by __rw_setWebGLActive(), called from
  # dom_preamble.js when a WebGL canvas is appended to document.body.
  # Leave drawing buffer FBO bound (JS expects "default" = our FBO)

proc jsSetWebGLActive(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_setWebGLActive() — called from dom_preamble.js when a WebGL canvas
  ## is appended to document.body.  Only then do we switch presentAllCanvas2D
  ## to the WebGL compositing path.  Calling getContext('webgl') on a
  ## throwaway detection canvas must NOT activate WebGL mode.
  ## Ignored when forceCanvas mode is active.
  if not gForceCanvasMode:
    gWebGLActive = true
  ctx.newUndefined()

proc jsSetForceCanvas(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_setForceCanvas() — called from the injected preamble when
  ## renderer=canvas is set in package.json.  Blocks any later WebGL
  ## activation and lets the F2 overlay label the mode clearly.
  gForceCanvasMode = true
  ctx.newUndefined()

proc jsResizeDrawingBuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## __rw_resizeDrawingBuffer(w, h) — called when canvas width/height changes
  if args.len < 2: return ctx.newUndefined()
  let w = int(ctx.toInt32(args[0]))
  let h = int(ctx.toInt32(args[1]))
  if w > 0 and h > 0:
    initDrawingBuffer(w, h)
  ctx.newUndefined()

# -- Helpers: GL handle wrappers for ScriptCtx --

proc jsNewGLHandle(ctx: ptr ScriptCtx; id: uint32): ScriptValue =
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "__id", ctx.newInt(int32(id)))
  obj

proc jsNewGLLocHandle(ctx: ptr ScriptCtx; loc: int32): ScriptValue =
  if loc < 0: return ctx.newNull()
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "__id", ctx.newInt(loc))
  obj

proc jsGetGLId(ctx: ptr ScriptCtx; v: ScriptValue): uint32 =
  if ctx.isNull(v) or ctx.isUndefined(v): return 0
  let idVal = ctx.getProp(v, "__id")
  result = uint32(ctx.toInt32(idVal))
  ctx.freeValue(idVal)

proc jsGetGLLocId(ctx: ptr ScriptCtx; v: ScriptValue): int32 =
  if ctx.isNull(v) or ctx.isUndefined(v): return -1
  let idVal = ctx.getProp(v, "__id")
  result = ctx.toInt32(idVal)
  ctx.freeValue(idVal)

# -- Helpers: extract float/int array from either TypedArray or plain JS Array --

proc jsGetFloatArray(ctx: ptr ScriptCtx; v: ScriptValue;
                     buf: var seq[GLfloat]): bool =
  ## Try jsGetBufferData first (TypedArray/ArrayBuffer); if that fails,
  ## iterate a plain JS Array and extract float values into buf.
  ## Returns true if buf has data.
  var size: int
  let data = ctx.getArrayBufferData(v, size)
  if data != nil:
    let count = int(size) div sizeof(GLfloat)
    buf.setLen(count)
    if count > 0:
      copyMem(addr buf[0], data, count * sizeof(GLfloat))
    return count > 0
  # Fallback: plain JS Array
  let lenVal = ctx.getProp(v, "length")
  var arrLen: int32
  arrLen = ctx.toInt32(lenVal)
  ctx.freeValue(lenVal)
  if arrLen <= 0: return false
  buf.setLen(arrLen)
  for i in 0..<arrLen:
    let el = ctx.getIndex(v, uint32(uint32(i)))
    var f: float64
    f = ctx.toFloat64(el)
    ctx.freeValue(el)
    buf[i] = GLfloat(f)
  true

proc jsGetIntArray(ctx: ptr ScriptCtx; v: ScriptValue;
                   buf: var seq[GLint]): bool =
  ## Same as jsGetFloatArray but for int32 uniforms.
  var size: int
  let data = ctx.getArrayBufferData(v, size)
  if data != nil:
    let count = int(size) div sizeof(GLint)
    buf.setLen(count)
    if count > 0:
      copyMem(addr buf[0], data, count * sizeof(GLint))
    return count > 0
  let lenVal = ctx.getProp(v, "length")
  var arrLen: int32
  arrLen = ctx.toInt32(lenVal)
  ctx.freeValue(lenVal)
  if arrLen <= 0: return false
  buf.setLen(arrLen)
  for i in 0..<arrLen:
    let el = ctx.getIndex(v, uint32(uint32(i)))
    var iv: int32
    iv = ctx.toInt32(el)
    ctx.freeValue(el)
    buf[i] = GLint(iv)
  true

proc loadGLProcs() =
  ## Load all OpenGL function pointers via SDL_GL_GetProcAddress.
  ## Must be called after SDL_GL_CreateContext.
  template load(name: untyped) =
    name = cast[typeof(name)](SDL_GL_GetProcAddress(astToStr(name)))

  load(glViewport); load(glClearColor); load(glClear)
  load(glEnable); load(glDisable)
  load(glBlendFunc); load(glBlendFuncSeparate)
  load(glBlendEquation); load(glBlendEquationSeparate); load(glBlendColor)
  load(glDepthFunc); load(glDepthMask); load(glDepthRange); load(glClearDepth)
  load(glCullFace); load(glFrontFace); load(glScissor); load(glLineWidth)
  load(glColorMask)
  load(glStencilFunc); load(glStencilFuncSeparate)
  load(glStencilOp); load(glStencilOpSeparate)
  load(glStencilMask); load(glStencilMaskSeparate)
  load(glClearStencil); load(glPixelStorei)
  load(glFlush); load(glFinish)
  load(glGetError); load(glGetIntegerv); load(glGetFloatv)
  load(glGetBooleanv); load(glGetString); load(glIsEnabled)
  load(glCreateShader); load(glDeleteShader)
  load(glShaderSource); load(glCompileShader)
  load(glGetShaderiv); load(glGetShaderInfoLog); load(glGetShaderSource)
  load(glCreateProgram); load(glDeleteProgram)
  load(glAttachShader); load(glDetachShader); load(glLinkProgram)
  load(glGetProgramiv); load(glGetProgramInfoLog)
  load(glUseProgram); load(glValidateProgram)
  load(glGetAttribLocation); load(glGetUniformLocation); load(glBindAttribLocation)
  load(glGetActiveAttrib); load(glGetActiveUniform)
  load(glGenBuffers); load(glDeleteBuffers); load(glBindBuffer)
  load(glBufferData); load(glBufferSubData)
  load(glVertexAttribPointer)
  load(glEnableVertexAttribArray); load(glDisableVertexAttribArray)
  load(glGenTextures); load(glDeleteTextures); load(glBindTexture)
  load(glActiveTexture)
  load(glTexImage2D); load(glTexSubImage2D)
  load(glTexParameteri); load(glTexParameterf)
  load(glGenerateMipmap); load(glCopyTexImage2D); load(glCopyTexSubImage2D)
  load(glGenFramebuffers); load(glDeleteFramebuffers); load(glBindFramebuffer)
  load(glFramebufferTexture2D); load(glFramebufferRenderbuffer)
  load(glCheckFramebufferStatus)
  load(glGenRenderbuffers); load(glDeleteRenderbuffers); load(glBindRenderbuffer)
  load(glRenderbufferStorage); load(glGetRenderbufferParameteriv)
  load(glDrawArrays); load(glDrawElements)
  load(glUniform1f); load(glUniform2f); load(glUniform3f); load(glUniform4f)
  load(glUniform1i); load(glUniform2i); load(glUniform3i); load(glUniform4i)
  load(glUniform1fv); load(glUniform2fv); load(glUniform3fv); load(glUniform4fv)
  load(glUniform1iv); load(glUniform2iv); load(glUniform3iv); load(glUniform4iv)
  load(glUniformMatrix2fv); load(glUniformMatrix3fv); load(glUniformMatrix4fv)
  load(glReadPixels)
  load(glGenVertexArrays); load(glDeleteVertexArrays); load(glBindVertexArray)
  load(glDrawArraysInstanced); load(glDrawElementsInstanced); load(glVertexAttribDivisor)
  # Optional — may be nil on GL 3.3 (only in GL 4.1+ / GL ES 2.0)
  glGetShaderPrecisionFormat = cast[typeof(glGetShaderPrecisionFormat)](
    SDL_GL_GetProcAddress("glGetShaderPrecisionFormat"))

  # Create and bind the default VAO (Core Profile requires a VAO)
  glGenVertexArrays(1, addr glDefaultVAO)
  glBindVertexArray(glDefaultVAO)

# ===========================================================================
# Phase 4 — WebGL JSCFunction callbacks — grouped by category
# ===========================================================================

# ── State management ────────────────────────────────────────────────────────

proc jsGlViewport(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let x = GLint(ctx.toInt32(args[0]))
  let y = GLint(ctx.toInt32(args[1]))
  let w = GLsizei(ctx.toInt32(args[2]))
  let h = GLsizei(ctx.toInt32(args[3]))
  if x == glCacheVpX and y == glCacheVpY and w == glCacheVpW and h == glCacheVpH:
    return ctx.newUndefined()
  glViewport(x, y, w, h)
  glCacheVpX = x; glCacheVpY = y; glCacheVpW = w; glCacheVpH = h
  ctx.newUndefined()

proc jsGlClearColor(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glClearColor(float32(ctx.toFloat64(args[0])), float32(ctx.toFloat64(args[1])),
               float32(ctx.toFloat64(args[2])), float32(ctx.toFloat64(args[3])))
  ctx.newUndefined()

proc jsGlClear(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glClear(GLbitfield(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlEnable(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cap = GLenum(ctx.toUint32(args[0]))
  let idx = glCapIndex(cap)
  if idx >= 0:
    if glCapState[idx] == 1: return ctx.newUndefined()
    glCapState[idx] = 1
  glEnable(cap)
  ctx.newUndefined()

proc jsGlDisable(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cap = GLenum(ctx.toUint32(args[0]))
  let idx = glCapIndex(cap)
  if idx >= 0:
    if glCapState[idx] == 0: return ctx.newUndefined()
    glCapState[idx] = 0
  glDisable(cap)
  ctx.newUndefined()

proc jsGlBlendFunc(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let src = GLenum(ctx.toUint32(args[0]))
  let dst = GLenum(ctx.toUint32(args[1]))
  if src == glCacheBlendSrcRGB and dst == glCacheBlendDstRGB and
     src == glCacheBlendSrcA and dst == glCacheBlendDstA:
    return ctx.newUndefined()
  glBlendFunc(src, dst)
  glCacheBlendSrcRGB = src; glCacheBlendDstRGB = dst
  glCacheBlendSrcA = src; glCacheBlendDstA = dst
  ctx.newUndefined()

proc jsGlBlendFuncSeparate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let srcRGB = GLenum(ctx.toUint32(args[0]))
  let dstRGB = GLenum(ctx.toUint32(args[1]))
  let srcA   = GLenum(ctx.toUint32(args[2]))
  let dstA   = GLenum(ctx.toUint32(args[3]))
  if srcRGB == glCacheBlendSrcRGB and dstRGB == glCacheBlendDstRGB and
     srcA == glCacheBlendSrcA and dstA == glCacheBlendDstA:
    return ctx.newUndefined()
  glBlendFuncSeparate(srcRGB, dstRGB, srcA, dstA)
  glCacheBlendSrcRGB = srcRGB; glCacheBlendDstRGB = dstRGB
  glCacheBlendSrcA = srcA; glCacheBlendDstA = dstA
  ctx.newUndefined()

proc jsGlBlendEquation(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let mode = GLenum(ctx.toUint32(args[0]))
  if mode == glCacheBlendEqRGB and mode == glCacheBlendEqA:
    return ctx.newUndefined()
  glBlendEquation(mode)
  glCacheBlendEqRGB = mode; glCacheBlendEqA = mode
  ctx.newUndefined()

proc jsGlBlendEquationSeparate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let modeRGB = GLenum(ctx.toUint32(args[0]))
  let modeA   = GLenum(ctx.toUint32(args[1]))
  if modeRGB == glCacheBlendEqRGB and modeA == glCacheBlendEqA:
    return ctx.newUndefined()
  glBlendEquationSeparate(modeRGB, modeA)
  glCacheBlendEqRGB = modeRGB; glCacheBlendEqA = modeA
  ctx.newUndefined()

proc jsGlBlendColor(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glBlendColor(float32(ctx.toFloat64(args[0])), float32(ctx.toFloat64(args[1])),
               float32(ctx.toFloat64(args[2])), float32(ctx.toFloat64(args[3])))
  ctx.newUndefined()

proc jsGlDepthFunc(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDepthFunc(GLenum(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlDepthMask(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let flag = ctx.toBool(args[0])
  let val: int8 = if flag: 1 else: 0
  if val == glCacheDepthMask: return ctx.newUndefined()
  glDepthMask(GLboolean(val))
  glCacheDepthMask = val
  ctx.newUndefined()

proc jsGlDepthRange(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDepthRange(ctx.toFloat64(args[0]), ctx.toFloat64(args[1]))
  ctx.newUndefined()

proc jsGlClearDepth(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glClearDepth(ctx.toFloat64(args[0]))
  ctx.newUndefined()

proc jsGlCullFace(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glCullFace(GLenum(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlFrontFace(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glFrontFace(GLenum(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlScissor(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let x = GLint(ctx.toInt32(args[0]))
  let y = GLint(ctx.toInt32(args[1]))
  let w = GLsizei(ctx.toInt32(args[2]))
  let h = GLsizei(ctx.toInt32(args[3]))
  if x == glCacheScX and y == glCacheScY and w == glCacheScW and h == glCacheScH:
    return ctx.newUndefined()
  glScissor(x, y, w, h)
  glCacheScX = x; glCacheScY = y; glCacheScW = w; glCacheScH = h
  ctx.newUndefined()

proc jsGlLineWidth(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glLineWidth(float32(ctx.toFloat64(args[0])))
  ctx.newUndefined()

proc jsGlColorMask(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let r: int8 = if ctx.toBool(args[0]): 1 else: 0
  let g: int8 = if ctx.toBool(args[1]): 1 else: 0
  let b: int8 = if ctx.toBool(args[2]): 1 else: 0
  let a: int8 = if ctx.toBool(args[3]): 1 else: 0
  if r == glCacheColorMask[0] and g == glCacheColorMask[1] and
     b == glCacheColorMask[2] and a == glCacheColorMask[3]:
    return ctx.newUndefined()
  glColorMask(GLboolean(r), GLboolean(g), GLboolean(b), GLboolean(a))
  glCacheColorMask = [r, g, b, a]
  ctx.newUndefined()

proc jsGlStencilFunc(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glStencilFunc(GLenum(ctx.toUint32(args[0])), GLint(ctx.toInt32(args[1])),
                GLuint(ctx.toUint32(args[2])))
  ctx.newUndefined()

proc jsGlStencilFuncSeparate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glStencilFuncSeparate(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                        GLint(ctx.toInt32(args[2])), GLuint(ctx.toUint32(args[3])))
  ctx.newUndefined()

proc jsGlStencilOp(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glStencilOp(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
              GLenum(ctx.toUint32(args[2])))
  ctx.newUndefined()

proc jsGlStencilOpSeparate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glStencilOpSeparate(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                      GLenum(ctx.toUint32(args[2])), GLenum(ctx.toUint32(args[3])))
  ctx.newUndefined()

proc jsGlStencilMask(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glStencilMask(GLuint(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlStencilMaskSeparate(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glStencilMaskSeparate(GLenum(ctx.toUint32(args[0])), GLuint(ctx.toUint32(args[1])))
  ctx.newUndefined()

proc jsGlClearStencil(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glClearStencil(GLint(ctx.toInt32(args[0])))
  ctx.newUndefined()

proc jsGlPixelStorei(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let pname = GLenum(ctx.toUint32(args[0]))
  let param = ctx.toInt32(args[1])
  # Handle WebGL-specific pixel storage params
  if pname == 0x9240'u32:   # UNPACK_FLIP_Y_WEBGL
    glUnpackFlipY = param != 0
  elif pname == 0x9241'u32: # UNPACK_PREMULTIPLY_ALPHA_WEBGL
    glUnpackPremultiplyAlpha = param != 0
  elif pname == 0x9243'u32: # UNPACK_COLORSPACE_CONVERSION_WEBGL
    discard  # no-op
  else:
    glPixelStorei(pname, GLint(param))
  ctx.newUndefined()

proc jsGlFlush(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glFlush()
  ctx.newUndefined()

proc jsGlFinish(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glFinish()
  ctx.newUndefined()

proc jsGlGetError(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ctx.newInt(int32(glGetError()))

proc jsGlIsEnabled(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let cap = GLenum(ctx.toUint32(args[0]))
  let idx = glCapIndex(cap)
  if idx >= 0 and glCapState[idx] >= 0:
    return ctx.newBool(bool(cint(glCapState[idx])))
  ctx.newBool(bool(cint(glIsEnabled(cap))))

# ── Shaders ──────────────────────────────────────────────────────────────

proc jsGlCreateShader(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let id = glCreateShader(GLenum(ctx.toUint32(args[0])))
  jsNewGLHandle(ctx, id)

proc jsGlDeleteShader(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDeleteShader(GLuint(jsGetGLId(ctx, args[0])))
  ctx.newUndefined()

proc jsGlShaderSource(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let shader = GLuint(jsGetGLId(ctx, args[0]))
  var src = ctx.toNimString(args[1])
  # Preprocess GLSL ES → desktop GLSL 3.30 Core:
  # 1. Strip 'precision mediump/highp/lowp float/int;' lines
  # 2. Add #version 330 core if not present
  # 3. Convert attribute→in, varying→in/out (vertex→out, fragment→in)
  var lines = src.split('\n')
  var hasVersion = false
  var isFragShader = false
  for line in lines:
    let trimmed = line.strip()
    if trimmed.startsWith("#version"): hasVersion = true
    if trimmed.contains("gl_FragColor") or trimmed.contains("gl_FragData"):
      isFragShader = true
  var output: seq[string] = @[]
  if not hasVersion:
    output.add("#version 330 core")
  if isFragShader:
    output.add("out vec4 _rw_FragColor;")
  for line in lines:
    let trimmed = line.strip()
    if trimmed.startsWith("precision ") and (trimmed.contains("float") or trimmed.contains("int")) and trimmed.endsWith(";"):
      continue  # strip precision qualifiers
    if trimmed.startsWith("#version"):
      continue  # we already added our own
    var l = line
    if isFragShader:
      l = l.replace("varying ", "in ")
      l = l.replace("gl_FragColor", "_rw_FragColor")
      l = l.replace("gl_FragData[0]", "_rw_FragColor")
    else:
      l = l.replace("attribute ", "in ")
      l = l.replace("varying ", "out ")
    # Replace texture2D→texture (GLSL 3.30)
    l = l.replace("texture2D(", "texture(")
    l = l.replace("textureCube(", "texture(")
    output.add(l)
  src = output.join("\n")
  var csrc = cstring(src)
  var slen = GLint(src.len)
  glShaderSource(shader, 1, addr csrc, addr slen)
  ctx.newUndefined()

proc jsGlCompileShader(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let id = GLuint(jsGetGLId(ctx, args[0]))
  glCompileShader(id)
  # Diagnostic: log compilation errors so shader failures are visible
  var status: GLint
  glGetShaderiv(id, 0x8B81'u32, addr status)  # GL_COMPILE_STATUS
  if status == 0:
    var logLen: GLint
    glGetShaderiv(id, 0x8B84'u32, addr logLen)  # GL_INFO_LOG_LENGTH
    if logLen > 0:
      var buf = newString(logLen)
      glGetShaderInfoLog(id, GLsizei(logLen), nil, cstring(buf))
      stderr.writeLine("[GL] shader compile FAILED (id=" & $id & "): " & buf)
    else:
      stderr.writeLine("[GL] shader compile FAILED (id=" & $id & ") (no info log)")
    # Also dump the translated source for diagnosis
    var srcLen: GLint
    glGetShaderiv(id, 0x8B88'u32, addr srcLen)  # GL_SHADER_SOURCE_LENGTH
    if srcLen > 0:
      var srcBuf = newString(srcLen)
      glGetShaderSource(id, GLsizei(srcLen), nil, cstring(srcBuf))
      stderr.writeLine("[GL] shader source:\n" & srcBuf)
  ctx.newUndefined()

proc jsGlGetShaderParameter(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let shader = GLuint(jsGetGLId(ctx, args[0]))
  let pname = GLenum(ctx.toUint32(args[1]))
  var v: GLint
  glGetShaderiv(shader, pname, addr v)
  if pname == 0x8B81'u32 or pname == 0x8B80'u32:  # COMPILE_STATUS, DELETE_STATUS
    return ctx.newBool(bool(cint(v)))
  ctx.newInt(v)

proc jsGlGetShaderInfoLog(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let shader = GLuint(jsGetGLId(ctx, args[0]))
  var logLen: GLint
  glGetShaderiv(shader, 0x8B84'u32, addr logLen)  # INFO_LOG_LENGTH
  if logLen <= 0: return ctx.newString("")
  var buf = newString(logLen)
  var actual: GLsizei
  glGetShaderInfoLog(shader, GLsizei(logLen), addr actual, cstring(buf))
  buf.setLen(actual)
  ctx.newString(cstring(buf))

proc jsGlCreateProgram(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  jsNewGLHandle(ctx, glCreateProgram())

proc jsGlDeleteProgram(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let id = GLuint(jsGetGLId(ctx, args[0]))
  glDeleteProgram(id)
  if id == glCacheProgram: glCacheProgram = 0
  ctx.newUndefined()

proc jsGlAttachShader(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glAttachShader(GLuint(jsGetGLId(ctx, args[0])),
                 GLuint(jsGetGLId(ctx, args[1])))
  ctx.newUndefined()

proc jsGlDetachShader(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDetachShader(GLuint(jsGetGLId(ctx, args[0])),
                 GLuint(jsGetGLId(ctx, args[1])))
  ctx.newUndefined()

proc jsGlLinkProgram(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let id = GLuint(jsGetGLId(ctx, args[0]))
  glLinkProgram(id)
  # Diagnostic: log link errors so program failures are visible
  var status: GLint
  glGetProgramiv(id, 0x8B82'u32, addr status)  # GL_LINK_STATUS
  if status == 0:
    var logLen: GLint
    glGetProgramiv(id, 0x8B84'u32, addr logLen)  # GL_INFO_LOG_LENGTH
    if logLen > 0:
      var buf = newString(logLen)
      glGetProgramInfoLog(id, GLsizei(logLen), nil, cstring(buf))
      stderr.writeLine("[GL] program link FAILED (id=" & $id & "): " & buf)
    else:
      stderr.writeLine("[GL] program link FAILED (id=" & $id & ") (no info log)")
  ctx.newUndefined()

proc jsGlGetProgramiv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  let pname = GLenum(ctx.toUint32(args[1]))
  var v: GLint
  glGetProgramiv(prog, pname, addr v)
  if pname == 0x8B82'u32 or pname == 0x8B83'u32 or pname == 0x8B80'u32:
    # LINK_STATUS, VALIDATE_STATUS, DELETE_STATUS
    return ctx.newBool(bool(cint(v)))
  ctx.newInt(v)

proc jsGlGetProgramInfoLog(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  var logLen: GLint
  glGetProgramiv(prog, 0x8B84'u32, addr logLen)  # INFO_LOG_LENGTH
  if logLen <= 0: return ctx.newString("")
  var buf = newString(logLen)
  var actual: GLsizei
  glGetProgramInfoLog(prog, GLsizei(logLen), addr actual, cstring(buf))
  buf.setLen(actual)
  ctx.newString(cstring(buf))

proc jsGlUseProgram(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  if prog == glCacheProgram: return ctx.newUndefined()
  glUseProgram(prog)
  glCacheProgram = prog
  ctx.newUndefined()

proc jsGlValidateProgram(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glValidateProgram(GLuint(jsGetGLId(ctx, args[0])))
  ctx.newUndefined()

# ── Attributes / Uniforms Location ───────────────────────────────────────

proc jsGlGetAttribLocation(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  let name = ctx.toNimString(args[1])
  ctx.newInt(glGetAttribLocation(prog, cstring(name)))

proc jsGlGetUniformLocation(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  let name = ctx.toNimString(args[1])
  jsNewGLLocHandle(ctx, glGetUniformLocation(prog, cstring(name)))

proc jsGlBindAttribLocation(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  glBindAttribLocation(prog, GLuint(ctx.toUint32(args[1])), cstring(ctx.toNimString(args[2])))
  ctx.newUndefined()

proc jsGlEnableVertexAttribArray(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glEnableVertexAttribArray(GLuint(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlDisableVertexAttribArray(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDisableVertexAttribArray(GLuint(ctx.toUint32(args[0])))
  ctx.newUndefined()

proc jsGlVertexAttribPointer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glVertexAttribPointer(
    GLuint(ctx.toUint32(args[0])),
    GLint(ctx.toInt32(args[1])),
    GLenum(ctx.toUint32(args[2])),
    GLboolean(if ctx.toBool(args[3]): 1 else: 0),
    GLsizei(ctx.toInt32(args[4])),
    cast[pointer](ctx.toInt32(args[5]))  # byte offset → pointer
  )
  ctx.newUndefined()

proc jsGlGetActiveAttrib(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  let index = GLuint(ctx.toUint32(args[1]))
  var nameBuf: array[256, char]
  var length: GLsizei
  var size: GLint
  var typ: GLenum
  glGetActiveAttrib(prog, index, 256, addr length, addr size, addr typ, cast[cstring](addr nameBuf[0]))
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "size", ctx.newInt(size))
  ctx.setPropSteal(obj, "type", ctx.newInt(int32(typ)))
  ctx.setPropSteal(obj, "name", ctx.newStringLen(cast[cstring](addr nameBuf[0]), int(csize_t(length))))
  obj

proc jsGlGetActiveUniform(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let prog = GLuint(jsGetGLId(ctx, args[0]))
  let index = GLuint(ctx.toUint32(args[1]))
  var nameBuf: array[256, char]
  var length: GLsizei
  var size: GLint
  var typ: GLenum
  glGetActiveUniform(prog, index, 256, addr length, addr size, addr typ, cast[cstring](addr nameBuf[0]))
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "size", ctx.newInt(size))
  ctx.setPropSteal(obj, "type", ctx.newInt(int32(typ)))
  ctx.setPropSteal(obj, "name", ctx.newStringLen(cast[cstring](addr nameBuf[0]), int(csize_t(length))))
  obj

# ── Buffers ──────────────────────────────────────────────────────────────

proc jsGlCreateBuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id: GLuint
  glGenBuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteBuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id = GLuint(jsGetGLId(ctx, args[0]))
  glDeleteBuffers(1, addr id)
  if id == glCacheArrayBuf: glCacheArrayBuf = 0
  if id == glCacheElementBuf: glCacheElementBuf = 0
  ctx.newUndefined()

proc jsGlBindBuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let target = GLenum(ctx.toUint32(args[0]))
  let buf = GLuint(jsGetGLId(ctx, args[1]))
  if target == 0x8892.GLenum:       # GL_ARRAY_BUFFER
    if buf == glCacheArrayBuf: return ctx.newUndefined()
    glCacheArrayBuf = buf
  elif target == 0x8893.GLenum:     # GL_ELEMENT_ARRAY_BUFFER
    if buf == glCacheElementBuf: return ctx.newUndefined()
    glCacheElementBuf = buf
  glBindBuffer(target, buf)
  ctx.newUndefined()

proc jsGlBufferData(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let target = GLenum(ctx.toUint32(args[0]))
  let usage  = GLenum(ctx.toUint32(args[2]))
  if ctx.isNumber(args[1]):
    # bufferData(target, size, usage) — allocate empty
    let size = ctx.toInt32(args[1])
    glBufferData(target, int(size), nil, usage)
  else:
    # bufferData(target, typedArray, usage) — allocate with data
    var size: int
    let data = ctx.getArrayBufferData(args[1], size)
    glBufferData(target, int(size), data, usage)
  ctx.newUndefined()

proc jsGlBufferSubData(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let target = GLenum(ctx.toUint32(args[0]))
  let offset = ctx.toInt32(args[1])
  var size: int
  let data = ctx.getArrayBufferData(args[2], size)
  if data != nil:
    glBufferSubData(target, int(offset), int(size), data)
  ctx.newUndefined()

# ── Textures ─────────────────────────────────────────────────────────────

proc jsGlCreateTexture(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id: GLuint
  glGenTextures(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteTexture(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id = GLuint(jsGetGLId(ctx, args[0]))
  glDeleteTextures(1, addr id)
  for i in 0..<glCacheBoundTex2D.len:
    if glCacheBoundTex2D[i] == id: glCacheBoundTex2D[i] = 0
  ctx.newUndefined()

proc jsGlBindTexture(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let target = GLenum(ctx.toUint32(args[0]))
  let tex = GLuint(jsGetGLId(ctx, args[1]))
  if target == 0x0DE1.GLenum:       # GL_TEXTURE_2D
    let unit = int(uint32(glCacheActiveTexUnit) - 0x84C0'u32)
    if unit >= 0 and unit < 16:
      if glCacheBoundTex2D[unit] == tex: return ctx.newUndefined()
      glCacheBoundTex2D[unit] = tex
  glBindTexture(target, tex)
  ctx.newUndefined()

proc jsGlActiveTexture(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let unit = GLenum(ctx.toUint32(args[0]))
  if unit == glCacheActiveTexUnit: return ctx.newUndefined()
  glActiveTexture(unit)
  glCacheActiveTexUnit = unit
  ctx.newUndefined()

proc jsGlTexImage2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  if args.len >= 9:
    # texImage2D(target, level, internalformat, width, height, border, format, type, data)
    let target = GLenum(ctx.toUint32(args[0]))
    let level  = GLint(ctx.toInt32(args[1]))
    let ifmt   = GLint(ctx.toInt32(args[2]))
    let width  = GLsizei(ctx.toInt32(args[3]))
    let height = GLsizei(ctx.toInt32(args[4]))
    let border = GLint(ctx.toInt32(args[5]))
    let fmt    = GLenum(ctx.toUint32(args[6]))
    let typ    = GLenum(ctx.toUint32(args[7]))
    if (ctx.isNull(args[8]) or ctx.isUndefined(args[8])):
      glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, nil)
    else:
      var dataLen: int
      let data = ctx.getArrayBufferData(args[8], dataLen)
      glUploadTexImage(target, level, ifmt, width, height, border, fmt, typ, data)
  elif args.len >= 6:
    # texImage2D(target, level, internalformat, format, type, source)
    # source is HTMLImageElement, HTMLCanvasElement, or null
    let target = GLenum(ctx.toUint32(args[0]))
    let level  = GLint(ctx.toInt32(args[1]))
    let ifmt   = GLint(ctx.toInt32(args[2]))
    let fmt    = GLenum(ctx.toUint32(args[3]))
    let typ    = GLenum(ctx.toUint32(args[4]))
    let source = args[5]
    # Handle null/undefined source (e.g. PIXI's empty placeholder texture).
    # In real WebGL this generates INVALID_VALUE; we allocate a 1x1 empty tex.
    if (ctx.isNull(source) or ctx.isUndefined(source)):
      glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, nil)
      return ctx.newUndefined()
    # Check if source is a canvas element with a 2D context (__ctxId)
    let ctxIdProp = ctx.getProp(source, "__ctxId")
    if ctx.isNumber(ctxIdProp):
      var srcId: int32
      srcId = ctx.toInt32(ctxIdProp)
      ctx.freeValue(ctxIdProp)
      if srcId >= 0 and srcId < int32(canvas2dStates.len):
        let sc = addr canvas2dStates[srcId]
        if sc.pixels.len > 0:
          glUploadTexImage(target, level, ifmt, GLsizei(sc.width), GLsizei(sc.height),
                           0, fmt, typ, addr sc.pixels[0])
        else:
          var px: array[4, uint8] = [255'u8, 255, 255, 255]
          glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, addr px[0])
    else:
      ctx.freeValue(ctxIdProp)
      let pxProp = ctx.getProp(source, "__pixelData")
      if not ctx.isNull(pxProp) and not ctx.isUndefined(pxProp):
        # Image has pixel data — extract width/height and buffer
        let wProp = ctx.getProp(source, "naturalWidth")
        let hProp = ctx.getProp(source, "naturalHeight")
        var iw, ih: int32
        iw = ctx.toInt32(wProp)
        ih = ctx.toInt32(hProp)
        var dataLen: int
        let data = ctx.getArrayBufferData(pxProp, dataLen)
        # Our decoded pixel data is ALWAYS RGBA32 (4 bytes/pixel).
        # If the JS requested GL_RGB (0x1907), uploading as GL_RGB would cause
        # row-stride misalignment and color corruption because applyUnpackTransform
        # and processImageQueue both output 4-byte RGBA rows, not 3-byte RGB rows.
        # Fix: override the format to GL_RGBA for all image-source uploads.
        let uploadIfmt = if ifmt == GLint(0x1907): GLint(0x1908) else: ifmt  # GL_RGB→GL_RGBA
        let uploadFmt  = if fmt  == GLenum(0x1907): GLenum(0x1908) else: fmt
        if ifmt != uploadIfmt:
          stderr.writeLine("[GL:texImage2D] img " & $iw & "x" & $ih & " ifmt=" & $ifmt & "→" & $uploadIfmt & " (RGB→RGBA forced) premul=" & $glUnpackPremultiplyAlpha)
        else:
          stderr.writeLine("[GL:texImage2D] img " & $iw & "x" & $ih & " ifmt=" & $uploadIfmt & " premul=" & $glUnpackPremultiplyAlpha)
        glUploadTexImage(target, level, uploadIfmt, GLsizei(iw), GLsizei(ih), 0, uploadFmt, typ, data)
        ctx.freeValue(wProp)
        ctx.freeValue(hProp)
      else:
        # Fallback: 1x1 white pixel — this means __pixelData was missing!
        stderr.writeLine("[GL:texImage2D] WARNING: no __pixelData on Image source")
        var px: array[4, uint8] = [255'u8, 255, 255, 255]
        glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, addr px[0])
      ctx.freeValue(pxProp)
  ctx.newUndefined()

proc jsGlTexSubImage2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  if args.len >= 9:
    # texSubImage2D(target, level, xoffset, yoffset, width, height, format, type, data)
    var dataLen: int
    let data = ctx.getArrayBufferData(args[8], dataLen)
    glUploadTexSub(GLenum(ctx.toUint32(args[0])), GLint(ctx.toInt32(args[1])),
                   GLint(ctx.toInt32(args[2])), GLint(ctx.toInt32(args[3])),
                   GLsizei(ctx.toInt32(args[4])), GLsizei(ctx.toInt32(args[5])),
                   GLenum(ctx.toUint32(args[6])), GLenum(ctx.toUint32(args[7])), data)
  elif args.len >= 7:
    # texSubImage2D(target, level, xoffset, yoffset, format, type, source)
    let target  = GLenum(ctx.toUint32(args[0]))
    let level   = GLint(ctx.toInt32(args[1]))
    let xoff    = GLint(ctx.toInt32(args[2]))
    let yoff    = GLint(ctx.toInt32(args[3]))
    let fmt     = GLenum(ctx.toUint32(args[4]))
    let typ     = GLenum(ctx.toUint32(args[5]))
    let source  = args[6]
    if not ctx.isNull(source) and not ctx.isUndefined(source):
      # Try canvas (__ctxId) first, then image (__pixelData)
      let ctxIdProp = ctx.getProp(source, "__ctxId")
      if ctx.isNumber(ctxIdProp):
        var srcId: int32
        srcId = ctx.toInt32(ctxIdProp)
        ctx.freeValue(ctxIdProp)
        if srcId >= 0 and srcId < int32(canvas2dStates.len):
          let sc = addr canvas2dStates[srcId]
          if sc.pixels.len > 0:
            glUploadTexSub(target, level, xoff, yoff,
                           GLsizei(sc.width), GLsizei(sc.height),
                           fmt, typ, addr sc.pixels[0])
      else:
        ctx.freeValue(ctxIdProp)
        let pxProp = ctx.getProp(source, "__pixelData")
        if not ctx.isNull(pxProp) and not ctx.isUndefined(pxProp):
          let wProp = ctx.getProp(source, "naturalWidth")
          let hProp = ctx.getProp(source, "naturalHeight")
          var iw, ih: int32
          iw = ctx.toInt32(wProp)
          ih = ctx.toInt32(hProp)
          var dataLen: int
          let data = ctx.getArrayBufferData(pxProp, dataLen)
          if data != nil:
            glUploadTexSub(target, level, xoff, yoff,
                           GLsizei(iw), GLsizei(ih), fmt, typ, data)
          ctx.freeValue(wProp)
          ctx.freeValue(hProp)
        ctx.freeValue(pxProp)
  ctx.newUndefined()

# ── Copy tex functions ───────────────────────────────────────────────────

proc jsGlCopyTexImage2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glCopyTexImage2D(GLenum(ctx.toUint32(args[0])), GLint(ctx.toInt32(args[1])),
                   GLenum(ctx.toUint32(args[2])),
                   GLint(ctx.toInt32(args[3])), GLint(ctx.toInt32(args[4])),
                   GLsizei(ctx.toInt32(args[5])), GLsizei(ctx.toInt32(args[6])),
                   GLint(ctx.toInt32(args[7])))
  ctx.newUndefined()

proc jsGlCopyTexSubImage2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glCopyTexSubImage2D(GLenum(ctx.toUint32(args[0])), GLint(ctx.toInt32(args[1])),
                      GLint(ctx.toInt32(args[2])), GLint(ctx.toInt32(args[3])),
                      GLint(ctx.toInt32(args[4])), GLint(ctx.toInt32(args[5])),
                      GLsizei(ctx.toInt32(args[6])), GLsizei(ctx.toInt32(args[7])))
  ctx.newUndefined()

proc jsGlTexParameteri(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glTexParameteri(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                  GLint(ctx.toInt32(args[2])))
  ctx.newUndefined()

proc jsGlTexParameterf(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glTexParameterf(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                  float32(ctx.toFloat64(args[2])))
  ctx.newUndefined()

proc jsGlGenerateMipmap(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glGenerateMipmap(GLenum(ctx.toUint32(args[0])))
  ctx.newUndefined()

# ── Framebuffers / Renderbuffers ─────────────────────────────────────────

proc jsGlCreateFramebuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id: GLuint
  glGenFramebuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteFramebuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id = GLuint(jsGetGLId(ctx, args[0]))
  glDeleteFramebuffers(1, addr id)
  ctx.newUndefined()

proc jsGlBindFramebuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let target = GLenum(ctx.toUint32(args[0]))
  let id = GLuint(jsGetGLId(ctx, args[1]))
  glJSBoundFBO = id
  if id == 0 and glDrawingFBO != 0:
    # Redirect "default framebuffer" to our drawing buffer FBO
    glBindFramebuffer(target, glDrawingFBO)
  else:
    glBindFramebuffer(target, id)
  ctx.newUndefined()

proc jsGlFramebufferTexture2D(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glFramebufferTexture2D(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                         GLenum(ctx.toUint32(args[2])),
                         GLuint(jsGetGLId(ctx, args[3])),
                         GLint(ctx.toInt32(args[4])))
  ctx.newUndefined()

proc jsGlFramebufferRenderbuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glFramebufferRenderbuffer(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                            GLenum(ctx.toUint32(args[2])),
                            GLuint(jsGetGLId(ctx, args[3])))
  ctx.newUndefined()

proc jsGlCheckFramebufferStatus(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ctx.newInt(int32(glCheckFramebufferStatus(GLenum(ctx.toUint32(args[0])))))

proc jsGlCreateRenderbuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id: GLuint
  glGenRenderbuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteRenderbuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  var id = GLuint(jsGetGLId(ctx, args[0]))
  glDeleteRenderbuffers(1, addr id)
  ctx.newUndefined()

proc jsGlBindRenderbuffer(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glBindRenderbuffer(GLenum(ctx.toUint32(args[0])), GLuint(jsGetGLId(ctx, args[1])))
  ctx.newUndefined()

proc jsGlRenderbufferStorage(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glRenderbufferStorage(GLenum(ctx.toUint32(args[0])), GLenum(ctx.toUint32(args[1])),
                        GLsizei(ctx.toInt32(args[2])), GLsizei(ctx.toInt32(args[3])))
  ctx.newUndefined()

# ── Drawing ──────────────────────────────────────────────────────────────

proc jsGlDrawArrays(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDrawArrays(GLenum(ctx.toUint32(args[0])), GLint(ctx.toInt32(args[1])),
               GLsizei(ctx.toInt32(args[2])))
  ctx.newUndefined()

proc jsGlDrawElements(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glDrawElements(GLenum(ctx.toUint32(args[0])), GLsizei(ctx.toInt32(args[1])),
                 GLenum(ctx.toUint32(args[2])),
                 cast[pointer](ctx.toInt32(args[3])))  # byte offset → pointer
  ctx.newUndefined()

# ── Uniforms ─────────────────────────────────────────────────────────────

proc jsGlUniform1f(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform1f(jsGetGLLocId(ctx, args[0]), float32(ctx.toFloat64(args[1])))
  ctx.newUndefined()

proc jsGlUniform2f(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform2f(jsGetGLLocId(ctx, args[0]), float32(ctx.toFloat64(args[1])), float32(ctx.toFloat64(args[2])))
  ctx.newUndefined()

proc jsGlUniform3f(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform3f(jsGetGLLocId(ctx, args[0]), float32(ctx.toFloat64(args[1])),
              float32(ctx.toFloat64(args[2])), float32(ctx.toFloat64(args[3])))
  ctx.newUndefined()

proc jsGlUniform4f(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform4f(jsGetGLLocId(ctx, args[0]), float32(ctx.toFloat64(args[1])),
              float32(ctx.toFloat64(args[2])), float32(ctx.toFloat64(args[3])), float32(ctx.toFloat64(args[4])))
  ctx.newUndefined()

proc jsGlUniform1i(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform1i(jsGetGLLocId(ctx, args[0]), GLint(ctx.toInt32(args[1])))
  ctx.newUndefined()

proc jsGlUniform2i(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform2i(jsGetGLLocId(ctx, args[0]), GLint(ctx.toInt32(args[1])),
              GLint(ctx.toInt32(args[2])))
  ctx.newUndefined()

proc jsGlUniform3i(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform3i(jsGetGLLocId(ctx, args[0]), GLint(ctx.toInt32(args[1])),
              GLint(ctx.toInt32(args[2])), GLint(ctx.toInt32(args[3])))
  ctx.newUndefined()

proc jsGlUniform4i(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  glUniform4i(jsGetGLLocId(ctx, args[0]), GLint(ctx.toInt32(args[1])),
              GLint(ctx.toInt32(args[2])), GLint(ctx.toInt32(args[3])),
              GLint(ctx.toInt32(args[4])))
  ctx.newUndefined()

# Uniform*v and UniformMatrix*fv — handle both TypedArray and plain JS Array

proc jsGlUniform1fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[1], buf):
    glUniform1fv(loc, GLsizei(buf.len), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform2fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[1], buf):
    glUniform2fv(loc, GLsizei(buf.len div 2), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform3fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[1], buf):
    glUniform3fv(loc, GLsizei(buf.len div 3), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform4fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[1], buf):
    glUniform4fv(loc, GLsizei(buf.len div 4), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform1iv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLint]
  if jsGetIntArray(ctx, args[1], buf):
    glUniform1iv(loc, GLsizei(buf.len), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform2iv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLint]
  if jsGetIntArray(ctx, args[1], buf):
    glUniform2iv(loc, GLsizei(buf.len div 2), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform3iv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLint]
  if jsGetIntArray(ctx, args[1], buf):
    glUniform3iv(loc, GLsizei(buf.len div 3), addr buf[0])
  ctx.newUndefined()

proc jsGlUniform4iv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  var buf: seq[GLint]
  if jsGetIntArray(ctx, args[1], buf):
    glUniform4iv(loc, GLsizei(buf.len div 4), addr buf[0])
  ctx.newUndefined()

proc jsGlUniformMatrix2fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  let transpose = GLboolean(if ctx.toBool(args[1]): 1 else: 0)
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[2], buf):
    glUniformMatrix2fv(loc, GLsizei(buf.len div 4), transpose, addr buf[0])
  ctx.newUndefined()

proc jsGlUniformMatrix3fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  let transpose = GLboolean(if ctx.toBool(args[1]): 1 else: 0)
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[2], buf):
    glUniformMatrix3fv(loc, GLsizei(buf.len div 9), transpose, addr buf[0])
  ctx.newUndefined()

proc jsGlUniformMatrix4fv(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let loc = jsGetGLLocId(ctx, args[0])
  let transpose = GLboolean(if ctx.toBool(args[1]): 1 else: 0)
  var buf: seq[GLfloat]
  if jsGetFloatArray(ctx, args[2], buf):
    glUniformMatrix4fv(loc, GLsizei(buf.len div 16), transpose, addr buf[0])
  ctx.newUndefined()

# ── Reading ──────────────────────────────────────────────────────────────

proc jsGlReadPixels(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  if args.len >= 7:
    var dataLen: int
    let data = ctx.getArrayBufferData(args[6], dataLen)
    if data != nil:
      glReadPixels(GLint(ctx.toInt32(args[0])), GLint(ctx.toInt32(args[1])),
                   GLsizei(ctx.toInt32(args[2])), GLsizei(ctx.toInt32(args[3])),
                   GLenum(ctx.toUint32(args[4])), GLenum(ctx.toUint32(args[5])), data)
  ctx.newUndefined()

# ── Query / Parameter ────────────────────────────────────────────────────

proc jsGlGetParameter(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let pname = GLenum(ctx.toUint32(args[0]))
  case pname
  of 0x1F00'u32:  # VENDOR
    let s = glGetString(pname)
    if s != nil: return ctx.newString(cast[cstring](s))
    return ctx.newString("rwebview")
  of 0x1F01'u32:  # RENDERER
    let s = glGetString(pname)
    if s != nil: return ctx.newString(cast[cstring](s))
    return ctx.newString("rwebview OpenGL")
  of 0x9245'u32:  # UNMASKED_VENDOR_WEBGL (WEBGL_debug_renderer_info)
    let s = glGetString(0x1F00'u32)  # GL_VENDOR
    if s != nil: return ctx.newString(cast[cstring](s))
    return ctx.newString("rwebview")
  of 0x9246'u32:  # UNMASKED_RENDERER_WEBGL (WEBGL_debug_renderer_info)
    let s = glGetString(0x1F01'u32)  # GL_RENDERER
    if s != nil: return ctx.newString(cast[cstring](s))
    return ctx.newString("rwebview OpenGL")
  of 0x1F02'u32:  # VERSION
    return ctx.newString("WebGL 1.0")
  of 0x8B8C'u32:  # SHADING_LANGUAGE_VERSION
    return ctx.newString("WebGL GLSL ES 1.0")
  of 0x0BA2'u32:  # VIEWPORT
    var v: array[4, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = ctx.newArray()
    for i in 0..3:
      ctx.setIndexSteal(arr, uint32(uint32(i)), ctx.newInt(v[i]))
    return arr
  of 0x0C23'u32:  # COLOR_WRITEMASK
    var v: array[4, GLboolean]
    glGetBooleanv(pname, addr v[0])
    let arr = ctx.newArray()
    for i in 0..3:
      ctx.setIndexSteal(arr, uint32(uint32(i)), ctx.newBool(bool(cint(v[i]))))
    return arr
  of 0x0D3A'u32:  # MAX_VIEWPORT_DIMS
    var v: array[2, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = ctx.newArray()
    ctx.setIndexSteal(arr, uint32(0), ctx.newInt(v[0]))
    ctx.setIndexSteal(arr, uint32(1), ctx.newInt(v[1]))
    return arr
  of 0x846E'u32:  # ALIASED_LINE_WIDTH_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = ctx.newArray()
    ctx.setIndexSteal(arr, uint32(0), ctx.newFloat(float64(v[0])))
    ctx.setIndexSteal(arr, uint32(1), ctx.newFloat(float64(v[1])))
    return arr
  of 0x846D'u32:  # ALIASED_POINT_SIZE_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = ctx.newArray()
    ctx.setIndexSteal(arr, uint32(0), ctx.newFloat(float64(v[0])))
    ctx.setIndexSteal(arr, uint32(1), ctx.newFloat(float64(v[1])))
    return arr
  of 0x0C10'u32:  # SCISSOR_BOX
    var v: array[4, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = ctx.newArray()
    for i in 0..3:
      ctx.setIndexSteal(arr, uint32(uint32(i)), ctx.newInt(v[i]))
    return arr
  of 0x8005'u32:  # BLEND_COLOR
    var v: array[4, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = ctx.newArray()
    for i in 0..3:
      ctx.setIndexSteal(arr, uint32(uint32(i)), ctx.newFloat(float64(v[i])))
    return arr
  of 0x0C22'u32:  # COLOR_CLEAR_VALUE
    var v: array[4, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = ctx.newArray()
    for i in 0..3:
      ctx.setIndexSteal(arr, uint32(uint32(i)), ctx.newFloat(float64(v[i])))
    return arr
  of 0x0B70'u32:  # DEPTH_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = ctx.newArray()
    ctx.setIndexSteal(arr, uint32(0), ctx.newFloat(float64(v[0])))
    ctx.setIndexSteal(arr, uint32(1), ctx.newFloat(float64(v[1])))
    return arr
  of 0x0B73'u32:  # DEPTH_CLEAR_VALUE
    var v: GLfloat
    glGetFloatv(pname, addr v)
    return ctx.newFloat(float64(v))
  of 0x0B21'u32:  # LINE_WIDTH
    var v: GLfloat
    glGetFloatv(pname, addr v)
    return ctx.newFloat(float64(v))
  of 0x8038'u32, 0x2A00'u32:  # POLYGON_OFFSET_FACTOR, POLYGON_OFFSET_UNITS
    var v: GLfloat
    glGetFloatv(pname, addr v)
    return ctx.newFloat(float64(v))
  of 0x80AA'u32:  # SAMPLE_COVERAGE_VALUE
    var v: GLfloat
    glGetFloatv(pname, addr v)
    return ctx.newFloat(float64(v))
  of 0x0B72'u32:  # DEPTH_WRITEMASK
    var v: GLboolean
    glGetBooleanv(pname, addr v)
    return ctx.newBool(bool(cint(v)))
  of 0x80AB'u32:  # SAMPLE_COVERAGE_INVERT
    var v: GLboolean
    glGetBooleanv(pname, addr v)
    return ctx.newBool(bool(cint(v)))
  of 0x0BE2'u32:  # BLEND
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x0B44'u32:  # CULL_FACE
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x0B71'u32:  # DEPTH_TEST
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x0BD0'u32:  # DITHER
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x8037'u32:  # POLYGON_OFFSET_FILL
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x80A0'u32:  # SAMPLE_COVERAGE
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x0C11'u32:  # SCISSOR_TEST
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x0B90'u32:  # STENCIL_TEST
    return ctx.newBool(bool(cint(glIsEnabled(pname))))
  of 0x9240'u32:  # UNPACK_FLIP_Y_WEBGL
    return ctx.newBool(bool(cint(ord(glUnpackFlipY))))
  of 0x9241'u32:  # UNPACK_PREMULTIPLY_ALPHA_WEBGL
    return ctx.newBool(bool(cint(ord(glUnpackPremultiplyAlpha))))
  of 0x8CA6'u32:  # FRAMEBUFFER_BINDING
    # Return null (0) when the drawing buffer FBO is bound as "default"
    if glJSBoundFBO == 0:
      return ctx.newNull()
    return jsNewGLHandle(ctx, glJSBoundFBO)
  else:
    # Default: integer query
    var v: GLint
    glGetIntegerv(pname, addr v)
    return ctx.newInt(v)

proc jsGlGetContextAttributes(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ## Returns a WebGLContextAttributes-like object describing the context
  ## parameters used at creation time.  PIXI's capability check (`ho()`)
  ## reads `result.stencil`; it must be truthy for WebGL to be chosen.
  let obj = ctx.newObject()
  ctx.setPropSteal(obj, "stencil",                    ctx.newBool(true))
  ctx.setPropSteal(obj, "antialias",                  ctx.newBool(false))
  ctx.setPropSteal(obj, "alpha",                      ctx.newBool(true))
  ctx.setPropSteal(obj, "depth",                      ctx.newBool(true))
  ctx.setPropSteal(obj, "premultipliedAlpha",         ctx.newBool(true))
  ctx.setPropSteal(obj, "preserveDrawingBuffer",      ctx.newBool(false))
  ctx.setPropSteal(obj, "powerPreference",            ctx.newString("default"))
  ctx.setPropSteal(obj, "failIfMajorPerformanceCaveat", ctx.newBool(false))
  return obj

# jsGlGetExtension and jsGlGetSupportedExtensions are defined AFTER the
# instanced-rendering procs below because they reference jsGlDrawArraysInstanced
# etc. (Nim requires procs to be declared before use).

proc jsGlHint(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  # WebGL spec says hint() accepts target and mode but implementations may ignore.
  ctx.newUndefined()

proc jsGlGetShaderPrecisionFormat(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let obj = ctx.newObject()
  if glGetShaderPrecisionFormat != nil:
    let shaderType = GLenum(ctx.toUint32(args[0]))
    let precisionType = GLenum(ctx.toUint32(args[1]))
    var range: array[2, GLint]
    var precision: GLint
    glGetShaderPrecisionFormat(shaderType, precisionType, addr range[0], addr precision)
    ctx.setPropSteal(obj, "rangeMin", ctx.newInt(range[0]))
    ctx.setPropSteal(obj, "rangeMax", ctx.newInt(range[1]))
    ctx.setPropSteal(obj, "precision", ctx.newInt(precision))
  else:
    # GL 3.3 may not have this function; return sensible defaults
    ctx.setPropSteal(obj, "rangeMin", ctx.newInt(127))
    ctx.setPropSteal(obj, "rangeMax", ctx.newInt(127))
    ctx.setPropSteal(obj, "precision", ctx.newInt(23))
  obj

proc jsGlIsContextLost(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  ctx.newBool(false)

# ── Instanced rendering (ANGLE_instanced_arrays extension) ───────────────

proc jsGlDrawArraysInstanced(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  if glDrawArraysInstanced != nil:
    glDrawArraysInstanced(GLenum(ctx.toUint32(args[0])), GLint(ctx.toInt32(args[1])),
                          GLsizei(ctx.toInt32(args[2])), GLsizei(ctx.toInt32(args[3])))
  ctx.newUndefined()

proc jsGlDrawElementsInstanced(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  if glDrawElementsInstanced != nil:
    glDrawElementsInstanced(GLenum(ctx.toUint32(args[0])), GLsizei(ctx.toInt32(args[1])),
                            GLenum(ctx.toUint32(args[2])),
                            cast[pointer](ctx.toInt32(args[3])),
                            GLsizei(ctx.toInt32(args[4])))
  ctx.newUndefined()

proc jsGlVertexAttribDivisor(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  if glVertexAttribDivisor != nil:
    glVertexAttribDivisor(GLuint(ctx.toUint32(args[0])), GLuint(ctx.toUint32(args[1])))
  ctx.newUndefined()

proc jsGlGetExtension(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let name = ctx.toNimString(args[0])
  case name
  of "OES_element_index_uint", "OES_texture_float",
     "OES_texture_float_linear", "OES_standard_derivatives",
     "EXT_shader_texture_lod", "EXT_frag_depth",
     "EXT_blend_minmax":
    return ctx.newObject()
  of "OES_texture_half_float":
    let obj = ctx.newObject()
    ctx.setPropSteal(obj, "HALF_FLOAT_OES", ctx.newInt(0x8D61))
    return obj
  of "OES_texture_half_float_linear":
    return ctx.newObject()
  of "OES_vertex_array_object":
    # Return null so PIXI uses its software VAO fallback (manually calls
    # vertexAttribPointer each frame) instead of trying to call
    # createVertexArrayOES() on an empty stub object and crashing.
    return ctx.newNull()
  of "ANGLE_instanced_arrays":
    let obj = ctx.newObject()
    # WebGL1 engines (PIXI v5/v6 in WebGL1 mode) get the ANGLE extension and
    # call the *ANGLE-suffixed* methods on it instead of the core GL3.3 names.
    # We reuse the same native implementations that are bound directly on the
    # context object (jsGlDrawArraysInstanced etc.) since they are stateless
    # procs that just call through to the OpenGL function pointers.
    let daiFn = ctx.newFunction("drawArraysInstancedANGLE", jsGlDrawArraysInstanced, 4)
    ctx.setPropSteal(obj, "drawArraysInstancedANGLE", daiFn)
    let deiFn = ctx.newFunction("drawElementsInstancedANGLE", jsGlDrawElementsInstanced, 5)
    ctx.setPropSteal(obj, "drawElementsInstancedANGLE", deiFn)
    let vadFn = ctx.newFunction("vertexAttribDivisorANGLE", jsGlVertexAttribDivisor, 2)
    ctx.setPropSteal(obj, "vertexAttribDivisorANGLE", vadFn)
    return obj
  of "WEBGL_lose_context":
    # PIXI's ho() calls `n.loseContext()` after testing; it must be a callable
    # function or ho() throws a TypeError and returns false.
    proc jsNoop(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
      return ctx.newUndefined()
    let obj = ctx.newObject()
    let lc = ctx.newFunction("loseContext", jsNoop, int(0))
    ctx.setPropSteal(obj, "loseContext", lc)
    let rc = ctx.newFunction("restoreContext", jsNoop, int(0))
    ctx.setPropSteal(obj, "restoreContext", rc)
    return obj
  of "WEBGL_depth_texture":
    return ctx.newObject()
  of "WEBGL_debug_renderer_info":
    # Exposes UNMASKED_VENDOR_WEBGL (0x9245) and UNMASKED_RENDERER_WEBGL (0x9246)
    # as integer enum constants on the extension object.  Callers pass these
    # constants back to gl.getParameter() to get the real GPU vendor/renderer.
    let obj = ctx.newObject()
    ctx.setPropSteal(obj, "UNMASKED_VENDOR_WEBGL",   ctx.newInt(0x9245))
    ctx.setPropSteal(obj, "UNMASKED_RENDERER_WEBGL", ctx.newInt(0x9246))
    return obj
  else:
    return ctx.newNull()

proc jsGlGetSupportedExtensions(ctx: ptr ScriptCtx; this: ScriptValue;
                      args: openArray[ScriptValue]): ScriptValue =
  let arr = ctx.newArray()
  const exts = [
    "OES_element_index_uint", "OES_texture_float",
    "OES_texture_float_linear", "OES_standard_derivatives",
    "OES_texture_half_float", "OES_texture_half_float_linear",
    "EXT_shader_texture_lod", "EXT_frag_depth",
    "EXT_blend_minmax", "ANGLE_instanced_arrays",
    "WEBGL_lose_context", "WEBGL_depth_texture",
    "WEBGL_debug_renderer_info"
  ]
  for i, name in exts:
    ctx.setIndexSteal(arr, uint32(uint32(i)), ctx.newString(name))
  arr

# ── bindWebGL — create GL context JS object with all methods + constants ──

const glConstantsJS = """
var g=__rw_glContext;
g.DEPTH_BUFFER_BIT=0x100;g.STENCIL_BUFFER_BIT=0x400;g.COLOR_BUFFER_BIT=0x4000;
g.FALSE=0;g.TRUE=1;g.POINTS=0;g.LINES=1;g.LINE_LOOP=2;g.LINE_STRIP=3;
g.TRIANGLES=4;g.TRIANGLE_STRIP=5;g.TRIANGLE_FAN=6;
g.ZERO=0;g.ONE=1;g.SRC_COLOR=0x300;g.ONE_MINUS_SRC_COLOR=0x301;
g.SRC_ALPHA=0x302;g.ONE_MINUS_SRC_ALPHA=0x303;g.DST_ALPHA=0x304;
g.ONE_MINUS_DST_ALPHA=0x305;g.DST_COLOR=0x306;g.ONE_MINUS_DST_COLOR=0x307;
g.SRC_ALPHA_SATURATE=0x308;g.FUNC_ADD=0x8006;g.FUNC_SUBTRACT=0x800A;
g.FUNC_REVERSE_SUBTRACT=0x800B;g.BLEND_EQUATION=0x8009;
g.BLEND_EQUATION_RGB=0x8009;g.BLEND_EQUATION_ALPHA=0x883D;
g.BLEND_DST_RGB=0x80C8;g.BLEND_SRC_RGB=0x80C9;
g.BLEND_DST_ALPHA=0x80CA;g.BLEND_SRC_ALPHA=0x80CB;
g.CONSTANT_COLOR=0x8001;g.ONE_MINUS_CONSTANT_COLOR=0x8002;
g.CONSTANT_ALPHA=0x8003;g.ONE_MINUS_CONSTANT_ALPHA=0x8004;
g.BLEND_COLOR=0x8005;g.BLEND=0x0BE2;
g.CULL_FACE=0x0B44;g.DEPTH_TEST=0x0B71;g.STENCIL_TEST=0x0B90;
g.DITHER=0x0BD0;g.SCISSOR_TEST=0x0C11;g.POLYGON_OFFSET_FILL=0x8037;
g.SAMPLE_ALPHA_TO_COVERAGE=0x809E;g.SAMPLE_COVERAGE=0x80A0;
g.NO_ERROR=0;g.INVALID_ENUM=0x500;g.INVALID_VALUE=0x501;
g.INVALID_OPERATION=0x502;g.OUT_OF_MEMORY=0x505;
g.INVALID_FRAMEBUFFER_OPERATION=0x506;
g.CW=0x900;g.CCW=0x901;g.FRONT=0x404;g.BACK=0x405;g.FRONT_AND_BACK=0x408;
g.NEVER=0x200;g.LESS=0x201;g.EQUAL=0x202;g.LEQUAL=0x203;
g.GREATER=0x204;g.NOTEQUAL=0x205;g.GEQUAL=0x206;g.ALWAYS=0x207;
g.KEEP=0x1E00;g.REPLACE=0x1E01;g.INCR=0x1E02;g.DECR=0x1E03;
g.INVERT=0x150A;g.INCR_WRAP=0x8507;g.DECR_WRAP=0x8508;
g.BYTE=0x1400;g.UNSIGNED_BYTE=0x1401;g.SHORT=0x1402;
g.UNSIGNED_SHORT=0x1403;g.INT=0x1404;g.UNSIGNED_INT=0x1405;g.FLOAT=0x1406;
g.ARRAY_BUFFER=0x8892;g.ELEMENT_ARRAY_BUFFER=0x8893;
g.ARRAY_BUFFER_BINDING=0x8894;g.ELEMENT_ARRAY_BUFFER_BINDING=0x8895;
g.STREAM_DRAW=0x88E0;g.STATIC_DRAW=0x88E4;g.DYNAMIC_DRAW=0x88E8;
g.BUFFER_SIZE=0x8764;g.BUFFER_USAGE=0x8765;
g.CURRENT_VERTEX_ATTRIB=0x8626;
g.TEXTURE0=0x84C0;g.TEXTURE1=0x84C1;g.TEXTURE2=0x84C2;g.TEXTURE3=0x84C3;
g.TEXTURE4=0x84C4;g.TEXTURE5=0x84C5;g.TEXTURE6=0x84C6;g.TEXTURE7=0x84C7;
g.TEXTURE8=0x84C8;g.TEXTURE9=0x84C9;g.TEXTURE10=0x84CA;g.TEXTURE11=0x84CB;
g.TEXTURE12=0x84CC;g.TEXTURE13=0x84CD;g.TEXTURE14=0x84CE;g.TEXTURE15=0x84CF;
g.TEXTURE16=0x84D0;g.TEXTURE17=0x84D1;g.TEXTURE18=0x84D2;g.TEXTURE19=0x84D3;
g.TEXTURE20=0x84D4;g.TEXTURE21=0x84D5;g.TEXTURE22=0x84D6;g.TEXTURE23=0x84D7;
g.TEXTURE24=0x84D8;g.TEXTURE25=0x84D9;g.TEXTURE26=0x84DA;g.TEXTURE27=0x84DB;
g.TEXTURE28=0x84DC;g.TEXTURE29=0x84DD;g.TEXTURE30=0x84DE;g.TEXTURE31=0x84DF;
g.TEXTURE_2D=0x0DE1;g.TEXTURE_CUBE_MAP=0x8513;
g.TEXTURE_CUBE_MAP_POSITIVE_X=0x8515;g.TEXTURE_CUBE_MAP_NEGATIVE_X=0x8516;
g.TEXTURE_CUBE_MAP_POSITIVE_Y=0x8517;g.TEXTURE_CUBE_MAP_NEGATIVE_Y=0x8518;
g.TEXTURE_CUBE_MAP_POSITIVE_Z=0x8519;g.TEXTURE_CUBE_MAP_NEGATIVE_Z=0x851A;
g.TEXTURE_WRAP_S=0x2802;g.TEXTURE_WRAP_T=0x2803;
g.TEXTURE_MIN_FILTER=0x2801;g.TEXTURE_MAG_FILTER=0x2800;
g.NEAREST=0x2600;g.LINEAR=0x2601;
g.NEAREST_MIPMAP_NEAREST=0x2700;g.LINEAR_MIPMAP_NEAREST=0x2701;
g.NEAREST_MIPMAP_LINEAR=0x2702;g.LINEAR_MIPMAP_LINEAR=0x2703;
g.CLAMP_TO_EDGE=0x812F;g.MIRRORED_REPEAT=0x8370;g.REPEAT=0x2901;
g.ALPHA=0x1906;g.RGB=0x1907;g.RGBA=0x1908;
g.LUMINANCE=0x1909;g.LUMINANCE_ALPHA=0x190A;
g.DEPTH_COMPONENT=0x1902;g.DEPTH_STENCIL=0x84F9;
g.DEPTH_COMPONENT16=0x81A5;g.STENCIL_INDEX8=0x8D48;
g.DEPTH24_STENCIL8=0x88F0;
g.UNPACK_ALIGNMENT=0x0CF5;g.PACK_ALIGNMENT=0x0D05;
g.UNPACK_FLIP_Y_WEBGL=0x9240;g.UNPACK_PREMULTIPLY_ALPHA_WEBGL=0x9241;
g.UNPACK_COLORSPACE_CONVERSION_WEBGL=0x9243;
g.FRAGMENT_SHADER=0x8B30;g.VERTEX_SHADER=0x8B31;
g.COMPILE_STATUS=0x8B81;g.LINK_STATUS=0x8B82;g.VALIDATE_STATUS=0x8B83;
g.DELETE_STATUS=0x8B80;g.SHADER_TYPE=0x8B4F;
g.ATTACHED_SHADERS=0x8B85;g.ACTIVE_UNIFORMS=0x8B86;
g.ACTIVE_ATTRIBUTES=0x8B89;g.ACTIVE_UNIFORM_MAX_LENGTH=0x8B87;
g.ACTIVE_ATTRIB_MAX_LENGTH=0x8B8A;
g.FRAMEBUFFER=0x8D40;g.RENDERBUFFER=0x8D41;
g.COLOR_ATTACHMENT0=0x8CE0;g.DEPTH_ATTACHMENT=0x8D00;
g.STENCIL_ATTACHMENT=0x8D20;g.DEPTH_STENCIL_ATTACHMENT=0x821A;
g.FRAMEBUFFER_COMPLETE=0x8CD5;
g.FRAMEBUFFER_INCOMPLETE_ATTACHMENT=0x8CD6;
g.FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT=0x8CD7;
g.FRAMEBUFFER_INCOMPLETE_DIMENSIONS=0x8CD9;
g.FRAMEBUFFER_UNSUPPORTED=0x8CDD;g.NONE=0;
g.RENDERBUFFER_WIDTH=0x8D42;g.RENDERBUFFER_HEIGHT=0x8D43;
g.RENDERBUFFER_INTERNAL_FORMAT=0x8D44;
g.RENDERBUFFER_RED_SIZE=0x8D50;g.RENDERBUFFER_GREEN_SIZE=0x8D51;
g.RENDERBUFFER_BLUE_SIZE=0x8D52;g.RENDERBUFFER_ALPHA_SIZE=0x8D53;
g.RENDERBUFFER_DEPTH_SIZE=0x8D54;g.RENDERBUFFER_STENCIL_SIZE=0x8D55;
g.UNSIGNED_SHORT_4_4_4_4=0x8033;g.UNSIGNED_SHORT_5_5_5_1=0x8034;
g.UNSIGNED_SHORT_5_6_5=0x8363;
g.MAX_VERTEX_ATTRIBS=0x8869;g.MAX_VERTEX_UNIFORM_VECTORS=0x8DFB;
g.MAX_VARYING_VECTORS=0x8DFC;g.MAX_COMBINED_TEXTURE_IMAGE_UNITS=0x8B4D;
g.MAX_VERTEX_TEXTURE_IMAGE_UNITS=0x8B4C;g.MAX_TEXTURE_IMAGE_UNITS=0x8872;
g.MAX_FRAGMENT_UNIFORM_VECTORS=0x8DFD;g.MAX_TEXTURE_SIZE=0x0D33;
g.MAX_CUBE_MAP_TEXTURE_SIZE=0x851C;g.MAX_RENDERBUFFER_SIZE=0x84E8;
g.MAX_VIEWPORT_DIMS=0x0D3A;g.VIEWPORT=0x0BA2;
g.COLOR_WRITEMASK=0x0C23;g.DEPTH_WRITEMASK=0x0B72;
g.STENCIL_WRITEMASK=0x0B98;g.STENCIL_BACK_WRITEMASK=0x8CA5;
g.HIGH_FLOAT=0x8DF2;g.MEDIUM_FLOAT=0x8DF1;g.LOW_FLOAT=0x8DF0;
g.HIGH_INT=0x8DF5;g.MEDIUM_INT=0x8DF4;g.LOW_INT=0x8DF3;
g.FLOAT_VEC2=0x8B50;g.FLOAT_VEC3=0x8B51;g.FLOAT_VEC4=0x8B52;
g.INT_VEC2=0x8B53;g.INT_VEC3=0x8B54;g.INT_VEC4=0x8B55;
g.BOOL=0x8B56;g.BOOL_VEC2=0x8B57;g.BOOL_VEC3=0x8B58;g.BOOL_VEC4=0x8B59;
g.FLOAT_MAT2=0x8B5A;g.FLOAT_MAT3=0x8B5B;g.FLOAT_MAT4=0x8B5C;
g.SAMPLER_2D=0x8B5E;g.SAMPLER_CUBE=0x8B60;
g.POLYGON_OFFSET_FACTOR=0x8038;g.POLYGON_OFFSET_UNITS=0x2A00;
g.SAMPLE_BUFFERS=0x80A8;g.SAMPLES=0x80A9;
g.SAMPLE_COVERAGE_VALUE=0x80AA;g.SAMPLE_COVERAGE_INVERT=0x80AB;
g.GENERATE_MIPMAP_HINT=0x8192;g.FASTEST=0x1101;g.NICEST=0x1102;
g.DONT_CARE=0x1100;
g.STENCIL_FUNC=0x0B92;g.STENCIL_FAIL=0x0B94;
g.STENCIL_PASS_DEPTH_FAIL=0x0B95;g.STENCIL_PASS_DEPTH_PASS=0x0B96;
g.STENCIL_REF=0x0B97;g.STENCIL_VALUE_MASK=0x0B93;
g.STENCIL_BACK_FUNC=0x8800;g.STENCIL_BACK_FAIL=0x8801;
g.STENCIL_BACK_PASS_DEPTH_FAIL=0x8802;g.STENCIL_BACK_PASS_DEPTH_PASS=0x8803;
g.STENCIL_BACK_REF=0x8CA3;g.STENCIL_BACK_VALUE_MASK=0x8CA4;
g.DEPTH_FUNC=0x0B74;g.BLEND_SRC=0x0BE1;g.BLEND_DST=0x0BE0;
g.DEPTH_RANGE=0x0B70;g.DEPTH_CLEAR_VALUE=0x0B73;
g.STENCIL_CLEAR_VALUE=0x0B91;g.COLOR_CLEAR_VALUE=0x0C22;
g.SCISSOR_BOX=0x0C10;g.FRONT_FACE=0x0B46;g.CULL_FACE_MODE=0x0B45;
g.LINE_WIDTH=0x0B21;
g.VERTEX_ATTRIB_ARRAY_ENABLED=0x8622;
g.VERTEX_ATTRIB_ARRAY_SIZE=0x8623;
g.VERTEX_ATTRIB_ARRAY_STRIDE=0x8624;
g.VERTEX_ATTRIB_ARRAY_TYPE=0x8625;
g.VERTEX_ATTRIB_ARRAY_NORMALIZED=0x886A;
g.VERTEX_ATTRIB_ARRAY_POINTER=0x8645;
g.VERTEX_ATTRIB_ARRAY_BUFFER_BINDING=0x889F;
g.IMPLEMENTATION_COLOR_READ_TYPE=0x8B9A;
g.IMPLEMENTATION_COLOR_READ_FORMAT=0x8B9B;
g.BROWSER_DEFAULT_WEBGL=0x9244;
g.VERSION=0x1F02;g.VENDOR=0x1F00;g.RENDERER=0x1F01;
g.SHADING_LANGUAGE_VERSION=0x8B8C;
"""

# Forward declarations for the Canvas2D blit pool (used in bindWebGL reset)
type C2dBlitTex = object
  id:    GLuint
  lastW: int
  lastH: int
var c2dBlitProg:     GLuint = 0
var c2dBlitVAO2d:    GLuint = 0
var c2dBlitVAO_fbo:  GLuint = 0   # FBO blit quad (non-flipped UVs for GL textures)
var c2dBlitVBO:      GLuint = 0
var c2dBlitVBO_fbo:  GLuint = 0
var c2dBlitTextures: seq[C2dBlitTex]
var c2dBlitTexLoc:   GLint  = -1  # cached uniform location — set once at init

proc bindWebGL*(ctx: ptr ScriptCtx; width, height: int32) =
  ## Create the WebGL context JS object with all methods and constants,
  ## then store as __rw_glContext global.
  let global = ctx.getGlobal()
  let glObj = ctx.newObject()
  # Reset blit texture cache on each page load
  c2dBlitTextures = @[]
  resetGLStateCache()

  # Create / resize the off-screen drawing buffer FBO at the game resolution.
  # WebGL apps render to this; we composite to the real window each frame.
  initDrawingBuffer(width, height)

  # drawingBufferWidth / drawingBufferHeight (match the drawing buffer)
  ctx.setPropSteal(glObj, "drawingBufferWidth", ctx.newInt(width))
  ctx.setPropSteal(glObj, "drawingBufferHeight", ctx.newInt(height))

  # Install all gl.* native method bindings
  template glFn(jsName: cstring; fn: ScriptNativeProc; nargs: int) =
    ctx.bindMethod(glObj, jsName, fn, nargs)

  # State
  glFn("viewport",            jsGlViewport, 4)
  glFn("clearColor",          jsGlClearColor, 4)
  glFn("clear",               jsGlClear, 1)
  glFn("enable",              jsGlEnable, 1)
  glFn("disable",             jsGlDisable, 1)
  glFn("blendFunc",           jsGlBlendFunc, 2)
  glFn("blendFuncSeparate",   jsGlBlendFuncSeparate, 4)
  glFn("blendEquation",       jsGlBlendEquation, 1)
  glFn("blendEquationSeparate", jsGlBlendEquationSeparate, 2)
  glFn("blendColor",          jsGlBlendColor, 4)
  glFn("depthFunc",           jsGlDepthFunc, 1)
  glFn("depthMask",           jsGlDepthMask, 1)
  glFn("depthRange",          jsGlDepthRange, 2)
  glFn("clearDepth",          jsGlClearDepth, 1)
  glFn("cullFace",            jsGlCullFace, 1)
  glFn("frontFace",           jsGlFrontFace, 1)
  glFn("scissor",             jsGlScissor, 4)
  glFn("lineWidth",           jsGlLineWidth, 1)
  glFn("colorMask",           jsGlColorMask, 4)
  glFn("stencilFunc",         jsGlStencilFunc, 3)
  glFn("stencilFuncSeparate", jsGlStencilFuncSeparate, 4)
  glFn("stencilOp",           jsGlStencilOp, 3)
  glFn("stencilOpSeparate",   jsGlStencilOpSeparate, 4)
  glFn("stencilMask",         jsGlStencilMask, 1)
  glFn("stencilMaskSeparate", jsGlStencilMaskSeparate, 2)
  glFn("clearStencil",        jsGlClearStencil, 1)
  glFn("pixelStorei",         jsGlPixelStorei, 2)
  glFn("flush",               jsGlFlush, 0)
  glFn("finish",              jsGlFinish, 0)
  glFn("getError",            jsGlGetError, 0)
  glFn("isEnabled",           jsGlIsEnabled, 1)
  # Shaders & Programs
  glFn("createShader",        jsGlCreateShader, 1)
  glFn("deleteShader",        jsGlDeleteShader, 1)
  glFn("shaderSource",        jsGlShaderSource, 2)
  glFn("compileShader",       jsGlCompileShader, 1)
  glFn("getShaderParameter",  jsGlGetShaderParameter, 2)
  glFn("getShaderInfoLog",    jsGlGetShaderInfoLog, 1)
  glFn("createProgram",       jsGlCreateProgram, 0)
  glFn("deleteProgram",       jsGlDeleteProgram, 1)
  glFn("attachShader",        jsGlAttachShader, 2)
  glFn("detachShader",        jsGlDetachShader, 2)
  glFn("linkProgram",         jsGlLinkProgram, 1)
  glFn("getProgramParameter", jsGlGetProgramiv, 2)
  glFn("getProgramInfoLog",   jsGlGetProgramInfoLog, 1)
  glFn("useProgram",          jsGlUseProgram, 1)
  glFn("validateProgram",     jsGlValidateProgram, 1)
  # Attributes
  glFn("getAttribLocation",   jsGlGetAttribLocation, 2)
  glFn("bindAttribLocation",  jsGlBindAttribLocation, 3)
  glFn("enableVertexAttribArray",  jsGlEnableVertexAttribArray, 1)
  glFn("disableVertexAttribArray", jsGlDisableVertexAttribArray, 1)
  glFn("vertexAttribPointer", jsGlVertexAttribPointer, 6)
  glFn("getActiveAttrib",     jsGlGetActiveAttrib, 2)
  glFn("getActiveUniform",    jsGlGetActiveUniform, 2)
  # Uniforms
  glFn("getUniformLocation",  jsGlGetUniformLocation, 2)
  glFn("uniform1f",           jsGlUniform1f, 2)
  glFn("uniform2f",           jsGlUniform2f, 3)
  glFn("uniform3f",           jsGlUniform3f, 4)
  glFn("uniform4f",           jsGlUniform4f, 5)
  glFn("uniform1i",           jsGlUniform1i, 2)
  glFn("uniform2i",           jsGlUniform2i, 3)
  glFn("uniform3i",           jsGlUniform3i, 4)
  glFn("uniform4i",           jsGlUniform4i, 5)
  glFn("uniform1fv",          jsGlUniform1fv, 2)
  glFn("uniform2fv",          jsGlUniform2fv, 2)
  glFn("uniform3fv",          jsGlUniform3fv, 2)
  glFn("uniform4fv",          jsGlUniform4fv, 2)
  glFn("uniform1iv",          jsGlUniform1iv, 2)
  glFn("uniform2iv",          jsGlUniform2iv, 2)
  glFn("uniform3iv",          jsGlUniform3iv, 2)
  glFn("uniform4iv",          jsGlUniform4iv, 2)
  glFn("uniformMatrix2fv",    jsGlUniformMatrix2fv, 3)
  glFn("uniformMatrix3fv",    jsGlUniformMatrix3fv, 3)
  glFn("uniformMatrix4fv",    jsGlUniformMatrix4fv, 3)
  # Buffers
  glFn("createBuffer",        jsGlCreateBuffer, 0)
  glFn("deleteBuffer",        jsGlDeleteBuffer, 1)
  glFn("bindBuffer",          jsGlBindBuffer, 2)
  glFn("bufferData",          jsGlBufferData, 3)
  glFn("bufferSubData",       jsGlBufferSubData, 3)
  # Textures
  glFn("createTexture",       jsGlCreateTexture, 0)
  glFn("deleteTexture",       jsGlDeleteTexture, 1)
  glFn("bindTexture",         jsGlBindTexture, 2)
  glFn("activeTexture",       jsGlActiveTexture, 1)
  glFn("texImage2D",          jsGlTexImage2D, 9)
  glFn("texSubImage2D",       jsGlTexSubImage2D, 9)
  glFn("texParameteri",       jsGlTexParameteri, 3)
  glFn("texParameterf",       jsGlTexParameterf, 3)
  glFn("generateMipmap",      jsGlGenerateMipmap, 1)
  glFn("copyTexImage2D",      jsGlCopyTexImage2D, 8)
  glFn("copyTexSubImage2D",   jsGlCopyTexSubImage2D, 8)
  # Framebuffers
  glFn("createFramebuffer",   jsGlCreateFramebuffer, 0)
  glFn("deleteFramebuffer",   jsGlDeleteFramebuffer, 1)
  glFn("bindFramebuffer",     jsGlBindFramebuffer, 2)
  glFn("framebufferTexture2D", jsGlFramebufferTexture2D, 5)
  glFn("framebufferRenderbuffer", jsGlFramebufferRenderbuffer, 4)
  glFn("checkFramebufferStatus", jsGlCheckFramebufferStatus, 1)
  # Renderbuffers
  glFn("createRenderbuffer",  jsGlCreateRenderbuffer, 0)
  glFn("deleteRenderbuffer",  jsGlDeleteRenderbuffer, 1)
  glFn("bindRenderbuffer",    jsGlBindRenderbuffer, 2)
  glFn("renderbufferStorage", jsGlRenderbufferStorage, 4)
  # Drawing
  glFn("drawArrays",          jsGlDrawArrays, 3)
  glFn("drawElements",        jsGlDrawElements, 4)
  # Reading
  glFn("readPixels",          jsGlReadPixels, 7)
  # Query
  glFn("getParameter",        jsGlGetParameter, 1)
  glFn("getExtension",        jsGlGetExtension, 1)
  glFn("getSupportedExtensions", jsGlGetSupportedExtensions, 0)
  glFn("hint",                jsGlHint, 2)
  glFn("getShaderPrecisionFormat", jsGlGetShaderPrecisionFormat, 2)
  glFn("getContextAttributes", jsGlGetContextAttributes, 0)
  glFn("isContextLost",       jsGlIsContextLost, 0)
  # Instanced rendering
  glFn("drawArraysInstanced", jsGlDrawArraysInstanced, 4)
  glFn("drawElementsInstanced", jsGlDrawElementsInstanced, 5)
  glFn("vertexAttribDivisor", jsGlVertexAttribDivisor, 2)

  # Store as global __rw_glContext
  ctx.setPropSteal(global, "__rw_glContext", glObj)
  # Register drawing buffer helpers as globals
  ctx.bindGlobal("__rw_resizeDrawingBuffer", jsResizeDrawingBuffer, 2)
  ctx.bindGlobal("__rw_setWebGLActive", jsSetWebGLActive, 0)
  ctx.bindGlobal("__rw_setForceCanvas", jsSetForceCanvas, 0)
  ctx.freeValue(global)

  # Eval the constants JS to set all WebGL enum constants on the context object
  let constRet = ctx.eval(cstring(glConstantsJS), "<gl-constants>")
  discard ctx.checkException(constRet, "<gl-constants>")

# ===========================================================================
# Phase 5 — Canvas 2D → OpenGL fullscreen blit
# ===========================================================================
# After each rAF frame, upload the CPU pixel buffer to a GL texture and draw
# it as a fullscreen quad so the canvas actually appears on screen.
# Lives here (after rwebview_canvas2d include) so all GL types are available.

const c2dBlitVS = """
#version 330 core
layout(location=0) in vec2 aPos;
layout(location=1) in vec2 aUV;
out vec2 vUV;
void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
    vUV = aUV;
}
"""

const c2dBlitFS = """
#version 330 core
uniform sampler2D uTex;
in vec2 vUV;
out vec4 fragColor;
void main() {
    fragColor = texture(uTex, vUV);
}
"""

proc c2dCompileShader(typ: GLenum; src: string): GLuint =
  result = glCreateShader(typ)
  var p = src.cstring
  glShaderSource(result, 1, addr p, nil)
  glCompileShader(result)
  var ok: GLint
  glGetShaderiv(result, 0x8B81.GLenum, addr ok)   # GL_COMPILE_STATUS
  if ok == 0:
    var log = newString(512)
    glGetShaderInfoLog(result, 512, nil, cstring(log))
    stderr.writeLine("[c2d blit] shader error: " & log)

proc initCanvas2dBlit() =
  ## Create the fullscreen blit shader + VAO + VBO. Called lazily on first present.
  if c2dBlitProg != 0: return
  let vs = c2dCompileShader(0x8B31.GLenum, c2dBlitVS)   # GL_VERTEX_SHADER
  let fs = c2dCompileShader(0x8B30.GLenum, c2dBlitFS)   # GL_FRAGMENT_SHADER
  c2dBlitProg = glCreateProgram()
  glAttachShader(c2dBlitProg, vs)
  glAttachShader(c2dBlitProg, fs)
  glLinkProgram(c2dBlitProg)
  var linkOk: GLint
  glGetProgramiv(c2dBlitProg, 0x8B82.GLenum, addr linkOk)  # GL_LINK_STATUS
  if linkOk == 0:
    var log = newString(512)
    glGetProgramInfoLog(c2dBlitProg, 512, nil, cstring(log))
    stderr.writeLine("[c2d blit] link error: " & log)
  else:
    stderr.writeLine("[c2d blit] shader program linked OK")
  glDeleteShader(vs)
  glDeleteShader(fs)
  # Cache the uTex uniform location once so we avoid per-frame hash lookups.
  c2dBlitTexLoc = glGetUniformLocation(c2dBlitProg, "uTex")
  # Fullscreen quad — 6 vertices (x, y, u, v).
  # NDC +Y = screen top; V=0 → first uploaded pixel row (row 0 = our top).
  # glTexImage2D stores row 0 at texture bottom (V=0), so the mapping is:
  #   screen top (NDC +1) ↔ V=0 ↔ pixel row 0 ↔ image top  ✓
  let verts: array[24, float32] = [
    -1.0f,  1.0f,  0.0f, 0.0f,   # top-left
    -1.0f, -1.0f,  0.0f, 1.0f,   # bottom-left
     1.0f, -1.0f,  1.0f, 1.0f,   # bottom-right
    -1.0f,  1.0f,  0.0f, 0.0f,   # top-left
     1.0f, -1.0f,  1.0f, 1.0f,   # bottom-right
     1.0f,  1.0f,  1.0f, 0.0f,   # top-right
  ]
  glGenVertexArrays(1, addr c2dBlitVAO2d)
  glBindVertexArray(c2dBlitVAO2d)
  glGenBuffers(1, addr c2dBlitVBO)
  glBindBuffer(0x8892.GLenum, c2dBlitVBO)
  glBufferData(0x8892.GLenum, sizeof(verts), unsafeAddr verts[0], 0x88E4.GLenum)
  glVertexAttribPointer(0, 2, 0x1406.GLenum, 0.GLboolean, 16, nil)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(1, 2, 0x1406.GLenum, 0.GLboolean, 16, cast[pointer](8))
  glEnableVertexAttribArray(1)
  # FBO blit quad — standard GL texture orientation (V=0 at bottom).
  # For FBO color attachments, (0,0) is bottom-left, matching GL convention.
  let vertsFBO: array[24, float32] = [
    -1.0f,  1.0f,  0.0f, 1.0f,   # top-left     (UV for texture top)
    -1.0f, -1.0f,  0.0f, 0.0f,   # bottom-left  (UV for texture bottom)
     1.0f, -1.0f,  1.0f, 0.0f,   # bottom-right
    -1.0f,  1.0f,  0.0f, 1.0f,   # top-left
     1.0f, -1.0f,  1.0f, 0.0f,   # bottom-right
     1.0f,  1.0f,  1.0f, 1.0f,   # top-right
  ]
  glGenVertexArrays(1, addr c2dBlitVAO_fbo)
  glBindVertexArray(c2dBlitVAO_fbo)
  glGenBuffers(1, addr c2dBlitVBO_fbo)
  glBindBuffer(0x8892.GLenum, c2dBlitVBO_fbo)
  glBufferData(0x8892.GLenum, sizeof(vertsFBO), unsafeAddr vertsFBO[0], 0x88E4.GLenum)
  glVertexAttribPointer(0, 2, 0x1406.GLenum, 0.GLboolean, 16, nil)
  glEnableVertexAttribArray(0)
  glVertexAttribPointer(1, 2, 0x1406.GLenum, 0.GLboolean, 16, cast[pointer](8))
  glEnableVertexAttribArray(1)
  glBindVertexArray(glDefaultVAO)
  # Unbind the array buffer so the JS-side GL cache stays consistent.
  # initCanvas2dBlit natively bound c2dBlitVBO_fbo; if we leave it bound,
  # the cache still holds the ID of whatever the JS app (PIXI) last bound,
  # and PIXI's next gl.bindBuffer(ARRAY_BUFFER, ...) call would be skipped
  # as a "redundant" rebind — causing PIXI to record the blit VBO as the
  # source for its vertex attributes and rendering nothing. Reset to 0.
  glBindBuffer(0x8892.GLenum, 0)    # GL_ARRAY_BUFFER = 0
  glCacheArrayBuf = 0

var c2dBlitLogOnce: bool = false

# ── Letterbox viewport params (exported for mouse mapping and overlay) ────────
var c2dBlitVpX*: int = 0
var c2dBlitVpY*: int = 0
var c2dBlitVpW*: int = 0
var c2dBlitVpH*: int = 0

# ── Native F2 debug overlay ──────────────────────────────────────────────────
var c2dShowOverlay*: bool = false
var c2dFpsDisplay*: int   = 0
var c2dGpuName*:    string = "Querying..."
const OV_W = 520
const OV_H = 22
var ovPixels: array[OV_W * OV_H * 4, uint8]
var ovTexId:      GLuint       = 0
var ovFontLoaded: bool         = false
var ovGpuQueried: bool         = false

proc drawNativeOverlay(winW, winH: int) =
  ## Render the F2 status bar (FPS + resolution + GPU) and blit at top-left
  ## of the letterboxed game viewport using a small GL viewport trick.
  if not ovFontLoaded:
    if fonsInitialized and defaultFontPath != "":
      let fid = getOrLoadFonsFont("__overlay__", 13.0f, "")
      ovFontLoaded = fid >= 0
  if not ovFontLoaded: return
  # Fill semi-transparent black background
  const bgA = 180u8
  for i in 0..<OV_W * OV_H:
    ovPixels[i*4]   = 0; ovPixels[i*4+1] = 0
    ovPixels[i*4+2] = 0; ovPixels[i*4+3] = bgA
  # Compose info line matching testmedia.html style
  let fpsCol =
    if c2dFpsDisplay >= 55: (r: 160u8, g: 255u8, b: 160u8)
    elif c2dFpsDisplay >= 45: (r: 255u8, g: 230u8, b: 80u8)
    else:                     (r: 255u8, g: 100u8, b: 100u8)
  let gpuShort = if c2dGpuName.len > 30: c2dGpuName[0..28] & "\xe2\x80\xa6" else: c2dGpuName
  let modeTag = if gForceCanvasMode: "Canvas (forced)"
                elif gWebGLActive:   "WebGL"
                else:                "Canvas"
  let line = "FPS:" & $c2dFpsDisplay &
             "  " & $c2dBlitVpW & "x" & $c2dBlitVpH &
             "  [" & modeTag & "]" &
             "  [GPU] " & gpuShort
  # Render text via fonstash
  discard getOrLoadFonsFont("__overlay__", 13.0f, "")
  var tw, th, baselineY: cint
  let rgbaPtr = rw_fons_render_text_rgba(cstring(line), fpsCol.r, fpsCol.g, fpsCol.b,
                                          addr tw, addr th, addr baselineY)
  if rgbaPtr != nil:
    let sp = cast[ptr UncheckedArray[uint8]](rgbaPtr)
    let maxTw = min(int(tw), OV_W - 4)
    let maxTh = min(int(th), OV_H)
    for row in 0..<maxTh:
      let srcRow = cast[ptr UncheckedArray[uint8]](addr sp[row * int(tw) * 4])
      for col in 0..<maxTw:
        let di = (row * OV_W + col + 4) * 4
        let sa = int(srcRow[col*4+3])
        if sa > 0:
          ovPixels[di]   = srcRow[col*4]
          ovPixels[di+1] = srcRow[col*4+1]
          ovPixels[di+2] = srcRow[col*4+2]
          ovPixels[di+3] = uint8(min(255, int(bgA) + sa))
    c_free(rgbaPtr)
  # Upload overlay texture
  if ovTexId == 0: glGenTextures(1, addr ovTexId)
  glBindTexture(0x0DE1.GLenum, ovTexId)
  glTexParameteri(0x0DE1.GLenum, 0x2800.GLenum, 0x2600.GLint)  # MAG=NEAREST
  glTexParameteri(0x0DE1.GLenum, 0x2801.GLenum, 0x2600.GLint)  # MIN=NEAREST
  glTexParameteri(0x0DE1.GLenum, 0x2802.GLenum, 0x812F.GLint)  # WRAP_S=CLAMP
  glTexParameteri(0x0DE1.GLenum, 0x2803.GLenum, 0x812F.GLint)  # WRAP_T=CLAMP
  glTexImage2D(0x0DE1.GLenum, 0, 0x8058.GLint,
               GLsizei(OV_W), GLsizei(OV_H), 0,
               0x1908.GLenum, 0x1401.GLenum, unsafeAddr ovPixels[0])
  # Position overlay at top-left of game viewport.
  # SDL origin = top-left; GL origin = bottom-left.
  let ovX = c2dBlitVpX + 4
  let ovY = winH - c2dBlitVpY - 4 - OV_H   # convert SDL-top to GL-bottom
  glViewport(GLint(ovX), GLint(ovY), GLsizei(OV_W), GLsizei(OV_H))
  glDrawArrays(0x0004.GLenum, 0, 6)

proc presentAllCanvas2D*(winW, winH: int) =
  ## Upload CPU pixel buffers to GL textures and draw fullscreen quads.
  ## Called each frame after rAF dispatch, before SDL_GL_SwapWindow.
  ## In WebGL mode, composites the drawing buffer FBO to the window instead.
  if canvas2dStates.len == 0 and not gWebGLActive: return
  if c2dBlitProg == 0: initCanvas2dBlit()
  # Query GPU name once (GL context must be current)
  if not ovGpuQueried:
    ovGpuQueried = true
    let r = cast[cstring](glGetString(0x1F01.GLenum))  # GL_RENDERER
    let v = cast[cstring](glGetString(0x1F00.GLenum))  # GL_VENDOR
    var rs = ""; var vs = ""
    if r != nil: rs = $r
    if v != nil: vs = $v
    if rs.len > 0: c2dGpuName = rs
    elif vs.len > 0: c2dGpuName = vs
    else: c2dGpuName = "Unknown GPU"
  if not c2dBlitLogOnce:
    c2dBlitLogOnce = true
    for i in 0..<canvas2dStates.len:
      let cs = addr canvas2dStates[i]
      if not cs.isDisplay: continue
      stderr.writeLine("[c2d blit] display canvas[" & $i & "] size=" &
                       $cs.width & "x" & $cs.height &
                       " pixels.len=" & $cs.pixels.len)
    stderr.writeLine("[c2d blit] viewport=" & $winW & "x" & $winH &
                     " prog=" & $c2dBlitProg)
  # Grow texture pool to match states
  while c2dBlitTextures.len < canvas2dStates.len:
    var tid: GLuint = 0
    glGenTextures(1, addr tid)
    c2dBlitTextures.add(C2dBlitTex(id: tid, lastW: 0, lastH: 0))
  # Compute aspect-ratio-preserving (letterbox) viewport to match RPG Maker's layout.
  # RPG Maker uses realScale = min(winW/gameW, winH/gameH) and centers the canvas.
  var dispW, dispH: int = 0
  for cs in canvas2dStates:
    if cs.isDisplay and cs.width > dispW:
      dispW = cs.width; dispH = cs.height
  # In WebGL mode, use the drawing buffer dimensions for letterbox computation
  if gWebGLActive and glDrawingBufW > 0 and dispW == 0:
    dispW = glDrawingBufW; dispH = glDrawingBufH
  if dispW > 0 and dispH > 0:
    let scaleX = float32(winW) / float32(dispW)
    let scaleY = float32(winH) / float32(dispH)
    let scale  = min(scaleX, scaleY)
    c2dBlitVpW = int(float32(dispW) * scale + 0.5f)
    c2dBlitVpH = int(float32(dispH) * scale + 0.5f)
    c2dBlitVpX = (winW - c2dBlitVpW) div 2
    c2dBlitVpY = (winH - c2dBlitVpH) div 2
  else:
    c2dBlitVpX = 0; c2dBlitVpY = 0
    c2dBlitVpW = winW; c2dBlitVpH = winH
  # ── WebGL compositing path ──────────────────────────────────────────────
  # PIXI renders to the drawing buffer FBO.  Blit it to the real default
  # framebuffer with letterboxing, then draw the debug overlay on top.
  # CRITICAL: We must save ALL GL state that the WebGL app (PIXI) caches,
  # because PIXI uses a state cache and won't re-set state it thinks
  # hasn't changed.  If we modify GL state behind its back, the cache
  # becomes stale and rendering breaks on the next frame.
  if gWebGLActive:
    if glDrawingFBO == 0: return
    # Check if JS rendering left any GL error before we start compositing
    let preErr = glGetError()
    if preErr != 0:
      stderr.writeLine("[GL] error from JS rendering before compositing: " & $preErr)
    # ── Save GL state that the WebGL app's cache relies on ──────────
    var sBlend   = glIsEnabled(0x0BE2.GLenum)           # GL_BLEND
    var sDepthT  = glIsEnabled(0x0B71.GLenum)           # GL_DEPTH_TEST
    var sCull    = glIsEnabled(0x0B44.GLenum)           # GL_CULL_FACE
    var sScissor = glIsEnabled(0x0C11.GLenum)           # GL_SCISSOR_TEST
    var sStencil = glIsEnabled(0x0B90.GLenum)           # GL_STENCIL_TEST
    var sBSrcRGB, sBDstRGB, sBSrcA, sBDstA: GLint
    glGetIntegerv(0x80C9.GLenum, addr sBSrcRGB)         # BLEND_SRC_RGB
    glGetIntegerv(0x80C8.GLenum, addr sBDstRGB)         # BLEND_DST_RGB
    glGetIntegerv(0x80CB.GLenum, addr sBSrcA)           # BLEND_SRC_ALPHA
    glGetIntegerv(0x80CA.GLenum, addr sBDstA)           # BLEND_DST_ALPHA
    var sBEqRGB, sBEqA: GLint
    glGetIntegerv(0x8009.GLenum, addr sBEqRGB)          # BLEND_EQUATION_RGB
    glGetIntegerv(0x883D.GLenum, addr sBEqA)            # BLEND_EQUATION_ALPHA
    var sProg: GLint
    glGetIntegerv(0x8B8D.GLenum, addr sProg)            # CURRENT_PROGRAM
    var sVp: array[4, GLint]
    glGetIntegerv(0x0BA2.GLenum, addr sVp[0])           # VIEWPORT
    var sActiveTex: GLint
    glGetIntegerv(0x84E0.GLenum, addr sActiveTex)       # ACTIVE_TEXTURE
    # Save the texture bound on unit 0 (we modify unit 0 during compositing)
    glActiveTexture(0x84C0.GLenum)                       # GL_TEXTURE0
    var sTex0: GLint
    glGetIntegerv(0x8069.GLenum, addr sTex0)             # TEXTURE_BINDING_2D on unit 0
    glActiveTexture(GLenum(sActiveTex))                  # restore active unit for now
    var sClearColor: array[4, GLfloat]
    glGetFloatv(0x0C22.GLenum, addr sClearColor[0])     # COLOR_CLEAR_VALUE
    # ── Compositing: blit drawing buffer FBO → real default framebuffer ──
    glBindFramebuffer(0x8D40.GLenum, 0)        # bind REAL default framebuffer
    glViewport(0, 0, GLsizei(winW), GLsizei(winH))
    glDisable(0x0B71.GLenum)                    # GL_DEPTH_TEST
    glDisable(0x0B44.GLenum)                    # GL_CULL_FACE
    glDisable(0x0BE2.GLenum)                    # GL_BLEND (FBO already composited)
    glDisable(0x0C11.GLenum)                    # GL_SCISSOR_TEST
    glDisable(0x0B90.GLenum)                    # GL_STENCIL_TEST
    glClearColor(0.0f, 0.0f, 0.0f, 1.0f)
    glClear(0x4000.GLbitfield)                  # GL_COLOR_BUFFER_BIT
    # Letterbox viewport
    glViewport(GLint(c2dBlitVpX), GLint(winH - c2dBlitVpY - c2dBlitVpH),
               GLsizei(c2dBlitVpW), GLsizei(c2dBlitVpH))
    glUseProgram(c2dBlitProg)
    glUniform1i(c2dBlitTexLoc, 0)
    glActiveTexture(0x84C0.GLenum)              # GL_TEXTURE0
    glBindTexture(0x0DE1.GLenum, glDrawingColorTex)
    glBindVertexArray(c2dBlitVAO_fbo)
    glDrawArrays(0x0004.GLenum, 0, 6)           # GL_TRIANGLES
    # FPS overlay (needs blending for semi-transparent background)
    if c2dShowOverlay:
      glEnable(0x0BE2.GLenum)                   # GL_BLEND
      glBlendFunc(0x0302.GLenum, 0x0303.GLenum) # SRC_ALPHA, ONE_MINUS_SRC_ALPHA
      glBindVertexArray(c2dBlitVAO2d)            # overlay is CPU pixels (flipped UV)
      drawNativeOverlay(winW, winH)
    # ── Restore ALL saved GL state ──────────────────────────────────
    # Enable/disable flags
    if sBlend   != 0: glEnable(0x0BE2.GLenum) else: glDisable(0x0BE2.GLenum)
    if sDepthT  != 0: glEnable(0x0B71.GLenum) else: glDisable(0x0B71.GLenum)
    if sCull    != 0: glEnable(0x0B44.GLenum) else: glDisable(0x0B44.GLenum)
    if sScissor != 0: glEnable(0x0C11.GLenum) else: glDisable(0x0C11.GLenum)
    if sStencil != 0: glEnable(0x0B90.GLenum) else: glDisable(0x0B90.GLenum)
    # Blend function and equation
    glBlendFuncSeparate(GLenum(sBSrcRGB), GLenum(sBDstRGB),
                        GLenum(sBSrcA), GLenum(sBDstA))
    glBlendEquationSeparate(GLenum(sBEqRGB), GLenum(sBEqA))
    # Shader program
    glUseProgram(GLuint(sProg))
    # Viewport
    glViewport(sVp[0], sVp[1], GLsizei(sVp[2]), GLsizei(sVp[3]))
    # Texture state — restore unit 0 binding, then restore active unit
    glActiveTexture(0x84C0.GLenum)                       # GL_TEXTURE0
    glBindTexture(0x0DE1.GLenum, GLuint(sTex0))
    glActiveTexture(GLenum(sActiveTex))
    # Clear color
    glClearColor(sClearColor[0], sClearColor[1], sClearColor[2], sClearColor[3])
    # Framebuffer — redirect JS's "default" back to our drawing buffer
    glBindFramebuffer(0x8D40.GLenum, if glJSBoundFBO == 0: glDrawingFBO else: glJSBoundFBO)
    glBindVertexArray(glDefaultVAO)
    # ── Sync state cache with restored values ─────────────────────
    # The compositing path used direct GL calls (not jsGl* functions),
    # so the shadow cache is stale.  Update it to match restored state
    # so that JS's next redundant call is correctly skipped.
    glCapState[0] = int8(sBlend)    # GL_BLEND
    glCapState[1] = int8(sCull)     # GL_CULL_FACE
    glCapState[2] = int8(sDepthT)   # GL_DEPTH_TEST
    glCapState[7] = int8(sScissor)  # GL_SCISSOR_TEST
    glCapState[8] = int8(sStencil)  # GL_STENCIL_TEST
    glCacheBlendSrcRGB = GLenum(sBSrcRGB)
    glCacheBlendDstRGB = GLenum(sBDstRGB)
    glCacheBlendSrcA   = GLenum(sBSrcA)
    glCacheBlendDstA   = GLenum(sBDstA)
    glCacheBlendEqRGB  = GLenum(sBEqRGB)
    glCacheBlendEqA    = GLenum(sBEqA)
    glCacheProgram = GLuint(sProg)
    glCacheVpX = sVp[0]; glCacheVpY = sVp[1]
    glCacheVpW = GLsizei(sVp[2]); glCacheVpH = GLsizei(sVp[3])
    glCacheActiveTexUnit = GLenum(sActiveTex)
    let unit0 = int(uint32(sActiveTex) - 0x84C0'u32)
    if unit0 == 0:
      glCacheBoundTex2D[0] = GLuint(sTex0)
    else:
      # We restored tex0 on unit 0, then switched active unit back
      glCacheBoundTex2D[0] = GLuint(sTex0)
    return

  glBindFramebuffer(0x8D40.GLenum, 0)      # GL_FRAMEBUFFER → default
  glViewport(0, 0, GLsizei(winW), GLsizei(winH))
  glDisable(0x0B71.GLenum)                  # GL_DEPTH_TEST
  glDisable(0x0B44.GLenum)                  # GL_CULL_FACE
  glEnable(0x0BE2.GLenum)                   # GL_BLEND
  glBlendFunc(0x0302.GLenum, 0x0303.GLenum) # SRC_ALPHA, ONE_MINUS_SRC_ALPHA
  glDisable(0x0C11.GLenum)                  # GL_SCISSOR_TEST
  glDisable(0x0B90.GLenum)                  # GL_STENCIL_TEST
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f)
  glClear(0x4000.GLbitfield)                # GL_COLOR_BUFFER_BIT
  # Now restrict drawing to the letterbox game area.
  # GL Y-axis is bottom-up; SDL vpY (from top) → GL y = winH - vpY - vpH.
  glViewport(GLint(c2dBlitVpX), GLint(winH - c2dBlitVpY - c2dBlitVpH),
             GLsizei(c2dBlitVpW), GLsizei(c2dBlitVpH))
  glUseProgram(c2dBlitProg)
  glUniform1i(c2dBlitTexLoc, 0)
  glActiveTexture(0x84C0.GLenum)            # GL_TEXTURE0
  glBindVertexArray(c2dBlitVAO2d)
  for i in 0..<canvas2dStates.len:
    let cs = addr canvas2dStates[i]
    if cs.pixels.len == 0: continue
    if not cs.isDisplay: continue   # only render canvases attached to document.body
    var tex = addr c2dBlitTextures[i]
    glBindTexture(0x0DE1.GLenum, tex.id)    # GL_TEXTURE_2D
    if not cs.dirty and tex.lastW > 0:
      # Canvas unchanged since last upload — reuse existing texture
      glDrawArrays(0x0004.GLenum, 0, 6)     # GL_TRIANGLES
      continue
    glPixelStorei(0x0CF5.GLenum, 4)         # GL_UNPACK_ALIGNMENT = 4
    glPixelStorei(0x0CF2.GLenum, 0)         # GL_UNPACK_ROW_LENGTH = 0 (use width)
    if tex.lastW != cs.width or tex.lastH != cs.height:
      # Set sampling state once here (size changed or first use)
      glTexParameteri(0x0DE1.GLenum, 0x2800.GLenum, 0x2601.GLint)  # MAG_FILTER = LINEAR
      glTexParameteri(0x0DE1.GLenum, 0x2801.GLenum, 0x2601.GLint)  # MIN_FILTER = LINEAR
      glTexParameteri(0x0DE1.GLenum, 0x2802.GLenum, 0x812F.GLint)  # WRAP_S = CLAMP_TO_EDGE
      glTexParameteri(0x0DE1.GLenum, 0x2803.GLenum, 0x812F.GLint)  # WRAP_T = CLAMP_TO_EDGE
      glTexImage2D(0x0DE1.GLenum, 0, 0x8058.GLint,  # GL_RGBA8
                   GLsizei(cs.width), GLsizei(cs.height), 0,
                   0x1908.GLenum, 0x1401.GLenum, addr cs.pixels[0])
      tex.lastW = cs.width
      tex.lastH = cs.height
    else:
      glTexSubImage2D(0x0DE1.GLenum, 0, 0, 0,
                      GLsizei(cs.width), GLsizei(cs.height),
                      0x1908.GLenum, 0x1401.GLenum, addr cs.pixels[0])
    cs.dirty = false
    glDrawArrays(0x0004.GLenum, 0, 6)       # GL_TRIANGLES
  # Draw native debug overlay on top when F2 is toggled
  if c2dShowOverlay:
    drawNativeOverlay(winW, winH)
  glBindVertexArray(glDefaultVAO)


