#ifndef RDP_FRAME_GENERATION_H
#define RDP_FRAME_GENERATION_H

#include <stdint.h>

static inline int rdp_frame_is_new(uint64_t generation, uint64_t frame_id,
                                   uint64_t previous_generation, uint64_t previous_frame_id) {
 return generation > previous_generation ||
        (generation == previous_generation && frame_id > previous_frame_id);
}

#endif
