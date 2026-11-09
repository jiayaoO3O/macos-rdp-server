#ifndef RDP_DIRTY_TILES_H
#define RDP_DIRTY_TILES_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
static inline int rdp_tile_changed(const uint8_t *current, const uint8_t *previous,
                                   uint32_t stride_pixels, uint32_t x, uint32_t y,
                                   uint32_t width, uint32_t height) {
 if (!previous) return 1;
 for (uint32_t row=0;row<height;row++) {
  size_t offset=((size_t)(y+row)*stride_pixels+x)*4;
  if (memcmp(current+offset,previous+offset,(size_t)width*4)!=0) return 1;
 }
 return 0;
}
#endif
