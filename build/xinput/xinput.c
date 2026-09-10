/* xinput.c — Madeira's replacement xinput1_1/1_2/1_3/1_4/9_1_0.dll (ARM64EC).
 *
 * Wine's built-in XInput needs a HID gamepad from winebus.sys, which cannot
 * run on iOS. This DLL exports the same API and instead asks the app for
 * controller state through a Wine unix call into build/ntdll-unix/
 * xinput_ios.c, where Gamepad.swift publishes what GameController reports.
 * Games therefore see a normal Xbox 360 pad: analog sticks, triggers,
 * button bitmask, packet numbers, capabilities, and rumble requests flow
 * back to the phone's haptics.
 *
 * No Wine headers: every XInput structure is declared here so the DLL
 * builds with a stock llvm-mingw ARM64EC toolchain.
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include "madeira_xinput.h"

/* ---- XInput ABI ---------------------------------------------------------- */

#define XUSER_MAX_COUNT              4
#define XINPUT_FLAG_GAMEPAD          0x00000001
#define XINPUT_DEVTYPE_GAMEPAD       0x01
#define XINPUT_DEVSUBTYPE_GAMEPAD    0x01
#define XINPUT_CAPS_FFB_SUPPORTED    0x0001
#define XINPUT_GAMEPAD_GUIDE         0x0400
#define BATTERY_DEVTYPE_GAMEPAD      0x00
#define BATTERY_TYPE_WIRED           0x01
#define BATTERY_LEVEL_FULL           0x03
#ifndef ERROR_DEVICE_NOT_CONNECTED
#define ERROR_DEVICE_NOT_CONNECTED   1167
#endif
#ifndef ERROR_EMPTY
#define ERROR_EMPTY                  4306
#endif

typedef struct { WORD wButtons; BYTE bLeftTrigger; BYTE bRightTrigger;
                 SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY; } XINPUT_GAMEPAD;
typedef struct { DWORD dwPacketNumber; XINPUT_GAMEPAD Gamepad; } XINPUT_STATE;
typedef struct { WORD wLeftMotorSpeed, wRightMotorSpeed; } XINPUT_VIBRATION;
typedef struct { BYTE Type, SubType; WORD Flags; XINPUT_GAMEPAD Gamepad;
                 XINPUT_VIBRATION Vibration; } XINPUT_CAPABILITIES;
typedef struct { XINPUT_CAPABILITIES Capabilities; WORD VendorId, ProductId, ProductVersion;
                 WORD unk1; DWORD unk2; } XINPUT_CAPABILITIES_EX;
typedef struct { BYTE BatteryType, BatteryLevel; } XINPUT_BATTERY_INFORMATION;
typedef struct { WORD VirtualKey; WCHAR Unicode; WORD Flags; BYTE UserIndex, HidCode; } XINPUT_KEYSTROKE;

/* ---- unix call bootstrap ------------------------------------------------- */

typedef LONG NTSTATUS;
typedef NTSTATUS (*unix_call_fn)(UINT64 handle, unsigned int code, void *args);
typedef NTSTATUS (WINAPI *nt_qvm_fn)(HANDLE process, PVOID addr, int info_class,
                                     PVOID buffer, SIZE_T len, SIZE_T *res_len);
#define MEMORY_WINE_LOAD_UNIX_LIB 1000   /* MemoryWineLoadUnixLib, wine include/winternl.h */

extern IMAGE_DOS_HEADER __ImageBase;

static UINT64 g_unix_handle;
/* Not static: the naked thunk below references it by symbol name. */
unix_call_fn madeira_xinput_unix_dispatcher;
static volatile LONG g_init_state;       /* 0 untried, 1 ok, -1 failed */
static BOOL g_enabled = TRUE;            /* XInputEnable */

/* ntdll exports no callable unix-call FUNCTION, only the dispatcher
 * pointer variables (`@ extern -private __wine_unix_call_dispatcher` and
 * the arm64ec twin in ntdll.spec). The arm64ec slot holds the native
 * ARM64 unix dispatcher, which is what ARM64EC code must use.
 *
 * It has to be reached with a plain branch, exactly as winecrt0's
 * __wine_unix_call_arm64ec does: an ordinary C indirect call in ARM64EC
 * code goes through __os_arm64x_check_icall, which classifies a target
 * outside any PE image as x64 code and would run the unix dispatcher
 * under the emulator. */
