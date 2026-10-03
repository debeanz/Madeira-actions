/*
 * iOS-Madeira override for wine/dlls/win32u/syscall.c.
 *
 * THE RULE, and why upstream's cannot be used verbatim here.
 *
 * Upstream win32u keeps one process-global, `zero_bits`, set at unix-lib init
 * when the process has a WoW64 TEB:
 *
 *     if (NtCurrentTeb()->WowTebOffset)
 *         zero_bits = (ULONG_PTR)info.HighestUserAddress | 0x7fffffff;
 *
 * Every later NtAllocateVirtualMemory in win32u passes it, so the GDI shared
 * handle table (gdiobj.c), DC_ATTR buckets (dc.c), DIB section pixel buffers
 * (dib.c), message return buffers (message.c) and Vulkan host mappings
 * (vulkan.c) land where 32-bit guest code can address them.  That is not an
 * optimisation: win32u hands those addresses to the guest, and 32-bit gdi32
 * TRUNCATES them (wine/dlls/gdi32/objects.c:70-79 reads
 * peb64->GdiSharedHandleTable through a 32-bit UINT_PTR cast).
 *
 * On Madeira every Windows process is a pseudo-process -- a thread inside ONE
 * Mach task, sharing ONE win32u instance -- so a "process global" is really
 * TASK-global and is wrong for every process except the one that wrote it:
 *
 *   - 32-bit process first: the global stays set after it exits, so every
 *     later 64-bit pseudo-process allocates with a low-2GB ceiling it can
 *     never satisfy on iOS (`[va-scan] FAILED window=0x10000..0x80000000 ...
 *     STATUS_NO_MEMORY`) -- explorer's dialogs got no window surface.
 *   - Global cleared (the ml750 change this file used to make): a 32-bit
 *     pseudo-process then receives raw HOST pointers, and the truncation above
 *     produces a guest address that FEX rebases into the window at B + low32,
 *     which is unmapped -- `[mach_exc] UNHANDLED pc=... addr=0x7138c9057e`
 *     inside i386 gdi32!get_gdi_client_ptr.
 *
 * Both are the same root cause, so neither value can be right for everyone.
 * `zero_bits` is therefore DEAD on iOS (kept at 0 so a missed call site fails
 * the safe way for the 64-bit majority) and every consumer calls
 * win32u_zero_bits(), which answers for the CALLING pseudo-process:
 *
 *     wow (WowTebOffset != 0) -> HighestUserAddress | 0x7fffffff   (a GUEST
 *         ceiling, which build/ntdll-unix/virtual_ios.c's
 *         ios_wow_translate_limits() turns into [B+floor, B+ceiling])
 *     otherwise               -> 0
 *
 * The ceiling is cached per (pid, peb) -- the key class_ios.c's builtin-class
 * registry already uses, so a recycled PEB address cannot answer for a dead
 * process -- plus a per-thread fast path.
 *
 * NOTE the companion rule in gdiobj.c: the GDI shared table itself must NOT be
 * allocated with a guest ceiling even when the process that first initialises
 * win32u is 32-bit.  It is session-wide state, while a guest window is torn
 * down and replaced with PROT_NONE when its 32-bit pseudo-process exits.  The
 * master table stays at a host address for the life of the session and each
 * 32-bit pseudo-process gets a second VIEW of it inside its own window.
 */

#include <stdio.h>
#include <unistd.h>
#include <pthread.h>

/* Compile upstream syscall.c with its init entry point renamed, then wrap it.
 * build.sh already maps __wine_unix_lib_init -> win32u_unix_lib_init; this
 * pushes that one step further so the wrapper below can own the real name. */
#define win32u_unix_lib_init win32u_unix_lib_init_upstream
#include "../../wine/dlls/win32u/syscall.c"
#undef win32u_unix_lib_init

/***********************************************************************
 *           win32u_zero_bits
 *
 * The allocation ceiling of the CALLING pseudo-process.  See the file header.
 */

struct ios_zero_bits_entry
{
    DWORD     pid;
    void     *peb;
    ULONG_PTR zero_bits;
};

