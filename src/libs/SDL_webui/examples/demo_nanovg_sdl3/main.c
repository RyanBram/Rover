/*
 * demo_nanovg_sdl3/main.c
 *
 * Full visual SDL3 port of libs/nanovg/example/example_gl3.c.
 *
 * Includes upstream demo.c (shapes, gradients, text, images) and perf.c
 * (FPS / CPU-time graphs) via unity build.
 *
 * Resources (fonts + images) are loaded from resources/ next to the exe.
 * build.bat copies them automatically.
 */

/* -------------------------------------------------------------------------
 * 1) GL loader first so gl* macro redirects are visible to all includes.
 * ---------------------------------------------------------------------- */
#include "nvg_gl3_loader_win.h"

/* -------------------------------------------------------------------------
 * 2) NanoVG unity build (FreeType backend)
 * ---------------------------------------------------------------------- */
#define FONS_USE_FREETYPE
#define NANOVG_GL3 1
#include "../../nanovg/src/nanovg.c"
#include "../../nanovg/src/nanovg_gl.c"

/* -------------------------------------------------------------------------
 * 3) Upstream visual demo and perf graph code.
 *
 * Rename load/free so we can provide SDL_webui-local versions with
 * resource paths that match this demo folder.
 * ---------------------------------------------------------------------- */
#define loadDemoData loadDemoData_ORIG
#define freeDemoData freeDemoData_ORIG
#include "../../nanovg/example/demo.c"
#undef loadDemoData
#undef freeDemoData

#include "../../nanovg/example/perf.c"

#include <stdio.h>
#include <stdlib.h>

#define DEMO_RES "resources/"

static int loadDemoData(NVGcontext* vg, DemoData* data)
{
    int i;
    char file[512];

    if (vg == NULL) {
        return -1;
    }

    for (i = 0; i < 12; i++) {
        snprintf(file, sizeof(file), DEMO_RES "images/image%d.jpg", i + 1);
        data->images[i] = nvgCreateImage(vg, file, 0);
        if (data->images[i] == 0) {
            printf("Could not load %s.\n", file);
            return -1;
        }
    }

    data->fontIcons = nvgCreateFont(vg, "icons", DEMO_RES "entypo.ttf");
    if (data->fontIcons == -1) {
        printf("Could not add font icons.\n");
        return -1;
    }

    data->fontNormal = nvgCreateFont(vg, "sans", DEMO_RES "Roboto-Regular.ttf");
    if (data->fontNormal == -1) {
        printf("Could not add font sans.\n");
        return -1;
    }

    data->fontBold = nvgCreateFont(vg, "sans-bold", DEMO_RES "Roboto-Bold.ttf");
    if (data->fontBold == -1) {
        printf("Could not add font sans-bold.\n");
        return -1;
    }

    data->fontEmoji = nvgCreateFont(vg, "emoji", DEMO_RES "NotoEmoji-Regular.ttf");
    if (data->fontEmoji == -1) {
        printf("Could not add font emoji.\n");
        return -1;
    }

    nvgAddFallbackFontId(vg, data->fontNormal, data->fontEmoji);
    nvgAddFallbackFontId(vg, data->fontBold, data->fontEmoji);

    return 0;
}

static void freeDemoData(NVGcontext* vg, DemoData* data)
{
    int i;

    if (vg == NULL) {
        return;
    }

    for (i = 0; i < 12; i++) {
        nvgDeleteImage(vg, data->images[i]);
    }
}

static double getTimeSeconds(void)
{
    return (double)SDL_GetPerformanceCounter() /
           (double)SDL_GetPerformanceFrequency();
}

