/* Madeira session agent (ml791).
 *
 * A native AArch64 Windows program that lives inside the virtual desktop
 * session and starts games on the app's behalf. explorer's /desktop switch
 * runs exactly one command (it used to be services.exe); that command is now
 *
 *     madeira-agent.exe C:\windows\system32\services.exe
 *
 * The agent starts whatever it was given (services.exe: the SCM the desktop
 * needs), then polls C:\madeira\launch.txt. The app (SessionLauncher.swift)
 * writes that file to launch a game from the Games tab:
 *
 *     id=<token>
 *     exe=C:\Games\Hollow Knight\hollow_knight.exe
 *     dir=C:\Games\Hollow Knight
 *     args=<optional>
 *     shadercache=off  or  shadercache=/abs/unix/dir    (optional, ml830)
 *
 * The agent deletes the request, CreateProcess()es the game with its folder
 * as working directory, and answers in C:\madeira\launch.result:
 *
 *     id=<token>
 *     ok pid=<pid>          or          err code=<GetLastError>
 *
 * ml830: "shadercache=" gives this one game its own DXMT shader cache, or
 * none. DXMT's d3d11.dll reads DXMT_SHADER_CACHE / DXMT_SHADER_CACHE_PATH
 * from the game's Windows environment block, which CreateProcessW copies from
 * ours. "off" sets DXMT_SHADER_CACHE=0 and removes DXMT_SHADER_CACHE_PATH; an
 * absolute path removes DXMT_SHADER_CACHE and sets DXMT_SHADER_CACHE_PATH to
 * it. Both are set around that CreateProcessW only: the agent's own values
 * (imported from the unix environ at runtime start) are put back right after,
 * so they never leak into the next launch. Without the line the game inherits
 * the agent's environment unchanged, as before.
 *
 * Why a helper instead of the app calling into Wine: every Wine "process" is
 * a thread here, and NtCreateUserProcess needs a caller with a TEB, server
 * connection and process parameters — only Windows code inside the session
 * has those. A polling helper is dumb, but it is the same CreateProcess path
 * File Explorer's double-click uses, and it needs nothing from Wine that a
 * regular program does not. Native AArch64 so it costs no FEX translation.
 *
 * C:\madeira\agent.ready is (re)created once services.exe has been started,
 * so the app can tell the session is able to take requests. No window, no
 * console (GUI subsystem), sleeps 200 ms between polls. */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <wchar.h>

#define AGENT_DIR    L"C:\\madeira"
#define REQUEST_PATH L"C:\\madeira\\launch.txt"
#define RESULT_PATH  L"C:\\madeira\\launch.result"
#define READY_PATH   L"C:\\madeira\\agent.ready"
#define LOG_PATH     L"C:\\madeira\\agent.log"
#define EXIT_PATH    L"C:\\madeira\\exit.txt"

/* ml797: programs we started, so their exit can be reported (the app's
 * Games tab turns "Resume" back into "Play"). */
static HANDLE g_child_handle[32];
static DWORD  g_child_pid[32];
static DWORD  g_child_kill_at[32];   /* ml799: tick when a hard kill is due, 0 = none */
static int    g_child_n;

static void agent_log( const char *fmt, ... );   /* defined below; reap_children logs */

/* ml799: a violent TerminateProcess from outside wedges the desktop on
 * this port (the victim's threads never get the signal and keep their
 * locks), so "force close" first asks every window of the process to
 * close — what Alt+F4 does, which Unity and most games honour — and only
 * terminates after CLOSE_GRACE_MS if the process is still there. */
#define CLOSE_GRACE_MS 8000
static int g_close_posted;

/* ml825: the hard kill below has NEVER fired on device: its deadline is
 * GetTickCount()-based and the shared-data tick count was frozen until ml825
 * turned the clock on. Turning the clock on must not silently arm a violent
 * outside TerminateProcess (see the ml799 note above) in the force-close flow
 * the app's quit watchdog (ml814-818) was built around, so it stays off unless
 * MADEIRA_AGENT_HARDKILL=1. */
static int hardkill_enabled( void )
{
    static int v = -1;
    if (v < 0)
    {
        char buf[8];
        DWORD n = GetEnvironmentVariableA( "MADEIRA_AGENT_HARDKILL", buf, sizeof(buf) );
        v = (n > 0 && n < sizeof(buf) && buf[0] == '1') ? 1 : 0;
    }
    return v;
}