#define IOS_MAX_ZERO_BITS_PROCS 64
static struct ios_zero_bits_entry ios_zero_bits_reg[IOS_MAX_ZERO_BITS_PROCS];
static int ios_zero_bits_count;
static pthread_mutex_t ios_zero_bits_lock = PTHREAD_MUTEX_INITIALIZER;

/* a thread never changes pseudo-process, so this needs no invalidation */
static __thread void      *ios_zero_bits_cached_peb;
static __thread ULONG_PTR  ios_zero_bits_cached;

static ULONG_PTR ios_compute_zero_bits( void *peb, DWORD pid )
{
    SYSTEM_BASIC_INFORMATION info;
    ULONG_PTR high = 0, value;

    if (!NtCurrentTeb()->WowTebOffset) value = 0;
    else
    {
        if (!NtQuerySystemInformation( SystemEmulationBasicInformation, &info, sizeof(info), NULL ))
            high = (ULONG_PTR)info.HighestUserAddress;
        /* A sane answer is a GUEST address below 4 GB.  Anything else (query
         * failure, or a host-sized limit leaking out of a session global) must
         * not escape as a ceiling: >= 4 GB would be taken for a host address
         * and skip the window translation entirely, so fall back to the
         * conservative 2 GB guest ceiling. */
        value = (high && high < ((ULONG_PTR)1 << 32)) ? (high | 0x7fffffff) : 0x7fffffff;
    }

    dprintf( 2, "[zero-bits] peb=%p pid=%04x wow=%d ceiling=%#lx\n",
             peb, (int)pid, NtCurrentTeb()->WowTebOffset ? 1 : 0, (unsigned long)value );
    return value;
}

ULONG_PTR win32u_zero_bits(void)
{
    void *peb = NtCurrentTeb()->Peb;
    ULONG_PTR ret;
    DWORD pid;
    int i;

    if (ios_zero_bits_cached_peb == peb) return ios_zero_bits_cached;

    pid = HandleToULong( NtCurrentTeb()->ClientId.UniqueProcess );

    pthread_mutex_lock( &ios_zero_bits_lock );
    for (i = 0; i < ios_zero_bits_count; i++)
        if (ios_zero_bits_reg[i].peb == peb && ios_zero_bits_reg[i].pid == pid) break;

    if (i < ios_zero_bits_count) ret = ios_zero_bits_reg[i].zero_bits;
    else
    {
        ret = ios_compute_zero_bits( peb, pid );
        if (ios_zero_bits_count < IOS_MAX_ZERO_BITS_PROCS)
        {
            ios_zero_bits_reg[i].pid       = pid;
            ios_zero_bits_reg[i].peb       = peb;
            ios_zero_bits_reg[i].zero_bits = ret;
            ios_zero_bits_count = i + 1;
        }
        else
        {
            static int warned;
            if (!warned++)
                dprintf( 2, "[zero-bits] registry FULL (%d processes) — recomputing per call\n",
                         IOS_MAX_ZERO_BITS_PROCS );
        }
    }
    pthread_mutex_unlock( &ios_zero_bits_lock );

    /* only cache what the registry vouches for, so a full registry keeps
     * answering from a fresh query instead of pinning a stale value */
    if (i < IOS_MAX_ZERO_BITS_PROCS)
    {
        ios_zero_bits_cached     = ret;
        ios_zero_bits_cached_peb = peb;
    }
    return ret;
}

