# PLANNING3b — SDL_webui Phase 3b: CSS-mapped API

> **Status:** Planning (not yet implemented)  
> **Goal:** Replace the current `swu_open/swu_close/swu_slot` tree API with a proper
> HTML-tag + CSS-property API that maps 1:1 onto CSS1/Flexbox concepts.  
> The integration with **rwebview** (which produces real HTML/CSS from Nim/QuickJS) is
> the driving force: SDL_webui must be able to consume a CSS property bag and call the
> right underlying flex/microui primitives without the caller knowing the difference.

---

## 1. Analisis Fitur yang Beririsan (microui vs flex)

Kedua library memiliki konsep yang terdengar sama tetapi bekerja di lapisan berbeda.
Tabel berikut memetakan setiap tumpang-tindih dan keputusan yang diambil.

### 1.1 Layout Anak (Child Positioning)

| Aspek | microui | flex | Keputusan |
|---|---|---|---|
| Arah tata letak | `mu_layout_begin_column` — hanya kolom tunggal | `flex_direction`: row, column, row-reverse, column-reverse | **flex** |
| Bungkus baris | Tidak ada (`mu_layout_row` menulis baris baru tapi tidak wrap) | `flex_wrap`: nowrap, wrap, wrap-reverse | **flex** |
| Pembagian ruang sisa | Lebar `-1` → "isi sisa" (kasar, satu item) | `flex_grow` + `flex_shrink` + `flex_basis` (W3C spec) | **flex** |
| Perataan cross-axis | Tidak ada | `align_items`, `align_self`, `align_content` | **flex** |
| Perataan main-axis | Tidak ada | `justify_content` | **flex** |
| Urutan render | Urutan deklarasi | `order` property | **flex** |
| Ukuran otomatis (teks) | `mu_text()` menghitung sendiri di dalam `mu_layout_row` | `flex_self_sizing` callback (dipanggil saat layout pass) | **flex** self_sizing untuk `<p>` dan `height: auto` |

**Aturan:** flex adalah satu-satunya mesin layout untuk semua container.  
microui's `mu_layout_*` functions hanya boleh digunakan **di dalam** sebuah sel flex
untuk internal widget rendering (contoh: memposisikan label di dalam tombol).

---

### 1.2 Padding

| | microui | flex |
|---|---|---|
| Representasi | `mu_Style.padding` — integer, uniform, global | `padding_left/right/top/bottom` — float, per-sisi, per-item |
| Pengaruh | Menggeser konten widget di dalam rect (label spacing, textbox inner margin) | Mengurangi content-rect anak di dalam parent container |

**Keputusan:**  
- **flex padding** → Ukuran dan penempatan container (`swu_css_padding_*`).  
- **microui `style.padding`** → Dilestarikan untuk kebutuhan internal widget (jarak teks di dalam tombol, inner textbox margin). Tidak diekspos ke caller.

---

### 1.3 Margin / Spacing Antar Item

| | microui | flex |
|---|---|---|
| Representasi | `mu_Style.spacing` — integer, uniform, berlaku di dalam satu `mu_layout_row` | `margin_left/right/top/bottom` — float, per-sisi, per-item |

**Keputusan:**  
- **flex margin** → Jarak antar elemen (`swu_css_margin_*`).  
- **microui `style.spacing`** → Hanya untuk jarak antar widget dalam satu baris internal microui. Tidak diekspos.

---

### 1.4 Width / Height

| | microui | flex |
|---|---|---|
| API | `mu_layout_row(items, widths[], height)` — array tetap per baris | `flex_item_set_width/height`, `flex_basis/grow/shrink` |
| `height: auto` | `mu_text()` menghitung sendiri | `flex_self_sizing` callback |
| `-1` / fill | Negatif = sisa ruang (satu item saja) | `flex_grow: 1; flex_basis: 0` (bisa banyak item) |

**Keputusan:** flex untuk semua ukuran container.

---

### 1.5 Warna Latar & Border

| | microui | flex |
|---|---|---|
| Representasi | `mu_Style.colors[]` — palet global, berlaku untuk semua widget | Tidak ada |
| Per-elemen | `ctx->draw_frame` bisa di-override per container (rumit) | — |

**Keputusan:**  
SDL_webui menyimpan metadata warna per elemen di sebuah **shadow struct** kecil yang
disimpan via `flex_item_set_managed_ptr()`. Saat `swu_render_backgrounds()` dipanggil,
SDL_webui menarik warna dari shadow struct dan menggambar rect via **SDL_RenderFillRect**
langsung (bukan lewat microui). Border digambar via `mu_draw_box`.

