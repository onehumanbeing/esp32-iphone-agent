// GOP buffer (every access unit since the latest IDR) and the BLE video chunker.
// Plain C with caller-provided memory so it can be unit-tested on the host.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// video notify flags (docs/ble-protocol.md)
// VF_RESUME: the first AU after a reconnect that goes on from the app's last one (`hello <token> at <ts>`).
enum { VF_START = 1, VF_END = 2, VF_IDR = 4, VF_CONFIG = 8, VF_BENCH = 16, VF_SNAP = 32, VF_RESUME = 64 };
#define VCHUNK_HDR 3  // seq u16 LE + flags u8
#define GOP_CFG_MAX 512

typedef struct {
  uint32_t off, len, ts;
  bool idr;
} gop_au;

typedef struct {
  uint8_t *arena;
  size_t cap, used;
  gop_au *aus;
  int n, max;
  uint8_t cfg[GOP_CFG_MAX];  // SPS+PPS, Annex-B
  size_t cfg_len;
  uint32_t cfg_ts;
  bool wait_idr;    // start, or an IDR too big for the buffer: drop until the next IDR
  bool frozen;      // full: the GOP stays decodable up to here, newer AUs are dropped until the next IDR
  uint32_t gen;     // bumps whenever the buffer restarts
  uint32_t overflows;
} gop_buf;

void gop_init(gop_buf *g, uint8_t *arena, size_t cap, gop_au *aus, int max);
void gop_set_config(gop_buf *g, const uint8_t *annexb, size_t len, uint32_t ts);
// Appends one Annex-B access unit. Returns its index, or -1 if it was dropped.
int gop_push(gop_buf *g, const uint8_t *annexb, size_t len, bool idr, uint32_t ts);
// Appends without the IDR rules (a plain AU list, e.g. the AUs after a frozen GOP). -1 if full.
int gop_append(gop_buf *g, const uint8_t *annexb, size_t len, bool idr, uint32_t ts);
// Empties the list, same generation.
void gop_clear(gop_buf *g);
int gop_find(const gop_buf *g, uint32_t ts);  // the last AU with this timestamp, -1 if none
void gop_drop_front(gop_buf *g, int k);       // forget the oldest k AUs (a plain AU list, e.g. the tail)
// True if the Annex-B data contains an IDR slice (NAL type 5).
bool annexb_has_idr(const uint8_t *p, size_t len);
// Rewrites AVCC (4-byte big-endian length prefixes) in place into Annex-B start codes.
// Returns false if the lengths do not tile the buffer exactly.
bool avcc_to_annexb(uint8_t *p, size_t len);

// Splits one access unit into notifies: [seq u16 LE][flags][payload], the START chunk
// carrying a u32 LE timestamp before the data.
typedef struct {
  const uint8_t *data;
  size_t len, pos;
  uint32_t ts;
  uint8_t flags;
  bool started;
} vchunk;

void vchunk_begin(vchunk *c, const uint8_t *data, size_t len, uint8_t flags, uint32_t ts);
// Writes the next notify into out (room for VCHUNK_HDR + max_payload bytes); 0 when done.
size_t vchunk_next(vchunk *c, uint8_t *out, size_t max_payload, uint16_t seq);

#ifdef __cplusplus
}
#endif
