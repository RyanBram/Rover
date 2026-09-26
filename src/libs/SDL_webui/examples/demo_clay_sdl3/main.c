/* clay SDL3-simple-demo — MinGW adaptation for microclay_ui Phase 2.
 *
 * Adapted from ../clay/examples/SDL3-simple-demo/main.c.
 * The upstream demo uses SDL_MAIN_USE_CALLBACKS (SDL3 app-event model).
 * This version converts it to a standard main() event loop so it compiles
 * with a plain MinGW gcc invocation without any CMake plumbing.
 *
 * What is unchanged:
 *   - All clay layout and rendering logic
 *   - ClayVideoDemo_CreateLayout / ClayImageSample_CreateLayout
 *   - SDL_MeasureText / HandleClayErrors
 *
 * What changed:
 *   - SDL_MAIN_USE_CALLBACKS replaced by standard int main()
 *   - Init / event / iterate / quit folded back into main()
 *   - #include paths updated for the local directory layout
 */

#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <SDL3_ttf/SDL_ttf.h>
#include <SDL3_image/SDL_image.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>

#define CLAY_IMPLEMENTATION
#include "../../clay/clay.h"

/* Include clay SDL3 renderer directly (it's a .c file, not a library). */
#include "../../clay/renderers/SDL3/clay_renderer_SDL3.c"

/* Include the shared-layout demo used by the upstream example. */
#include "../../clay/examples/shared-layouts/clay-video-demo.c"

/* ---------------------------------------------------------------------------
 * Constants & types
 * ------------------------------------------------------------------------ */

static const Uint32 FONT_ID = 0;

/* NOTE: these colors are defined by the shared clay-video-demo layout.
 * They are kept here for reference but not directly used in this file. */
/* static const Clay_Color COLOR_ORANGE, COLOR_BLUE, COLOR_LIGHT; */

typedef struct {
    SDL_Window            *window;
    Clay_SDL3RendererData  rendererData;
    ClayVideoDemo_Data     demoData;
} AppState;

/* ---------------------------------------------------------------------------
 * Globals
 * ------------------------------------------------------------------------ */

static SDL_Texture *sample_image = NULL;
static bool         show_demo    = true;

/* ---------------------------------------------------------------------------
 * clay helpers
 * ------------------------------------------------------------------------ */

static Clay_Dimensions SDL_MeasureText(Clay_StringSlice text,
                                       Clay_TextElementConfig *config,
                                       void *userData)
{
    TTF_Font **fonts = userData;
    TTF_Font  *font  = fonts[config->fontId];
    int width = 0, height = 0;

    TTF_SetFontSize(font, config->fontSize);
    if (!TTF_GetStringSize(font, text.chars, text.length, &width, &height)) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR,
                     "SDL_MeasureText: TTF_GetStringSize failed: %s",
                     SDL_GetError());
    }
    return (Clay_Dimensions){ (float)width, (float)height };
}

static void HandleClayErrors(Clay_ErrorData errorData) {
    printf("Clay error: %s\n", errorData.errorText.chars);
}

/* ---------------------------------------------------------------------------
 * Image-only layout (shown when SPACE is pressed to hide the video demo)
 * ------------------------------------------------------------------------ */

static Clay_RenderCommandArray ClayImageSample_CreateLayout(void) {
    Clay_BeginLayout();

    Clay_Sizing layoutExpand = {
        .width  = CLAY_SIZING_GROW(0),
        .height = CLAY_SIZING_GROW(0)
    };

    CLAY(CLAY_ID("OuterContainer"), {
        .layout = {
            .layoutDirection = CLAY_TOP_TO_BOTTOM,
            .sizing   = layoutExpand,
            .padding  = CLAY_PADDING_ALL(16),
            .childGap = 16
        }
    }) {
        CLAY(CLAY_ID("SampleImage"), {
            .layout      = { .sizing = layoutExpand },
            .aspectRatio = { 23.0f / 42.0f },
            .image       = { .imageData = sample_image }
        });
    }

    return Clay_EndLayout();
}

/* ---------------------------------------------------------------------------
 * Per-frame render helper — called from both the main loop and the event
 * watcher so that layout updates happen even during Windows resize drag.
 * ------------------------------------------------------------------------ */

static void do_frame(AppState *state) {
    /* Always sync clay layout dimensions to the actual window size.
     * This is the authoritative update — no resize event needed. */
    int w = 0, h = 0;
    SDL_GetWindowSize(state->window, &w, &h);
    Clay_SetLayoutDimensions((Clay_Dimensions){ (float)w, (float)h });

    Clay_RenderCommandArray render_commands = (show_demo
        ? ClayVideoDemo_CreateLayout(&state->demoData)
        : ClayImageSample_CreateLayout());

    SDL_SetRenderDrawColor(state->rendererData.renderer, 0, 0, 0, 255);
    SDL_RenderClear(state->rendererData.renderer);
    SDL_Clay_RenderClayCommands(&state->rendererData, &render_commands);
    SDL_RenderPresent(state->rendererData.renderer);
}

/* Event watcher — called by SDL from *within* the Windows modal resize loop,
 * which otherwise blocks the main event loop entirely.
 * Rendering here is what makes live resize feel instantaneous. */
static AppState *g_state = NULL;