/***********************************************************************
 *           ml878: ATOMS THAT CROSS THE 32-BIT BRIDGE AS ADDRESSES
 *
 * 125hz's wow64win.dll (prebuilt; it converts every i386 user32 call) turns
 * each 32-bit pointer argument into a host address with guest_ptr32(), which
 * adds the guest window base B to anything non-NULL -- including the arguments
 * Win32 lets be an ATOM instead of a string.  MAKEINTATOM(32770), the dialog
 * class, arrives as B + 0x8002: no longer an atom to IS_INTRESOURCE(), and not
 * readable memory either (the guest's first 64 KB are never mapped).
 *
 *   - NtUserCreateWindowEx's `class` (user32 hands over the caller's own class
 *     argument).  Its TRACE formats it with debugstr_w(), and Wine evaluates a
 *     TRACE's arguments the first time a file's channel is used, before it
 *     knows the channel is off.  So the FIRST window of a session made from an
 *     atom class died reading B + 0x8002: Prince of Persia: The Two Thrones'
 *     launcher PrinceOfPersia.exe (an MFC dialog) is the first window anyone
 *     creates in a game session, which has no explorer (0.1.142:
 *     wine_dbgstr_wn+0x4c <- NtUserCreateWindowEx+0x100, addr 0x400008002).
 *     Past that TRACE it only cost the atom: cs.lpszClass became the class
 *     NAME where Windows gives the CBT hook and WM_CREATE the atom.
 *   - NtUserGetProp / SetProp / RemoveProp's `str`: an atom property name
 *     (SetPropW(hwnd, MAKEINTATOM(a), ...), what Delphi's VCL does for every
 *     window) went to lstrlenW(B + a) -- a crash on every call, not just once.
 *
 * Everything else that can carry an atom either arrives as a UNICODE_STRING
 * user32 filled with the class NAME (init_class_name), or is only ever used
 * through LOWORD (cursor resource ids).
 *
 * B + x with x below 64 KB is never a guest address, so it is always an atom:
 * it is taken back to x, for a caller that has a guest window (B is 0 for
 * every 64-bit process, which keeps upstream behaviour exactly).  wow64win.dll
 * cannot be rebuilt here, so the fix sits at its only other point of contact:
 * the win32u syscall table, whose four entries are swapped before upstream
 * init publishes it. */
extern ULONG_PTR ios_wow_base(void);

static const WCHAR *ios_wow_atom( const WCHAR *str, const char *where )
{
    static int logged;
    ULONG_PTR base;

    if (IS_INTRESOURCE( str ) || !(base = ios_wow_base())) return str;
    if ((ULONG_PTR)str - base >= 0x10000) return str;
    if (__atomic_add_fetch( &logged, 1, __ATOMIC_RELAXED ) <= 8)
        dprintf( 2, "[wow-atom] ml878 %s: %p from a 32-bit caller is atom %#lx (B=%p)\n",
                 where, str, (unsigned long)((ULONG_PTR)str - base), (void *)base );
    return (const WCHAR *)((ULONG_PTR)str - base);
}

static HWND WINAPI ios_NtUserCreateWindowEx( DWORD ex_style, UNICODE_STRING *class_name,
                                             UNICODE_STRING *version, UNICODE_STRING *window_name,
                                             DWORD style, INT x, INT y, INT cx, INT cy,
                                             HWND parent, HMENU menu, HINSTANCE instance, void *params,
                                             DWORD flags, HINSTANCE client_instance, const WCHAR *class,
                                             BOOL ansi )
{
    const WCHAR *atom = ios_wow_atom( class, "NtUserCreateWindowEx" );
    HWND ret;

    /* ml882: and for that 32-bit caller pass NO class rather than the atom.
     * `class` only feeds the TRACE and CREATESTRUCT.lpszClass; with NULL,
     * win32u puts the class NAME there (NtUserGetClassName), which is what
     * every 32-bit window got before ml878 (B + atom was never IS_INTRESOURCE).
     * 64-bit callers keep upstream's atom. (ml882 blamed the atom for the
     * callback faults at guest 0x81/0x82 in Prince of Persia's launcher; they
     * stayed in 0.1.148 and were winproc handles, see ml883 below. The class
     * name is kept: it is what 32-bit programs always got here.) */
    if (atom != class) class = NULL;
    ret = NtUserCreateWindowEx( ex_style, class_name, version, window_name, style, x, y, cx, cy,
                                parent, menu, instance, params, flags, client_instance, class, ansi );
    if (!ret && ios_wow_base())
    {
        static int logged;
        char name[96];
        unsigned int i, n = class_name ? class_name->Length / sizeof(WCHAR) : 0;

        for (i = 0; i < n && i < sizeof(name) - 1; i++)
            name[i] = (class_name->Buffer[i] >= 0x20 && class_name->Buffer[i] < 0x7f) ? (char)class_name->Buffer[i] : '?';
        name[i] = 0;
        if (__atomic_add_fetch( &logged, 1, __ATOMIC_RELAXED ) <= 16)
            dprintf( 2, "[wow-cw] ml882 a 32-bit CreateWindowEx failed: class \"%s\" style %#x parent %p error %u\n",
                     name, (unsigned int)style, parent, (unsigned int)RtlGetLastWin32Error() );
    }
    return ret;
}

