#include "logring.h"
#include <string.h>

void logring_init(logring *r, char *buf, size_t size) {
  r->buf = buf;
  r->size = size;
  r->start = r->end = 0;
}

static char at(const logring *r, uint32_t off) { return r->buf[off % r->size]; }

void logring_add(logring *r, const char *line) {
  size_t n = strlen(line);
  if (n > r->size - 1) { line += n - (r->size - 1); n = r->size - 1; }  // keep the tail of a huge line
  while (r->end + n + 1 - r->start > r->size) {  // make room: drop the oldest whole lines (before overwriting)
    while (at(r, r->start) != '\n') r->start++;
    r->start++;
  }
  for (size_t i = 0; i <= n; i++) r->buf[(r->end + i) % r->size] = i < n ? line[i] : '\n';
  r->end += n + 1;
}

uint32_t logring_read(const logring *r, uint32_t from, char *out, size_t max) {
  size_t n = 0;
  if (from < r->start || from > r->end) from = r->start;
  while (from < r->end) {
    char c = at(r, from);
    const char *s = c == '\n' ? "\\n" : c == '\\' ? "\\\\" : NULL;
    size_t need = s ? 2 : 1;
    if (n + need > max - 1) break;
    if (s) { out[n++] = s[0]; out[n++] = s[1]; } else out[n++] = c;
    from++;
  }
  out[n] = 0;
  return from;
}
