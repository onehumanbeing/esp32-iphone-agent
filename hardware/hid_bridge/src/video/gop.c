// GOP buffer and BLE video chunker, see gop.h.
#include "gop.h"
#include <string.h>

void gop_init(gop_buf *g, uint8_t *arena, size_t cap, gop_au *aus, int max) {
  memset(g, 0, sizeof *g);
  g->arena = arena;
  g->cap = cap;
  g->aus = aus;
  g->max = max;
  g->wait_idr = true;
}

void gop_set_config(gop_buf *g, const uint8_t *annexb, size_t len, uint32_t ts) {
  if (len > GOP_CFG_MAX) len = 0;  // never seen in practice; treat as missing
  memcpy(g->cfg, annexb, len);
  g->cfg_len = len;
  g->cfg_ts = ts;
}

static void restart(gop_buf *g) {
  g->used = 0;
  g->n = 0;
  g->gen++;
}

int gop_append(gop_buf *g, const uint8_t *annexb, size_t len, bool idr, uint32_t ts) {
  if (g->used + len > g->cap || g->n == g->max) return -1;
  memcpy(g->arena + g->used, annexb, len);
  g->aus[g->n] = (gop_au){(uint32_t)g->used, (uint32_t)len, ts, idr};
  g->used += len;
  return g->n++;
}

void gop_clear(gop_buf *g) {
  g->used = 0;
  g->n = 0;
}

int gop_find(const gop_buf *g, uint32_t ts) {
  for (int i = g->n - 1; i >= 0; i--)
    if (g->aus[i].ts == ts) return i;
  return -1;
}

static bool gop_room_after(const gop_buf *g, int k, size_t len) {  // room for len once the oldest k AUs go
  size_t used = k < g->n ? g->used - g->aus[k].off : 0;
  return used + len <= g->cap && g->n - k < g->max;
}

int gop_trim_sent(gop_buf *g, int sent, int keep, size_t len) {
  if (sent > g->n) sent = g->n;
  int k = sent > keep ? sent - keep : 0;
  while (k < sent && !gop_room_after(g, k, len)) k++;
  if (k == 0 || !gop_room_after(g, k, len)) return 0;
  gop_drop_front(g, k);
  return k;
}

void gop_drop_front(gop_buf *g, int k) {
  if (k <= 0) return;
  if (k >= g->n) return gop_clear(g);
  uint32_t off = g->aus[k].off;
  memmove(g->arena, g->arena + off, g->used - off);
  memmove(g->aus, g->aus + k, (size_t)(g->n - k) * sizeof *g->aus);
  g->n -= k;
  g->used -= off;
  for (int i = 0; i < g->n; i++) g->aus[i].off -= off;
}

int gop_push(gop_buf *g, const uint8_t *annexb, size_t len, bool idr, uint32_t ts) {
  if (idr) {
    restart(g);
    g->wait_idr = false;
    g->frozen = false;
  } else if (g->wait_idr || g->frozen) {
    return -1;
  }
  int i = gop_append(g, annexb, len, idr, ts);
  if (i < 0) {
    // Full. Keep what we have: it still decodes, and iOS 26 may send no IDR for the rest of the mirroring
    // session, so restarting would leave nothing to show at all (#25). Only an IDR too big leaves it empty.
    if (g->n) g->frozen = true;
    else g->wait_idr = true;
    g->overflows++;
  }
  return i;
}

bool annexb_has_idr(const uint8_t *p, size_t len) {
  for (size_t i = 0; i + 4 < len; i++)
    if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 1 && (p[i + 3] & 0x1f) == 5) return true;
  return false;
}

bool avcc_to_annexb(uint8_t *p, size_t len) {
  size_t i = 0;
  while (i + 4 <= len) {
    uint32_t n = (uint32_t)p[i] << 24 | (uint32_t)p[i + 1] << 16 | (uint32_t)p[i + 2] << 8 | p[i + 3];
    if (n > len - i - 4) return false;
    p[i] = p[i + 1] = p[i + 2] = 0;
    p[i + 3] = 1;
    i += 4 + n;
  }
  return i == len;
}

void vchunk_begin(vchunk *c, const uint8_t *data, size_t len, uint8_t flags, uint32_t ts) {
  *c = (vchunk){data, len, 0, ts, (uint8_t)(flags & ~(VF_START | VF_END)), false};
}

size_t vchunk_next(vchunk *c, uint8_t *out, size_t max_payload, uint16_t seq) {
  if (max_payload < 5 || (c->started && c->pos >= c->len)) return 0;
  uint8_t flags = c->flags;
  size_t o = VCHUNK_HDR, room = max_payload;
  if (!c->started) {
    flags |= VF_START;
    for (int i = 0; i < 4; i++) out[o++] = (uint8_t)(c->ts >> (8 * i));
    room -= 4;
    c->started = true;
  }
  size_t n = c->len - c->pos < room ? c->len - c->pos : room;
  memcpy(out + o, c->data + c->pos, n);
  c->pos += n;
  if (c->pos >= c->len) flags |= VF_END;
  out[0] = (uint8_t)seq;
  out[1] = (uint8_t)(seq >> 8);
  out[2] = flags;
  return o + n;
}
