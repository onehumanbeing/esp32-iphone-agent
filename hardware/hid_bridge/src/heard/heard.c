// See heard.h.
#include "heard.h"
#include <stdio.h>
#include <string.h>

void heard_clear(heard_ring *r) { memset(r, 0, sizeof *r); }

void heard_add(heard_ring *r, uint32_t now_ms, const char *text, size_t n) {
  if (!n) return;
  if (n > HEARD_TEXT) {  // cut at a UTF-8 boundary: a character split by the cut goes entirely
    n = HEARD_TEXT;
    while (n && ((unsigned char)text[n] & 0xC0) == 0x80) n--;
  }
  unsigned i = r->next;
  r->ms[i] = now_ms;
  memcpy(r->text[i], text, n);
  r->text[i][n] = 0;
  r->next = (i + 1) % HEARD_LINES;
  if (r->count < HEARD_LINES) r->count++;
}

// s as a JSON string body into out (room cap); returns its length, or 0 if it does not fit.
static size_t escape(const char *s, char *out, size_t cap) {
  size_t o = 0;
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    char e[8];
    size_t k;
    if (c == '"' || c == '\\') e[0] = '\\', e[1] = (char)c, k = 2;
    else if (c < 0x20) k = (size_t)snprintf(e, sizeof e, "\\u%04x", c);
    else e[0] = (char)c, k = 1;
    if (o + k > cap) return 0;
    memcpy(out + o, e, k);
    o += k;
  }
  return o;
}

size_t heard_json(const heard_ring *r, uint32_t now_ms, bool app, char *out, size_t cap) {
  int n = snprintf(out, cap, "{\"app\":%d,\"lines\":[", app ? 1 : 0);
  if (n < 0 || (size_t)n + 3 > cap) return 0;
  size_t o = (size_t)n;
  bool first = true;
  for (unsigned k = 0; k < r->count; k++) {
    unsigned i = (r->next + HEARD_LINES - 1 - k) % HEARD_LINES;
    uint32_t ago = now_ms - r->ms[i];
    if (ago > HEARD_KEEP_MS) break;  // older ones are older still
    char head[40];
    int h = snprintf(head, sizeof head, "%s{\"ago\":%lu,\"t\":\"", first ? "" : ",", (unsigned long)ago);
    if (o + (size_t)h + 3 + 3 > cap) break;  // + `"}` + `]}`
    size_t room = cap - o - (size_t)h - 3 - 3;
    size_t e = escape(r->text[i], out + o + h, room);
    if (!e && r->text[i][0]) break;
    memcpy(out + o, head, (size_t)h);
    o += (size_t)h + e;
    memcpy(out + o, "\"}", 2);
    o += 2;
    first = false;
  }
  memcpy(out + o, "]}", 3);
  return o + 2;
}
