# SDL_webui

SDL_webui; an HTML/CSS-compatible layout and widget framework for SDL3.

## What is this?

SDL_webui is a library that provides web-like layout and UI capabilities for SDL3 applications. It combines:

- **flex**: A CSS Flexbox layout engine (hard fork) that computes element geometry based on CSS properties
- **microui**: An immediate-mode widget toolkit (hard fork) for interactive UI components
- **SDL3_webui**: A wrapper layer that unifies them with an immediate-mode API using CSS-style naming conventions

The result is a familiar development experience for web developers building desktop/embedded applications in C. You declare your layout declaratively each frame using CSS-like property names (`flex-direction`, `flex-grow`, `padding`, etc.), and the framework handles all the messy details of coordinate math, widget rendering, and event handling behind the scenes.

## Key features

- **CSS-compatible layout**: Full CSS Flexbox property support (`flex-grow`, `flex-shrink`, `flex-basis`, `flex-wrap`, margins, padding, alignment, etc.)
- **Immediate-mode API**: Same mental model as microui and web frameworks — declare your UI fresh every frame
- **No external dependencies**: Zero upstream library requirements; everything is self-contained
- **Hard-forked dependencies**: flex and microui are vendored as local copies (not git submodules), ensuring stable, reproducible builds
- **SDL3 only**: Requires Simple Directmedia Layer (SDL) 3.x. Get SDL from https://www.libsdl.org/

## Building/Installing

Please read [building instructions](docs/BUILD.md) (coming soon).

## Directory structure

```
include/SDL3_webui/
    SDL3_webui.h            Public API header (work in progress)

src/
    flex.c, flex.h          Hard fork: CSS Flexbox layout engine (main source)
    microui.c, microui.h    Hard fork: immediate-mode widget kit (main source)
    flex/
        LICENSE.txt         Original flex license
        README.md           Original flex documentation
    microui/
        LICENSE             Original microui license
        README.md           Original microui documentation

examples/                   Demo applications and integration examples
    demo_flex_sdl3/         Phase 2: flex layout on SDL3
    demo_sdl_webui1_sdl3/   Phase 3a: flex + microui integrated
    demo_microclay_ui1/     Reference: Clay + microui pattern
    (and others)

build-scripts/              Build helper scripts
cmake/                      CMake configuration (coming soon)
docs/                       Documentation
tests/                      Test suite
external/                   Third-party dependencies (currently empty)
```

**Hard fork model:** flex and microui source files (`flex.[ch]`, `microui.[ch]`) are extracted
and flattened into `src/` as the main codebase. Original project metadata (LICENSE, README)
is preserved in subdirectories (`src/flex/`, `src/microui/`) for attribution.

## Project phases

- **Phase 1** ✅ — microui on SDL3 renderer (reference implementation)
- **Phase 2** ✅ — flex layout on SDL3 (layout engine demonstration)
- **Phase 3a** ✅ — flex + microui integration (stable demo)
- **Phase 3b** 🔄 — CSS-style wrapper API (sdl_webui v1.0)

## Reporting bugs/commenting

Please visit the project repository for the bug tracker.

## License

SDL_webui uses a hard-fork model for its core dependencies. Original project licenses are preserved
in their respective source directories (`src/flex/LICENSE.txt`, `src/microui/LICENSE`) for full
attribution and compliance:

- **flex** (`src/flex.c`, `src/flex.h`): Microsoft Public License (MS-PL) — see `src/flex/LICENSE.txt`
- **microui** (`src/microui.c`, `src/microui.h`): MIT License — see `src/microui/LICENSE`

**SDL3_webui wrapper layer** (`include/SDL3_webui/`, integration code): TBD

## Web development context

SDL_webui is designed for projects that want to leverage web-like UI patterns (HTML structure, CSS layout properties, responsive design) in native SDL3 applications. It is particularly useful for:

- Cross-platform desktop applications with complex layouts
- Embedded systems with graphical UIs (kiosk, industrial control, etc.)
- Games with in-game UI systems
- Applications that need responsive design without external GUI frameworks

Unlike web frameworks, SDL_webui compiles to native code with zero JavaScript runtime overhead. Like web frameworks, developers can use familiar CSS mental models for layout without learning a specialized layout system.
