/* nvg_gl3_loader_win.h
 *
 * Minimal OpenGL 3.x function loader for nanovg on Windows + SDL3.
 *
 * USAGE
 *   1. #include this file BEFORE any nanovg header or source.
 *   2. After SDL_GL_CreateContext(), call nvg_gl3_load().
 *
 * Why this exists:
 *   Windows opengl32.dll only exports OpenGL 1.1 functions. All GL 2.0–3.x
 *   functions (shaders, VBOs, VAOs, UBOs, …) must be loaded dynamically via
 *   SDL_GL_GetProcAddress. This header provides static function pointers and
 *   #define redirects so that nanovg_gl.c finds all gl* names at compile time
 *   without requiring GLEW.
 *
 * Only the functions actually called by nanovg_gl.c are included.
 */

#pragma once

/* SDL3 OpenGL headers: GL types, GL 1.1 declarations, PFNGL* typedefs */
#include <SDL3/SDL_opengl.h>
#include <SDL3/SDL_opengl_glext.h>
#include <SDL3/SDL.h>

/* -------------------------------------------------------------------------
 * Function-pointer declarations (GL 1.2 and above — not in opengl32.dll)
 * ---------------------------------------------------------------------- */

static PFNGLACTIVETEXTUREPROC             nvgl_ActiveTexture           = NULL;
static PFNGLBLENDFUNCSEPARATEPROC         nvgl_BlendFuncSeparate       = NULL;

/* GL 2.0 — shaders */
static PFNGLCREATESHADERPROC              nvgl_CreateShader            = NULL;
static PFNGLDELETESHADERPROC              nvgl_DeleteShader            = NULL;
static PFNGLSHADERSOURCEPROC              nvgl_ShaderSource            = NULL;
static PFNGLCOMPILESHADERPROC             nvgl_CompileShader           = NULL;
static PFNGLGETSHADERIVPROC               nvgl_GetShaderiv             = NULL;
static PFNGLGETSHADERINFOLOGPROC          nvgl_GetShaderInfoLog        = NULL;
static PFNGLCREATEPROGRAMPROC             nvgl_CreateProgram           = NULL;
static PFNGLDELETEPROGRAMPROC             nvgl_DeleteProgram           = NULL;
static PFNGLATTACHSHADERPROC              nvgl_AttachShader            = NULL;
static PFNGLLINKPROGRAMPROC               nvgl_LinkProgram             = NULL;
static PFNGLUSEPROGRAMPROC                nvgl_UseProgram              = NULL;
static PFNGLGETPROGRAMIVPROC              nvgl_GetProgramiv            = NULL;
static PFNGLGETPROGRAMINFOLOGPROC         nvgl_GetProgramInfoLog       = NULL;
static PFNGLGETUNIFORMLOCATIONPROC        nvgl_GetUniformLocation      = NULL;
static PFNGLUNIFORM1IPROC                 nvgl_Uniform1i               = NULL;
static PFNGLUNIFORM2FVPROC                nvgl_Uniform2fv              = NULL;
static PFNGLUNIFORM4FVPROC                nvgl_Uniform4fv              = NULL;
static PFNGLBINDATTRIBLOCATIONPROC        nvgl_BindAttribLocation      = NULL;
static PFNGLENABLEVERTEXATTRIBARRAYPROC   nvgl_EnableVertexAttribArray  = NULL;
static PFNGLDISABLEVERTEXATTRIBARRAYPROC  nvgl_DisableVertexAttribArray = NULL;
static PFNGLVERTEXATTRIBPOINTERPROC       nvgl_VertexAttribPointer     = NULL;
static PFNGLSTENCILOPSEPARATEPROC         nvgl_StencilOpSeparate       = NULL;

/* GL 2.1 — VBOs */
static PFNGLGENBUFFERSPROC                nvgl_GenBuffers              = NULL;
static PFNGLDELETEBUFFERSPROC             nvgl_DeleteBuffers           = NULL;
static PFNGLBINDBUFFERPROC                nvgl_BindBuffer              = NULL;
static PFNGLBUFFERDATAPROC                nvgl_BufferData              = NULL;

