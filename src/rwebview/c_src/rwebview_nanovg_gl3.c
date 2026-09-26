/*
 * rwebview_nanovg_gl3.c
 *
 * NanoVG OpenGL 3.3 Core backend for rwebview.
 * Loads GL3 functions via SDL_GL_GetProcAddress and compiles nanovg_gl.c.
 *
 * Provides:
 *   rw_nvg_gl3_init()   — must be called after GL context creation
 *   nvgCreateGL3()      — standard nanovg GL3 context creation
 *   nvgDeleteGL3()      — destroy nanovg GL3 context
 */

/* We need GL types but not actual SDL functions.
 * Use a minimal set of typedefs from the OpenGL spec. */
#include <stddef.h>
#include <stdint.h>

#ifndef APIENTRY
#ifdef _WIN32
#define APIENTRY __stdcall
#else
#define APIENTRY
#endif
#endif

#ifndef APIENTRYP
#define APIENTRYP APIENTRY *
#endif

/* Base GL types (matching OpenGL spec) */
typedef unsigned int   GLenum;
typedef unsigned char  GLboolean;
typedef unsigned int   GLbitfield;
typedef void           GLvoid;
typedef signed char    GLbyte;
typedef short          GLshort;
typedef int            GLint;
typedef unsigned char  GLubyte;
typedef unsigned short GLushort;
typedef unsigned int   GLuint;
typedef int            GLsizei;
typedef float          GLfloat;
typedef float          GLclampf;
typedef double         GLdouble;
typedef double         GLclampd;
typedef char           GLchar;

/* ====================================================================== */
/* GL3 types not in base gl.h / SDL_opengl.h (GL 1.1 only on Windows)     */
/* ====================================================================== */

#ifndef GL_VERSION_2_0
typedef char GLchar;
#endif

/* ====================================================================== */
/* GL constants used by nanovg_gl.c                                        */
/* ====================================================================== */

/* Boolean */
#define GL_FALSE                          0
#define GL_TRUE                           1

/* Errors */
#define GL_NO_ERROR                       0
#define GL_INVALID_ENUM                   0x0500

/* Data types */
#define GL_UNSIGNED_BYTE                  0x1401
#define GL_FLOAT                          0x1406

/* Primitives */
#define GL_TRIANGLES                      0x0004
#define GL_TRIANGLE_STRIP                 0x0005
#define GL_TRIANGLE_FAN                   0x0006

/* Depth / Stencil */
#define GL_DEPTH_TEST                     0x0B71
#define GL_STENCIL_TEST                   0x0B90
#define GL_SCISSOR_TEST                   0x0C11
#define GL_NEVER                          0x0200
#define GL_LESS                           0x0201
#define GL_EQUAL                          0x0202
#define GL_LEQUAL                         0x0203
#define GL_GREATER                        0x0204
#define GL_NOTEQUAL                       0x0205
#define GL_GEQUAL                         0x0206
#define GL_ALWAYS                         0x0207
#define GL_KEEP                           0x1E00
#define GL_INCR                           0x1E02
#define GL_ZERO                           0

/* Blending */
#define GL_BLEND                          0x0BE2
#define GL_ONE                            1
#define GL_SRC_COLOR                      0x0300
#define GL_ONE_MINUS_SRC_COLOR            0x0301
#define GL_SRC_ALPHA                      0x0302
#define GL_ONE_MINUS_SRC_ALPHA            0x0303
#define GL_DST_ALPHA                      0x0304
#define GL_ONE_MINUS_DST_ALPHA            0x0305
#define GL_DST_COLOR                      0x0306
#define GL_ONE_MINUS_DST_COLOR            0x0307
#define GL_SRC_ALPHA_SATURATE             0x0308

/* Face culling */
#define GL_CULL_FACE                      0x0B44
#define GL_CW                             0x0900
#define GL_CCW                            0x0901
#define GL_FRONT                          0x0404
#define GL_BACK                           0x0405