---

### 1.6 Overflow / Scroll

| | microui | flex |
|---|---|---|
| Representasi | `mu_Container.scroll`, scrollbar rendering built-in | Tidak ada |
| Kontrol | `MU_OPT_NOSCROLL` mematikan scrollbar | — |

**Keputusan:**  
Ketika `overflow: auto` atau `overflow: scroll` di-set pada sebuah elemen, SDL_webui
membungkus isinya dalam `mu_begin_panel_ex / mu_end_panel`. Rect panel diambil dari
hasil flex layout (`swu_get_rect`). microui mengurus scrollbar rendering dan input.

---

### 1.7 Clipping

| | microui | flex |
|---|---|---|
| API | `mu_push_clip_rect / mu_pop_clip_rect` | Tidak ada |

**Keputusan:** microui clipping saja. flex tidak memiliki fitur ini.

---

### 1.8 Z-Order

| | microui | flex |
|---|---|---|
| Container z-order | `mu_Container.zindex`, `mu_bring_to_front` | Tidak ada |
| Item order dalam flex | — | `order` property |

**Keputusan:** Keduanya dipertahankan secara terpisah dan tidak konflikt:
- microui z-index → untuk popup, modal, window overlap.
- flex `order` → urutan render anak dalam satu flex container.

---

### 1.9 Text Rendering

| | microui | flex |
|---|---|---|
| API | `mu_text`, `mu_label`, `mu_draw_text`, `mu_draw_control_text` | Tidak ada |
| Font | `mu_Style.font` (satu font handle global) | `flex_self_sizing` (query ukuran) |

**Keputusan:** microui untuk semua text rendering. `flex_self_sizing` digunakan oleh
elemen `<p>` untuk melaporkan tinggi teks yang di-word-wrap ke flex engine.

---

### 1.10 Ringkasan Kepemilikan

```
flex  → LAYOUT: posisi, ukuran, arah, wrap, grow/shrink, margin, padding, order
microui → WIDGET: draw commands, interaksi (hover/focus/click), scroll, clipping, teks
SDL_webui → ONGKOS: warna per-elemen, background-color, border, overflow, bridge flex↔mu
```

---

## 2. Mapping Nama: CSS/HTML → SDL_webui API

### 2.1 HTML Tags → Fungsi Element

Pola: `swu_TAG(ctx, id, ...)` — lowercase, mengikuti nama tag HTML.  
Semua container dikembalikan sebagai `swu_elem_t *` untuk pemanggilan `swu_css_*`.  
Semua container ditutup dengan **`swu_end(ctx)`** (satu fungsi, seperti `</tag>` di HTML).

| HTML Tag | SDL_webui Function | Backend | Keterangan |
|---|---|---|---|
| `<div>` | `swu_div(ctx, id)` | flex item | Container block, default `flex-direction: column` |
| `<span>` | `swu_span(ctx, id)` | flex item | Container inline, default `flex-direction: row` |
| `<p>` | `swu_p(ctx, id, text)` | flex item + mu_text | Paragraf, `height: auto` via `flex_self_sizing` |
| `<h1>`…`<h6>` | `swu_h1(ctx,id,text)` … `swu_h6(ctx,id,text)` | mu_draw_control_text | Heading; ukuran font berbeda memerlukan SDL_TTF (Phase 3c) |
| `<label>` | `swu_label(ctx, id, text)` | mu_draw_control_text | Teks non-interaktif satu baris |
| `<button>` | `swu_button(ctx, id, label)` | mu_button_ex | Return `SWU_RES_CLICK` saat diklik |
| `<input type="text">` | `swu_input(ctx, id, buf, bufsz)` | mu_textbox_ex | Return `SWU_RES_CHANGE`, `SWU_RES_SUBMIT` |
| `<input type="checkbox">` | `swu_checkbox(ctx, id, label, &state)` | mu_checkbox | Return `SWU_RES_CHANGE` |
| `<input type="range">` | `swu_range(ctx, id, &val, lo, hi)` | mu_slider_ex | Return `SWU_RES_CHANGE` |
| `<img>` | `swu_img(ctx, id, texture)` | SDL_RenderTexture | `SDL_Texture*`, dipasang pada flex rect |
| `<hr>` | `swu_hr(ctx, id)` | mu_draw_rect | Garis divider 1px, warna dari `border-color` |
| `<a>` | `swu_a(ctx, id, text)` | mu_button_ex (noframe) | Teks klikable, tampak seperti hyperlink |

