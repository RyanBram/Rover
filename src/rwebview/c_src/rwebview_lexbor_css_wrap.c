/*
 * rwebview_lexbor_css_wrap.c
 *
 * Pure C string-based CSS @font-face extraction for rwebview.
 * Extracts font-family + src url() pairs from CSS text.
 * No dependency on Lexbor CSS module (which may not be in the static lib).
 */

#include <stdlib.h>
#include <string.h>
#include <ctype.h>

/* ---- Dynamic buffer ---------------------------------------------------- */

typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} rw_buf_t;

static int rw_buf_reserve(rw_buf_t *b, size_t need)
{
    if (need <= b->cap) return 1;
    size_t ncap = (b->cap == 0) ? 256 : b->cap;
    while (ncap < need) ncap *= 2;
    char *p = (char *) realloc(b->buf, ncap);
    if (p == NULL) return 0;
    b->buf = p;
    b->cap = ncap;
    return 1;
}

static int rw_buf_append_n(rw_buf_t *b, const char *s, size_t n)
{
    if (n == 0) return 1;
    if (!rw_buf_reserve(b, b->len + n + 1)) return 0;
    memcpy(b->buf + b->len, s, n);
    b->len += n;
    b->buf[b->len] = '\0';
    return 1;
}

static int rw_buf_append(rw_buf_t *b, const char *s)
{
    return rw_buf_append_n(b, s, strlen(s));
}

/* ---- Helpers ----------------------------------------------------------- */

static void rw_unquote_inplace(char *s)
{
    size_t n;
    if (s == NULL) return;
    n = strlen(s);
    if (n >= 2) {
        if ((s[0] == '"' && s[n - 1] == '"') ||
            (s[0] == '\'' && s[n - 1] == '\''))
        {
            memmove(s, s + 1, n - 2);
            s[n - 2] = '\0';
        }
    }
}

/* Case-insensitive prefix match (portable, no _strnicmp dependency). */
static int rw_strnicmp(const char *a, const char *b, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        int ca = tolower((unsigned char) a[i]);
        int cb = tolower((unsigned char) b[i]);
        if (ca != cb) return ca - cb;
        if (ca == 0) return 0;
    }
    return 0;
}

/* Skip whitespace, return pointer past it. */
static const char *rw_skip_ws(const char *p)
{
    while (*p && isspace((unsigned char) *p)) p++;
    return p;
}

/* Skip a CSS comment (if at "/*"), return pointer past it. */
static const char *rw_skip_comment(const char *p)
{
    if (p[0] == '/' && p[1] == '*') {
        p += 2;
        while (*p) {
            if (p[0] == '*' && p[1] == '/') return p + 2;
            p++;
        }
    }
    return p;
}

/* Skip whitespace and comments. */
static const char *rw_skip_ws_comments(const char *p)
{
    for (;;) {
        const char *prev = p;
        p = rw_skip_ws(p);
        if (p[0] == '/' && p[1] == '*') {
            p = rw_skip_comment(p);
            continue;
        }
        if (p == prev) break;
    }
    return p;
}

/* Find matching '}' for an opening '{', respecting nesting. */
static const char *rw_find_block_end(const char *p)
{
    int depth = 1;
    while (*p && depth > 0) {
        if (*p == '{') depth++;
        else if (*p == '}') depth--;
        if (depth > 0) p++;
    }
    return p;
}

/* Extract a CSS declaration value by property name from a block body.
 * E.g. from "font-family: 'Foo'; src: url(bar.ttf);" extract "Foo" for "font-family".
 * Returns 1 on success. */
static int rw_extract_decl_value(const char *block, size_t block_len,
                                 const char *prop, char *out, size_t out_sz)
{
    size_t prop_len = strlen(prop);
    const char *end = block + block_len;
    const char *p = block;

    while (p < end) {
        p = rw_skip_ws_comments(p);
        if (p >= end) break;

        /* Find the colon for this declaration */
        const char *colon = NULL;
        const char *scan = p;
        while (scan < end && *scan != ':' && *scan != ';' && *scan != '}') scan++;
        if (scan >= end || *scan != ':') {
            /* Skip to next semicolon or end */
            while (p < end && *p != ';') p++;
            if (p < end) p++;
            continue;
        }
        colon = scan;

        /* Check if property name matches */
        const char *key_start = p;
        const char *key_end = colon;
        while (key_end > key_start && isspace((unsigned char) *(key_end - 1))) key_end--;
        while (key_start < key_end && isspace((unsigned char) *key_start)) key_start++;

        int match = ((size_t)(key_end - key_start) == prop_len &&
                     rw_strnicmp(key_start, prop, prop_len) == 0);

        /* Find semicolon (value end) */
        const char *val_start = colon + 1;
        const char *semi = val_start;
        while (semi < end && *semi != ';' && *semi != '}') semi++;

        if (match) {
            const char *vs = val_start;
            const char *ve = semi;
            while (vs < ve && isspace((unsigned char) *vs)) vs++;
            while (ve > vs && isspace((unsigned char) *(ve - 1))) ve--;
            size_t n = (size_t)(ve - vs);
            if (n >= out_sz) n = out_sz - 1;
            memcpy(out, vs, n);
            out[n] = '\0';
            return 1;
        }

        p = (semi < end) ? semi + 1 : end;
    }
    return 0;
}