/* Texture */
#define GL_TEXTURE_2D                     0x0DE1
#define GL_TEXTURE_WRAP_S                 0x2802
#define GL_TEXTURE_WRAP_T                 0x2803
#define GL_TEXTURE_MAG_FILTER             0x2800
#define GL_TEXTURE_MIN_FILTER             0x2801
#define GL_NEAREST                        0x2600
#define GL_LINEAR                         0x2601
#define GL_NEAREST_MIPMAP_NEAREST         0x2700
#define GL_LINEAR_MIPMAP_LINEAR           0x2703
#define GL_REPEAT                         0x2901
#define GL_RGBA                           0x1908
#define GL_LUMINANCE                      0x1909

/* Pixel store */
#define GL_UNPACK_ALIGNMENT               0x0CF5
#define GL_UNPACK_ROW_LENGTH              0x0CF2
#define GL_UNPACK_SKIP_ROWS               0x0CF3
#define GL_UNPACK_SKIP_PIXELS             0x0CF4

/* GL_EXT / GL_ARB */
#define GL_EXTENSIONS                     0x1F03

#ifndef GL_FRAGMENT_SHADER
#define GL_FRAGMENT_SHADER                0x8B30
#define GL_VERTEX_SHADER                  0x8B31
#define GL_COMPILE_STATUS                 0x8B81
#define GL_LINK_STATUS                    0x8B82
#define GL_INFO_LOG_LENGTH                0x8B84
#define GL_CURRENT_PROGRAM                0x8B8D
#define GL_ACTIVE_TEXTURE_ARB             0x84E0
#define GL_TEXTURE0                       0x84C0
#define GL_ARRAY_BUFFER                   0x8892
#define GL_STREAM_DRAW                    0x88E0
#define GL_CLAMP_TO_EDGE                  0x812F
#define GL_GENERATE_MIPMAP                0x8191
#define GL_INCR_WRAP                      0x8507
#define GL_DECR_WRAP                      0x8508
#define GL_UNIFORM_BUFFER                 0x8A11
#define GL_INVALID_INDEX                  0xFFFFFFFFu
#define GL_FUNC_ADD                       0x8006
#define GL_STENCIL_BUFFER_BIT             0x00000400
#endif

/* GL 3.0+ formats */
#ifndef GL_R8
#define GL_R8                             0x8229
#endif
#ifndef GL_RED
#define GL_RED                            0x1903
#endif

/* UBO alignment query */
#ifndef GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT
#define GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT 0x8A34
#endif

/* ====================================================================== */
/* GL function pointer declarations (loaded via SDL_GL_GetProcAddress)     */
/* ====================================================================== */

/* We declare these as static function pointers and define macros so that
 * nanovg_gl.c can call them by their standard GL names. We also guard
 * against re-declaration of GL 1.1 functions already declared in gl.h. */