static HANDLE WINAPI ios_NtUserGetProp( HWND hwnd, const WCHAR *str )
{
    return NtUserGetProp( hwnd, ios_wow_atom( str, "NtUserGetProp" ));
}

static BOOL WINAPI ios_NtUserSetProp( HWND hwnd, const WCHAR *str, HANDLE handle )
{
    return NtUserSetProp( hwnd, ios_wow_atom( str, "NtUserSetProp" ), handle );
}

static HANDLE WINAPI ios_NtUserRemoveProp( HWND hwnd, const WCHAR *str )
{
    return NtUserRemoveProp( hwnd, ios_wow_atom( str, "NtUserRemoveProp" ));
}

/***********************************************************************
 *           ml883: WINDOW PROCEDURE HANDLES THAT CROSS THE 32-BIT BRIDGE
 *
 * GetWindowLongPtrA(GWLP_WNDPROC) on a window whose class has only a Unicode
 * procedure (or W on an ANSI-only one) does not return that procedure: win32u
 * hands out a winproc HANDLE, 0xffff0000 | index, that only CallWindowProc
 * understands -- as Windows does. wow64win.dll's CallWindowProc thunk converts
 * its target with guest_ptr32(), so the handle reaches win32u as B + 0xffff00xx.
 * That is no longer a handle (handle_to_proc wants 0xffff in the top half), so
 * win32u finds no procedure for it and gives it back as the function to call,
 * and 32-bit user32 CALLS 0xffff00xx: the guest runs whatever lies at the top
 * of its window. Prince of Persia: The Two Thrones' launcher faulted reading
 * guest 0x81/0x82 (eip 0xffff004e) in every such call; the user callback
 * swallowed the exception, returned 0, and the window being created failed.
 *
 * MFC does exactly that for each top-level window a thread creates while its
 * CBT hook is installed (always, in an MFC .exe): _AfxCbtFilterHook keeps
 * GetWindowLongPtr(GWLP_WNDPROC) as the "AfxOldWndProc423" property and
 * subclasses with _AfxActivationWndProc, which forwards every message through
 * CallWindowProc(old). An ANSI MFC program creating a Unicode-class window --
 * COM's apartment window (OleMainThreadWndClass), the IME windows, comctl32's
 * tooltips -- got a handle, so all of them failed (0.1.143-0.1.148:
 * "apartment_createwindowifneeded CreateWindow failed", [wow-cw] "Wine IME"
 * error 1400). CWnd::DefWindowProc forwards through CallWindowProc(m_pfnSuper)
 * for every control MFC subclasses, so a comctl32 control in an ANSI MFC
 * dialog lost its default handling the same way.
 *
 * The top 64 KB of a 32-bit address space is never mapped, so B + 0xffffxxxx
 * is never a guest function: it is taken back to the handle. Two thunks
 * convert a WNDPROC with guest_ptr32(): CallWindowProc (NtUserMessageCall,
 * type NtUserCallWindowProc) and RegisterClassEx (a class registered with the
 * procedure GetClassInfo returned, the usual way to superclass). SetWindowLong
 * (Ptr) and SetClassLong(Ptr) pass the 32-bit value through as it is, and
 * dialog procedures go through NtUserCallTwoParam unconverted, so those were
 * never affected. 64-bit callers (B = 0) keep upstream behaviour exactly. */