static bool on_resize_event(void *userdata, SDL_Event *event) {
    (void)userdata;
    if (event->type == SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED && g_state) {
        do_frame(g_state);
    }
    return true; /* pass the event through to the main loop */
}

/* ---------------------------------------------------------------------------
 * Main
 * ------------------------------------------------------------------------ */

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    /* ---- SDL + TTF init ---- */
    if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS)) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR, "SDL_Init failed: %s", SDL_GetError());
        return 1;
    }
    if (!TTF_Init()) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR, "TTF_Init failed: %s", SDL_GetError());
        return 1;
    }

    AppState *state = SDL_calloc(1, sizeof(AppState));
    if (!state) { SDL_LogError(SDL_LOG_CATEGORY_ERROR, "OOM"); return 1; }

    if (!SDL_CreateWindowAndRenderer("Clay Demo (microclay_ui Phase 2)",
                                      640, 480, SDL_WINDOW_RESIZABLE,
                                      &state->window,
                                      &state->rendererData.renderer)) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR,
                     "SDL_CreateWindowAndRenderer failed: %s", SDL_GetError());
        return 1;
    }

    /* ---- TTF text engine ---- */
    state->rendererData.textEngine =
        TTF_CreateRendererTextEngine(state->rendererData.renderer);
    if (!state->rendererData.textEngine) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR,
                     "TTF_CreateRendererTextEngine failed: %s", SDL_GetError());
        return 1;
    }

    state->rendererData.fonts = SDL_calloc(1, sizeof(TTF_Font *));
    if (!state->rendererData.fonts) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR, "OOM for font array"); return 1; }

    TTF_Font *font = TTF_OpenFont("resources/Roboto-Regular.ttf", 24);
    if (!font) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR,
                     "TTF_OpenFont failed: %s", SDL_GetError());
        return 1;
    }
    state->rendererData.fonts[FONT_ID] = font;

    /* ---- Load sample image ---- */
    sample_image = IMG_LoadTexture(state->rendererData.renderer,
                                   "resources/sample.png");
    if (!sample_image) {
        SDL_LogError(SDL_LOG_CATEGORY_ERROR,
                     "IMG_LoadTexture failed: %s", SDL_GetError());
        return 1;
    }

    /* ---- Initialise clay ---- */
    uint64_t totalMemorySize = Clay_MinMemorySize();
    Clay_Arena clayMemory = (Clay_Arena){
        .memory   = SDL_malloc(totalMemorySize),
        .capacity = totalMemorySize
    };

    int winW = 0, winH = 0;
    SDL_GetWindowSize(state->window, &winW, &winH);
    Clay_Initialize(clayMemory,
                    (Clay_Dimensions){ (float)winW, (float)winH },
                    (Clay_ErrorHandler){ HandleClayErrors });
    Clay_SetMeasureTextFunction(SDL_MeasureText, state->rendererData.fonts);

    state->demoData = ClayVideoDemo_Initialize();

    /* Register live-resize watcher — fires from inside Windows resize loop. */
    g_state = state;
    SDL_AddEventWatch(on_resize_event, NULL);

    printf("Clay demo running. Press SPACE to toggle between video demo and image sample.\n");
    printf("Close the window or press Q to quit.\n");

    /* ---- Main event loop ---- */
    bool running = true;
    while (running) {
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            switch (event.type) {
                case SDL_EVENT_QUIT:
                    running = false;
                    break;
                case SDL_EVENT_KEY_UP:
                    if (event.key.scancode == SDL_SCANCODE_SPACE) {
                        show_demo = !show_demo;
                    }
                    if (event.key.scancode == SDL_SCANCODE_Q) {
                        running = false;
                    }
                    break;
                case SDL_EVENT_WINDOW_RESIZED:
                    /* Handled continuously by do_frame() — no extra action needed. */
                    break;
                case SDL_EVENT_MOUSE_MOTION:
                    Clay_SetPointerState(
                        (Clay_Vector2){ event.motion.x, event.motion.y },
                        (event.motion.state & SDL_BUTTON_LMASK) != 0);
                    break;
                case SDL_EVENT_MOUSE_BUTTON_DOWN:
                    Clay_SetPointerState(
                        (Clay_Vector2){ event.button.x, event.button.y },
                        event.button.button == SDL_BUTTON_LEFT);
                    break;
                case SDL_EVENT_MOUSE_WHEEL:
                    Clay_UpdateScrollContainers(true,
                        (Clay_Vector2){ event.wheel.x, event.wheel.y }, 0.01f);
                    break;
                default:
                    break;
            }
        }

        /* ---- Build layout + render ---- */
        do_frame(state);
    }

    /* ---- Cleanup ---- */
    SDL_RemoveEventWatch(on_resize_event, NULL);
    g_state = NULL;
    if (sample_image)               SDL_DestroyTexture(sample_image);
    if (state->rendererData.fonts) {
        TTF_CloseFont(state->rendererData.fonts[FONT_ID]);
        SDL_free(state->rendererData.fonts);
    }
    if (state->rendererData.textEngine)
        TTF_DestroyRendererTextEngine(state->rendererData.textEngine);
    if (state->rendererData.renderer)
        SDL_DestroyRenderer(state->rendererData.renderer);
    if (state->window)
        SDL_DestroyWindow(state->window);
    SDL_free(clayMemory.memory);
    SDL_free(state);
    TTF_Quit();
    SDL_Quit();
    return 0;
}
