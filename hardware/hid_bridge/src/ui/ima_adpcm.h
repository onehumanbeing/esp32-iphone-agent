#pragma once
// IMA ADPCM, 4 bits a sample (the StopWatch's voice to the app: 16 kHz is 8 KB/s, which BLE carries). Two samples
// a byte, the first in the low nibble. Each chunk carries the state it starts from, so a lost chunk loses only itself.
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int16_t pred;
  uint8_t index;  // 0-88
} ima_state;

size_t ima_encode(ima_state *s, const int16_t *pcm, size_t n, uint8_t *out);  // n even; returns n / 2 bytes
void ima_decode(ima_state *s, const uint8_t *in, size_t bytes, int16_t *out);  // 2 * bytes samples

#ifdef __cplusplus
}
#endif