static WNDPROC ios_wow_proc( WNDPROC proc, const char *where )
{
    static int logged;
    ULONG_PTR base, off;

    if (!proc || !(base = ios_wow_base())) return proc;
    off = (ULONG_PTR)proc - base;
    if (off >> 16 != 0xffff) return proc;
    if (__atomic_add_fetch( &logged, 1, __ATOMIC_RELAXED ) <= 8)
        dprintf( 2, "[wow-proc] ml883 %s: %p from a 32-bit caller is winproc handle %#lx (B=%p)\n",
                 where, proc, (unsigned long)off, (void *)base );
    return (WNDPROC)off;
}

static LRESULT WINAPI ios_NtUserMessageCall( HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam,
                                             void *result_info, DWORD type, BOOL ansi )
{
    if (type == NtUserCallWindowProc && result_info)
    {
        struct win_proc_params *params = result_info;
        params->func = ios_wow_proc( params->func, "CallWindowProc" );
    }
    return NtUserMessageCall( hwnd, msg, wparam, lparam, result_info, type, ansi );
}

static ATOM WINAPI ios_NtUserRegisterClassExWOW( const WNDCLASSEXW *wc, UNICODE_STRING *name,
                                                 UNICODE_STRING *version,
                                                 struct client_menu_name *client_menu_name,
                                                 DWORD fnid, DWORD flags, DWORD *wow )
{
    WNDCLASSEXW copy;
    WNDPROC proc;

    if (wc && (proc = ios_wow_proc( wc->lpfnWndProc, "RegisterClassEx" )) != wc->lpfnWndProc)
    {
        copy = *wc;
        copy.lpfnWndProc = proc;
        wc = &copy;
    }
    return NtUserRegisterClassExWOW( wc, name, version, client_menu_name, fnid, flags, wow );
}

static void ios_swap_syscall( ULONG_PTR orig, ULONG_PTR hook, const char *name )
{
    unsigned int i;

    for (i = 0; i < ARRAY_SIZE(syscalls); i++)
    {
        if (syscalls[i] == hook) return;   /* a later init: already swapped */
        if (syscalls[i] != orig) continue;
        syscalls[i] = hook;
        return;
    }
    dprintf( 2, "[wow-atom] ml878 %s is not in the win32u syscall table -- "
                "values from 32-bit callers stay unconverted there\n", name );
}

NTSTATUS win32u_unix_lib_init(void)
{
    NTSTATUS status;

    ios_swap_syscall( (ULONG_PTR)NtUserCreateWindowEx, (ULONG_PTR)ios_NtUserCreateWindowEx,
                      "NtUserCreateWindowEx" );
    ios_swap_syscall( (ULONG_PTR)NtUserGetProp, (ULONG_PTR)ios_NtUserGetProp, "NtUserGetProp" );
    ios_swap_syscall( (ULONG_PTR)NtUserSetProp, (ULONG_PTR)ios_NtUserSetProp, "NtUserSetProp" );
    ios_swap_syscall( (ULONG_PTR)NtUserRemoveProp, (ULONG_PTR)ios_NtUserRemoveProp, "NtUserRemoveProp" );
    ios_swap_syscall( (ULONG_PTR)NtUserMessageCall, (ULONG_PTR)ios_NtUserMessageCall,
                      "NtUserMessageCall" );   /* ml883 */
    ios_swap_syscall( (ULONG_PTR)NtUserRegisterClassExWOW, (ULONG_PTR)ios_NtUserRegisterClassExWOW,
                      "NtUserRegisterClassExWOW" );   /* ml883 */
    status = win32u_unix_lib_init_upstream();

    /* The task-global is dead here; win32u_zero_bits() answers per
     * pseudo-process.  Keep it at 0 so that any call site that still reads it
     * behaves like a 64-bit process (which is the common case and the only one
     * for which a host address is right). */
    if (zero_bits)
    {
        dprintf( 2, "[zero-bits] win32u unix init: dropping the task-global ceiling %#lx — "
                    "every consumer now asks win32u_zero_bits() for the calling "
                    "pseudo-process\n", (unsigned long)zero_bits );
        zero_bits = 0;
    }
    return status;
}
