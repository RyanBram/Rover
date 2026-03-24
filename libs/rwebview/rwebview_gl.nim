# ===========================================================================
# Phase 4 — OpenGL types, function pointers, and loader
# ===========================================================================

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

# WebGL-specific pixelStorei state (no OpenGL equivalent)
var glUnpackFlipY: bool = false
var glUnpackPremultiplyAlpha: bool = false

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
  load(glGetShaderiv); load(glGetShaderInfoLog)
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

proc jsGlViewport(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glViewport(GLint(argI32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
             GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlClearColor(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClearColor(argF32(ctx, argv, 0), argF32(ctx, argv, 1),
               argF32(ctx, argv, 2), argF32(ctx, argv, 3))
  rw_JS_Undefined()

proc jsGlClear(ctx: ptr JSContext; thisVal: JSValue;
               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClear(GLbitfield(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlEnable(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glEnable(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlDisable(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDisable(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlBlendFunc(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendFunc(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlBlendFuncSeparate(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendFuncSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                      GLenum(argU32(ctx, argv, 2)), GLenum(argU32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlBlendEquation(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendEquation(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlBlendEquationSeparate(ctx: ptr JSContext; thisVal: JSValue;
                               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendEquationSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlBlendColor(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBlendColor(argF32(ctx, argv, 0), argF32(ctx, argv, 1),
               argF32(ctx, argv, 2), argF32(ctx, argv, 3))
  rw_JS_Undefined()

proc jsGlDepthFunc(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDepthFunc(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlDepthMask(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDepthMask(GLboolean(if argBool(ctx, argv, 0): 1 else: 0))
  rw_JS_Undefined()

proc jsGlDepthRange(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDepthRange(argF64(ctx, argv, 0), argF64(ctx, argv, 1))
  rw_JS_Undefined()

proc jsGlClearDepth(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClearDepth(argF64(ctx, argv, 0))
  rw_JS_Undefined()

proc jsGlCullFace(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glCullFace(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlFrontFace(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFrontFace(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlScissor(ctx: ptr JSContext; thisVal: JSValue;
                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glScissor(GLint(argI32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
            GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlLineWidth(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glLineWidth(argF32(ctx, argv, 0))
  rw_JS_Undefined()

proc jsGlColorMask(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glColorMask(GLboolean(if argBool(ctx, argv, 0): 1 else: 0),
              GLboolean(if argBool(ctx, argv, 1): 1 else: 0),
              GLboolean(if argBool(ctx, argv, 2): 1 else: 0),
              GLboolean(if argBool(ctx, argv, 3): 1 else: 0))
  rw_JS_Undefined()

proc jsGlStencilFunc(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilFunc(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                GLuint(argU32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlStencilFuncSeparate(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilFuncSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                        GLint(argI32(ctx, argv, 2)), GLuint(argU32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlStencilOp(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilOp(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
              GLenum(argU32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlStencilOpSeparate(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilOpSeparate(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                      GLenum(argU32(ctx, argv, 2)), GLenum(argU32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlStencilMask(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilMask(GLuint(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlStencilMaskSeparate(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glStencilMaskSeparate(GLenum(argU32(ctx, argv, 0)), GLuint(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlClearStencil(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glClearStencil(GLint(argI32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlPixelStorei(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let pname = GLenum(argU32(ctx, argv, 0))
  let param = argI32(ctx, argv, 1)
  # Handle WebGL-specific pixel storage params
  if pname == 0x9240'u32:   # UNPACK_FLIP_Y_WEBGL
    glUnpackFlipY = param != 0
  elif pname == 0x9241'u32: # UNPACK_PREMULTIPLY_ALPHA_WEBGL
    glUnpackPremultiplyAlpha = param != 0
  elif pname == 0x9243'u32: # UNPACK_COLORSPACE_CONVERSION_WEBGL
    discard  # no-op
  else:
    glPixelStorei(pname, GLint(param))
  rw_JS_Undefined()

proc jsGlFlush(ctx: ptr JSContext; thisVal: JSValue;
               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFlush()
  rw_JS_Undefined()

proc jsGlFinish(ctx: ptr JSContext; thisVal: JSValue;
                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFinish()
  rw_JS_Undefined()

proc jsGlGetError(ctx: ptr JSContext; thisVal: JSValue;
                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_NewInt32(ctx, int32(glGetError()))

proc jsGlIsEnabled(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_NewBool(ctx, cint(glIsEnabled(GLenum(argU32(ctx, argv, 0)))))

# ── Shaders ──────────────────────────────────────────────────────────────

proc jsGlCreateShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let id = glCreateShader(GLenum(argU32(ctx, argv, 0)))
  jsNewGLHandle(ctx, id)

proc jsGlDeleteShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDeleteShader(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlShaderSource(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let shader = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  var src = argStr(ctx, argv, 1)
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
  rw_JS_Undefined()

proc jsGlCompileShader(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glCompileShader(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlGetShaderParameter(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let shader = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let pname = GLenum(argU32(ctx, argv, 1))
  var v: GLint
  glGetShaderiv(shader, pname, addr v)
  if pname == 0x8B81'u32 or pname == 0x8B80'u32:  # COMPILE_STATUS, DELETE_STATUS
    return rw_JS_NewBool(ctx, cint(v))
  rw_JS_NewInt32(ctx, v)

proc jsGlGetShaderInfoLog(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let shader = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  var logLen: GLint
  glGetShaderiv(shader, 0x8B84'u32, addr logLen)  # INFO_LOG_LENGTH
  if logLen <= 0: return rw_JS_NewString(ctx, "")
  var buf = newString(logLen)
  var actual: GLsizei
  glGetShaderInfoLog(shader, GLsizei(logLen), addr actual, cstring(buf))
  buf.setLen(actual)
  rw_JS_NewString(ctx, cstring(buf))

proc jsGlCreateProgram(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  jsNewGLHandle(ctx, glCreateProgram())

proc jsGlDeleteProgram(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDeleteProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlAttachShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glAttachShader(GLuint(jsGetGLId(ctx, arg(argv, 0))),
                 GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlDetachShader(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDetachShader(GLuint(jsGetGLId(ctx, arg(argv, 0))),
                 GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlLinkProgram(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glLinkProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlGetProgramParameter(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let pname = GLenum(argU32(ctx, argv, 1))
  var v: GLint
  glGetProgramiv(prog, pname, addr v)
  if pname == 0x8B82'u32 or pname == 0x8B83'u32 or pname == 0x8B80'u32:
    # LINK_STATUS, VALIDATE_STATUS, DELETE_STATUS
    return rw_JS_NewBool(ctx, cint(v))
  rw_JS_NewInt32(ctx, v)

proc jsGlGetProgramInfoLog(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  var logLen: GLint
  glGetProgramiv(prog, 0x8B84'u32, addr logLen)  # INFO_LOG_LENGTH
  if logLen <= 0: return rw_JS_NewString(ctx, "")
  var buf = newString(logLen)
  var actual: GLsizei
  glGetProgramInfoLog(prog, GLsizei(logLen), addr actual, cstring(buf))
  buf.setLen(actual)
  rw_JS_NewString(ctx, cstring(buf))

proc jsGlUseProgram(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUseProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

proc jsGlValidateProgram(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glValidateProgram(GLuint(jsGetGLId(ctx, arg(argv, 0))))
  rw_JS_Undefined()

# ── Attributes / Uniforms Location ───────────────────────────────────────

proc jsGlGetAttribLocation(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let name = argStr(ctx, argv, 1)
  rw_JS_NewInt32(ctx, glGetAttribLocation(prog, cstring(name)))

proc jsGlGetUniformLocation(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let name = argStr(ctx, argv, 1)
  jsNewGLLocHandle(ctx, glGetUniformLocation(prog, cstring(name)))

proc jsGlBindAttribLocation(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glBindAttribLocation(prog, GLuint(argU32(ctx, argv, 1)), cstring(argStr(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlEnableVertexAttribArray(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glEnableVertexAttribArray(GLuint(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlDisableVertexAttribArray(ctx: ptr JSContext; thisVal: JSValue;
                                  argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDisableVertexAttribArray(GLuint(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlVertexAttribPointer(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glVertexAttribPointer(
    GLuint(argU32(ctx, argv, 0)),
    GLint(argI32(ctx, argv, 1)),
    GLenum(argU32(ctx, argv, 2)),
    GLboolean(if argBool(ctx, argv, 3): 1 else: 0),
    GLsizei(argI32(ctx, argv, 4)),
    cast[pointer](argI32(ctx, argv, 5))  # byte offset → pointer
  )
  rw_JS_Undefined()

proc jsGlGetActiveAttrib(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let index = GLuint(argU32(ctx, argv, 1))
  var nameBuf: array[256, char]
  var length: GLsizei
  var size: GLint
  var typ: GLenum
  glGetActiveAttrib(prog, index, 256, addr length, addr size, addr typ, cast[cstring](addr nameBuf[0]))
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "size", rw_JS_NewInt32(ctx, size))
  discard JS_SetPropertyStr(ctx, obj, "type", rw_JS_NewInt32(ctx, int32(typ)))
  discard JS_SetPropertyStr(ctx, obj, "name", JS_NewStringLen(ctx, cast[cstring](addr nameBuf[0]), csize_t(length)))
  obj

proc jsGlGetActiveUniform(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let prog = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  let index = GLuint(argU32(ctx, argv, 1))
  var nameBuf: array[256, char]
  var length: GLsizei
  var size: GLint
  var typ: GLenum
  glGetActiveUniform(prog, index, 256, addr length, addr size, addr typ, cast[cstring](addr nameBuf[0]))
  let obj = JS_NewObject(ctx)
  discard JS_SetPropertyStr(ctx, obj, "size", rw_JS_NewInt32(ctx, size))
  discard JS_SetPropertyStr(ctx, obj, "type", rw_JS_NewInt32(ctx, int32(typ)))
  discard JS_SetPropertyStr(ctx, obj, "name", JS_NewStringLen(ctx, cast[cstring](addr nameBuf[0]), csize_t(length)))
  obj

# ── Buffers ──────────────────────────────────────────────────────────────

proc jsGlCreateBuffer(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenBuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteBuffer(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteBuffers(1, addr id)
  rw_JS_Undefined()

proc jsGlBindBuffer(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindBuffer(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlBufferData(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let target = GLenum(argU32(ctx, argv, 0))
  let usage  = GLenum(argU32(ctx, argv, 2))
  let tag = rw_JS_VALUE_GET_TAG(arg(argv, 1))
  if tag == JS_TAG_INT_C or tag == JS_TAG_FLOAT64_C:
    # bufferData(target, size, usage) — allocate empty
    let size = argI32(ctx, argv, 1)
    glBufferData(target, int(size), nil, usage)
  else:
    # bufferData(target, typedArray, usage) — allocate with data
    let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
    glBufferData(target, int(size), data, usage)
  rw_JS_Undefined()

proc jsGlBufferSubData(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let target = GLenum(argU32(ctx, argv, 0))
  let offset = argI32(ctx, argv, 1)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glBufferSubData(target, int(offset), int(size), data)
  rw_JS_Undefined()

# ── Textures ─────────────────────────────────────────────────────────────

proc jsGlCreateTexture(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenTextures(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteTexture(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteTextures(1, addr id)
  rw_JS_Undefined()

proc jsGlBindTexture(ctx: ptr JSContext; thisVal: JSValue;
                     argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindTexture(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlActiveTexture(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glActiveTexture(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

proc jsGlTexImage2D(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc >= 9:
    # texImage2D(target, level, internalformat, width, height, border, format, type, data)
    let target = GLenum(argU32(ctx, argv, 0))
    let level  = GLint(argI32(ctx, argv, 1))
    let ifmt   = GLint(argI32(ctx, argv, 2))
    let width  = GLsizei(argI32(ctx, argv, 3))
    let height = GLsizei(argI32(ctx, argv, 4))
    let border = GLint(argI32(ctx, argv, 5))
    let fmt    = GLenum(argU32(ctx, argv, 6))
    let typ    = GLenum(argU32(ctx, argv, 7))
    let tag = rw_JS_VALUE_GET_TAG(arg(argv, 8))
    if tag == JS_TAG_NULL_C or tag == JS_TAG_UNDEFINED_C:
      glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, nil)
    else:
      let (data, size) = jsGetBufferData(ctx, arg(argv, 8))
      glTexImage2D(target, level, ifmt, width, height, border, fmt, typ, data)
  elif argc >= 6:
    # texImage2D(target, level, internalformat, format, type, source)
    # source is HTMLImageElement — extract pixel data (stub: 1x1 white pixel)
    let target = GLenum(argU32(ctx, argv, 0))
    let level  = GLint(argI32(ctx, argv, 1))
    let ifmt   = GLint(argI32(ctx, argv, 2))
    let fmt    = GLenum(argU32(ctx, argv, 3))
    let typ    = GLenum(argU32(ctx, argv, 4))
    # Try to get __pixelData from the image object (set by Phase 6 image loader)
    let source = arg(argv, 5)
    # Check if source is a canvas element with a 2D context (__ctxId)
    let ctxIdProp = JS_GetPropertyStr(ctx, source, "__ctxId")
    let ctxIdTag = rw_JS_VALUE_GET_TAG(ctxIdProp)
    if ctxIdTag == JS_TAG_INT_C:
      var srcId: int32
      discard JS_ToInt32(ctx, addr srcId, ctxIdProp)
      rw_JS_FreeValue(ctx, ctxIdProp)
      if srcId >= 0 and srcId < int32(canvas2dStates.len):
        let sc = addr canvas2dStates[srcId]
        if sc.pixels.len > 0:
          glTexImage2D(target, level, ifmt, GLsizei(sc.width), GLsizei(sc.height),
                       0, fmt, typ, addr sc.pixels[0])
        else:
          var px: array[4, uint8] = [255'u8, 255, 255, 255]
          glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, addr px[0])
    else:
      rw_JS_FreeValue(ctx, ctxIdProp)
      let pxProp = JS_GetPropertyStr(ctx, source, "__pixelData")
      let pxTag = rw_JS_VALUE_GET_TAG(pxProp)
      if pxTag != JS_TAG_NULL_C and pxTag != JS_TAG_UNDEFINED_C:
        # Image has pixel data — extract width/height and buffer
        let wProp = JS_GetPropertyStr(ctx, source, "naturalWidth")
        let hProp = JS_GetPropertyStr(ctx, source, "naturalHeight")
        var iw, ih: int32
        discard JS_ToInt32(ctx, addr iw, wProp)
        discard JS_ToInt32(ctx, addr ih, hProp)
        let (data, sz) = jsGetBufferData(ctx, pxProp)
        glTexImage2D(target, level, ifmt, GLsizei(iw), GLsizei(ih), 0, fmt, typ, data)
        rw_JS_FreeValue(ctx, wProp)
        rw_JS_FreeValue(ctx, hProp)
      else:
        # Fallback: 1x1 white pixel
        var px: array[4, uint8] = [255'u8, 255, 255, 255]
        glTexImage2D(target, level, ifmt, 1, 1, 0, fmt, typ, addr px[0])
      rw_JS_FreeValue(ctx, pxProp)
  rw_JS_Undefined()

proc jsGlTexSubImage2D(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc >= 9:
    let (data, size) = jsGetBufferData(ctx, arg(argv, 8))
    glTexSubImage2D(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                    GLint(argI32(ctx, argv, 2)), GLint(argI32(ctx, argv, 3)),
                    GLsizei(argI32(ctx, argv, 4)), GLsizei(argI32(ctx, argv, 5)),
                    GLenum(argU32(ctx, argv, 6)), GLenum(argU32(ctx, argv, 7)), data)
  rw_JS_Undefined()

proc jsGlTexParameteri(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glTexParameteri(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                  GLint(argI32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlTexParameterf(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glTexParameterf(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                  argF32(ctx, argv, 2))
  rw_JS_Undefined()

proc jsGlGenerateMipmap(ctx: ptr JSContext; thisVal: JSValue;
                        argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glGenerateMipmap(GLenum(argU32(ctx, argv, 0)))
  rw_JS_Undefined()

# ── Framebuffers / Renderbuffers ─────────────────────────────────────────

proc jsGlCreateFramebuffer(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenFramebuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteFramebuffer(ctx: ptr JSContext; thisVal: JSValue;
                           argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteFramebuffers(1, addr id)
  rw_JS_Undefined()

proc jsGlBindFramebuffer(ctx: ptr JSContext; thisVal: JSValue;
                         argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindFramebuffer(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlFramebufferTexture2D(ctx: ptr JSContext; thisVal: JSValue;
                              argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFramebufferTexture2D(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                         GLenum(argU32(ctx, argv, 2)),
                         GLuint(jsGetGLId(ctx, arg(argv, 3))),
                         GLint(argI32(ctx, argv, 4)))
  rw_JS_Undefined()

proc jsGlFramebufferRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glFramebufferRenderbuffer(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                            GLenum(argU32(ctx, argv, 2)),
                            GLuint(jsGetGLId(ctx, arg(argv, 3))))
  rw_JS_Undefined()

proc jsGlCheckFramebufferStatus(ctx: ptr JSContext; thisVal: JSValue;
                                argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_NewInt32(ctx, int32(glCheckFramebufferStatus(GLenum(argU32(ctx, argv, 0)))))

proc jsGlCreateRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id: GLuint
  glGenRenderbuffers(1, addr id)
  jsNewGLHandle(ctx, id)

proc jsGlDeleteRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                            argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  var id = GLuint(jsGetGLId(ctx, arg(argv, 0)))
  glDeleteRenderbuffers(1, addr id)
  rw_JS_Undefined()

proc jsGlBindRenderbuffer(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glBindRenderbuffer(GLenum(argU32(ctx, argv, 0)), GLuint(jsGetGLId(ctx, arg(argv, 1))))
  rw_JS_Undefined()

proc jsGlRenderbufferStorage(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glRenderbufferStorage(GLenum(argU32(ctx, argv, 0)), GLenum(argU32(ctx, argv, 1)),
                        GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

# ── Drawing ──────────────────────────────────────────────────────────────

proc jsGlDrawArrays(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDrawArrays(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
               GLsizei(argI32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlDrawElements(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glDrawElements(GLenum(argU32(ctx, argv, 0)), GLsizei(argI32(ctx, argv, 1)),
                 GLenum(argU32(ctx, argv, 2)),
                 cast[pointer](argI32(ctx, argv, 3)))  # byte offset → pointer
  rw_JS_Undefined()

# ── Uniforms ─────────────────────────────────────────────────────────────

proc jsGlUniform1f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform1f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1))
  rw_JS_Undefined()

proc jsGlUniform2f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform2f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1), argF32(ctx, argv, 2))
  rw_JS_Undefined()

proc jsGlUniform3f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform3f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1),
              argF32(ctx, argv, 2), argF32(ctx, argv, 3))
  rw_JS_Undefined()

proc jsGlUniform4f(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform4f(jsGetGLLocId(ctx, arg(argv, 0)), argF32(ctx, argv, 1),
              argF32(ctx, argv, 2), argF32(ctx, argv, 3), argF32(ctx, argv, 4))
  rw_JS_Undefined()

proc jsGlUniform1i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform1i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)))
  rw_JS_Undefined()

proc jsGlUniform2i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform2i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)),
              GLint(argI32(ctx, argv, 2)))
  rw_JS_Undefined()

proc jsGlUniform3i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform3i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)),
              GLint(argI32(ctx, argv, 2)), GLint(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlUniform4i(ctx: ptr JSContext; thisVal: JSValue;
                   argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  glUniform4i(jsGetGLLocId(ctx, arg(argv, 0)), GLint(argI32(ctx, argv, 1)),
              GLint(argI32(ctx, argv, 2)), GLint(argI32(ctx, argv, 3)),
              GLint(argI32(ctx, argv, 4)))
  rw_JS_Undefined()

# Uniform*v and UniformMatrix*fv — take TypedArray data

proc jsGlUniform1fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform1fv(loc, GLsizei(int(size) div sizeof(GLfloat)), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform2fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform2fv(loc, GLsizei(int(size) div (2 * sizeof(GLfloat))), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform3fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform3fv(loc, GLsizei(int(size) div (3 * sizeof(GLfloat))), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform4fv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform4fv(loc, GLsizei(int(size) div (4 * sizeof(GLfloat))), cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniform1iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform1iv(loc, GLsizei(int(size) div sizeof(GLint)), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniform2iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform2iv(loc, GLsizei(int(size) div (2 * sizeof(GLint))), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniform3iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform3iv(loc, GLsizei(int(size) div (3 * sizeof(GLint))), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniform4iv(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let (data, size) = jsGetBufferData(ctx, arg(argv, 1))
  if data != nil:
    glUniform4iv(loc, GLsizei(int(size) div (4 * sizeof(GLint))), cast[ptr GLint](data))
  rw_JS_Undefined()

proc jsGlUniformMatrix2fv(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let transpose = GLboolean(if argBool(ctx, argv, 1): 1 else: 0)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glUniformMatrix2fv(loc, GLsizei(int(size) div (4 * sizeof(GLfloat))), transpose, cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniformMatrix3fv(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let transpose = GLboolean(if argBool(ctx, argv, 1): 1 else: 0)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glUniformMatrix3fv(loc, GLsizei(int(size) div (9 * sizeof(GLfloat))), transpose, cast[ptr GLfloat](data))
  rw_JS_Undefined()

proc jsGlUniformMatrix4fv(ctx: ptr JSContext; thisVal: JSValue;
                          argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let loc = jsGetGLLocId(ctx, arg(argv, 0))
  let transpose = GLboolean(if argBool(ctx, argv, 1): 1 else: 0)
  let (data, size) = jsGetBufferData(ctx, arg(argv, 2))
  if data != nil:
    glUniformMatrix4fv(loc, GLsizei(int(size) div (16 * sizeof(GLfloat))), transpose, cast[ptr GLfloat](data))
  rw_JS_Undefined()

# ── Reading ──────────────────────────────────────────────────────────────

proc jsGlReadPixels(ctx: ptr JSContext; thisVal: JSValue;
                    argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if argc >= 7:
    let (data, size) = jsGetBufferData(ctx, arg(argv, 6))
    if data != nil:
      glReadPixels(GLint(argI32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                   GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)),
                   GLenum(argU32(ctx, argv, 4)), GLenum(argU32(ctx, argv, 5)), data)
  rw_JS_Undefined()

# ── Query / Parameter ────────────────────────────────────────────────────

proc jsGlGetParameter(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let pname = GLenum(argU32(ctx, argv, 0))
  case pname
  of 0x1F00'u32:  # VENDOR
    let s = glGetString(pname)
    if s != nil: return rw_JS_NewString(ctx, cast[cstring](s))
    return rw_JS_NewString(ctx, "rwebview")
  of 0x1F01'u32:  # RENDERER
    let s = glGetString(pname)
    if s != nil: return rw_JS_NewString(ctx, cast[cstring](s))
    return rw_JS_NewString(ctx, "rwebview OpenGL")
  of 0x1F02'u32:  # VERSION
    return rw_JS_NewString(ctx, "WebGL 1.0")
  of 0x8B8C'u32:  # SHADING_LANGUAGE_VERSION
    return rw_JS_NewString(ctx, "WebGL GLSL ES 1.0")
  of 0x0BA2'u32:  # VIEWPORT
    var v: array[4, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    for i in 0..3:
      discard JS_SetPropertyUint32(ctx, arr, uint32(i), rw_JS_NewInt32(ctx, v[i]))
    return arr
  of 0x0C23'u32:  # COLOR_WRITEMASK
    var v: array[4, GLboolean]
    glGetBooleanv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    for i in 0..3:
      discard JS_SetPropertyUint32(ctx, arr, uint32(i), rw_JS_NewBool(ctx, cint(v[i])))
    return arr
  of 0x0D3A'u32:  # MAX_VIEWPORT_DIMS
    var v: array[2, GLint]
    glGetIntegerv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    discard JS_SetPropertyUint32(ctx, arr, 0, rw_JS_NewInt32(ctx, v[0]))
    discard JS_SetPropertyUint32(ctx, arr, 1, rw_JS_NewInt32(ctx, v[1]))
    return arr
  of 0x846E'u32:  # ALIASED_LINE_WIDTH_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    discard JS_SetPropertyUint32(ctx, arr, 0, rw_JS_NewFloat64(ctx, float64(v[0])))
    discard JS_SetPropertyUint32(ctx, arr, 1, rw_JS_NewFloat64(ctx, float64(v[1])))
    return arr
  of 0x846D'u32:  # ALIASED_POINT_SIZE_RANGE
    var v: array[2, GLfloat]
    glGetFloatv(pname, addr v[0])
    let arr = JS_NewArray(ctx)
    discard JS_SetPropertyUint32(ctx, arr, 0, rw_JS_NewFloat64(ctx, float64(v[0])))
    discard JS_SetPropertyUint32(ctx, arr, 1, rw_JS_NewFloat64(ctx, float64(v[1])))
    return arr
  of 0x0B72'u32:  # DEPTH_WRITEMASK
    var v: GLboolean
    glGetBooleanv(pname, addr v)
    return rw_JS_NewBool(ctx, cint(v))
  of 0x0BE2'u32:  # BLEND
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0B44'u32:  # CULL_FACE
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0B71'u32:  # DEPTH_TEST
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0BD0'u32:  # DITHER
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x8037'u32:  # POLYGON_OFFSET_FILL
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x80A0'u32:  # SAMPLE_COVERAGE
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0C11'u32:  # SCISSOR_TEST
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x0B90'u32:  # STENCIL_TEST
    return rw_JS_NewBool(ctx, cint(glIsEnabled(pname)))
  of 0x9240'u32:  # UNPACK_FLIP_Y_WEBGL
    return rw_JS_NewBool(ctx, cint(ord(glUnpackFlipY)))
  of 0x9241'u32:  # UNPACK_PREMULTIPLY_ALPHA_WEBGL
    return rw_JS_NewBool(ctx, cint(ord(glUnpackPremultiplyAlpha)))
  else:
    # Default: integer query
    var v: GLint
    glGetIntegerv(pname, addr v)
    return rw_JS_NewInt32(ctx, v)

proc jsGlGetExtension(ctx: ptr JSContext; thisVal: JSValue;
                      argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let name = argStr(ctx, argv, 0)
  case name
  of "OES_element_index_uint", "OES_texture_float",
     "OES_texture_float_linear", "OES_standard_derivatives",
     "EXT_shader_texture_lod", "EXT_frag_depth",
     "EXT_blend_minmax":
    return JS_NewObject(ctx)
  of "OES_texture_half_float":
    let obj = JS_NewObject(ctx)
    discard JS_SetPropertyStr(ctx, obj, "HALF_FLOAT_OES", rw_JS_NewInt32(ctx, 0x8D61))
    return obj
  of "OES_texture_half_float_linear":
    return JS_NewObject(ctx)
  of "OES_vertex_array_object":
    # GL 3.3 Core has native VAO support; expose as OES extension
    let obj = JS_NewObject(ctx)
    # Stub methods — these call the real GL functions via __rw_* natives
    # installed during bindWebGL
    return obj
  of "ANGLE_instanced_arrays":
    let obj = JS_NewObject(ctx)
    return obj
  of "WEBGL_lose_context":
    let obj = JS_NewObject(ctx)
    return obj
  of "WEBGL_depth_texture":
    return JS_NewObject(ctx)
  else:
    return rw_JS_Null()

proc jsGlGetShaderPrecisionFormat(ctx: ptr JSContext; thisVal: JSValue;
                                 argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  let obj = JS_NewObject(ctx)
  if glGetShaderPrecisionFormat != nil:
    let shaderType = GLenum(argU32(ctx, argv, 0))
    let precisionType = GLenum(argU32(ctx, argv, 1))
    var range: array[2, GLint]
    var precision: GLint
    glGetShaderPrecisionFormat(shaderType, precisionType, addr range[0], addr precision)
    discard JS_SetPropertyStr(ctx, obj, "rangeMin", rw_JS_NewInt32(ctx, range[0]))
    discard JS_SetPropertyStr(ctx, obj, "rangeMax", rw_JS_NewInt32(ctx, range[1]))
    discard JS_SetPropertyStr(ctx, obj, "precision", rw_JS_NewInt32(ctx, precision))
  else:
    # GL 3.3 may not have this function; return sensible defaults
    discard JS_SetPropertyStr(ctx, obj, "rangeMin", rw_JS_NewInt32(ctx, 127))
    discard JS_SetPropertyStr(ctx, obj, "rangeMax", rw_JS_NewInt32(ctx, 127))
    discard JS_SetPropertyStr(ctx, obj, "precision", rw_JS_NewInt32(ctx, 23))
  obj

proc jsGlIsContextLost(ctx: ptr JSContext; thisVal: JSValue;
                       argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  rw_JS_False()

# ── Instanced rendering (ANGLE_instanced_arrays extension) ───────────────

proc jsGlDrawArraysInstanced(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if glDrawArraysInstanced != nil:
    glDrawArraysInstanced(GLenum(argU32(ctx, argv, 0)), GLint(argI32(ctx, argv, 1)),
                          GLsizei(argI32(ctx, argv, 2)), GLsizei(argI32(ctx, argv, 3)))
  rw_JS_Undefined()

proc jsGlDrawElementsInstanced(ctx: ptr JSContext; thisVal: JSValue;
                               argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if glDrawElementsInstanced != nil:
    glDrawElementsInstanced(GLenum(argU32(ctx, argv, 0)), GLsizei(argI32(ctx, argv, 1)),
                            GLenum(argU32(ctx, argv, 2)),
                            cast[pointer](argI32(ctx, argv, 3)),
                            GLsizei(argI32(ctx, argv, 4)))
  rw_JS_Undefined()

proc jsGlVertexAttribDivisor(ctx: ptr JSContext; thisVal: JSValue;
                             argc: cint; argv: ptr JSValue): JSValue {.cdecl.} =
  if glVertexAttribDivisor != nil:
    glVertexAttribDivisor(GLuint(argU32(ctx, argv, 0)), GLuint(argU32(ctx, argv, 1)))
  rw_JS_Undefined()

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
var c2dBlitVBO:      GLuint = 0
var c2dBlitTextures: seq[C2dBlitTex]
var c2dBlitTexLoc:   GLint  = -1  # cached uniform location — set once at init

proc bindWebGL(state: ptr RWebviewState) =
  ## Create the WebGL context JS object with all methods and constants,
  ## then store as __rw_glContext global.
  let ctx = state.jsCtx
  let global = JS_GetGlobalObject(ctx)
  let glObj = JS_NewObject(ctx)
  # Reset blit texture cache on each page load
  c2dBlitTextures = @[]

  # drawingBufferWidth / drawingBufferHeight
  discard JS_SetPropertyStr(ctx, glObj, "drawingBufferWidth", rw_JS_NewInt32(ctx, state.width))
  discard JS_SetPropertyStr(ctx, glObj, "drawingBufferHeight", rw_JS_NewInt32(ctx, state.height))

  # Install all gl.* native method bindings
  template glFn(jsName: cstring; fn: JSCFunction; nargs: cint) =
    let f = JS_NewCFunction(ctx, fn, jsName, nargs)
    discard JS_SetPropertyStr(ctx, glObj, jsName, f)

  # State
  glFn("viewport",            cast[JSCFunction](jsGlViewport), 4)
  glFn("clearColor",          cast[JSCFunction](jsGlClearColor), 4)
  glFn("clear",               cast[JSCFunction](jsGlClear), 1)
  glFn("enable",              cast[JSCFunction](jsGlEnable), 1)
  glFn("disable",             cast[JSCFunction](jsGlDisable), 1)
  glFn("blendFunc",           cast[JSCFunction](jsGlBlendFunc), 2)
  glFn("blendFuncSeparate",   cast[JSCFunction](jsGlBlendFuncSeparate), 4)
  glFn("blendEquation",       cast[JSCFunction](jsGlBlendEquation), 1)
  glFn("blendEquationSeparate", cast[JSCFunction](jsGlBlendEquationSeparate), 2)
  glFn("blendColor",          cast[JSCFunction](jsGlBlendColor), 4)
  glFn("depthFunc",           cast[JSCFunction](jsGlDepthFunc), 1)
  glFn("depthMask",           cast[JSCFunction](jsGlDepthMask), 1)
  glFn("depthRange",          cast[JSCFunction](jsGlDepthRange), 2)
  glFn("clearDepth",          cast[JSCFunction](jsGlClearDepth), 1)
  glFn("cullFace",            cast[JSCFunction](jsGlCullFace), 1)
  glFn("frontFace",           cast[JSCFunction](jsGlFrontFace), 1)
  glFn("scissor",             cast[JSCFunction](jsGlScissor), 4)
  glFn("lineWidth",           cast[JSCFunction](jsGlLineWidth), 1)
  glFn("colorMask",           cast[JSCFunction](jsGlColorMask), 4)
  glFn("stencilFunc",         cast[JSCFunction](jsGlStencilFunc), 3)
  glFn("stencilFuncSeparate", cast[JSCFunction](jsGlStencilFuncSeparate), 4)
  glFn("stencilOp",           cast[JSCFunction](jsGlStencilOp), 3)
  glFn("stencilOpSeparate",   cast[JSCFunction](jsGlStencilOpSeparate), 4)
  glFn("stencilMask",         cast[JSCFunction](jsGlStencilMask), 1)
  glFn("stencilMaskSeparate", cast[JSCFunction](jsGlStencilMaskSeparate), 2)
  glFn("clearStencil",        cast[JSCFunction](jsGlClearStencil), 1)
  glFn("pixelStorei",         cast[JSCFunction](jsGlPixelStorei), 2)
  glFn("flush",               cast[JSCFunction](jsGlFlush), 0)
  glFn("finish",              cast[JSCFunction](jsGlFinish), 0)
  glFn("getError",            cast[JSCFunction](jsGlGetError), 0)
  glFn("isEnabled",           cast[JSCFunction](jsGlIsEnabled), 1)
  # Shaders & Programs
  glFn("createShader",        cast[JSCFunction](jsGlCreateShader), 1)
  glFn("deleteShader",        cast[JSCFunction](jsGlDeleteShader), 1)
  glFn("shaderSource",        cast[JSCFunction](jsGlShaderSource), 2)
  glFn("compileShader",       cast[JSCFunction](jsGlCompileShader), 1)
  glFn("getShaderParameter",  cast[JSCFunction](jsGlGetShaderParameter), 2)
  glFn("getShaderInfoLog",    cast[JSCFunction](jsGlGetShaderInfoLog), 1)
  glFn("createProgram",       cast[JSCFunction](jsGlCreateProgram), 0)
  glFn("deleteProgram",       cast[JSCFunction](jsGlDeleteProgram), 1)
  glFn("attachShader",        cast[JSCFunction](jsGlAttachShader), 2)
  glFn("detachShader",        cast[JSCFunction](jsGlDetachShader), 2)
  glFn("linkProgram",         cast[JSCFunction](jsGlLinkProgram), 1)
  glFn("getProgramParameter", cast[JSCFunction](jsGlGetProgramParameter), 2)
  glFn("getProgramInfoLog",   cast[JSCFunction](jsGlGetProgramInfoLog), 1)
  glFn("useProgram",          cast[JSCFunction](jsGlUseProgram), 1)
  glFn("validateProgram",     cast[JSCFunction](jsGlValidateProgram), 1)
  # Attributes
  glFn("getAttribLocation",   cast[JSCFunction](jsGlGetAttribLocation), 2)
  glFn("bindAttribLocation",  cast[JSCFunction](jsGlBindAttribLocation), 3)
  glFn("enableVertexAttribArray",  cast[JSCFunction](jsGlEnableVertexAttribArray), 1)
  glFn("disableVertexAttribArray", cast[JSCFunction](jsGlDisableVertexAttribArray), 1)
  glFn("vertexAttribPointer", cast[JSCFunction](jsGlVertexAttribPointer), 6)
  glFn("getActiveAttrib",     cast[JSCFunction](jsGlGetActiveAttrib), 2)
  glFn("getActiveUniform",    cast[JSCFunction](jsGlGetActiveUniform), 2)
  # Uniforms
  glFn("getUniformLocation",  cast[JSCFunction](jsGlGetUniformLocation), 2)
  glFn("uniform1f",           cast[JSCFunction](jsGlUniform1f), 2)
  glFn("uniform2f",           cast[JSCFunction](jsGlUniform2f), 3)
  glFn("uniform3f",           cast[JSCFunction](jsGlUniform3f), 4)
  glFn("uniform4f",           cast[JSCFunction](jsGlUniform4f), 5)
  glFn("uniform1i",           cast[JSCFunction](jsGlUniform1i), 2)
  glFn("uniform2i",           cast[JSCFunction](jsGlUniform2i), 3)
  glFn("uniform3i",           cast[JSCFunction](jsGlUniform3i), 4)
  glFn("uniform4i",           cast[JSCFunction](jsGlUniform4i), 5)
  glFn("uniform1fv",          cast[JSCFunction](jsGlUniform1fv), 2)
  glFn("uniform2fv",          cast[JSCFunction](jsGlUniform2fv), 2)
  glFn("uniform3fv",          cast[JSCFunction](jsGlUniform3fv), 2)
  glFn("uniform4fv",          cast[JSCFunction](jsGlUniform4fv), 2)
  glFn("uniform1iv",          cast[JSCFunction](jsGlUniform1iv), 2)
  glFn("uniform2iv",          cast[JSCFunction](jsGlUniform2iv), 2)
  glFn("uniform3iv",          cast[JSCFunction](jsGlUniform3iv), 2)
  glFn("uniform4iv",          cast[JSCFunction](jsGlUniform4iv), 2)
  glFn("uniformMatrix2fv",    cast[JSCFunction](jsGlUniformMatrix2fv), 3)
  glFn("uniformMatrix3fv",    cast[JSCFunction](jsGlUniformMatrix3fv), 3)
  glFn("uniformMatrix4fv",    cast[JSCFunction](jsGlUniformMatrix4fv), 3)
  # Buffers
  glFn("createBuffer",        cast[JSCFunction](jsGlCreateBuffer), 0)
  glFn("deleteBuffer",        cast[JSCFunction](jsGlDeleteBuffer), 1)
  glFn("bindBuffer",          cast[JSCFunction](jsGlBindBuffer), 2)
  glFn("bufferData",          cast[JSCFunction](jsGlBufferData), 3)
  glFn("bufferSubData",       cast[JSCFunction](jsGlBufferSubData), 3)
  # Textures
  glFn("createTexture",       cast[JSCFunction](jsGlCreateTexture), 0)
  glFn("deleteTexture",       cast[JSCFunction](jsGlDeleteTexture), 1)
  glFn("bindTexture",         cast[JSCFunction](jsGlBindTexture), 2)
  glFn("activeTexture",       cast[JSCFunction](jsGlActiveTexture), 1)
  glFn("texImage2D",          cast[JSCFunction](jsGlTexImage2D), 9)
  glFn("texSubImage2D",       cast[JSCFunction](jsGlTexSubImage2D), 9)
  glFn("texParameteri",       cast[JSCFunction](jsGlTexParameteri), 3)
  glFn("texParameterf",       cast[JSCFunction](jsGlTexParameterf), 3)
  glFn("generateMipmap",      cast[JSCFunction](jsGlGenerateMipmap), 1)
  # Framebuffers
  glFn("createFramebuffer",   cast[JSCFunction](jsGlCreateFramebuffer), 0)
  glFn("deleteFramebuffer",   cast[JSCFunction](jsGlDeleteFramebuffer), 1)
  glFn("bindFramebuffer",     cast[JSCFunction](jsGlBindFramebuffer), 2)
  glFn("framebufferTexture2D", cast[JSCFunction](jsGlFramebufferTexture2D), 5)
  glFn("framebufferRenderbuffer", cast[JSCFunction](jsGlFramebufferRenderbuffer), 4)
  glFn("checkFramebufferStatus", cast[JSCFunction](jsGlCheckFramebufferStatus), 1)
  # Renderbuffers
  glFn("createRenderbuffer",  cast[JSCFunction](jsGlCreateRenderbuffer), 0)
  glFn("deleteRenderbuffer",  cast[JSCFunction](jsGlDeleteRenderbuffer), 1)
  glFn("bindRenderbuffer",    cast[JSCFunction](jsGlBindRenderbuffer), 2)
  glFn("renderbufferStorage", cast[JSCFunction](jsGlRenderbufferStorage), 4)
  # Drawing
  glFn("drawArrays",          cast[JSCFunction](jsGlDrawArrays), 3)
  glFn("drawElements",        cast[JSCFunction](jsGlDrawElements), 4)
  # Reading
  glFn("readPixels",          cast[JSCFunction](jsGlReadPixels), 7)
  # Query
  glFn("getParameter",        cast[JSCFunction](jsGlGetParameter), 1)
  glFn("getExtension",        cast[JSCFunction](jsGlGetExtension), 1)
  glFn("getShaderPrecisionFormat", cast[JSCFunction](jsGlGetShaderPrecisionFormat), 2)
  glFn("isContextLost",       cast[JSCFunction](jsGlIsContextLost), 0)
  # Instanced rendering
  glFn("drawArraysInstanced", cast[JSCFunction](jsGlDrawArraysInstanced), 4)
  glFn("drawElementsInstanced", cast[JSCFunction](jsGlDrawElementsInstanced), 5)
  glFn("vertexAttribDivisor", cast[JSCFunction](jsGlVertexAttribDivisor), 2)

  # Store as global __rw_glContext
  discard JS_SetPropertyStr(ctx, global, "__rw_glContext", glObj)
  rw_JS_FreeValue(ctx, global)

  # Eval the constants JS to set all WebGL enum constants on the context object
  let constRet = JS_Eval(ctx, cstring(glConstantsJS), csize_t(glConstantsJS.len),
                         "<gl-constants>", JS_EVAL_TYPE_GLOBAL)
  discard jsCheck(ctx, constRet, "<gl-constants>")

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
  glBindVertexArray(glDefaultVAO)

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
var ovFont:       ptr TTF_Font = nil
var ovGpuQueried: bool         = false

proc drawNativeOverlay(winW, winH: int) =
  ## Render the F2 status bar (FPS + resolution + GPU) and blit at top-left
  ## of the letterboxed game viewport using a small GL viewport trick.
  if ovFont == nil:
    if ttfInitialized and defaultFontPath != "":
      ovFont = TTF_OpenFont(cstring(defaultFontPath), cfloat(13.0))
  if ovFont == nil: return
  # Fill semi-transparent black background
  const bgA = 180u8
  for i in 0..<OV_W * OV_H:
    ovPixels[i*4]   = 0; ovPixels[i*4+1] = 0
    ovPixels[i*4+2] = 0; ovPixels[i*4+3] = bgA
  # Compose info line matching testmedia.html style
  let fpsCol =
    if c2dFpsDisplay >= 55: SDL_Color(r: 160, g: 255, b: 160, a: 255)
    elif c2dFpsDisplay >= 45: SDL_Color(r: 255, g: 230, b: 80,  a: 255)
    else:                     SDL_Color(r: 255, g: 100, b: 100, a: 255)
  let gpuShort = if c2dGpuName.len > 30: c2dGpuName[0..28] & "\xe2\x80\xa6" else: c2dGpuName
  let line = "FPS:" & $c2dFpsDisplay &
             "  " & $c2dBlitVpW & "x" & $c2dBlitVpH &
             "  [GPU] " & gpuShort
  let rawSurf = TTF_RenderText_Blended(ovFont, cstring(line), 0, fpsCol)
  if rawSurf != nil:
    let rgbaSurf = cast[ptr SDL_Surface](SDL_ConvertSurface(rawSurf, SDL_PIXELFORMAT_RGBA32))
    SDL_DestroySurface(rawSurf)
    if rgbaSurf != nil:
      let tw = min(int(rgbaSurf.w), OV_W - 4)
      let th = min(int(rgbaSurf.h), OV_H)
      let sp = cast[ptr UncheckedArray[uint8]](rgbaSurf.pixels)
      for row in 0..<th:
        let srcRow = cast[ptr UncheckedArray[uint8]](addr sp[row * int(rgbaSurf.pitch)])
        for col in 0..<tw:
          let di = (row * OV_W + col + 4) * 4
          let sa = int(srcRow[col*4+3])
          if sa > 0:
            ovPixels[di]   = srcRow[col*4]
            ovPixels[di+1] = srcRow[col*4+1]
            ovPixels[di+2] = srcRow[col*4+2]
            ovPixels[di+3] = uint8(min(255, int(bgA) + sa))
      SDL_DestroySurface(rgbaSurf)
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
  if canvas2dStates.len == 0: return
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
  glBindFramebuffer(0x8D40.GLenum, 0)      # GL_FRAMEBUFFER → default
  # Clear the full window to black first (paints the letterbox bars)
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
    glDrawArrays(0x0004.GLenum, 0, 6)       # GL_TRIANGLES
  # Draw native debug overlay on top when F2 is toggled
  if c2dShowOverlay:
    drawNativeOverlay(winW, winH)
  glBindVertexArray(glDefaultVAO)