> **Catatan:** `<ul>/<li>`, `<select>/<option>`, `<textarea>`, `<table>` ditangguhkan
> ke Phase 3c atau lebih lanjut.

---

### 2.2 CSS Properties → `swu_css_*` Setters

Pola: `swu_css_PROPERTY(el, value)` di mana PROPERTY = nama CSS dengan underscore.

#### Box Model (CSS1 — didukung langsung oleh flex)

```c
void swu_css_width(swu_elem_t *el, float px);           /* width: <px>        */
void swu_css_height(swu_elem_t *el, float px);          /* height: <px>       */

void swu_css_margin(swu_elem_t *el, float px);          /* margin: <px>       */
void swu_css_margin_top(swu_elem_t *el, float px);
void swu_css_margin_right(swu_elem_t *el, float px);
void swu_css_margin_bottom(swu_elem_t *el, float px);
void swu_css_margin_left(swu_elem_t *el, float px);

void swu_css_padding(swu_elem_t *el, float px);         /* padding: <px>      */
void swu_css_padding_top(swu_elem_t *el, float px);
void swu_css_padding_right(swu_elem_t *el, float px);
void swu_css_padding_bottom(swu_elem_t *el, float px);
void swu_css_padding_left(swu_elem_t *el, float px);

void swu_css_position(swu_elem_t *el, swu_position_t v); /* relative|absolute */
void swu_css_top(swu_elem_t *el, float px);
void swu_css_right(swu_elem_t *el, float px);
void swu_css_bottom(swu_elem_t *el, float px);
void swu_css_left(swu_elem_t *el, float px);
```

#### CSS Flexbox (didukung oleh flex)

```c
void swu_css_flex_direction(swu_elem_t *el, swu_flex_direction_t v);
    /* SWU_FLEX_ROW | SWU_FLEX_COLUMN | SWU_FLEX_ROW_REVERSE | SWU_FLEX_COLUMN_REVERSE */

void swu_css_flex_wrap(swu_elem_t *el, swu_flex_wrap_t v);
    /* SWU_NOWRAP | SWU_WRAP | SWU_WRAP_REVERSE */

void swu_css_flex_grow(swu_elem_t *el, float v);
void swu_css_flex_shrink(swu_elem_t *el, float v);
void swu_css_flex_basis(swu_elem_t *el, float px);      /* NAN = auto */

void swu_css_justify_content(swu_elem_t *el, swu_align_t v);
    /* SWU_FLEX_START | SWU_FLEX_END | SWU_CENTER |
       SWU_SPACE_BETWEEN | SWU_SPACE_AROUND | SWU_SPACE_EVENLY */

void swu_css_align_items(swu_elem_t *el, swu_align_t v);
void swu_css_align_self(swu_elem_t *el, swu_align_t v);
void swu_css_align_content(swu_elem_t *el, swu_align_t v);
    /* SWU_AUTO | SWU_STRETCH | SWU_CENTER | SWU_FLEX_START | SWU_FLEX_END |
       SWU_SPACE_BETWEEN | SWU_SPACE_AROUND */

void swu_css_order(swu_elem_t *el, int v);
```

#### Visual Properties (dikelola SDL_webui/microui)

```c
void swu_css_color(swu_elem_t *el, SDL_Color c);               /* color: …          */
void swu_css_background_color(swu_elem_t *el, SDL_Color c);    /* background-color: */
void swu_css_border_color(swu_elem_t *el, SDL_Color c);        /* border-color:     */
void swu_css_border_width(swu_elem_t *el, float px);           /* border-width: (uniform) */
void swu_css_overflow(swu_elem_t *el, swu_overflow_t v);       /* hidden|auto|scroll */
    /* SWU_OVERFLOW_VISIBLE | SWU_OVERFLOW_HIDDEN | SWU_OVERFLOW_AUTO | SWU_OVERFLOW_SCROLL */

void swu_css_text_align(swu_elem_t *el, swu_text_align_t v);   /* text-align: */
    /* SWU_TEXT_LEFT | SWU_TEXT_CENTER | SWU_TEXT_RIGHT */

void swu_css_display(swu_elem_t *el, swu_display_t v);         /* display: none|flex */
    /* SWU_DISPLAY_NONE | SWU_DISPLAY_FLEX */
```

---

### 2.3 Event Return Type