static BOOL CALLBACK close_windows_proc( HWND hwnd, LPARAM lp )
{
    DWORD pid = 0;
    GetWindowThreadProcessId( hwnd, &pid );
    if (pid == (DWORD)lp)
    {
        PostMessageW( hwnd, WM_CLOSE, 0, 0 );
        g_close_posted++;
    }
    return TRUE;
}

static void append_text_file( const WCHAR *path, const char *text )
{
    HANDLE h = CreateFileW( path, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    DWORD written;
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile( h, text, (DWORD)strlen( text ), &written, NULL );
    CloseHandle( h );
}

static void reap_children( void )
{
    int i = 0;
    while (i < g_child_n)
    {
        if (WaitForSingleObject( g_child_handle[i], 0 ) == WAIT_OBJECT_0)
        {
            DWORD code = 0;
            char line[96];
            GetExitCodeProcess( g_child_handle[i], &code );
            CloseHandle( g_child_handle[i] );
            snprintf( line, sizeof(line), "pid=%lu code=%ld\r\n", (unsigned long)g_child_pid[i], (long)(int)code );
            append_text_file( EXIT_PATH, line );
            agent_log( "%s", line );
            g_child_n--;
            g_child_handle[i] = g_child_handle[g_child_n];
            g_child_pid[i] = g_child_pid[g_child_n];
            g_child_kill_at[i] = g_child_kill_at[g_child_n];
            continue;
        }
        if (g_child_kill_at[i] && hardkill_enabled() && (LONG)(GetTickCount() - g_child_kill_at[i]) >= 0)
        {
            agent_log( "pid=%lu ignored WM_CLOSE for %d ms -> TerminateProcess", (unsigned long)g_child_pid[i], CLOSE_GRACE_MS );
            TerminateProcess( g_child_handle[i], 1 );
            g_child_kill_at[i] = 0;
        }
        i++;
    }
}

static void agent_log( const char *fmt, ... )
{
    char line[1024];
    va_list ap;
    DWORD written, len;
    int n;
    HANDLE h;
    SYSTEMTIME st;

    GetLocalTime( &st );
    len = (DWORD)snprintf( line, sizeof(line), "[%02u:%02u:%02u] ", st.wHour, st.wMinute, st.wSecond );
    va_start( ap, fmt );
    n = vsnprintf( line + len, sizeof(line) - len - 2, fmt, ap );
    va_end( ap );
    /* ml830: vsnprintf returns the length it WOULD have written; clamp it to
     * what fits, or a long line (2 KB args or cache path) wrote the '\n' and
     * NUL past the end of line[]. */
    if (n < 0) n = 0;
    if ((DWORD)n > sizeof(line) - len - 3) n = (int)(sizeof(line) - len - 3);
    len += (DWORD)n;
    line[len++] = '\n';
    line[len] = 0;
    /* Also to stderr: the app maps a child's stderr onto madeira-log.txt. */
    h = GetStdHandle( STD_ERROR_HANDLE );
    if (h && h != INVALID_HANDLE_VALUE) WriteFile( h, line, len, &written, NULL );
    h = CreateFileW( LOG_PATH, FILE_APPEND_DATA, FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    if (h != INVALID_HANDLE_VALUE)
    {
        WriteFile( h, line, len, &written, NULL );
        CloseHandle( h );
    }
}

static void write_text_file( const WCHAR *path, const char *text )
{
    HANDLE h = CreateFileW( path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL );
    DWORD written;
    if (h == INVALID_HANDLE_VALUE) return;
    WriteFile( h, text, (DWORD)strlen( text ), &written, NULL );
    CloseHandle( h );
}

/* Read a whole small UTF-8 file (the request is a few hundred bytes). */
static char *read_text_file( const WCHAR *path )
{
    HANDLE h = CreateFileW( path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                            NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL );
    DWORD size, got;
    char *buf;
    if (h == INVALID_HANDLE_VALUE) return NULL;
    size = GetFileSize( h, NULL );
    if (size == INVALID_FILE_SIZE || size > 65536) { CloseHandle( h ); return NULL; }
    buf = HeapAlloc( GetProcessHeap(), 0, size + 1 );
    if (!buf) { CloseHandle( h ); return NULL; }
    if (!ReadFile( h, buf, size, &got, NULL )) got = 0;
    buf[got] = 0;
    CloseHandle( h );
    return buf;
}

/* "key=value" line lookup; value is copied without the trailing CR/LF. */
static int get_field( const char *text, const char *key, char *out, size_t out_size )
{
    size_t klen = strlen( key );
    const char *p = text;
    out[0] = 0;
    while (p && *p)
    {
        const char *eol = strpbrk( p, "\r\n" );
        size_t len = eol ? (size_t)(eol - p) : strlen( p );
        if (len > klen + 1 && !strncmp( p, key, klen ) && p[klen] == '=')
        {
            size_t vlen = len - klen - 1;
            if (vlen >= out_size) vlen = out_size - 1;
            memcpy( out, p + klen + 1, vlen );
            out[vlen] = 0;
            return 1;
        }
        if (!eol) break;
        p = eol;
        while (*p == '\r' || *p == '\n') p++;
    }
    return 0;
}

static WCHAR *utf8_to_wide( const char *s )
{
    int n = MultiByteToWideChar( CP_UTF8, 0, s, -1, NULL, 0 );
    WCHAR *w = HeapAlloc( GetProcessHeap(), 0, n * sizeof(WCHAR) );
    if (w) MultiByteToWideChar( CP_UTF8, 0, s, -1, w, n );
    return w;
}

/* ml830: the two variables a "shadercache=" line overrides for one launch. */
#define ENV_SHADER_CACHE      L"DXMT_SHADER_CACHE"
#define ENV_SHADER_CACHE_PATH L"DXMT_SHADER_CACHE_PATH"

struct saved_env
{
    const WCHAR *name;
    WCHAR       *value;   /* NULL = the variable was not set */
};

/* Snapshot one variable of our environment so it can be put back exactly.
 * FALSE only when it is set but could not be copied: the caller must then not
 * override what it cannot restore. */
static BOOL save_env( struct saved_env *s, const WCHAR *name )
{
    DWORD len, got;

    s->name = name;
    s->value = NULL;
    SetLastError( ERROR_SUCCESS );
    len = GetEnvironmentVariableW( name, NULL, 0 );
    if (!len && GetLastError() == ERROR_ENVVAR_NOT_FOUND) return TRUE;
    if (!len) len = 1;   /* set, to an empty value */
    s->value = HeapAlloc( GetProcessHeap(), 0, len * sizeof(WCHAR) );
    if (!s->value) return FALSE;
    s->value[0] = 0;
    got = GetEnvironmentVariableW( name, s->value, len );
    if (got >= len)
    {
        HeapFree( GetProcessHeap(), 0, s->value );
        s->value = NULL;
        return FALSE;
    }
    return TRUE;
}

/* Put a snapshot back (a NULL value removes the variable) and free it. */
static void restore_env( struct saved_env *s )
{
    SetEnvironmentVariableW( s->name, s->value );
    if (s->value) HeapFree( GetProcessHeap(), 0, s->value );
    s->value = NULL;
}

/* Start a program; returns the pid or 0 (GetLastError() set). */
static DWORD start_process( const WCHAR *exe, const WCHAR *args, const WCHAR *dir )
{
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    size_t len = wcslen( exe ) + (args ? wcslen( args ) : 0) + 4;
    WCHAR *cmdline = HeapAlloc( GetProcessHeap(), 0, len * sizeof(WCHAR) );
    DWORD pid = 0;

    if (!cmdline) return 0;
    /* Quote the exe: game folders have spaces. */
    /* %ls means a wide string under both MSVC and ISO wide-printf rules. */
    swprintf( cmdline, len, L"\"%ls\"%ls%ls", exe, (args && *args) ? L" " : L"", (args && *args) ? args : L"" );
    memset( &si, 0, sizeof(si) );
    si.cb = sizeof(si);
    if (CreateProcessW( exe, cmdline, NULL, NULL, FALSE, 0, NULL, (dir && *dir) ? dir : NULL, &si, &pi ))
    {
        pid = pi.dwProcessId;
        CloseHandle( pi.hThread );
        if (g_child_n < 32)
        {
            g_child_handle[g_child_n] = pi.hProcess;
            g_child_pid[g_child_n] = pi.dwProcessId;
            g_child_kill_at[g_child_n] = 0;
            g_child_n++;
        }
        else CloseHandle( pi.hProcess );
    }
    HeapFree( GetProcessHeap(), 0, cmdline );
    return pid;
}

static void handle_request( void )
{
    char *text = read_text_file( REQUEST_PATH );
    char id[128], exe[1024], dir[1024], args[2048], cache[2048], result[256];
    WCHAR *wexe, *wdir, *wargs, *wcache = NULL;
    DWORD pid, err = 0;
    int cache_mode = 0;   /* ml830: 0 = leave the environment alone, 1 = off, 2 = cache dir */
    struct saved_env saved[2];

    if (!text) return;
    /* Delete first so a failure cannot be retried forever. */
    DeleteFileW( REQUEST_PATH );
    get_field( text, "id", id, sizeof(id) );
    /* ml798: "kill=<pid>" — force close a program we started. */
    if (get_field( text, "kill", args, sizeof(args) ))
    {
        DWORD kpid = strtoul( args, NULL, 10 );
        BOOL ok = FALSE;
        int i;
        g_close_posted = 0;
        EnumWindows( close_windows_proc, (LPARAM)kpid );
        for (i = 0; i < g_child_n; i++)
            if (g_child_pid[i] == kpid)
            {
                /* Polite close first; the reap loop terminates after the grace. */
                g_child_kill_at[i] = GetTickCount() + CLOSE_GRACE_MS;
                if (!g_child_kill_at[i]) g_child_kill_at[i] = 1;
                ok = TRUE;
                break;
            }
        if (i == g_child_n)
        {
            /* Not ours: close its windows now, terminate if none took it. */
            if (g_close_posted) ok = TRUE;
            else
            {
                HANDLE h = OpenProcess( PROCESS_TERMINATE, FALSE, kpid );
                if (h) { ok = TerminateProcess( h, 1 ); CloseHandle( h ); }
            }
        }
        agent_log( "kill id=%s pid=%lu -> %s (WM_CLOSE to %d window(s), hard kill in %d ms if ignored)",
                   id, (unsigned long)kpid, ok ? "ok" : "err", g_close_posted, CLOSE_GRACE_MS );
        snprintf( result, sizeof(result), ok ? "id=%s\r\nok kill\r\n" : "id=%s\r\nerr code=%lu\r\n", id, (unsigned long)GetLastError() );
        write_text_file( RESULT_PATH, result );
        HeapFree( GetProcessHeap(), 0, text );
        return;
    }
    if (!get_field( text, "exe", exe, sizeof(exe) ))
    {
        agent_log( "request without exe= ignored" );
        snprintf( result, sizeof(result), "id=%s\r\nerr code=87\r\n", id );
        write_text_file( RESULT_PATH, result );
        HeapFree( GetProcessHeap(), 0, text );
        return;
    }
    get_field( text, "dir", dir, sizeof(dir) );
    get_field( text, "args", args, sizeof(args) );
    /* ml830: per-game DXMT shader cache. get_field returns the first line
     * only, and an empty value counts as absent (so: no override). */
    if (get_field( text, "shadercache", cache, sizeof(cache) ))
    {
        if (strlen( cache ) >= sizeof(cache) - 1)
            agent_log( "shadercache ignored: value too long (%u+ bytes, may be truncated)", (unsigned)strlen( cache ) );
        else if (!strcmp( cache, "off" )) cache_mode = 1;
        else if (cache[0] == '/') cache_mode = 2;
        else agent_log( "shadercache=%s ignored: neither \"off\" nor an absolute path", cache );
    }
    HeapFree( GetProcessHeap(), 0, text );

    wexe = utf8_to_wide( exe );
    wdir = utf8_to_wide( dir );
    wargs = utf8_to_wide( args );
    agent_log( "launch id=%s exe=%s dir=%s args=%s", id, exe, dir, args );

    /* ml830: override both variables for this CreateProcessW only. Snapshot
     * first; if either cannot be saved (out of memory), change nothing. */
    if (cache_mode)
    {
        BOOL ok_cache = save_env( &saved[0], ENV_SHADER_CACHE );
        BOOL ok_path = save_env( &saved[1], ENV_SHADER_CACHE_PATH );

        if (cache_mode == 2) wcache = utf8_to_wide( cache );
        if (!ok_cache || !ok_path || (cache_mode == 2 && !wcache))
        {
            agent_log( "shadercache override skipped: could not save the agent's environment" );
            if (saved[0].value) HeapFree( GetProcessHeap(), 0, saved[0].value );
            if (saved[1].value) HeapFree( GetProcessHeap(), 0, saved[1].value );
            cache_mode = 0;
        }
        else if (cache_mode == 1)
        {
            BOOL ok = SetEnvironmentVariableW( ENV_SHADER_CACHE, L"0" );
            DWORD set_err = ok ? 0 : GetLastError();
            SetEnvironmentVariableW( ENV_SHADER_CACHE_PATH, NULL );
            agent_log( "shadercache off: DXMT_SHADER_CACHE=0%s (err %lu), DXMT_SHADER_CACHE_PATH removed "
                       "(agent had DXMT_SHADER_CACHE=%ls DXMT_SHADER_CACHE_PATH=%ls)",
                       ok ? "" : " FAILED", (unsigned long)set_err,
                       saved[0].value ? saved[0].value : L"<unset>",
                       saved[1].value ? saved[1].value : L"<unset>" );
        }
        else
        {
            BOOL ok;
            DWORD set_err;
            SetEnvironmentVariableW( ENV_SHADER_CACHE, NULL );
            ok = SetEnvironmentVariableW( ENV_SHADER_CACHE_PATH, wcache );
            set_err = ok ? 0 : GetLastError();
            agent_log( "shadercache on: DXMT_SHADER_CACHE removed, DXMT_SHADER_CACHE_PATH=%s%s (err %lu) "
                       "(agent had DXMT_SHADER_CACHE=%ls DXMT_SHADER_CACHE_PATH=%ls)",
                       cache, ok ? "" : " FAILED", (unsigned long)set_err,
                       saved[0].value ? saved[0].value : L"<unset>",
                       saved[1].value ? saved[1].value : L"<unset>" );
            /* DXMT reads the path into a MAX_PATH buffer (util_env.cpp) and
             * silently drops anything longer. */
            if (wcslen( wcache ) >= MAX_PATH)
                agent_log( "shadercache WARNING: path is %u chars; DXMT ignores paths of %d or more",
                           (unsigned)wcslen( wcache ), MAX_PATH );
        }
    }

    pid = start_process( wexe, wargs, wdir );
    if (!pid) err = GetLastError();
    if (cache_mode)
    {
        /* Back to exactly what the agent had; a NULL snapshot removes. */
        restore_env( &saved[0] );
        restore_env( &saved[1] );
    }
    if (pid) snprintf( result, sizeof(result), "id=%s\r\nok pid=%lu\r\n", id, (unsigned long)pid );
    else     snprintf( result, sizeof(result), "id=%s\r\nerr code=%lu\r\n", id, (unsigned long)err );
    agent_log( "%s", result );
    write_text_file( RESULT_PATH, result );
    HeapFree( GetProcessHeap(), 0, wexe );
    HeapFree( GetProcessHeap(), 0, wdir );
    HeapFree( GetProcessHeap(), 0, wargs );
    if (wcache) HeapFree( GetProcessHeap(), 0, wcache );
}

int WINAPI wWinMain( HINSTANCE inst, HINSTANCE prev, LPWSTR cmdline, int show )
{
    char ready[64];

    CreateDirectoryW( AGENT_DIR, NULL );
    DeleteFileW( READY_PATH );
    DeleteFileW( REQUEST_PATH );
    DeleteFileW( RESULT_PATH );
    agent_log( "madeira-agent started, pid=%lu, cmdline=%ls", (unsigned long)GetCurrentProcessId(), cmdline );

    /* ml803: in game mode there is no explorer, so nothing owns the win32
     * session's desktop window, and a game child cannot reliably create one
     * itself (the wineserver looks window classes up per process). We are the
     * first pseudo-process and the only one that never exits, so create it
     * here, before any child exists: children then inherit desktop->top_window
     * exactly as they do under explorer, and it outlives every game — which is
     * what makes the second and third launch of a session work.
     * Nothing appears on screen: winios.drv exports no SetDesktopWindow, so
     * win32u falls back to the no-op nulldrv_SetDesktopWindow. */
    agent_log( "session desktop window = %p", (void *)GetDesktopWindow() );

    /* Run the command explorer used to run itself (services.exe). It is a
     * plain command line, so no quoting games: start it as given. */
    if (cmdline && *cmdline)
    {
        STARTUPINFOW si;
        PROCESS_INFORMATION pi;
        memset( &si, 0, sizeof(si) );
        si.cb = sizeof(si);
        if (CreateProcessW( NULL, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi ))
        {
            agent_log( "started %ls pid=%lu", cmdline, (unsigned long)pi.dwProcessId );
            CloseHandle( pi.hThread );
            CloseHandle( pi.hProcess );
        }
        else agent_log( "failed to start %ls: %lu", cmdline, (unsigned long)GetLastError() );
    }

    /* ml813: WAIT FOR THE SESSION TO BE USABLE before declaring readiness.
     *
     * agent.ready used to be written the instant CreateProcessW returned, which
     * only means services.exe EXISTS. SessionLauncher's own comment says this
     * file means "services.exe is up" — it did not. In the 0.1.66 log the game
     * was spawned 227 ms after services.exe ([phase] spawn services t+9.312s,
     * spawn Untitled.exe t+9.539s) and RPCSS only came up at t+12.205s, 2.7 s
     * INTO the game's own startup, demand-started by the game itself AFTER its
     * first COM call had already failed. The wreckage is all over that log:
     * CLSID_WbemLocator dead, \??\pipe\wine_plugplay NOT FOUND,
     * device_notify_proc "failed to open RPC handle, error 1722",
     * \??\pipe\lrpc\irpcss NOT FOUND.
     *
     * A DESKTOP session never had this problem: explorer boots the shell and
     * does its own COM registration over several seconds, so RPCSS is long up
     * before the user gets round to pressing Play. That is the real difference
     * behind "Untitled Goose Game works from the desktop but not from the Games
     * tab" — it dies on a virtual call through a NULL back-pointer in a Unity
     * singleton whose COM-dependent subsystem never finished initialising.
     *
     * So do explicitly, and quickly, what explorer did incidentally and slowly.
     * Hard caps throughout: readiness is ALWAYS declared, so a stuck service can
     * never wedge SessionLauncher's wait. */
    {
        DWORD t0 = GetTickCount();
        SC_HANDLE scm;

        /* 1. services.exe publishes \\.\pipe\svcctl when its RPC_Init is done. */
        while ((DWORD)(GetTickCount() - t0) < 5000)
        {
            if (WaitNamedPipeW( L"\\\\.\\pipe\\svcctl", 50 )) break;
            Sleep( 50 );
        }
        agent_log( "SCM pipe available after %lu ms", (unsigned long)(GetTickCount() - t0) );

        /* 2. Demand-start RPCSS ourselves rather than leaving the first game to
         *    trip over it mid-init. */
        scm = OpenSCManagerW( NULL, NULL, SC_MANAGER_CONNECT );
        if (scm)
        {
            SC_HANDLE svc = OpenServiceW( scm, L"RpcSs", SERVICE_START | SERVICE_QUERY_STATUS );
            if (svc)
            {
                SERVICE_STATUS st;
                memset( &st, 0, sizeof(st) );
                StartServiceW( svc, 0, NULL );     /* already-running is fine */
                while ((DWORD)(GetTickCount() - t0) < 8000)
                {
                    if (QueryServiceStatus( svc, &st ) && st.dwCurrentState == SERVICE_RUNNING) break;
                    Sleep( 50 );
                }
                agent_log( "RpcSs state=%lu after %lu ms total",
                           (unsigned long)st.dwCurrentState,
                           (unsigned long)(GetTickCount() - t0) );
                CloseServiceHandle( svc );
            }
            else agent_log( "OpenServiceW(RpcSs) failed: %lu", (unsigned long)GetLastError() );
            CloseServiceHandle( scm );
        }
        else agent_log( "OpenSCManagerW failed: %lu", (unsigned long)GetLastError() );
    }

    snprintf( ready, sizeof(ready), "pid=%lu\r\n", (unsigned long)GetCurrentProcessId() );
    write_text_file( READY_PATH, ready );

    DeleteFileW( EXIT_PATH );
    for (;;)
    {
        Sleep( 200 );
        if (GetFileAttributesW( REQUEST_PATH ) != INVALID_FILE_ATTRIBUTES) handle_request();
        if (g_child_n) reap_children();
    }
    return 0;
}