/* Extract first url() from a CSS src value. */
static int rw_extract_first_url(const char *src_value, char *out, size_t out_size)
{
    const char *u;
    if (src_value == NULL || out == NULL || out_size == 0) return 0;

    u = src_value;
    while (*u) {
        if ((u[0] == 'u' || u[0] == 'U') &&
            (u[1] == 'r' || u[1] == 'R') &&
            (u[2] == 'l' || u[2] == 'L') &&
            u[3] == '(')
        {
            const char *open = u + 4;
            while (*open && isspace((unsigned char) *open)) open++;
            const char *close = strchr(open, ')');
            if (!close) return 0;

            while (close > open && isspace((unsigned char) *(close - 1))) close--;
            size_t n = (size_t)(close - open);
            if (n >= out_size) n = out_size - 1;
            memcpy(out, open, n);
            out[n] = '\0';
            rw_unquote_inplace(out);
            return (out[0] != '\0');
        }
        u++;
    }
    return 0;
}

/* ---- Main extraction --------------------------------------------------- */

/*
 * Scan CSS text for @font-face blocks and extract font-family + src url().
 * Output format: one line per match, "family\turl\n".
 * Returns heap-allocated string; caller must call rw_lxb_free().
 */
const char *rw_lxb_extract_font_faces(const char *css, size_t css_len, size_t *out_len)
{
    rw_buf_t out = {0};
    const char *ret = NULL;
    const char *p;
    const char *end;

    if (out_len) *out_len = 0;
    if (css == NULL || css_len == 0) return NULL;

    p = css;
    end = css + css_len;

    while (p < end) {
        p = rw_skip_ws_comments(p);
        if (p >= end) break;

        /* Look for @font-face */
        if (*p == '@') {
            if (p + 10 <= end && rw_strnicmp(p + 1, "font-face", 9) == 0 &&
                (isspace((unsigned char) p[10]) || p[10] == '{'))
            {
                /* Found @font-face — find the block { ... } */
                const char *brace = p + 10;
                while (brace < end && *brace != '{') brace++;
                if (brace >= end) break;

                const char *body = brace + 1;
                const char *block_end = rw_find_block_end(body);
                size_t body_len = (size_t)(block_end - body);

                char family[256] = {0};
                char src_raw[1024] = {0};
                char url[1024] = {0};

                if (rw_extract_decl_value(body, body_len, "font-family", family, sizeof(family)) &&
                    rw_extract_decl_value(body, body_len, "src", src_raw, sizeof(src_raw)) &&
                    rw_extract_first_url(src_raw, url, sizeof(url)))
                {
                    rw_unquote_inplace(family);
                    if (family[0] != '\0' && url[0] != '\0') {
                        rw_buf_append(&out, family);
                        rw_buf_append(&out, "\t");
                        rw_buf_append(&out, url);
                        rw_buf_append(&out, "\n");
                    }
                }

                p = (*block_end == '}') ? block_end + 1 : block_end;
                continue;
            }

            /* Skip other @-rules with blocks */
            const char *scan = p + 1;
            while (scan < end && *scan != '{' && *scan != ';') scan++;
            if (scan < end && *scan == '{') {
                const char *body = scan + 1;
                const char *block_end = rw_find_block_end(body);
                p = (*block_end == '}') ? block_end + 1 : block_end;
            } else {
                p = (scan < end) ? scan + 1 : end;
            }
            continue;
        }

        /* Skip regular rules */
        const char *scan = p;
        while (scan < end && *scan != '{' && *scan != ';') scan++;
        if (scan < end && *scan == '{') {
            const char *body = scan + 1;
            const char *block_end = rw_find_block_end(body);
            p = (*block_end == '}') ? block_end + 1 : block_end;
        } else {
            p = (scan < end) ? scan + 1 : end;
        }
    }

    if (out.len == 0) {
        free(out.buf);
        return NULL;
    }

    ret = out.buf;
    if (out_len) *out_len = out.len;
    return ret;
}

void rw_lxb_free(void *p)
{
    free(p);
}