int main(int argc, char **argv)
{
    DemoData data;
    NVGcontext* vg = NULL;
    PerfGraph fps, cpuGraph;

    double prevt = 0.0;
    int blowup = 0;
    int screenshot = 0;
    int premult = 0;
    int running = 1;

    SDL_Window* window = NULL;
    SDL_GLContext context = NULL;
    SDL_Event event;

    (void)argc;
    (void)argv;

    if (!SDL_Init(SDL_INIT_VIDEO)) {
        SDL_Log("SDL_Init failed: %s", SDL_GetError());
        return EXIT_FAILURE;
    }

    SDL_GL_SetAttribute(SDL_GL_STENCIL_SIZE, 8);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);

    window = SDL_CreateWindow(
        "SDL3 / NanoVG Full Demo",
        1000,
        600,
        SDL_WINDOW_OPENGL | SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY
    );
    if (!window) {
        SDL_Log("SDL_CreateWindow failed: %s", SDL_GetError());
        SDL_Quit();
        return EXIT_FAILURE;
    }

    context = SDL_GL_CreateContext(window);
    if (!context) {
        SDL_Log("SDL_GL_CreateContext failed: %s", SDL_GetError());
        SDL_DestroyWindow(window);
        SDL_Quit();
        return EXIT_FAILURE;
    }

    SDL_GL_MakeCurrent(window, context);
    SDL_GL_SetSwapInterval(0);

    nvg_gl3_load();

    vg = nvgCreateGL3(NVG_ANTIALIAS | NVG_STENCIL_STROKES | NVG_DEBUG);
    if (!vg) {
        SDL_Log("nvgCreateGL3 failed");
        SDL_GL_DestroyContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return EXIT_FAILURE;
    }

    if (loadDemoData(vg, &data) == -1) {
        SDL_Log("loadDemoData failed. Ensure resources/ was copied by build.bat.");
        nvgDeleteGL3(vg);
        SDL_GL_DestroyContext(context);
        SDL_DestroyWindow(window);
        SDL_Quit();
        return EXIT_FAILURE;
    }

    initGraph(&fps, GRAPH_RENDER_FPS, "Frame Time");
    initGraph(&cpuGraph, GRAPH_RENDER_MS, "CPU Time");

    prevt = getTimeSeconds();

    while (running) {
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_QUIT) {
                running = 0;
            } else if (event.type == SDL_EVENT_KEY_DOWN) {
                switch (event.key.key) {
                    case SDLK_ESCAPE:
                        running = 0;
                        break;
                    case SDLK_SPACE:
                        blowup = !blowup;
                        break;
                    case SDLK_S:
                        screenshot = 1;
                        break;
                    case SDLK_P:
                        premult = !premult;
                        break;
                    default:
                        break;
                }
            }
        }

        {
            double t = getTimeSeconds();
            double dt = t - prevt;
            double cpuTime;
            int winWidth, winHeight;
            int fbWidth, fbHeight;
            float pxRatio;
            float mx = 0.0f;
            float my = 0.0f;

            prevt = t;

            SDL_GetMouseState(&mx, &my);
            SDL_GetWindowSize(window, &winWidth, &winHeight);
            SDL_GetWindowSizeInPixels(window, &fbWidth, &fbHeight);

            pxRatio = (winWidth > 0) ? ((float)fbWidth / (float)winWidth) : 1.0f;

            glViewport(0, 0, fbWidth, fbHeight);
            if (premult) {
                glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
            } else {
                glClearColor(0.3f, 0.3f, 0.32f, 1.0f);
            }
            glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

            nvgBeginFrame(vg, (float)winWidth, (float)winHeight, pxRatio);
            renderDemo(vg, mx, my, (float)winWidth, (float)winHeight, (float)t, blowup, &data);
            renderGraph(vg, 5.0f, 5.0f, &fps);
            renderGraph(vg, 210.0f, 5.0f, &cpuGraph);
            nvgEndFrame(vg);

            cpuTime = getTimeSeconds() - t;
            updateGraph(&fps, (float)dt);
            updateGraph(&cpuGraph, (float)cpuTime);

            if (screenshot) {
                screenshot = 0;
                saveScreenShot(fbWidth, fbHeight, premult, "dump.png");
            }
        }

        SDL_GL_SwapWindow(window);
    }

    freeDemoData(vg, &data);
    nvgDeleteGL3(vg);
    SDL_GL_DestroyContext(context);
    SDL_DestroyWindow(window);
    SDL_Quit();

    return EXIT_SUCCESS;
}