__attribute__((naked)) static NTSTATUS unix_call(UINT64 handle, unsigned int code, void *args)
{
    __asm__(
        "adrp x16, madeira_xinput_unix_dispatcher\n\t"
        "ldr  x16, [x16, :lo12:madeira_xinput_unix_dispatcher]\n\t"
        "br   x16\n\t");
}

static BOOL init_unix(void)
{
    HMODULE ntdll;
    nt_qvm_fn qvm;
    unix_call_fn *slot;
    NTSTATUS st;

    if (g_init_state == 1) return TRUE;
    if (g_init_state == -1) return FALSE;

    ntdll = GetModuleHandleW(L"ntdll.dll");
    qvm = ntdll ? (nt_qvm_fn)GetProcAddress(ntdll, "NtQueryVirtualMemory") : NULL;
    slot = ntdll ? (unix_call_fn *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher_arm64ec") : NULL;
    if (!slot && ntdll) slot = (unix_call_fn *)GetProcAddress(ntdll, "__wine_unix_call_dispatcher");
    if (!qvm || !slot || !*slot)
    {
        OutputDebugStringA("madeira xinput: ntdll unix-call dispatcher missing\n");
        g_init_state = -1;
        return FALSE;
    }
    madeira_xinput_unix_dispatcher = *slot;
    /* ntdll resolves the module to the statically linked table by the
     * name in our export directory ("xinput..."), see virtual_ios.c. */
    st = qvm(GetCurrentProcess(), &__ImageBase, MEMORY_WINE_LOAD_UNIX_LIB,
             &g_unix_handle, sizeof(g_unix_handle), NULL);
    if (st != 0 || !g_unix_handle)
    {
        OutputDebugStringA("madeira xinput: MemoryWineLoadUnixLib failed\n");
        g_init_state = -1;
        return FALSE;
    }
    g_init_state = 1;
    return TRUE;
}

/* ERROR_SUCCESS with the pad filled in, or ERROR_DEVICE_NOT_CONNECTED. */
static DWORD fetch(DWORD index, struct madeira_xinput_state *s)
{
    struct madeira_xinput_get_state_args a;
    if (index >= XUSER_MAX_COUNT) return ERROR_BAD_ARGUMENTS;
    if (!init_unix()) return ERROR_DEVICE_NOT_CONNECTED;
    a.index = index;
    a.pad_ = 0;
    a.state = s;
    if (unix_call(g_unix_handle, MADEIRA_XINPUT_CALL_GET_STATE, &a) != 0) return ERROR_DEVICE_NOT_CONNECTED;
    if (!s->connected) return ERROR_DEVICE_NOT_CONNECTED;
    return ERROR_SUCCESS;
}

static void fill_state(XINPUT_STATE *out, const struct madeira_xinput_state *s, BOOL with_guide)
{
    out->dwPacketNumber = s->packet;
    if (!g_enabled)
    {
        /* XInputEnable(FALSE): report neutral input but keep the pad. */
        memset(&out->Gamepad, 0, sizeof(out->Gamepad));
        return;
    }
    out->Gamepad.wButtons = with_guide ? s->buttons : (WORD)(s->buttons & ~XINPUT_GAMEPAD_GUIDE);
    out->Gamepad.bLeftTrigger = s->left_trigger;
    out->Gamepad.bRightTrigger = s->right_trigger;
    out->Gamepad.sThumbLX = s->lx;
    out->Gamepad.sThumbLY = s->ly;
    out->Gamepad.sThumbRX = s->rx;
    out->Gamepad.sThumbRY = s->ry;
}

/* ---- exports -------------------------------------------------------------- */

DWORD WINAPI XInputGetState(DWORD index, XINPUT_STATE *state)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if (!state) return ERROR_BAD_ARGUMENTS;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    fill_state(state, &s, FALSE);
    return ERROR_SUCCESS;
}

/* Ordinal 100: same as XInputGetState but reports the guide button. */
DWORD WINAPI XInputGetStateEx(DWORD index, XINPUT_STATE *state)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if (!state) return ERROR_BAD_ARGUMENTS;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    fill_state(state, &s, TRUE);
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputSetState(DWORD index, XINPUT_VIBRATION *vibration)
{
    struct madeira_xinput_state s;
    struct madeira_xinput_set_rumble_args a;
    DWORD ret;
    if (!vibration) return ERROR_BAD_ARGUMENTS;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    a.index = index;
    a.low = vibration->wLeftMotorSpeed;
    a.high = vibration->wRightMotorSpeed;
    unix_call(g_unix_handle, MADEIRA_XINPUT_CALL_SET_RUMBLE, &a);
    return ERROR_SUCCESS;
}