/* GL 1.1 functions — available from opengl32.dll but load uniformly */
#define DECLARE_GL_FUNC(ret, name, params) \
    static ret (APIENTRY *rw_##name) params = NULL;

/* GL 1.1 */
DECLARE_GL_FUNC(void,     glBindTexture,       (GLenum target, GLuint texture))
DECLARE_GL_FUNC(void,     glBlendFunc,         (GLenum sfactor, GLenum dfactor))
DECLARE_GL_FUNC(void,     glColorMask,         (GLboolean r, GLboolean g, GLboolean b, GLboolean a))
DECLARE_GL_FUNC(void,     glCullFace,          (GLenum mode))
DECLARE_GL_FUNC(void,     glDeleteTextures,    (GLsizei n, const GLuint *textures))
DECLARE_GL_FUNC(void,     glDisable,           (GLenum cap))
DECLARE_GL_FUNC(void,     glDrawArrays,        (GLenum mode, GLint first, GLsizei count))
DECLARE_GL_FUNC(void,     glEnable,            (GLenum cap))
DECLARE_GL_FUNC(void,     glFinish,            (void))
DECLARE_GL_FUNC(void,     glFrontFace,         (GLenum mode))
DECLARE_GL_FUNC(void,     glGenTextures,       (GLsizei n, GLuint *textures))
DECLARE_GL_FUNC(GLenum,   glGetError,          (void))
DECLARE_GL_FUNC(void,     glGetIntegerv,       (GLenum pname, GLint *data))
DECLARE_GL_FUNC(void,     glPixelStorei,       (GLenum pname, GLint param))
DECLARE_GL_FUNC(void,     glStencilFunc,       (GLenum func, GLint ref, GLuint mask))
DECLARE_GL_FUNC(void,     glStencilMask,       (GLuint mask))
DECLARE_GL_FUNC(void,     glStencilOp,         (GLenum fail, GLenum zfail, GLenum zpass))
DECLARE_GL_FUNC(void,     glTexImage2D,        (GLenum target, GLint level, GLint internalformat, GLsizei width, GLsizei height, GLint border, GLenum format, GLenum type, const void *pixels))
DECLARE_GL_FUNC(void,     glTexParameteri,     (GLenum target, GLenum pname, GLint param))
DECLARE_GL_FUNC(void,     glTexSubImage2D,     (GLenum target, GLint level, GLint xoffset, GLint yoffset, GLsizei width, GLsizei height, GLenum format, GLenum type, const void *pixels))

/* GL 1.3+ */
DECLARE_GL_FUNC(void,     glActiveTexture,     (GLenum texture))

/* GL 1.4+ */
DECLARE_GL_FUNC(void,     glBlendFuncSeparate, (GLenum sfactorRGB, GLenum dfactorRGB, GLenum sfactorAlpha, GLenum dfactorAlpha))

/* GL 2.0 */
DECLARE_GL_FUNC(void,     glAttachShader,      (GLuint program, GLuint shader))
DECLARE_GL_FUNC(void,     glBindAttribLocation,(GLuint program, GLuint index, const GLchar *name))
DECLARE_GL_FUNC(void,     glCompileShader,     (GLuint shader))
DECLARE_GL_FUNC(GLuint,   glCreateProgram,     (void))
DECLARE_GL_FUNC(GLuint,   glCreateShader,      (GLenum type))
DECLARE_GL_FUNC(void,     glDeleteProgram,     (GLuint program))
DECLARE_GL_FUNC(void,     glDeleteShader,      (GLuint shader))
DECLARE_GL_FUNC(void,     glDisableVertexAttribArray, (GLuint index))
DECLARE_GL_FUNC(void,     glEnableVertexAttribArray,  (GLuint index))
DECLARE_GL_FUNC(void,     glGetProgramInfoLog, (GLuint program, GLsizei bufSize, GLsizei *length, GLchar *infoLog))
DECLARE_GL_FUNC(void,     glGetProgramiv,      (GLuint program, GLenum pname, GLint *params))
DECLARE_GL_FUNC(void,     glGetShaderInfoLog,  (GLuint shader, GLsizei bufSize, GLsizei *length, GLchar *infoLog))
DECLARE_GL_FUNC(void,     glGetShaderiv,       (GLuint shader, GLenum pname, GLint *params))
DECLARE_GL_FUNC(GLint,    glGetUniformLocation,(GLuint program, const GLchar *name))
DECLARE_GL_FUNC(void,     glLinkProgram,       (GLuint program))
DECLARE_GL_FUNC(void,     glShaderSource,      (GLuint shader, GLsizei count, const GLchar *const*string, const GLint *length))
DECLARE_GL_FUNC(void,     glStencilOpSeparate, (GLenum face, GLenum sfail, GLenum dpfail, GLenum dppass))
DECLARE_GL_FUNC(void,     glUniform1i,         (GLint location, GLint v0))
DECLARE_GL_FUNC(void,     glUniform2fv,        (GLint location, GLsizei count, const GLfloat *value))
DECLARE_GL_FUNC(void,     glUniform4fv,        (GLint location, GLsizei count, const GLfloat *value))
DECLARE_GL_FUNC(void,     glUseProgram,        (GLuint program))
DECLARE_GL_FUNC(void,     glVertexAttribPointer,(GLuint index, GLint size, GLenum type, GLboolean normalized, GLsizei stride, const void *pointer))

/* GL 1.5 / ARB_vertex_buffer_object */
DECLARE_GL_FUNC(void,     glGenBuffers,        (GLsizei n, GLuint *buffers))
DECLARE_GL_FUNC(void,     glDeleteBuffers,     (GLsizei n, const GLuint *buffers))
DECLARE_GL_FUNC(void,     glBindBuffer,        (GLenum target, GLuint buffer))
DECLARE_GL_FUNC(void,     glBufferData,        (GLenum target, ptrdiff_t size, const void *data, GLenum usage))

/* GL 3.0+ */
DECLARE_GL_FUNC(void,     glGenVertexArrays,   (GLsizei n, GLuint *arrays))
DECLARE_GL_FUNC(void,     glDeleteVertexArrays,(GLsizei n, const GLuint *arrays))
DECLARE_GL_FUNC(void,     glBindVertexArray,   (GLuint array))
DECLARE_GL_FUNC(void,     glGenerateMipmap,    (GLenum target))

/* GL 3.1 UBO */
DECLARE_GL_FUNC(GLuint,   glGetUniformBlockIndex,  (GLuint program, const GLchar *uniformBlockName))
DECLARE_GL_FUNC(void,     glUniformBlockBinding,   (GLuint program, GLuint uniformBlockIndex, GLuint uniformBlockBinding))
DECLARE_GL_FUNC(void,     glBindBufferRange,       (GLenum target, GLuint index, GLuint buffer, ptrdiff_t offset, ptrdiff_t size))

/* ====================================================================== */
/* GL name redirection: nanovg_gl.c calls glFoo() → rw_glFoo()           */
/* ====================================================================== */

#define glBindTexture       rw_glBindTexture
#define glBlendFunc         rw_glBlendFunc
#define glColorMask         rw_glColorMask
#define glCullFace          rw_glCullFace
#define glDeleteTextures    rw_glDeleteTextures
#define glDisable           rw_glDisable
#define glDrawArrays        rw_glDrawArrays
#define glEnable            rw_glEnable
#define glFinish            rw_glFinish
#define glFrontFace         rw_glFrontFace
#define glGenTextures       rw_glGenTextures
#define glGetError          rw_glGetError
#define glGetIntegerv       rw_glGetIntegerv
#define glPixelStorei       rw_glPixelStorei
#define glStencilFunc       rw_glStencilFunc
#define glStencilMask       rw_glStencilMask
#define glStencilOp         rw_glStencilOp
#define glTexImage2D        rw_glTexImage2D
#define glTexParameteri     rw_glTexParameteri
#define glTexSubImage2D     rw_glTexSubImage2D
#define glActiveTexture     rw_glActiveTexture
#define glBlendFuncSeparate rw_glBlendFuncSeparate
#define glAttachShader      rw_glAttachShader
#define glBindAttribLocation rw_glBindAttribLocation
#define glCompileShader     rw_glCompileShader
#define glCreateProgram     rw_glCreateProgram
#define glCreateShader      rw_glCreateShader
#define glDeleteProgram     rw_glDeleteProgram
#define glDeleteShader      rw_glDeleteShader
#define glDisableVertexAttribArray rw_glDisableVertexAttribArray
#define glEnableVertexAttribArray  rw_glEnableVertexAttribArray
#define glGetProgramInfoLog rw_glGetProgramInfoLog
#define glGetProgramiv      rw_glGetProgramiv
#define glGetShaderInfoLog  rw_glGetShaderInfoLog
#define glGetShaderiv       rw_glGetShaderiv
#define glGetUniformLocation rw_glGetUniformLocation
#define glLinkProgram       rw_glLinkProgram
#define glShaderSource      rw_glShaderSource
#define glStencilOpSeparate rw_glStencilOpSeparate
#define glUniform1i         rw_glUniform1i
#define glUniform2fv        rw_glUniform2fv
#define glUniform4fv        rw_glUniform4fv
#define glUseProgram        rw_glUseProgram
#define glVertexAttribPointer rw_glVertexAttribPointer
#define glGenBuffers        rw_glGenBuffers
#define glDeleteBuffers     rw_glDeleteBuffers
#define glBindBuffer        rw_glBindBuffer
#define glBufferData        rw_glBufferData
#define glGenVertexArrays   rw_glGenVertexArrays
#define glDeleteVertexArrays rw_glDeleteVertexArrays
#define glBindVertexArray   rw_glBindVertexArray
#define glGenerateMipmap    rw_glGenerateMipmap
#define glGetUniformBlockIndex  rw_glGetUniformBlockIndex
#define glUniformBlockBinding   rw_glUniformBlockBinding
#define glBindBufferRange       rw_glBindBufferRange

/* ====================================================================== */
/* Prevent nanovg_gl.c from including <GL/gl.h> (we already have types)   */
/* ====================================================================== */

/*  Suppress the real <GL/gl.h> include inside nanovg_gl.c.
 *  SDL_opengl.h already provides all GL 1.1 types. */
#ifndef __gl_h_
#define __gl_h_
#endif

/* Suppress the android.h include */
#define ANDROID_H_F380EB38

/* ====================================================================== */
/* Compile nanovg GL3 backend                                              */
/* ====================================================================== */

#define NANOVG_GL3

/* The nanovg_gl.c includes nanovg_gl.h which includes nanovg.h.
 * Point it to the c_src copies. */
#include "../libs/nanovg/src/nanovg_gl.c"

/* ====================================================================== */
/* GL function loader — must be called after SDL_GL_CreateContext          */
/* Accepts a getProcAddr function pointer to avoid linking SDL3 statically */
/* ====================================================================== */

typedef void *(*RwGLGetProcAddr)(const char *name);

static RwGLGetProcAddr rw_gl_getproc = NULL;

#define LOAD(name) rw_##name = (typeof(rw_##name)) rw_gl_getproc(#name)

int rw_nvg_gl3_init(RwGLGetProcAddr getProcAddr)
{
    if (!getProcAddr) return 0;
    rw_gl_getproc = getProcAddr;

    /* GL 1.1 */
    LOAD(glBindTexture); LOAD(glBlendFunc); LOAD(glColorMask); LOAD(glCullFace);
    LOAD(glDeleteTextures); LOAD(glDisable); LOAD(glDrawArrays); LOAD(glEnable);
    LOAD(glFinish); LOAD(glFrontFace); LOAD(glGenTextures); LOAD(glGetError);
    LOAD(glGetIntegerv); LOAD(glPixelStorei); LOAD(glStencilFunc);
    LOAD(glStencilMask); LOAD(glStencilOp); LOAD(glTexImage2D);
    LOAD(glTexParameteri); LOAD(glTexSubImage2D);
    /* GL 1.3+ */
    LOAD(glActiveTexture);
    /* GL 1.4+ */
    LOAD(glBlendFuncSeparate);
    /* GL 2.0 */
    LOAD(glAttachShader); LOAD(glBindAttribLocation); LOAD(glCompileShader);
    LOAD(glCreateProgram); LOAD(glCreateShader); LOAD(glDeleteProgram);
    LOAD(glDeleteShader); LOAD(glDisableVertexAttribArray);
    LOAD(glEnableVertexAttribArray); LOAD(glGetProgramInfoLog);
    LOAD(glGetProgramiv); LOAD(glGetShaderInfoLog); LOAD(glGetShaderiv);
    LOAD(glGetUniformLocation); LOAD(glLinkProgram); LOAD(glShaderSource);
    LOAD(glStencilOpSeparate); LOAD(glUniform1i); LOAD(glUniform2fv);
    LOAD(glUniform4fv); LOAD(glUseProgram); LOAD(glVertexAttribPointer);
    /* GL 1.5 */
    LOAD(glGenBuffers); LOAD(glDeleteBuffers); LOAD(glBindBuffer); LOAD(glBufferData);
    /* GL 3.0+ */
    LOAD(glGenVertexArrays); LOAD(glDeleteVertexArrays); LOAD(glBindVertexArray);
    LOAD(glGenerateMipmap);
    /* GL 3.1 UBO */
    LOAD(glGetUniformBlockIndex); LOAD(glUniformBlockBinding); LOAD(glBindBufferRange);

    /* Verify critical functions loaded */
    if (!rw_glCreateShader || !rw_glCreateProgram || !rw_glGenVertexArrays) {
        return 0;  /* failure */
    }
    return 1;  /* success */
}

#undef LOAD
