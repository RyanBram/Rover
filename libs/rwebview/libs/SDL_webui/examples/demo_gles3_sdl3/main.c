/*
 * demo_gles3_sdl3/main.c
 *
 * Port of libs/clay/examples/GLES3-SDL2-video-demo/main.c to SDL3.
 *
 * SDL2 → SDL3 changes:
 *   - SDL_CreateWindow: removed x, y position args
 *   - SDL_GL_GetDrawableSize → SDL_GetWindowSizeInPixels
 *   - SDL_QUIT → SDL_EVENT_QUIT
 *   - SDL_MOUSEWHEEL → SDL_EVENT_MOUSE_WHEEL
 *   - SDL_GetMouseState: coords are now float
 *   - SDL_BUTTON(1) → SDL_BUTTON_LMASK
 *   - gl3_win_load() called after SDL_GL_CreateContext for Windows GL3+ proc loading
 *   - SDL_AddEventWatch for live resize during Windows modal drag loop
 */

/* STB + Clay implementation macros — must come before any #include of those headers */
#define STB_IMAGE_IMPLEMENTATION
#define STB_TRUETYPE_IMPLEMENTATION
#define CLAY_IMPLEMENTATION
#define CLAY_RENDERER_GLES3_IMPLEMENTATION

/*
 * gl3_loader_win.h MUST be included first.
 * It defines GLSL_VERSION (used by clay_renderer_gles3.h) and
 * includes SDL3/SDL_opengl.h + SDL3/SDL_opengl_glext.h + SDL3/SDL.h.
 */
#include "gl3_loader_win.h"

/*
 * The renderer header guards against re-including GL headers because
 * GLSL_VERSION is already defined by gl3_loader_win.h.
 */
#include <clay.h>
#include "../../clay/renderers/GLES3/clay_renderer_gles3.h"
#include "../../clay/examples/shared-layouts/clay-video-demo.c"
#include "../../clay/renderers/GLES3/clay_renderer_gles3_loader_stb.c"

typedef struct VideoCtx
{
    int shouldContinue;
    SDL_Window   *sdlWindow;
    SDL_GLContext sdlContext;
    int screenWidth, screenHeight;
} VideoCtx;

VideoCtx g_ctx;

static int initVideo(VideoCtx *ctx, const int initialWidth, const int initialHeight)
{
    (void)ctx;

    SDL_Init(SDL_INIT_VIDEO);

    /* Desktop OpenGL 3.3 core — matches GLSL version 330 defined in gl3_loader_win.h */
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);

    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_RED_SIZE,   8);
    SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE,  8);
    SDL_GL_SetAttribute(SDL_GL_ALPHA_SIZE, 8);

    /* SDL3: no x/y position parameters */
    g_ctx.sdlWindow = SDL_CreateWindow(
        "SDL3 GLES3",
        initialWidth,
        initialHeight,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE
    );
    if (!g_ctx.sdlWindow) {
        SDL_Log("SDL_CreateWindow failed: %s", SDL_GetError());
        return 0;
    }

    g_ctx.sdlContext = SDL_GL_CreateContext(g_ctx.sdlWindow);
    if (!g_ctx.sdlContext) {
        SDL_Log("SDL_GL_CreateContext failed: %s", SDL_GetError());
        return 0;
    }

    /* Load all GL 1.2+ functions via SDL_GL_GetProcAddress (Windows requirement) */
    gl3_win_load();

    SDL_GL_MakeCurrent(g_ctx.sdlWindow, g_ctx.sdlContext);
    SDL_GL_SetSwapInterval(1);

    /* SDL3: SDL_GetWindowSizeInPixels replaces SDL_GL_GetDrawableSize */
    SDL_GetWindowSizeInPixels(g_ctx.sdlWindow, &g_ctx.screenWidth, &g_ctx.screenHeight);
    glViewport(0, 0, g_ctx.screenWidth, g_ctx.screenHeight);

    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glEnable(GL_DEPTH_TEST);

    return 1;
}

void My_ErrorHandler(Clay_ErrorData errorData)
{
    SDL_Log("[Clay Error] %s", errorData.errorText.chars);
}

Stb_FontData  g_stbFonts[MAX_FONTS];
Gles3_Renderer g_gles3;

Uint64 NOW  = 0;
Uint64 LAST = 0;
double deltaTime = 0;

static void do_frame(void);

/* SDL event watch: fires during the Windows modal resize/move loop */
static bool on_resize_event(void *userdata, SDL_Event *event)
{
    (void)userdata;
    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED) {
        do_frame();
    }
    return true;
}