/* GL 3.0 — VAOs, mipmaps */
static PFNGLGENVERTEXARRAYSPROC           nvgl_GenVertexArrays         = NULL;
static PFNGLDELETEVERTEXARRAYSPROC        nvgl_DeleteVertexArrays      = NULL;
static PFNGLBINDVERTEXARRAYPROC           nvgl_BindVertexArray         = NULL;
static PFNGLGENERATEMIPMAPPROC            nvgl_GenerateMipmap          = NULL;

/* GL 3.1 — UBOs */
static PFNGLGETUNIFORMBLOCKINDEXPROC      nvgl_GetUniformBlockIndex    = NULL;
static PFNGLUNIFORMBLOCKBINDINGPROC       nvgl_UniformBlockBinding     = NULL;
static PFNGLBINDBUFFERRANGEPROC           nvgl_BindBufferRange         = NULL;

/* GL 1.5 — query objects (used by perf.c GPU timer, always disabled at runtime) */
static PFNGLBEGINQUERYPROC                nvgl_BeginQuery              = NULL;
static PFNGLENDQUERYPROC                  nvgl_EndQuery                = NULL;
static PFNGLGETQUERYOBJECTIVPROC          nvgl_GetQueryObjectiv        = NULL;

/* -------------------------------------------------------------------------
 * Macro redirects — all nanovg calls transparently use the pointers above.
 * GL 1.1 functions (glEnable, glBindTexture, glTexImage2D, etc.) are left
 * unredirected and resolved by opengl32.dll at link time.
 * ---------------------------------------------------------------------- */

#define glActiveTexture            nvgl_ActiveTexture
#define glBlendFuncSeparate        nvgl_BlendFuncSeparate

#define glCreateShader             nvgl_CreateShader
#define glDeleteShader             nvgl_DeleteShader
#define glShaderSource             nvgl_ShaderSource
#define glCompileShader            nvgl_CompileShader
#define glGetShaderiv              nvgl_GetShaderiv
#define glGetShaderInfoLog         nvgl_GetShaderInfoLog
#define glCreateProgram            nvgl_CreateProgram
#define glDeleteProgram            nvgl_DeleteProgram
#define glAttachShader             nvgl_AttachShader
#define glLinkProgram              nvgl_LinkProgram
#define glUseProgram               nvgl_UseProgram
#define glGetProgramiv             nvgl_GetProgramiv
#define glGetProgramInfoLog        nvgl_GetProgramInfoLog
#define glGetUniformLocation       nvgl_GetUniformLocation
#define glUniform1i                nvgl_Uniform1i
#define glUniform2fv               nvgl_Uniform2fv
#define glUniform4fv               nvgl_Uniform4fv
#define glBindAttribLocation       nvgl_BindAttribLocation
#define glEnableVertexAttribArray  nvgl_EnableVertexAttribArray
#define glDisableVertexAttribArray nvgl_DisableVertexAttribArray
#define glVertexAttribPointer      nvgl_VertexAttribPointer
#define glStencilOpSeparate        nvgl_StencilOpSeparate

#define glGenBuffers               nvgl_GenBuffers
#define glDeleteBuffers            nvgl_DeleteBuffers
#define glBindBuffer               nvgl_BindBuffer
#define glBufferData               nvgl_BufferData

#define glGenVertexArrays          nvgl_GenVertexArrays
#define glDeleteVertexArrays       nvgl_DeleteVertexArrays
#define glBindVertexArray          nvgl_BindVertexArray
#define glGenerateMipmap           nvgl_GenerateMipmap

#define glGetUniformBlockIndex     nvgl_GetUniformBlockIndex
#define glUniformBlockBinding      nvgl_UniformBlockBinding
#define glBindBufferRange          nvgl_BindBufferRange

/* GL 1.5 query objects */
#define glBeginQuery               nvgl_BeginQuery
#define glEndQuery                 nvgl_EndQuery
#define glGetQueryObjectiv         nvgl_GetQueryObjectiv

/* -------------------------------------------------------------------------
 * Loader — call once after SDL_GL_CreateContext()
 * ---------------------------------------------------------------------- */

