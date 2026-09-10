/* madeira_xinput.h — controller state shared between three sides:
 *
 *   app (Swift, GameController)  -->  unix table (xinput_ios.c)  -->  PE xinput1_x.dll
 *
 * All three run in the ONE Mach process, so the PE side reaches the unix
 * table through a Wine unix call and the app writes it directly. Plain C
 * only: this header is included by the Swift bridging header, by the
 * ntdll unix build and by the ARM64EC PE build.
 */
#ifndef MADEIRA_XINPUT_H
#define MADEIRA_XINPUT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MADEIRA_XINPUT_MAX_PADS 4

/* Field for field the XINPUT_GAMEPAD layout, preceded by connection and
 * packet number. Buttons use the XINPUT_GAMEPAD_* bits including the
 * undocumented guide bit 0x0400 (reported only through XInputGetStateEx). */
struct madeira_xinput_state {
    uint32_t connected;
    uint32_t packet;              /* bumped on every change */
    uint16_t buttons;
    uint8_t  left_trigger;
    uint8_t  right_trigger;
    int16_t  lx, ly, rx, ry;      /* -32768..32767, up/right positive */
};

/* Unix-call codes: PE side -> unix table. `args` points at the struct. */
enum madeira_xinput_call {
    MADEIRA_XINPUT_CALL_GET_STATE = 0,
    MADEIRA_XINPUT_CALL_SET_RUMBLE = 1,
    MADEIRA_XINPUT_CALL_COUNT
};

struct madeira_xinput_get_state_args {
    uint32_t index;
    uint32_t pad_;
    struct madeira_xinput_state *state;   /* same address space: written directly */
};

struct madeira_xinput_set_rumble_args {
    uint32_t index;
    uint16_t low;                 /* left / low-frequency motor, 0..65535 */
    uint16_t high;                /* right / high-frequency motor */
};

/* App side (Swift via the bridging header). All thread-safe. */
void madeira_xinput_set_state(uint32_t index, const struct madeira_xinput_state *state);
void madeira_xinput_set_connected(uint32_t index, int connected);
/* Returns 1 and the latest motor speeds if a game changed them since the
 * previous call, else 0. */
int  madeira_xinput_get_rumble(uint32_t index, uint16_t *low, uint16_t *high);

#ifdef __cplusplus
}
#endif

#endif
