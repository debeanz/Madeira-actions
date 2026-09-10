/* xinput_ios.c — unix side of Madeira's XInput replacement.
 *
 * Wine's own xinput1_x.dll reads HID gamepads exposed by winebus.sys, and
 * winebus is force-disabled here because its winedevice host wedges on
 * iOS (patches/wine-rpcss-scm-bootstrap.patch). Instead build/xinput/
 * xinput.c ships an ARM64EC xinput1_x.dll that fetches controller state
 * from THIS table through a unix call, and the app (Gamepad.swift) fills
 * the table from GameController every frame. Registered by module name
 * in virtual_ios.c load_builtin_unixlib ("xinput").
 *
 * Deliberately free of Wine headers so it also compiles for the
 * simulator runtime. */

#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <pthread.h>
#include <unistd.h>

#include "../xinput/madeira_xinput.h"

typedef int NTSTATUS;
#define STATUS_SUCCESS            ((NTSTATUS)0x00000000)
#define STATUS_INVALID_PARAMETER  ((NTSTATUS)0xC000000D)

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static struct madeira_xinput_state g_pads[MADEIRA_XINPUT_MAX_PADS];
static struct { uint16_t low, high; int dirty; } g_rumble[MADEIRA_XINPUT_MAX_PADS];
static int g_first_query_logged;

/* ---- app side ---------------------------------------------------------- */

void madeira_xinput_set_state(uint32_t index, const struct madeira_xinput_state *state)
{
    if (index >= MADEIRA_XINPUT_MAX_PADS || !state) return;
    pthread_mutex_lock(&g_lock);
    {
        struct madeira_xinput_state *p = &g_pads[index];
        /* Compare everything but the packet number; a game polling at
         * 1000 Hz must see the packet advance only on real changes. */
        int changed = p->connected != state->connected || p->buttons != state->buttons ||
                      p->left_trigger != state->left_trigger || p->right_trigger != state->right_trigger ||
                      p->lx != state->lx || p->ly != state->ly || p->rx != state->rx || p->ry != state->ry;
        if (changed)
        {
            uint32_t packet = p->packet + 1;
            *p = *state;
            p->packet = packet ? packet : 1;
        }
    }
    pthread_mutex_unlock(&g_lock);
}

void madeira_xinput_set_connected(uint32_t index, int connected)
{
    if (index >= MADEIRA_XINPUT_MAX_PADS) return;
    pthread_mutex_lock(&g_lock);
    {
        struct madeira_xinput_state *p = &g_pads[index];
        if ((p->connected != 0) != (connected != 0))
        {
            uint32_t packet = p->packet + 1;
            memset(p, 0, sizeof(*p));
            p->connected = connected ? 1 : 0;
            p->packet = packet ? packet : 1;
            dprintf(2, "[xinput] pad %u %s\n", index, connected ? "connected" : "disconnected");
        }
    }
    pthread_mutex_unlock(&g_lock);
}

int madeira_xinput_get_rumble(uint32_t index, uint16_t *low, uint16_t *high)
{
    int changed = 0;
    if (index >= MADEIRA_XINPUT_MAX_PADS) return 0;
    pthread_mutex_lock(&g_lock);
    if (g_rumble[index].dirty)
    {
        if (low) *low = g_rumble[index].low;
        if (high) *high = g_rumble[index].high;
        g_rumble[index].dirty = 0;
        changed = 1;
    }
    pthread_mutex_unlock(&g_lock);
    return changed;
}

/* ---- PE side (unix calls) ---------------------------------------------- */

static NTSTATUS xinput_get_state(void *args)
{
    struct madeira_xinput_get_state_args *a = args;
    if (!a || a->index >= MADEIRA_XINPUT_MAX_PADS || !a->state) return STATUS_INVALID_PARAMETER;
    pthread_mutex_lock(&g_lock);
    *a->state = g_pads[a->index];
    pthread_mutex_unlock(&g_lock);
    if (!g_first_query_logged)
    {
        g_first_query_logged = 1;
        dprintf(2, "[xinput] first XInputGetState from a game (pad %u %s)\n",
                a->index, a->state->connected ? "connected" : "not connected");
    }
    return STATUS_SUCCESS;
}

static NTSTATUS xinput_set_rumble(void *args)
{
    struct madeira_xinput_set_rumble_args *a = args;
    if (!a || a->index >= MADEIRA_XINPUT_MAX_PADS) return STATUS_INVALID_PARAMETER;
    pthread_mutex_lock(&g_lock);
    if (g_rumble[a->index].low != a->low || g_rumble[a->index].high != a->high)
    {
        g_rumble[a->index].low = a->low;
        g_rumble[a->index].high = a->high;
        g_rumble[a->index].dirty = 1;
    }
    pthread_mutex_unlock(&g_lock);
    return STATUS_SUCCESS;
}

/* Indexed by enum madeira_xinput_call. Handed to the PE side as the
 * unixlib handle; __wine_unix_call_dispatcher does funcs[code](args). */
const void *madeira_xinput_unix_call_funcs[] = {
    xinput_get_state,     /* MADEIRA_XINPUT_CALL_GET_STATE */
    xinput_set_rumble,    /* MADEIRA_XINPUT_CALL_SET_RUMBLE */
};
