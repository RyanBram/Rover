# Rencana Integrasi NanoVG ke Sistem SDL_webui

## Tujuan
Menggantikan renderer microui berbasis `SDL_Renderer` murni dengan **NanoVG** agar UI dirender sebagai vektor yang halus (antialiased) serta menyederhanakan dependencies dengan membuang `stb_image` dan `stb_truetype` pelan-pelan dari ekosistem `nanovg`. Kita akan menggantikannya menggunakan `SDL_image` dan *native backend* dari `SDL_ttf`. Perubahan pada library external (*hard fork*) diizinkan dengan menyalin library tersebut ke dalam direktori `src`.

---

## Roadmap / Step-by-Step

### Step 1: Hard Fork dan Penyiapan Lingkungan (Hard Fork NanoVG)
- **Tugas**: Menyalin library external yang akan diubah agar kita tidak merusak kode *upstream*.
- **Implementasi**: Copy `nanovg.c`, `nanovg.h`, dan `fontstash.h` dari `libs/nanovg/src/` ke dalam `libs/SDL_webui/src/`. File-file tersebut akan dimodifikasi di tempat, diperlakukan sebagai basis *hard fork* yang murni menggunakan API SDL3.

### Step 2: Menghapus `stb_image` dan Menggunakan `SDL_image`
- **Tugas**: Menghapus dependensi `stb_image.h` di dalam source code `nanovg.c`.
- **Implementasi**: 
  - Gunakan *preprocessor flag* `-DNVG_NO_STB_IMPLEMENTATION` (*atau kikis library dari include nanovg.c*).
  - Alihkan fungsionalitas decoding gambar berformat eksternal (menggantikan `stbi_load()`). Tugas ini memanggil `IMG_Load()` dari `SDL_image`, lalu meneruskan piksel RGBA asli hasil terjemahan tsb ke perintah bawaan NanoVG (`nvgCreateImageRGBA()` atau sejenisnya).

### Step 3: Pembedahan Total `fontstash.h` (Pemetaan `SDL_ttf` sebagai Backend)
- **Tugas**: Arsitektur NanoVG untuk rendering teks, rotasi, kliping matriks, dan _batching_-nya sangat ketat. Pemisahan SDL_ttf dari stack akan memicu bug *Z-Order/overlap* dan membutuhkan sinkronisasi manual layaknya sebuah "hack" (_flushing_ dan _scissoring_ sinkron). Untuk itu, `stb_truetype` akan dicabut dari *engine*, lalu **fungsi-fungsi internal `fontstash.h` akan dipetakan langsung ke API `SDL_ttf`**.
- **Implementasi**: 
  Di dalam `fontstash.h` (versi *hard fork* di `src/`), buat dan aktifkan mekanisme makro / *backend* baru (`#define FONS_USE_SDL_TTF`). Fungsi internal _stb_truetype_ akan di-*mapping* 1:1 ke *engine* `TTF_Font`:
  - `fons__tt_init`: Dihubungkan ke `TTF_Init()`.
  - `fons__tt_loadFont`: Dihubungkan ke `TTF_OpenFontIO` (SDL3) / `TTF_OpenFontRW` (SDL2).
  - `fons__tt_getFontVMetrics`: Ambil besaran *ascender*, *descender*, *height* menggunakan fungsi bantu keluarga `TTF_FontHeight()`, `TTF_FontAscent()`, dsb.
  - `fons__tt_getGlyphIndex` & `fons__tt_buildGlyphBitmap`: Dihubungkan ke fungsi cek dimensi glyph (`TTF_GetGlyphMetrics`). 
  - `fons__tt_renderGlyphBitmap`: Permintaan untuk melukis glyph ke atlas dihubungkan ke pelukisan internal *surface* `TTF_RenderGlyph_Solid / TTF_RenderGlyph_Blended`. Kemudian *pixel buffer* (8-bit alpha/32-bit RGBA) milik *surface* cukup disalin (*memcpy*) meresapi memori milik `fontstash`.
- **Target Terukur**: NanoVG dapat merender glyph *cache atlas* memanggil `.ttf` namun *mesin* pembaca utamanya sudah murni API SDL_ttf, tanpa satupun *header* `.h` dari `stb`. Antrian *batch* matriks rendering teks dipastikan tetap sehat. 

### Step 4: Pembuatan Backend NanoVG untuk `SDL_Renderer` (nanovg_sdl3.c)
- **Tugas**: Buat file `libs/SDL_webui/src/nanovg_sdl3.c` dan `nanovg_sdl3.h`.
- **Implementasi**: Mengisi array struktur callback `NVGparams` yang bertugas menerjemahkan perintah _Shape_ NanoVG ke instrukis GPU modern `SDL_RenderGeometryRaw()` yang target akhirnya adalah `SDL_Renderer`.

### Step 5: Adaptasi `SDL_webui` (Microui -> NanoVG Bridge)
- **Tugas**: Menyambungkan iterasi log event `microui` (`mu_Command`) agar diterjemahkan jadi vektor NanoVG seutuhnya.
- **Implementasi**: Mengubah loop `mu_next_command()` di `sdl_webui.c`.
  - `MU_COMMAND_RECT`: Memanggil engine vektor `nvgBeginPath()`, `nvgRect()`, `nvgFill()`.
  - `MU_COMMAND_TEXT`: Murni memanggil `nvgText()` layaknya ekosistem natural! Rendering, margin, rotasi, pewarnaan otomatis mengikuti matriks NanoVG sebagaimana ekosistem alaminya mengatur tekstur bitmap (_atlas_ di step 3).
  - `MU_COMMAND_CLIP`: Menggunakan antrian pipeline native `nvgScissor()`. Tidak diperlukan penyesuaian khusus dengan batas koordinat `SDL_SetRenderClipRect()` layaknya metode pisah (*hybrid*).  

### Step 6: Validasi Skema Testsuite `demo_sdl_webui3_sdl3`
- **Tugas**: Adaptasikan folder _test suite_ baru (`examples/demo_sdl_webui3_sdl3`) dengan merujuk *hard-fork* baru.
- **Implementasi**: Update `build.bat` agar merujuk folder `src/` berisi *hard-fork* dan backend `nanovg_sdl3.c`. Hapus pemanggil pengumpul font lama (`renderer_sdl3_ttf.c`). Pastikan seluruh antarmuka, text box layouter microui, flexbox, antialiasing path presisi saling timpa 100% harmonis berkat konversi native subrutin `SDL_ttf` ke *core engine* `fontstash`.