```c
typedef int swu_result_t;
#define SWU_RES_NONE    0
#define SWU_RES_CLICK   (1 << 0)   /* MU_RES_SUBMIT */
#define SWU_RES_CHANGE  (1 << 1)   /* MU_RES_CHANGE */
#define SWU_RES_ACTIVE  (1 << 2)   /* MU_RES_ACTIVE */
```

---

### 2.4 Enum Mapping

```c
typedef enum {
    SWU_POSITION_RELATIVE = FLEX_POSITION_RELATIVE,
    SWU_POSITION_ABSOLUTE = FLEX_POSITION_ABSOLUTE
} swu_position_t;

typedef enum {
    SWU_FLEX_ROW            = FLEX_DIRECTION_ROW,
    SWU_FLEX_ROW_REVERSE    = FLEX_DIRECTION_ROW_REVERSE,
    SWU_FLEX_COLUMN         = FLEX_DIRECTION_COLUMN,
    SWU_FLEX_COLUMN_REVERSE = FLEX_DIRECTION_COLUMN_REVERSE
} swu_flex_direction_t;

typedef enum {
    SWU_NOWRAP       = FLEX_WRAP_NO_WRAP,
    SWU_WRAP         = FLEX_WRAP_WRAP,
    SWU_WRAP_REVERSE = FLEX_WRAP_WRAP_REVERSE
} swu_flex_wrap_t;

typedef enum {
    SWU_AUTO          = FLEX_ALIGN_AUTO,
    SWU_STRETCH       = FLEX_ALIGN_STRETCH,
    SWU_CENTER        = FLEX_ALIGN_CENTER,
    SWU_FLEX_START    = FLEX_ALIGN_START,
    SWU_FLEX_END      = FLEX_ALIGN_END,
    SWU_SPACE_BETWEEN = FLEX_ALIGN_SPACE_BETWEEN,
    SWU_SPACE_AROUND  = FLEX_ALIGN_SPACE_AROUND,
    SWU_SPACE_EVENLY  = FLEX_ALIGN_SPACE_EVENLY
} swu_align_t;

typedef enum { SWU_OVERFLOW_VISIBLE, SWU_OVERFLOW_HIDDEN,
               SWU_OVERFLOW_AUTO, SWU_OVERFLOW_SCROLL } swu_overflow_t;
typedef enum { SWU_TEXT_LEFT, SWU_TEXT_CENTER, SWU_TEXT_RIGHT } swu_text_align_t;
typedef enum { SWU_DISPLAY_FLEX, SWU_DISPLAY_NONE } swu_display_t;
```

---

### 2.5 Diagram Alur Satu Frame

```
swu_begin(ctx, w, h)
│
├── swu_div(ctx, "container")          ← flex_item_new + flex_item_add
│   │
│   ├── swu_css_flex_direction(el, SWU_FLEX_ROW)
│   ├── swu_css_padding(el, 8)
│   │
│   ├── swu_p(ctx, "text1", "Hello")   ← flex_item_new + self_sizing
│   └── swu_button(ctx, "btn1", "OK")  ← flex_item_new
│
└── swu_end(ctx)                        ← pop stack
│
swu_layout(ctx)                         ← flex_layout(root)
│
swu_render_backgrounds(ctx)             ← SDL_RenderFillRect per elemen
│
[mu_begin(mu)]
[mu_begin_window (ghost, fullscreen)]
│
├── overflow elemen → mu_begin_panel_ex → mu_end_panel
├── swu_place(ctx, "btn1")              ← mu_layout_set_next(mu, rect)
│   mu_button_ex(mu, "OK", 0, 0)       ← caller
│
[mu_end_window]
[mu_end(mu)]
│
swu_end_frame(ctx)                      ← cleanup flex tree
```

---

## 3. Tantangan dan Saran AI

### 3.1 Intrinsic Text Sizing (`height: auto`)

**Tantangan:**  
CSS menganggap `<p>` memiliki tinggi yang mengikuti konten teks. flex mendukung ini via
`flex_self_sizing` callback. Callback dipanggil saat layout pass dengan `size[0]` =
lebar tersedia. Kita perlu `ctx->text_width` dan `text_height` yang ada di dalam
`mu_Context` untuk menghitung jumlah baris.

Masalah: `flex_layout()` dipanggil di `swu_layout()`, tetapi `mu_Context` berada di
level SDL_webui. Callback harus bisa mengakses `mu_Context`.

