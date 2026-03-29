/* gl3_loader_win.h — Minimal OpenGL 3.3 function loader for Windows + SDL3.
 *
 * USAGE
 *   1. #define GLSL_VERSION before including clay_renderer_gles3.h (done here).
 *   2. Include THIS file before any header that calls GL3+ functions.
 *   3. After SDL_GL_CreateContext(), call gl3_win_load().
 *
 * Why this exists:
 *   Windows opengl32.dll only exports OpenGL 1.1 functions.  All GL 1.2–4.x
 *   functions (shaders, VBOs, VAOs, instanced rendering, …) must be loaded via
 *   wglGetProcAddress / SDL_GL_GetProcAddress at runtime.
 *   clay_renderer_gles3.h assumes a platform header (<OpenGL/gl3.h> on Apple,
 *   <GLES3/gl3.h> on Emscripten) that statically declares every GL symbol.
 *   This file emulates that by:
 *     a) Including SDL3/SDL_opengl.h  — gives GL1.1 linked symbols + GL types.
 *     b) Including SDL3/SDL_opengl_glext.h — gives PFNGL* typedefs for all ext.
 *     c) Declaring static function pointers for every GL3+ call the renderer uses.
 *     d) #define-ing each gl* name to its corresponding function pointer so the
 *        renderer header sees them as normal function calls.
 */

#pragma once

/* Tell clay_renderer_gles3.h we are managing the OpenGL headers ourselves,
 * and set the GLSL dialect (desktop GL 3.3 core = version 330).           */
#define GLSL_VERSION "#version 330 core"

#include <SDL3/SDL_opengl.h>
#include <SDL3/SDL_opengl_glext.h>
#include <SDL3/SDL.h>

/* GL_R8 / GL_RED / GL_TEXTURE0+ are constants defined in glext.h — verify: */
#ifndef GL_R8
#  define GL_R8  0x8229
#endif
#ifndef GL_RED
#  define GL_RED 0x1903
#endif

/* -------------------------------------------------------------------------
 * Function-pointer declarations
 * ---------------------------------------------------------------------- */

static PFNGLACTIVETEXTUREPROC               fp_ActiveTexture            = NULL;
static PFNGLCREATESHADERPROC                fp_CreateShader             = NULL;
static PFNGLDELETESHADERPROC                fp_DeleteShader             = NULL;
static PFNGLSHADERSOURCEPROC                fp_ShaderSource             = NULL;
static PFNGLCOMPILESHADERPROC               fp_CompileShader            = NULL;
static PFNGLGETSHADERIVPROC                 fp_GetShaderiv              = NULL;
static PFNGLGETSHADERINFOLOGPROC            fp_GetShaderInfoLog         = NULL;
static PFNGLCREATEPROGRAMPROC               fp_CreateProgram            = NULL;
static PFNGLATTACHSHADERPROC                fp_AttachShader             = NULL;
static PFNGLLINKPROGRAMPROC                 fp_LinkProgram              = NULL;
static PFNGLDELETEPROGRAMPROC               fp_DeleteProgram            = NULL;
static PFNGLUSEPROGRAMPROC                  fp_UseProgram               = NULL;
static PFNGLGETUNIFORMLOCATIONPROC          fp_GetUniformLocation       = NULL;
static PFNGLUNIFORM1IPROC                   fp_Uniform1i                = NULL;
static PFNGLUNIFORM2FPROC                   fp_Uniform2f                = NULL;
static PFNGLGENVERTEXARRAYSPROC             fp_GenVertexArrays          = NULL;
static PFNGLBINDVERTEXARRAYPROC             fp_BindVertexArray          = NULL;
static PFNGLDELETEVERTEXARRAYSPROC          fp_DeleteVertexArrays       = NULL;
static PFNGLGENBUFFERSPROC                  fp_GenBuffers               = NULL;
static PFNGLBINDBUFFERPROC                  fp_BindBuffer               = NULL;
static PFNGLBUFFERDATAPROC                  fp_BufferData               = NULL;
static PFNGLBUFFERSUBDATAPROC               fp_BufferSubData            = NULL;
static PFNGLDELETEBUFFERSPROC               fp_DeleteBuffers            = NULL;
static PFNGLENABLEVERTEXATTRIBARRAYPROC     fp_EnableVertexAttribArray  = NULL;
static PFNGLVERTEXATTRIBPOINTERPROC         fp_VertexAttribPointer      = NULL;
static PFNGLVERTEXATTRIBDIVISORPROC         fp_VertexAttribDivisor      = NULL;
static PFNGLDRAWARRAYSINSTANCEDPROC         fp_DrawArraysInstanced      = NULL;
static PFNGLGENERATEMIPMAPPROC               fp_GenerateMipmap           = NULL;

