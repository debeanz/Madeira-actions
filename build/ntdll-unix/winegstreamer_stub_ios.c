/*
 * winegstreamer unix side — STUB (wow64 port, first pass).
 *
 * The 125hz fork implements the WMA subset of winegstreamer's unix side with
 * libavcodec (winegstreamer_unixlib_ios.c), which needs toolchains/ffmpeg-ios.
 * That FFmpeg build comes from their local .xtool/build-ffmpeg.sh and does not
 * exist in this repo's CI yet, so the real file cannot compile here.
 *
 * virtual_ios.c binds "winegstreamer" to winegstreamer_unix_call_funcs /
 * winegstreamer_unix_call_wow64_funcs, so the symbols must exist for the app
 * to link. Every entry answers STATUS_NOT_IMPLEMENTED: winegstreamer.dll
 * loads, its init fails cleanly, and a title that wants the WMA decoder gets
 * "no decoder" instead of a NULL unixlib handle. Replace this file with
 * winegstreamer_unixlib_ios.c in build.sh once CI builds FFmpeg for iOS.
 *
 * The table is deliberately larger than enum unix_wg_funcs (dlls/winegstreamer
 * /unixlib.h) so no valid index can run off its end, and it avoids that header
 * so it does not depend on the widl-generated MF headers.
 */

#if 0
#pragma makedep unix
#endif

#include "config.h"

#include <stdarg.h>

#include "ntstatus.h"
#define WIN32_NO_STATUS
#include "windef.h"
#include "winbase.h"
#include "winternl.h"
#include "wine/unixlib.h"

#define IOS_WG_STUB_ENTRIES 96

static NTSTATUS ios_wg_not_implemented( void *args )
{
    (void)args;
    return STATUS_NOT_IMPLEMENTED;
}

const unixlib_entry_t __wine_unix_call_funcs[IOS_WG_STUB_ENTRIES] =
{
    [0 ... IOS_WG_STUB_ENTRIES - 1] = ios_wg_not_implemented,
};

const unixlib_entry_t __wine_unix_call_wow64_funcs[IOS_WG_STUB_ENTRIES] =
{
    [0 ... IOS_WG_STUB_ENTRIES - 1] = ios_wg_not_implemented,
};