**Saran:**  
Simpan pointer `mu_Context*` ke dalam `swu_context*` (sudah ada). Saat `swu_p` membuat
flex item, gunakan `flex_item_set_managed_ptr` untuk menyimpan sebuah shadow struct
`swu_elem_meta_t` yang mengandung: `mu_Context*, text*, text_align, color, overflow…`.
Callback `swu_p_self_sizer` mengambil `mu_Context*` dari `item->managed_ptr` dan
menghitung tinggi word-wrap.

```c
static void swu_p_self_sizer(struct flex_item *item, float size[2]) {
    swu_elem_meta_t *meta = flex_item_get_managed_ptr(item);
    int lines = count_wrapped_lines(meta->mu, meta->text, (int)size[0]);
    size[1] = lines * meta->mu->text_height(meta->mu->style->font);
}
```

---

### 3.2 Overflow dengan mu_begin_panel (Nested Container)

**Tantangan:**  
microui's `mu_begin_panel` menciptakan sub-container baru dengan scroll state sendiri.
Ini harus dipanggil **di dalam** `mu_begin_window`. Dalam arsitektur saat ini, ada satu
"ghost window" fullscreen. Semua panel ada di dalam window ini. Ini oke untuk satu level
scroll, tetapi scroll bersarang (panel di dalam panel) memerlukan perhatian ekstra
karena microui handle scroll target berdasarkan z-index dan hover-root.

**Saran:**  
Untuk Phase 3b, batasi `overflow: scroll` hanya satu level (tidak nested). Dokumentasikan
limitasi ini. Implementasi: sebelum memanggil widget anak di dalam elemen
yang `overflow != VISIBLE`, SDL_webui otomatis memanggil `mu_begin_panel_ex` dengan rect
dari flex, dan `mu_end_panel` setelah semua anak selesai.

---

### 3.3 Per-element Style vs Global mu_Style

**Tantangan:**  
microui memakai satu `mu_Style` global. CSS memiliki per-elemen color, dsb. Jika kita
patch `ctx->style->colors` sebelum setiap widget lalu restore, ini mahal dan rawan bug
(terutama jika widget memanggil widget lain secara rekursif, misalnya treenode → button).

**Saran:**  
Untuk warna background dan border, hindari mu_Style sama sekali. Gambar manual via
`SDL_RenderFillRect` (background) dan `mu_draw_box` (border) **sebelum** memanggil
widget microui. Untuk warna teks (`color`), override `ctx->style` secara lokal:

```c
mu_Color saved = ctx->style->colors[MU_COLOR_TEXT];
ctx->style->colors[MU_COLOR_TEXT] = meta->color;
mu_draw_control_text(ctx, text, rect, MU_COLOR_TEXT, opt);
ctx->style->colors[MU_COLOR_TEXT] = saved;
```

Ini aman selama tidak ada nested widget call di antara save dan restore.

---

### 3.4 Dua-Pass Layout vs Immediate Mode

**Tantangan:**  
CSS layout memerlukan dua pass: pertama hitung ukuran semua elemen, baru render.
Dalam model immediate-mode saat ini:
1. `swu_begin` → deklarasi elemen (flex tree dibangun)
2. `swu_layout` → flex menghitung semua rect
3. Render microui widgets

Ini sudah benar untuk kasus statis. Masalah muncul ketika ukuran elemen bergantung
pada kontennya dan konten bergantung pada ukuran (misalnya, `<p>` di dalam kontainer
yang `flex-grow: 1`), atau ketika scrollbar muncul dan mengubah lebar.

**Saran:**  
Untuk Phase 3b, terima keterbatasan ini sebagai "1-frame lag". Fix scrollbar-width
reflow sudah diimplementasi untuk kasus paling umum (lihat `render_text_block`
two-pass). Convergence dalam 2 frame adalah perilaku yang acceptable dan konsisten
dengan bagaimana browser lama (IE6) bekerja.

---

### 3.5 `display: none`

**Tantangan:**  
Jika `display: none`, elemen tidak boleh mengambil ruang di layout. flex tidak punya
`.display = none`. Solusi naif: set `width=0, height=0` — tapi ini masih menambahkan
item ke flex tree dan bisa mempengaruhi alignment.

**Saran:**  
Tambahkan flag `SWU_DISPLAY_NONE` ke shadow metadata. Saat `swu_layout()` dipanggil,
scan semua item; item yang `display=none`: `flex_item_set_width(0), height(0), margin(0)`.
Ini mengecilkan item ke nol tanpa menghapusnya dari tree (aman untuk immediate-mode
rebuild per frame). Alternatif lebih bersih: jangan tambahkan flex_item ke parent sama
sekali jika `display=none`, tapi ini memerlukan pengecekan at-declaration-time.