void init(void)
{
    size_t clayRequiredMemory = Clay_MinMemorySize();
    g_gles3.clayMemory = (Clay_Arena){
        .capacity = clayRequiredMemory,
        .memory   = (char *)malloc(clayRequiredMemory),
    };

    Clay_Context *clayCtx = Clay_Initialize(
        g_gles3.clayMemory,
        (Clay_Dimensions){
            .width  = (float)g_ctx.screenWidth,
            .height = (float)g_ctx.screenHeight,
        },
        (Clay_ErrorHandler){
            .errorHandlerFunction = My_ErrorHandler,
        });

    Clay_SetCurrentContext(clayCtx);
    Clay_SetMeasureTextFunction(Stb_MeasureText, &g_stbFonts);
    Gles3_SetRenderTextFunction(&g_gles3, Stb_RenderText, &g_stbFonts);

    Gles3_Initialize(&g_gles3, 4096);

    if (!Stb_LoadFont(
            &g_gles3.fontTextures[0],
            &g_stbFonts[0],
            "resources/Roboto-Regular.ttf",
            24.0f,
            1024, 1024))
    {
        SDL_Log("Failed to load font!");
        abort();
    }

    Clay_SetDebugModeEnabled(true);
}

static void do_frame(void)
{
    glClearColor(0.1f, 0.2f, 0.1f, 1.0f);

    /* SDL3: GetMouseState returns float coords */
    float fMouseX = 0.0f, fMouseY = 0.0f;
    SDL_MouseButtonFlags mouseState = SDL_GetMouseState(&fMouseX, &fMouseY);
    Clay_Vector2 mousePosition = { (float)fMouseX, (float)fMouseY };
    /* SDL3: SDL_BUTTON_LMASK replaces SDL_BUTTON(1) */
    Clay_SetPointerState(mousePosition, (mouseState & SDL_BUTTON_LMASK) != 0);

    LAST = NOW;
    NOW  = SDL_GetPerformanceCounter();
    deltaTime = (double)((NOW - LAST) * 1000 / (double)SDL_GetPerformanceFrequency());

    /* SDL3: SDL_GetWindowSizeInPixels for drawable size */
    SDL_GetWindowSizeInPixels(g_ctx.sdlWindow, &g_ctx.screenWidth, &g_ctx.screenHeight);
    glViewport(0, 0, g_ctx.screenWidth, g_ctx.screenHeight);
    Clay_SetLayoutDimensions((Clay_Dimensions){
        (float)g_ctx.screenWidth,
        (float)g_ctx.screenHeight
    });

    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
    glDisable(GL_DEPTH_TEST);
    glDepthMask(GL_FALSE);

    ClayVideoDemo_Data data = ClayVideoDemo_Initialize();
    Clay_RenderCommandArray cmds = ClayVideoDemo_CreateLayout(&data);
    Gles3_Render(&g_gles3, cmds, g_stbFonts);

    SDL_GL_SwapWindow(g_ctx.sdlWindow);
}

static void loop(Clay_Vector2 *scrollDelta)
{
    glClearColor(0.1f, 0.2f, 0.1f, 1.0f);

    SDL_Event event;
    /* SDL3: event names use SDL_EVENT_ prefix */
    while (SDL_PollEvent(&event))
    {
        switch (event.type)
        {
        case SDL_EVENT_QUIT:
            g_ctx.shouldContinue = false;
            break;
        case SDL_EVENT_MOUSE_WHEEL:
            scrollDelta->x = event.wheel.x;
            scrollDelta->y = event.wheel.y;
            break;
        default:
            break;
        }
    }

    Clay_UpdateScrollContainers(true, *scrollDelta, (float)deltaTime);
    scrollDelta->x = 0.0f;
    scrollDelta->y = 0.0f;

    do_frame();
}

int main(void)
{
    if (!initVideo(&g_ctx, 1280, 720))
        return 1;

    init();
    NOW = SDL_GetPerformanceCounter();

    /* Allow Clay to fire a frame during Windows modal resize drag */
    SDL_AddEventWatch(on_resize_event, NULL);

    g_ctx.shouldContinue = true;
    Clay_Vector2 scrollDelta = { 0.0f, 0.0f };
    while (g_ctx.shouldContinue)
    {
        loop(&scrollDelta);
    }

    SDL_RemoveEventWatch(on_resize_event, NULL);
    SDL_GL_DestroyContext(g_ctx.sdlContext);
    SDL_DestroyWindow(g_ctx.sdlWindow);
    SDL_Quit();
    return 0;
}