static void fill_caps(XINPUT_CAPABILITIES *caps)
{
    memset(caps, 0, sizeof(*caps));
    caps->Type = XINPUT_DEVTYPE_GAMEPAD;
    caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
    caps->Flags = XINPUT_CAPS_FFB_SUPPORTED;
    /* Everything a wired Xbox 360 pad reports: all buttons, full triggers
     * and thumbsticks (resolution masks as the real driver returns them). */
    caps->Gamepad.wButtons = 0xF3FF;
    caps->Gamepad.bLeftTrigger = 0xFF;
    caps->Gamepad.bRightTrigger = 0xFF;
    caps->Gamepad.sThumbLX = (SHORT)0xFFC0;
    caps->Gamepad.sThumbLY = (SHORT)0xFFC0;
    caps->Gamepad.sThumbRX = (SHORT)0xFFC0;
    caps->Gamepad.sThumbRY = (SHORT)0xFFC0;
    caps->Vibration.wLeftMotorSpeed = 0xFF;
    caps->Vibration.wRightMotorSpeed = 0xFF;
}

DWORD WINAPI XInputGetCapabilities(DWORD index, DWORD flags, XINPUT_CAPABILITIES *caps)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if (!caps) return ERROR_BAD_ARGUMENTS;
    if (flags & ~XINPUT_FLAG_GAMEPAD) return ERROR_BAD_ARGUMENTS;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    fill_caps(caps);
    return ERROR_SUCCESS;
}

/* Ordinal 108. Vendor/product of the Microsoft Xbox 360 wired controller
 * so engines that key their glyph set on the ids pick Xbox prompts. */
DWORD WINAPI XInputGetCapabilitiesEx(DWORD version, DWORD index, DWORD flags, XINPUT_CAPABILITIES_EX *caps)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if (!caps) return ERROR_BAD_ARGUMENTS;
    if (flags & ~XINPUT_FLAG_GAMEPAD) return ERROR_BAD_ARGUMENTS;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    memset(caps, 0, sizeof(*caps));
    fill_caps(&caps->Capabilities);
    caps->VendorId = 0x045E;
    caps->ProductId = 0x028E;
    caps->ProductVersion = 0x0114;
    return ERROR_SUCCESS;
}

void WINAPI XInputEnable(BOOL enable)
{
    g_enabled = enable;
}

DWORD WINAPI XInputGetBatteryInformation(DWORD index, BYTE dev_type, XINPUT_BATTERY_INFORMATION *info)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if (!info) return ERROR_BAD_ARGUMENTS;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    info->BatteryType = BATTERY_TYPE_WIRED;
    info->BatteryLevel = BATTERY_LEVEL_FULL;
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetKeystroke(DWORD index, DWORD reserved, XINPUT_KEYSTROKE *keystroke)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if (!keystroke) return ERROR_BAD_ARGUMENTS;
    if (index == 0xFF) index = 0;   /* XUSER_INDEX_ANY: one pad */
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    return ERROR_EMPTY;              /* no keystroke queue, like Wine */
}

DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD index, GUID *render, GUID *capture)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    if (render) memset(render, 0, sizeof(*render));
    if (capture) memset(capture, 0, sizeof(*capture));
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetAudioDeviceIds(DWORD index, LPWSTR render, UINT *render_count,
                                     LPWSTR capture, UINT *capture_count)
{
    struct madeira_xinput_state s;
    DWORD ret;
    if ((ret = fetch(index, &s)) != ERROR_SUCCESS) return ret;
    if (render_count) *render_count = 0;
    if (capture_count) *capture_count = 0;
    if (render) *render = 0;
    if (capture) *capture = 0;
    return ERROR_SUCCESS;
}

/* Ordinals 101-104: guide-button wait and bus queries. Nothing to do. */
DWORD WINAPI XInputWaitForGuideButton(DWORD index, DWORD flags, void *unknown)
{
    return ERROR_NOT_SUPPORTED;
}

DWORD WINAPI XInputCancelGuideButtonWait(DWORD index)
{
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputPowerOffController(DWORD index)
{
    return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetBaseBusInformation(DWORD index, void *info)
{
    return ERROR_NOT_SUPPORTED;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID reserved)
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
    return TRUE;
}