---

### 3.6 Stack Discipline — `swu_end()` Lupa Dipanggil

**Tantangan:**  
Programmer mungkin lupa memanggil `swu_end()` setelah `swu_div()`. Ini crash di
`flex_layout` karena tree tidak valid.

**Saran:**  
Tambahkan `SWU_DEBUG_ASSERT` di `swu_end_frame()` yang memvalidasi stack depth == 0.
Di debug build, log nama elemen yang belum di-close.

```c
#ifdef SWU_DEBUG
  if (ctx->stack_depth != 0)
    SDL_LogError(SDL_LOG_CATEGORY_APPLICATION,
                 "swu: unclosed element at depth %d (id=%s)",
                 ctx->stack_depth, ctx->stack[ctx->stack_depth-1].id);
#endif
```

---

### 3.7 CSS Tidak Memiliki Cascading di Phase 3b

**Tantangan:**  
CSS memiliki inheritance (misalnya `color` diwariskan ke semua anak). SDL_webui
immediate-mode tidak memiliki DOM tree aksesibel untuk cascade.

**Saran:**  
Phase 3b: **tidak ada cascading, tidak ada inheritance**. Setiap elemen hanya
membaca style-nya sendiri dari `swu_elem_meta_t`. Ini konsisten dengan microui.
Cascading adalah Phase 3c: saat SDL_webui membangun flex tree, ia bisa meneruskan
nilai shadow metadata dari parent ke child jika child tidak override.

---

### 3.8 Font Size untuk `<h1>`–`<h6>`

**Tantangan:**  
microui menggunakan satu `mu_Style.font` handle. Berbeda font size memerlukan
SDL_TTF multiple point size loads.

**Saran:**  
Phase 3b: `swu_h1` hingga `swu_h6` hanya menggunakan satu font (default). Dalam
shadow metadata, simpan `int font_scale` (1–6). Saat render, SDL_webui mengecek
apakah `ctx->ttf_fonts[scale]` tersedia (di-load manual oleh caller); jika tidak,
fall back ke default font. Sehingga font size adalah fitur opt-in.

---

## 4. Ringkasan Keputusan Arsitektur

| Keputusan | Detail |
|---|---|
| flex owns layout | Semua posisi dan ukuran container dikerjakan flex |
| microui owns widgets | Semua draw + interaksi via microui draw commands |
| SDL_webui owns metadata | Per-elemen color, overflow, text_align, display via shadow struct di `managed_ptr` |
| Satu `swu_end()` untuk semua container | Meniru HTML closing tag; konsisten dengan `swu_open/swu_close` saat ini |
| CSS naming 1:1 | `swu_css_PROPERTY` agar rwebview bisa langsung map CSS property name ke fungsi |
| HTML tag naming 1:1 | `swu_TAG` agar Nim/QuickJS di rwebview bisa generate panggilan SDL_webui dari DOM |
| Tidak ada cascading (Phase 3b) | Setiap elemen eksplisit. Cascading ditangguhkan ke Phase 3c |
| 1-frame overflow lag diterima | Konsisten dengan browser lama; fix two-pass sudah ada untuk scrollbar |
| SDL_TTF font sizes opt-in | Phase 3b pakai satu font; multi-size untuk Phase 3c |

---

## 5. File yang Akan Dibuat/Diubah di Phase 3b

```
libs/SDL_webui/
├── include/SDL3_webui/SDL_webui.h     UPDATE: tambah swu_TAG, swu_css_*, swu_elem_t, enums
├── src/SDL_webui.c                    UPDATE: implementasi semua fungsi baru
├── src/SDL_webui.exports              UPDATE: tambah semua simbol _swu_TAG, _swu_css_*
│
└── examples/
    └── demo_sdl_webui3b_sdl3/         BARU: demo Phase 3b menggunakan API baru
        ├── main.c                     BARU: gunakan swu_div/swu_p/swu_button dll
        └── build.bat                  BARU
```

Kedua file lama (`src/SDL_webui.c` dan `include/.../SDL_webui.h`) akan diupdate
in-place karena API baru adalah **superset** dari `swu_open/swu_close` yang lama.
`swu_open` dan `swu_close` bisa dialiaskan ke `swu_div` + `swu_end`.