/* -------------------------------------------------------------------------
 * Redirect gl* names used by the renderer to our loaded function pointers.
 * Only GL 1.2+ functions need this — GL 1.1 calls (glClear, glViewport,
 * glGenTextures, glBindTexture, glTexImage2D, …) are linked directly.
 * ---------------------------------------------------------------------- */

#define glActiveTexture             fp_ActiveTexture
#define glCreateShader              fp_CreateShader
#define glDeleteShader              fp_DeleteShader
#define glShaderSource              fp_ShaderSource
#define glCompileShader             fp_CompileShader
#define glGetShaderiv               fp_GetShaderiv
#define glGetShaderInfoLog          fp_GetShaderInfoLog
#define glCreateProgram             fp_CreateProgram
#define glAttachShader              fp_AttachShader
#define glLinkProgram               fp_LinkProgram
#define glDeleteProgram             fp_DeleteProgram
#define glUseProgram                fp_UseProgram
#define glGetUniformLocation        fp_GetUniformLocation
#define glUniform1i                 fp_Uniform1i
#define glUniform2f                 fp_Uniform2f
#define glGenVertexArrays           fp_GenVertexArrays
#define glBindVertexArray           fp_BindVertexArray
#define glDeleteVertexArrays        fp_DeleteVertexArrays
#define glGenBuffers                fp_GenBuffers
#define glBindBuffer                fp_BindBuffer
#define glBufferData                fp_BufferData
#define glBufferSubData             fp_BufferSubData
#define glDeleteBuffers             fp_DeleteBuffers
#define glEnableVertexAttribArray   fp_EnableVertexAttribArray
#define glVertexAttribPointer       fp_VertexAttribPointer
#define glVertexAttribDivisor       fp_VertexAttribDivisor
#define glDrawArraysInstanced       fp_DrawArraysInstanced
#define glGenerateMipmap            fp_GenerateMipmap

/* -------------------------------------------------------------------------
 * Loader — must be called once after SDL_GL_CreateContext().
 * ---------------------------------------------------------------------- */

#define GL3_LOAD(fp, name) \
    fp = (void*)SDL_GL_GetProcAddress(name); \
    if (!(fp)) SDL_Log("[GL3] WARNING: failed to load %s", name)

static void gl3_win_load(void) {
    GL3_LOAD(fp_ActiveTexture,           "glActiveTexture");
    GL3_LOAD(fp_CreateShader,            "glCreateShader");
    GL3_LOAD(fp_DeleteShader,            "glDeleteShader");
    GL3_LOAD(fp_ShaderSource,            "glShaderSource");
    GL3_LOAD(fp_CompileShader,           "glCompileShader");
    GL3_LOAD(fp_GetShaderiv,             "glGetShaderiv");
    GL3_LOAD(fp_GetShaderInfoLog,        "glGetShaderInfoLog");
    GL3_LOAD(fp_CreateProgram,           "glCreateProgram");
    GL3_LOAD(fp_AttachShader,            "glAttachShader");
    GL3_LOAD(fp_LinkProgram,             "glLinkProgram");
    GL3_LOAD(fp_DeleteProgram,           "glDeleteProgram");
    GL3_LOAD(fp_UseProgram,              "glUseProgram");
    GL3_LOAD(fp_GetUniformLocation,      "glGetUniformLocation");
    GL3_LOAD(fp_Uniform1i,               "glUniform1i");
    GL3_LOAD(fp_Uniform2f,               "glUniform2f");
    GL3_LOAD(fp_GenVertexArrays,         "glGenVertexArrays");
    GL3_LOAD(fp_BindVertexArray,         "glBindVertexArray");
    GL3_LOAD(fp_DeleteVertexArrays,      "glDeleteVertexArrays");
    GL3_LOAD(fp_GenBuffers,              "glGenBuffers");
    GL3_LOAD(fp_BindBuffer,              "glBindBuffer");
    GL3_LOAD(fp_BufferData,              "glBufferData");
    GL3_LOAD(fp_BufferSubData,           "glBufferSubData");
    GL3_LOAD(fp_DeleteBuffers,           "glDeleteBuffers");
    GL3_LOAD(fp_EnableVertexAttribArray, "glEnableVertexAttribArray");
    GL3_LOAD(fp_VertexAttribPointer,     "glVertexAttribPointer");
    GL3_LOAD(fp_VertexAttribDivisor,     "glVertexAttribDivisor");
    GL3_LOAD(fp_DrawArraysInstanced,     "glDrawArraysInstanced");    GL3_LOAD(fp_GenerateMipmap,           "glGenerateMipmap");}

#undef GL3_LOAD