#define NVG_GL3_LOAD(name, type) \
    nvgl_##name = (type)SDL_GL_GetProcAddress("gl" #name); \
    if (!nvgl_##name) SDL_Log("nvg_gl3_load: missing gl" #name)

static inline void nvg_gl3_load(void)
{
    NVG_GL3_LOAD(ActiveTexture,            PFNGLACTIVETEXTUREPROC);
    NVG_GL3_LOAD(BlendFuncSeparate,        PFNGLBLENDFUNCSEPARATEPROC);

    NVG_GL3_LOAD(CreateShader,             PFNGLCREATESHADERPROC);
    NVG_GL3_LOAD(DeleteShader,             PFNGLDELETESHADERPROC);
    NVG_GL3_LOAD(ShaderSource,             PFNGLSHADERSOURCEPROC);
    NVG_GL3_LOAD(CompileShader,            PFNGLCOMPILESHADERPROC);
    NVG_GL3_LOAD(GetShaderiv,              PFNGLGETSHADERIVPROC);
    NVG_GL3_LOAD(GetShaderInfoLog,         PFNGLGETSHADERINFOLOGPROC);
    NVG_GL3_LOAD(CreateProgram,            PFNGLCREATEPROGRAMPROC);
    NVG_GL3_LOAD(DeleteProgram,            PFNGLDELETEPROGRAMPROC);
    NVG_GL3_LOAD(AttachShader,             PFNGLATTACHSHADERPROC);
    NVG_GL3_LOAD(LinkProgram,              PFNGLLINKPROGRAMPROC);
    NVG_GL3_LOAD(UseProgram,               PFNGLUSEPROGRAMPROC);
    NVG_GL3_LOAD(GetProgramiv,             PFNGLGETPROGRAMIVPROC);
    NVG_GL3_LOAD(GetProgramInfoLog,        PFNGLGETPROGRAMINFOLOGPROC);
    NVG_GL3_LOAD(GetUniformLocation,       PFNGLGETUNIFORMLOCATIONPROC);
    NVG_GL3_LOAD(Uniform1i,                PFNGLUNIFORM1IPROC);
    NVG_GL3_LOAD(Uniform2fv,               PFNGLUNIFORM2FVPROC);
    NVG_GL3_LOAD(Uniform4fv,               PFNGLUNIFORM4FVPROC);
    NVG_GL3_LOAD(BindAttribLocation,       PFNGLBINDATTRIBLOCATIONPROC);
    NVG_GL3_LOAD(EnableVertexAttribArray,  PFNGLENABLEVERTEXATTRIBARRAYPROC);
    NVG_GL3_LOAD(DisableVertexAttribArray, PFNGLDISABLEVERTEXATTRIBARRAYPROC);
    NVG_GL3_LOAD(VertexAttribPointer,      PFNGLVERTEXATTRIBPOINTERPROC);
    NVG_GL3_LOAD(StencilOpSeparate,        PFNGLSTENCILOPSEPARATEPROC);

    NVG_GL3_LOAD(GenBuffers,               PFNGLGENBUFFERSPROC);
    NVG_GL3_LOAD(DeleteBuffers,            PFNGLDELETEBUFFERSPROC);
    NVG_GL3_LOAD(BindBuffer,               PFNGLBINDBUFFERPROC);
    NVG_GL3_LOAD(BufferData,               PFNGLBUFFERDATAPROC);

    NVG_GL3_LOAD(GenVertexArrays,          PFNGLGENVERTEXARRAYSPROC);
    NVG_GL3_LOAD(DeleteVertexArrays,       PFNGLDELETEVERTEXARRAYSPROC);
    NVG_GL3_LOAD(BindVertexArray,          PFNGLBINDVERTEXARRAYPROC);
    NVG_GL3_LOAD(GenerateMipmap,           PFNGLGENERATEMIPMAPPROC);

    NVG_GL3_LOAD(GetUniformBlockIndex,     PFNGLGETUNIFORMBLOCKINDEXPROC);
    NVG_GL3_LOAD(UniformBlockBinding,      PFNGLUNIFORMBLOCKBINDINGPROC);
    NVG_GL3_LOAD(BindBufferRange,          PFNGLBINDBUFFERRANGEPROC);

    NVG_GL3_LOAD(BeginQuery,               PFNGLBEGINQUERYPROC);
    NVG_GL3_LOAD(EndQuery,                 PFNGLENDQUERYPROC);
    NVG_GL3_LOAD(GetQueryObjectiv,         PFNGLGETQUERYOBJECTIVPROC);
}

#undef NVG_GL3_LOAD
