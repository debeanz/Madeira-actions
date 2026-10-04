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
 *     tso=off  or  tso=on                                 (optional, ml849)
 *     monosuspend=coop|hybrid|preemptive                  (optional, ml868)
 *     monohook=on                                         (optional, ml873)
 *     metalfx=<factor 1-3>                                (optional, ml912)
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
#include <tlhelp32.h>
#include <dbt.h>
#include <stdarg.h>
#include <stddef.h>
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
#define DEVCHANGE_PATH L"C:\\madeira\\devchange.txt"   /* ml875 */

/* ml797: programs we started, so their exit can be reported (the app's
 * Games tab turns "Resume" back into "Play"). ml878: plus, once such a program
 * has ended cleanly, what it left running for the game (see root_exited). */
static HANDLE g_child_handle[32];
static DWORD  g_child_pid[32];
static DWORD  g_child_kill_at[32];   /* ml799: tick when a hard kill is due, 0 = none */
static DWORD  g_child_root[32];      /* ml878: the pid the app knows it by (its own, for a program we started) */
static BOOL   g_child_orphan[32];    /* ml878: started by a program of ours that has ended cleanly */
static BOOL   g_child_window[32];    /* ml878: orphan with a visible window at the last look */
static BOOL   g_child_had_window[32];/* ml878: orphan ever seen with a visible window */
static int    g_child_misses[32];    /* ml878: looks in a row its family showed no sign of a game */
static int    g_child_n;

static void agent_log( const char *fmt, ... );   /* defined below; reap_children logs */

static BOOL is_child_pid( DWORD pid )
{
    int i;
    for (i = 0; i < g_child_n; i++) if (g_child_pid[i] == pid) return TRUE;
    return FALSE;
}

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

/* ml878: A LAUNCHER'S GAME IS PART OF THE LAUNCHER'S ENTRY.
 *
 * Prince of Persia: The Two Thrones refuses to run unless its launcher,
 * PrinceOfPersia.exe, starts it, and a launcher may exit once it has started
 * the game. We only knew the program we started, so its exit read as "the game
 * ended": the app went back to the Games tab with the game still running, and
 * Force close and the dialog relay (is_child_pid) never reached the game.
 *
 * Built so that NO OTHER GAME CHANGES BEHAVIOUR (user rule): while a program we
 * started runs, nothing here runs; when it ends with a non-zero code it is
 * reported at once, exactly as before, and whatever it left running is not
 * ours. Only when it ends CLEANLY does the agent look (one process snapshot)
 * for what it started. Those programs become ORPHANS of its entry if one of
 * them looks like the game -- started less than ORPHAN_YOUNG_MS ago (still
 * loading) or showing a window -- and the exit report waits for them. An old,
 * windowless helper (a crash reporter started with the game) never qualifies,
 * so it cannot hold the report back: with nothing that qualifies, the report
 * goes out at once, as before.
 *
 * While orphans run (watch_orphans, once a second): what they start joins too,
 * Force close reaches them, their dialogs are relayed. The report goes out when
 * a windowed orphan exits non-zero (its code: the game crashed), when the last
 * orphan is gone, or when for ORPHAN_MISSES looks in a row none qualifies (code
 * 0: only helpers are left; they keep running, untracked, as before).
 *
 * A parent id only names a parent while that pid cannot have been reused: we
 * hold a handle to every tracked process, which keeps its pid, and a candidate
 * created BEFORE its parent cannot be its child. */
#define ORPHAN_YOUNG_MS 60000   /* the app's own first-frame wait */
#define ORPHAN_MISSES   3

static void remove_child( int i )
{
    g_child_n--;
    g_child_handle[i] = g_child_handle[g_child_n];
    g_child_pid[i] = g_child_pid[g_child_n];
    g_child_kill_at[i] = g_child_kill_at[g_child_n];
    g_child_root[i] = g_child_root[g_child_n];
    g_child_orphan[i] = g_child_orphan[g_child_n];
    g_child_window[i] = g_child_window[g_child_n];
    g_child_had_window[i] = g_child_had_window[g_child_n];
    g_child_misses[i] = g_child_misses[g_child_n];
}

static void report_exit( DWORD root, DWORD code )
{
    char line[96];
    snprintf( line, sizeof(line), "pid=%lu code=%ld\r\n", (unsigned long)root, (long)(int)code );
    append_text_file( EXIT_PATH, line );
    agent_log( "%s", line );
}

static ULONGLONG process_start_time( HANDLE h )
{
    FILETIME created, exited, kernel, user;
    if (!GetProcessTimes( h, &created, &exited, &kernel, &user )) return 0;
    return ((ULONGLONG)created.dwHighDateTime << 32) | created.dwLowDateTime;
}

static BOOL is_young( HANDLE h )
{
    ULONGLONG start = process_start_time( h ), now;
    FILETIME ft;

    if (!start) return FALSE;
    GetSystemTimeAsFileTime( &ft );
    now = ((ULONGLONG)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    return now >= start && now - start < (ULONGLONG)ORPHAN_YOUNG_MS * 10000;   /* 100 ns units */
}

/* Every live process whose parent is the ending program `root` (still listed:
 * its handle is open) or, with root == 0, any orphan, joins as an orphan of
 * that one's entry. Several passes: a grandchild can be listed first. */
static int adopt_children( DWORD root )
{
    PROCESSENTRY32W pe;
    HANDLE snap, h;
    BOOL added = TRUE;
    int i, pass, joined = 0;

    snap = CreateToolhelp32Snapshot( TH32CS_SNAPPROCESS, 0 );
    if (snap == INVALID_HANDLE_VALUE) return 0;
    for (pass = 0; added && pass < 4; pass++)
    {
        added = FALSE;
        pe.dwSize = sizeof(pe);
        if (!Process32FirstW( snap, &pe )) break;
        do
        {
            ULONGLONG parent_start, start;
            DWORD family;

            if (g_child_n >= 32) break;
            if (is_child_pid( pe.th32ProcessID )) continue;
            for (i = 0; i < g_child_n; i++)
                if (g_child_pid[i] == pe.th32ParentProcessID &&
                    (g_child_orphan[i] || (root && g_child_pid[i] == root))) break;
            if (i == g_child_n) continue;
            h = OpenProcess( SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE,
                             FALSE, pe.th32ProcessID );
            if (!h) continue;
            parent_start = process_start_time( g_child_handle[i] );
            start = process_start_time( h );
            if (parent_start && start && start < parent_start)
            {
                CloseHandle( h );   /* older than the parent: an earlier owner of that pid started it */
                continue;
            }
            family = g_child_root[i];
            g_child_handle[g_child_n] = h;
            g_child_pid[g_child_n] = pe.th32ProcessID;
            g_child_kill_at[g_child_n] = 0;
            g_child_root[g_child_n] = family;
            g_child_orphan[g_child_n] = TRUE;
            g_child_window[g_child_n] = FALSE;
            g_child_had_window[g_child_n] = FALSE;
            g_child_misses[g_child_n] = 0;
            if (g_child_kill_at[i])
            {
                /* the user already asked to close this game: this part too */
                EnumWindows( close_windows_proc, (LPARAM)pe.th32ProcessID );
                g_child_kill_at[g_child_n] = GetTickCount() + CLOSE_GRACE_MS;
                if (!g_child_kill_at[g_child_n]) g_child_kill_at[g_child_n] = 1;
            }
            g_child_n++;
            joined++;
            added = TRUE;
            agent_log( "pid=%lu %ls, started by pid=%lu, stays with pid=%lu's entry",
                       (unsigned long)pe.th32ProcessID, pe.szExeFile,
                       (unsigned long)pe.th32ParentProcessID, (unsigned long)family );
        } while (Process32NextW( snap, &pe ));
    }
    CloseHandle( snap );
    return joined;
}

static BOOL CALLBACK mark_window_proc( HWND hwnd, LPARAM lp )
{
    DWORD pid = 0;
    int i;

    if (!IsWindowVisible( hwnd )) return TRUE;
    GetWindowThreadProcessId( hwnd, &pid );
    for (i = 0; i < g_child_n; i++)
        if (g_child_orphan[i] && g_child_pid[i] == pid) g_child_window[i] = g_child_had_window[i] = TRUE;
    return TRUE;
}

static void mark_orphan_windows( void )
{
    int i;
    for (i = 0; i < g_child_n; i++) g_child_window[i] = FALSE;
    EnumWindows( mark_window_proc, 0 );
}

/* Does anything of `root`'s orphans look like the game? Call after mark_orphan_windows. */
static BOOL orphans_look_like_game( DWORD root, int *count )
{
    BOOL live = FALSE;
    int i;

    *count = 0;
    for (i = 0; i < g_child_n; i++)
    {
        if (!g_child_orphan[i] || g_child_root[i] != root) continue;
        (*count)++;
        if (g_child_window[i] || is_young( g_child_handle[i] )) live = TRUE;
    }
    return live;
}

/* Stop tracking `root`'s orphans; they keep running, as untracked programs did before ml878. */
static void release_orphans( DWORD root )
{
    int i = 0;
    while (i < g_child_n)
    {
        if (g_child_orphan[i] && g_child_root[i] == root)
        {
            CloseHandle( g_child_handle[i] );
            remove_child( i );
            continue;
        }
        i++;
    }
}

/* A program the app started has ended (entry i, handle still open). */
static void root_exited( int i, DWORD code )
{
    DWORD root = g_child_pid[i];
    int joined = 0, count;

    if (!code) joined = adopt_children( root );   /* before the handle closes: the pid stays ours */
    CloseHandle( g_child_handle[i] );
    remove_child( i );
    if (!joined)
    {
        report_exit( root, code );   /* every program that started nothing: as before ml878 */
        return;
    }
    mark_orphan_windows();
    if (!orphans_look_like_game( root, &count ))
    {
        agent_log( "pid=%lu ended cleanly; what it left running (%d) is not a game -- reported as before", (unsigned long)root, count );
        release_orphans( root );
        report_exit( root, code );
        return;
    }
    agent_log( "pid=%lu ended cleanly while %d program(s) it started run on: its exit is reported when they are done",
               (unsigned long)root, count );
}

/* An orphan has ended (entry i, handle still open). */
static void orphan_exited( int i, DWORD code )
{
    DWORD root = g_child_root[i], pid = g_child_pid[i];
    BOOL had_window = g_child_had_window[i];
    int count;

    adopt_children( 0 );   /* what it started on its way out (a bootstrapper's game) */
    CloseHandle( g_child_handle[i] );
    remove_child( i );
    agent_log( "pid=%lu (of pid=%lu's entry) ended, code %ld", (unsigned long)pid, (unsigned long)root, (long)(int)code );
    if (had_window && code)
    {
        release_orphans( root );   /* the game itself crashed: report it now, whatever is left */
        report_exit( root, code );
        return;
    }
    mark_orphan_windows();
    if (!orphans_look_like_game( root, &count ))
    {
        release_orphans( root );
        report_exit( root, 0 );
    }
}

/* Once a second; does nothing (no snapshot) unless orphans exist. */
static void watch_orphans( void )
{
    DWORD roots[32];
    int i, j, n = 0, count, misses;

    for (i = 0; i < g_child_n; i++)
    {
        if (!g_child_orphan[i]) continue;
        for (j = 0; j < n; j++) if (roots[j] == g_child_root[i]) break;
        if (j == n) roots[n++] = g_child_root[i];
    }
    if (!n) return;
    adopt_children( 0 );
    mark_orphan_windows();
    for (j = 0; j < n; j++)
    {
        BOOL live = orphans_look_like_game( roots[j], &count );

        misses = 0;
        for (i = 0; i < g_child_n; i++)
            if (g_child_orphan[i] && g_child_root[i] == roots[j] && g_child_misses[i] > misses)
                misses = g_child_misses[i];
        misses = live ? 0 : misses + 1;
        for (i = 0; i < g_child_n; i++)
            if (g_child_orphan[i] && g_child_root[i] == roots[j]) g_child_misses[i] = misses;
        if (misses >= ORPHAN_MISSES)
        {
            agent_log( "pid=%lu's entry: %d program(s) left, none with a window -- reported as ended",
                       (unsigned long)roots[j], count );
            release_orphans( roots[j] );
            report_exit( roots[j], 0 );
        }
    }
}

static void reap_children( void )
{
    int i = 0;
    while (i < g_child_n)
    {
        if (WaitForSingleObject( g_child_handle[i], 0 ) == WAIT_OBJECT_0)
        {
            DWORD code = 0;

            GetExitCodeProcess( g_child_handle[i], &code );
            if (g_child_orphan[i]) orphan_exited( i, code );
            else root_exited( i, code );
            i = 0;   /* ml878: entries may have joined or left */
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
            g_child_root[g_child_n] = pi.dwProcessId;   /* ml878: its own entry */
            g_child_orphan[g_child_n] = FALSE;
            g_child_window[g_child_n] = FALSE;
            g_child_had_window[g_child_n] = FALSE;
            g_child_misses[g_child_n] = 0;
            g_child_n++;
        }
        else CloseHandle( pi.hProcess );
    }
    HeapFree( GetProcessHeap(), 0, cmdline );
    return pid;
}

/* ml883: THE INSTALL KEY A COPIED GAME LACKS.
 *
 * Prince of Persia: The Two Thrones' launcher (PrinceOfPersia.exe) starts the
 * game from the folder its installer recorded in
 *     HKLM\SOFTWARE\Ubisoft\Prince of Persia The Two Thrones\1.00.999
 * (Product_Path; the launcher is 32-bit, so it reads the Wow6432Node view). A
 * folder copied onto the device has no such key: the launcher passes its
 * hardware check (ml880), hides its window, fails to start pop3.exe and quits
 * with exit code 0 -- "closed before it started" (0.1.146-0.1.148: "Ubisoft"
 * missing under HKLM\Software twice, and no process creation for pop3.exe ever
 * reached Wine). PCGamingWiki's fix for the same symptom on Windows ("Launcher
 * not working") is that key with Product_Path and Profiles_Path set to the
 * game's folder; the other three values are what the retail installer writes.
 *
 * Written just before such a launch, so it follows the folder wherever the game
 * is kept, and only for the files listed here (the launcher name plus a file
 * beside it that identifies the game). Values the key already has are kept,
 * except the folder paths, which must name the folder being launched. */
struct install_value
{
    const WCHAR *name;
    const WCHAR *data;   /* NULL: the launched program's folder */
};

static const struct install_value pop_two_thrones_values[] =
{
    { L"Product_Path", NULL },
    { L"Profiles_Path", NULL },
    { L"Product_Executable", L"PrinceOfPersia.exe" },
    { L"Product_Language", L"9" },
    { L"Product_Release", L"Retail EMEA" },
};

static const struct install_key
{
    const WCHAR *exe;      /* the launched file's name */
    const WCHAR *marker;   /* a file beside it that identifies the game */
    const WCHAR *key;      /* under HKLM\Software, in the 32-bit view */
    const struct install_value *values;
    unsigned int count;
} install_keys[] =
{
    { L"PrinceOfPersia.exe", L"pop3.exe", L"Ubisoft\\Prince of Persia The Two Thrones\\1.00.999",
      pop_two_thrones_values, ARRAYSIZE(pop_two_thrones_values) },
};

static void write_install_key( const WCHAR *exe )
{
    const WCHAR *name = exe, *p;
    WCHAR folder[MAX_PATH], path[MAX_PATH + 32], keypath[256], have[MAX_PATH];
    unsigned int i, j;
    size_t len;

    for (p = exe; *p; p++) if (*p == '\\' || *p == '/') name = p + 1;
    len = name - exe;
    if (len < 2 || len > MAX_PATH) return;
    memcpy( folder, exe, (len - 1) * sizeof(WCHAR) );   /* without the separator */
    folder[len - 1] = 0;

    for (i = 0; i < ARRAYSIZE(install_keys); i++)
    {
        const struct install_key *k = &install_keys[i];
        BOOL wow_view;
        DWORD disp;
        HKEY hkey;
        LONG err;

        if (_wcsicmp( name, k->exe )) continue;
        swprintf( path, ARRAYSIZE(path), L"%ls\\%ls", folder, k->marker );
        if (GetFileAttributesW( path ) == INVALID_FILE_ATTRIBUTES) continue;

        /* The server shows a 32-bit program HKLM\Software\Wow6432Node in place
         * of HKLM\Software whenever that key exists; this agent is 64-bit and
         * always gets the plain view, so it names the node itself. */
        wow_view = !RegOpenKeyExW( HKEY_LOCAL_MACHINE, L"Software\\Wow6432Node", 0, KEY_READ, &hkey );
        if (wow_view) RegCloseKey( hkey );
        swprintf( keypath, ARRAYSIZE(keypath), L"Software\\%ls%ls", wow_view ? L"Wow6432Node\\" : L"", k->key );
        err = RegCreateKeyExW( HKEY_LOCAL_MACHINE, keypath, 0, NULL, REG_OPTION_NON_VOLATILE,
                               KEY_QUERY_VALUE | KEY_SET_VALUE, NULL, &hkey, &disp );
        if (err)
        {
            agent_log( "install key HKLM\\%ls: create failed, error %ld", keypath, err );
            continue;
        }
        agent_log( "install key HKLM\\%ls (%s) for %ls", keypath,
                   disp == REG_CREATED_NEW_KEY ? "created" : "already there", name );
        for (j = 0; j < k->count; j++)
        {
            const WCHAR *want = k->values[j].data ? k->values[j].data : folder;
            DWORD type, size = sizeof(have) - sizeof(WCHAR);

            memset( have, 0, sizeof(have) );
            if (!RegQueryValueExW( hkey, k->values[j].name, NULL, &type, (BYTE *)have, &size ) &&
                type == REG_SZ && (k->values[j].data || !_wcsicmp( have, folder )))
            {
                agent_log( "install key   %ls=%ls (kept)", k->values[j].name, have );
                continue;
            }
            err = RegSetValueExW( hkey, k->values[j].name, 0, REG_SZ, (const BYTE *)want,
                                  (DWORD)((wcslen( want ) + 1) * sizeof(WCHAR)) );
            agent_log( "install key   %ls=%ls%s", k->values[j].name, want,
                       err ? " -- FAILED" : "" );
        }
        RegCloseKey( hkey );
    }
}

static void handle_request( void )
{
    char *text = read_text_file( REQUEST_PATH );
    char id[128], exe[1024], dir[1024], args[2048], cache[2048], tso[16], mono[16], hook[8], result[256];
    char fx[32];          /* ml912 */
    WCHAR *wexe, *wdir, *wargs, *wcache = NULL;
    DWORD pid, err = 0;
    int cache_mode = 0;   /* ml830: 0 = leave the environment alone, 1 = off, 2 = cache dir */
    int tso_mode = 0;     /* ml849: 0 = leave it, 1 = FEX_TSOENABLED=0 (off), 2 = FEX_TSOENABLED=1 (on) */
    int mono_mode = 0;    /* ml868: 0 = leave it, 1 = MONO_THREADS_SUSPEND=<mono> */
    int hook_mode = 0;    /* ml873: 0 = leave it, 1 = MADEIRA_WINEMONO_BRIDGE=1 */
    int fx_mode = 0;      /* ml912: 0 = leave it, 1 = MetalFX upscaling at factor fx */
    struct saved_env saved[7];

    if (!text) return;
    /* Delete first so a failure cannot be retried forever. */
    DeleteFileW( REQUEST_PATH );
    get_field( text, "id", id, sizeof(id) );
    /* ml798: "kill=<pid>" — force close a program we started. */
    if (get_field( text, "kill", args, sizeof(args) ))
    {
        DWORD kpid = strtoul( args, NULL, 10 );
        BOOL ok = FALSE;
        int i, members = 0;
        g_close_posted = 0;
        /* ml878: and its orphans (a launcher's game), which carry its pid as root. */
        for (i = 0; i < g_child_n; i++)
            if (g_child_root[i] == kpid || g_child_pid[i] == kpid)
            {
                EnumWindows( close_windows_proc, (LPARAM)g_child_pid[i] );
                /* Polite close first; the reap loop terminates after the grace. */
                g_child_kill_at[i] = GetTickCount() + CLOSE_GRACE_MS;
                if (!g_child_kill_at[i]) g_child_kill_at[i] = 1;
                members++;
                ok = TRUE;
            }
        if (!members)
        {
            /* Not ours: close its windows now, terminate if none took it. */
            EnumWindows( close_windows_proc, (LPARAM)kpid );
            if (g_close_posted) ok = TRUE;
            else
            {
                HANDLE h = OpenProcess( PROCESS_TERMINATE, FALSE, kpid );
                if (h) { ok = TerminateProcess( h, 1 ); CloseHandle( h ); }
            }
        }
        agent_log( "kill id=%s pid=%lu -> %s (WM_CLOSE to %d window(s) of %d program(s), hard kill in %d ms if ignored)",
                   id, (unsigned long)kpid, ok ? "ok" : "err", g_close_posted, members, CLOSE_GRACE_MS );
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
    /* ml849: per-game FEX memory-ordering switch. FEX rebuilds its environment
     * in every process's ProcessInit (the CRT .CRT$FEXB InitEnv reads the
     * PEB block CreateProcessW copied from ours), so the value set around this
     * one CreateProcessW is what the game's own FEX context loads. */
    if (get_field( text, "tso", tso, sizeof(tso) ))
    {
        if (!strcmp( tso, "off" )) tso_mode = 1;
        else if (!strcmp( tso, "on" )) tso_mode = 2;
        else agent_log( "tso=%s ignored: neither \"off\" nor \"on\"", tso );
    }
    /* ml868: Wine Mono's thread-suspend policy, which it reads from the game's
     * environment at startup. The app sends "coop" for 32-bit .NET games: Mono's
     * default stops threads with SuspendThread + GetThreadContext, which a 32-bit
     * thread here cannot honour (see SessionLauncher.monoSuspend). */
    if (get_field( text, "monosuspend", mono, sizeof(mono) ))
    {
        if (!strcmp( mono, "coop" ) || !strcmp( mono, "hybrid" ) || !strcmp( mono, "preemptive" ))
            mono_mode = 1;
        else agent_log( "monosuspend=%s ignored: not coop, hybrid or preemptive", mono );
    }
    /* ml873: FEX's Wine Mono hook. FEX recognises libmono-2.0-x86.dll but only arms
     * its backpatcher handling when MADEIRA_WINEMONO_BRIDGE=1 is in the game's
     * environment (its [mono-winemono] line says which it saw). */
    if (get_field( text, "monohook", hook, sizeof(hook) ))
    {
        if (!strcmp( hook, "on" )) hook_mode = 1;
        else agent_log( "monohook=%s ignored: not \"on\"", hook );
    }
    /* ml912: MetalFX upscaling for this game. DXMT's d3d11 swapchain (64- and
     * 32-bit d3d11.dll alike) takes the MetalFX spatial-scaler path when
     * DXMT_METALFX_SPATIAL_SWAPCHAIN=1 is in the game's environment, and reads
     * the factor from DXMT_CONFIG (d3d11.metalSpatialUpscaleFactor). */
    if (get_field( text, "metalfx", fx, sizeof(fx) ))
    {
        double f = atof( fx );
        if (strspn( fx, "0123456789." ) == strlen( fx ) && f >= 1.0 && f <= 3.0) fx_mode = 1;
        else agent_log( "metalfx=%s ignored: not a factor between 1 and 3", fx );
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

    /* ml849: FEX_TSOENABLED for this CreateProcessW only, same snapshot rule. */
    if (tso_mode)
    {
        if (!save_env( &saved[2], L"FEX_TSOENABLED" ))
        {
            agent_log( "tso override skipped: could not save the agent's environment" );
            tso_mode = 0;
        }
        else
        {
            BOOL ok = SetEnvironmentVariableW( L"FEX_TSOENABLED", tso_mode == 1 ? L"0" : L"1" );
            agent_log( "tso=%s: FEX_TSOENABLED=%s%s (agent had %ls)", tso, tso_mode == 1 ? "0" : "1",
                       ok ? "" : " FAILED", saved[2].value ? saved[2].value : L"<unset>" );
        }
    }

    /* ml868: MONO_THREADS_SUSPEND for this CreateProcessW only, same snapshot rule. */
    if (mono_mode)
    {
        if (!save_env( &saved[3], L"MONO_THREADS_SUSPEND" ))
        {
            agent_log( "monosuspend override skipped: could not save the agent's environment" );
            mono_mode = 0;
        }
        else
        {
            WCHAR wmono[16];
            BOOL ok;
            MultiByteToWideChar( CP_UTF8, 0, mono, -1, wmono, ARRAYSIZE(wmono) );
            ok = SetEnvironmentVariableW( L"MONO_THREADS_SUSPEND", wmono );
            agent_log( "monosuspend=%s: MONO_THREADS_SUSPEND=%s%s (agent had %ls)", mono, mono,
                       ok ? "" : " FAILED", saved[3].value ? saved[3].value : L"<unset>" );
        }
    }

    /* ml873: MADEIRA_WINEMONO_BRIDGE for this CreateProcessW only, same snapshot rule. */
    if (hook_mode)
    {
        if (!save_env( &saved[4], L"MADEIRA_WINEMONO_BRIDGE" ))
        {
            agent_log( "monohook override skipped: could not save the agent's environment" );
            hook_mode = 0;
        }
        else
        {
            BOOL ok = SetEnvironmentVariableW( L"MADEIRA_WINEMONO_BRIDGE", L"1" );
            agent_log( "monohook=on: MADEIRA_WINEMONO_BRIDGE=1%s (agent had %ls)",
                       ok ? "" : " FAILED", saved[4].value ? saved[4].value : L"<unset>" );
        }
    }

    /* ml912: MetalFX for this CreateProcessW only, same snapshot rule. The factor
     * goes FIRST in DXMT_CONFIG, so it can never land inside a per-exe [section]
     * of whatever madeira-dxmt.txt put there. */
    if (fx_mode)
    {
        BOOL ok_sw = save_env( &saved[5], L"DXMT_METALFX_SPATIAL_SWAPCHAIN" );
        BOOL ok_conf = save_env( &saved[6], L"DXMT_CONFIG" );

        if (!ok_sw || !ok_conf)
        {
            agent_log( "metalfx override skipped: could not save the agent's environment" );
            if (saved[5].value) HeapFree( GetProcessHeap(), 0, saved[5].value );
            if (saved[6].value) HeapFree( GetProcessHeap(), 0, saved[6].value );
            fx_mode = 0;
        }
        else
        {
            size_t old_len = saved[6].value ? wcslen( saved[6].value ) : 0;
            WCHAR wfx[32], *conf = HeapAlloc( GetProcessHeap(), 0, (old_len + 96) * sizeof(WCHAR) );
            BOOL ok1, ok2 = FALSE;

            MultiByteToWideChar( CP_UTF8, 0, fx, -1, wfx, ARRAYSIZE(wfx) );
            ok1 = SetEnvironmentVariableW( L"DXMT_METALFX_SPATIAL_SWAPCHAIN", L"1" );
            if (conf)
            {
                wcscpy( conf, L"d3d11.metalSpatialUpscaleFactor = " );
                wcscat( conf, wfx );
                if (old_len)
                {
                    wcscat( conf, L";" );
                    wcscat( conf, saved[6].value );
                }
                ok2 = SetEnvironmentVariableW( L"DXMT_CONFIG", conf );
                HeapFree( GetProcessHeap(), 0, conf );
            }
            agent_log( "metalfx=%s: DXMT_METALFX_SPATIAL_SWAPCHAIN=1%s, factor in DXMT_CONFIG%s (agent had DXMT_CONFIG=%ls)",
                       fx, ok1 ? "" : " FAILED", ok2 ? "" : " FAILED",
                       saved[6].value ? saved[6].value : L"<unset>" );
        }
    }

    write_install_key( wexe );   /* ml883 */
    pid = start_process( wexe, wargs, wdir );
    if (!pid) err = GetLastError();
    if (cache_mode)
    {
        /* Back to exactly what the agent had; a NULL snapshot removes. */
        restore_env( &saved[0] );
        restore_env( &saved[1] );
    }
    if (tso_mode) restore_env( &saved[2] );   /* ml849 */
    if (mono_mode) restore_env( &saved[3] );  /* ml868 */
    if (hook_mode) restore_env( &saved[4] );  /* ml873 */
    if (fx_mode)                               /* ml912 */
    {
        restore_env( &saved[5] );
        restore_env( &saved[6] );
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

/* ml875: the app's controller came or went (C:\madeira\devchange.txt holds
 * "arrival" or "removal") -- the touch controls' Xbox pad, or a paired
 * controller.
 *
 * SDL (FNA games such as Celeste) re-scans XInput only when Windows sends
 * WM_DEVICECHANGE to the message-only window it registered with
 * RegisterDeviceNotification. Wine sends those from its plugplay service, which
 * does not run in this session (no \pipe\wine_plugplay), so a pad that appeared
 * after the game started was never seen: Celeste 0.1.138 with the Xbox preset
 * switched on mid-game. Send the same message ourselves, to every message-only
 * window in the session but ours. SendMessageTimeout, because WM_DEVICECHANGE
 * carries a pointer that Wine copies into the receiving process only for a sent
 * message; ABORTIFHUNG and a short timeout, so one stuck thread cannot stall the
 * poll loop. SDL answers with a re-scan 300 ms and 2 s later. */
static void handle_devchange( void )
{
    static const GUID hid_interface =
        { 0x4d1e55b2, 0xf16f, 0x11cf, { 0x88, 0xcb, 0x00, 0x11, 0x11, 0x00, 0x00, 0x30 } };
    static const WCHAR name[] =
        L"\\\\?\\HID#VID_045E&PID_028E&IG_00#madeira&0&0000#{4d1e55b2-f16f-11cf-88cb-001111000030}";
    union
    {
        DEV_BROADCAST_DEVICEINTERFACE_W hdr;
        BYTE bytes[offsetof( DEV_BROADCAST_DEVICEINTERFACE_W, dbcc_name ) + sizeof(name)];
    } note;
    char *text = read_text_file( DEVCHANGE_PATH );
    BOOL arrival = !text || !strstr( text, "removal" );
    HWND hwnd = NULL;
    int sent = 0, silent = 0;

    DeleteFileW( DEVCHANGE_PATH );
    if (text) HeapFree( GetProcessHeap(), 0, text );

    memset( &note, 0, sizeof(note) );
    note.hdr.dbcc_size = sizeof(note);
    note.hdr.dbcc_devicetype = DBT_DEVTYP_DEVICEINTERFACE;
    note.hdr.dbcc_classguid = hid_interface;
    memcpy( note.bytes + offsetof( DEV_BROADCAST_DEVICEINTERFACE_W, dbcc_name ), name, sizeof(name) );

    while ((hwnd = FindWindowExW( HWND_MESSAGE, hwnd, NULL, NULL )))
    {
        DWORD pid = 0;
        DWORD_PTR answer;

        GetWindowThreadProcessId( hwnd, &pid );
        if (pid == GetCurrentProcessId()) continue;
        if (SendMessageTimeoutW( hwnd, WM_DEVICECHANGE,
                                 arrival ? DBT_DEVICEARRIVAL : DBT_DEVICEREMOVECOMPLETE,
                                 (LPARAM)&note, SMTO_ABORTIFHUNG, 250, &answer ))
            sent++;
        else
            silent++;
    }
    agent_log( "devchange %s: WM_DEVICECHANGE to %d message-only window(s), %d did not answer",
               arrival ? "arrival" : "removal", sent, silent );
}

/* ml876: A GAME'S MESSAGE BOX, SHOWN BY THE APP AS AN ALERT.
 *
 * In a game session nothing draws GDI windows -- the app shows what the game
 * renders through Direct3D -- so a MessageBox was invisible, and the game sat
 * waiting for a click nobody could give until the app's 60 s first-frame
 * watchdog gave up: Prince of Persia: The Two Thrones (0.1.141) put up a
 * one-line box with an OK button and never got past it.
 *
 * Each poll, the first visible dialog window (#32770 -- what MessageBox and
 * DialogBox create) of a program we started is written to C:\madeira\dialog.txt
 *     hwnd=0x1002c
 *     title=<caption>
 *     text=<a line of static text>          (one per line)
 *     button=<control id> <label>           (one per push button)
 * and when it goes away the file becomes "closed=0x1002c". The app answers in
 * C:\madeira\dialog-answer.txt ("hwnd=0x1002c", "button=1") and the agent
 * presses that button -- WM_COMMAND/BN_CLICKED, exactly what a click sends.
 *
 * ml878: launchers are dialogs too (PrinceOfPersia.exe, an MFC dialog), so:
 * owner-drawn buttons count when they carry a label (skinned launchers draw
 * their own buttons), disabled ones never do, and a disabled dialog is skipped
 * -- a dialog is disabled while a modal one it opened is up (a launcher's
 * Settings), and that one is shown in its place; when it closes, the dialog
 * under it is enabled again and shown again. */
#define DIALOG_PATH        L"C:\\madeira\\dialog.txt"
#define DIALOG_TMP_PATH    L"C:\\madeira\\dialog.tmp"
#define DIALOG_ANSWER_PATH L"C:\\madeira\\dialog-answer.txt"
#ifndef BS_TYPEMASK
#define BS_TYPEMASK 0x0000000FL
#endif
static HWND g_dialog;   /* the dialog the app was told about; NULL = none */

/* ml879: in a game session a dialog is now SHOWN (the app's dialog overlay,
 * driver_ios.c winios_game_CreateWindowSurface), so the alert is only a
 * convenience: offered ("simple=1") for message-box-like dialogs -- text plus
 * enabled push buttons -- whose buttons are easier to hit as an iOS alert than
 * with the pointer. Anything richer (a launcher: pictures, trees, lists, combo
 * boxes, check boxes, progress bars, owner-drawn or disabled buttons) is used
 * through the window itself. One exception is offered for any dialog: a
 * DISABLED button that starts the game ("force=<id> <label>"; launch/play/start
 * in a few languages). Launchers of the era grey it out when their hardware
 * check does not know the GPU -- Prince of Persia: The Two Thrones' "Launch
 * Game !" next to "Unsupported card -- Apple A17 Pro GPU" -- and pressing it
 * anyway (WM_COMMAND/BN_CLICKED, which no MFC/Win32 handler re-checks against
 * the disabled state) is what the user asks for. */
struct dialog_info { char text[4096]; char buttons[1024]; char force[1024]; BOOL complex; int enabled_buttons; };

static BOOL starts_game( const WCHAR *label )
{
    static const WCHAR *const words[] = { L"launch", L"play", L"start", L"lancer", L"jouer", L"spielen",
                                          L"jugar", L"iniciar", L"avvia", L"gioca" };
    WCHAR lower[256];
    unsigned int i;

    lstrcpynW( lower, label, ARRAYSIZE(lower) );
    CharLowerW( lower );
    for (i = 0; i < ARRAYSIZE(words); i++) if (wcsstr( lower, words[i] )) return TRUE;
    return FALSE;
}

static BOOL CALLBACK find_dialog_proc( HWND hwnd, LPARAM lp )
{
    WCHAR cls[16];
    DWORD pid = 0;

    if (!IsWindowVisible( hwnd ) || !IsWindowEnabled( hwnd )) return TRUE;
    GetWindowThreadProcessId( hwnd, &pid );
    if (!is_child_pid( pid )) return TRUE;
    if (!GetClassNameW( hwnd, cls, ARRAYSIZE(cls) ) || lstrcmpiW( cls, L"#32770" )) return TRUE;
    *(HWND *)lp = hwnd;
    return FALSE;
}

/* Append "<key><line>\r\n" to `buf` for every line of `w`, as UTF-8. */
static void append_lines( char *buf, size_t size, const char *key, const WCHAR *w )
{
    char utf8[4096], *line = utf8, *end;

    if (WideCharToMultiByte( CP_UTF8, 0, w, -1, utf8, sizeof(utf8), NULL, NULL ) <= 0) return;
    utf8[sizeof(utf8) - 1] = 0;
    for (;;)
    {
        size_t used = strlen( buf );
        char brk;

        end = strpbrk( line, "\r\n" );
        brk = end ? *end : 0;
        if (end) *end = 0;
        if (used + 1 < size) snprintf( buf + used, size - used, "%s%s\r\n", key, line );
        if (!end) break;
        line = end + 1;
        if (brk == '\r' && *line == '\n') line++;
    }
}

static BOOL CALLBACK dialog_child_proc( HWND child, LPARAM lp )
{
    struct dialog_info *info = (struct dialog_info *)lp;
    WCHAR cls[32], label[1024];
    LONG style, kind;
    int i, j;

    if (!IsWindowVisible( child ) || !GetClassNameW( child, cls, ARRAYSIZE(cls) )) return TRUE;
    style = GetWindowLongW( child, GWL_STYLE );
    label[0] = 0;
    GetWindowTextW( child, label, ARRAYSIZE(label) );
    if (!lstrcmpiW( cls, L"Static" ))
    {
        /* ml879: an icon or a picture, not text: its "text" is a resource id,
         * 0xffff + ordinal, which read as "ÿh" in the alert */
        kind = style & SS_TYPEMASK;
        if (kind == SS_ICON || kind == SS_BITMAP || kind == SS_ENHMETAFILE || label[0] == 0xffff) return TRUE;
        if (label[0]) append_lines( info->text, sizeof(info->text), "text=", label );
        return TRUE;
    }
    if (lstrcmpiW( cls, L"Button" ))
    {
        info->complex = TRUE;   /* a list, tree, combo or edit box, a progress bar, a custom control */
        return TRUE;
    }
    kind = style & BS_TYPEMASK;
    if (kind != BS_PUSHBUTTON && kind != BS_DEFPUSHBUTTON && kind != BS_OWNERDRAW)
    {
        info->complex = TRUE;   /* check box, radio button, group box */
        return TRUE;
    }
    if (kind == BS_OWNERDRAW) info->complex = TRUE;   /* a skinned launcher's button */
    for (i = j = 0; label[i]; i++)   /* "&Yes" -> "Yes", "&&" -> "&" */
    {
        if (label[i] == '&')
        {
            if (label[i + 1] != '&') continue;
            i++;
        }
        label[j++] = label[i];
    }
    label[j] = 0;
    if (!label[0])
    {
        info->complex = TRUE;
        return TRUE;
    }
    {
        char key[32];
        snprintf( key, sizeof(key), "%s=%d ", IsWindowEnabled( child ) ? "button" : "force", GetDlgCtrlID( child ) );
        if (IsWindowEnabled( child ))
        {
            info->enabled_buttons++;
            append_lines( info->buttons, sizeof(info->buttons), key, label );
        }
        else
        {
            info->complex = TRUE;   /* ml878: greyed out in the game too */
            if (starts_game( label )) append_lines( info->force, sizeof(info->force), key, label );
        }
    }
    return TRUE;
}

static void relay_dialogs( void )
{
    static struct dialog_info info;
    static unsigned int seq;
    char out[6144];
    WCHAR title[256];
    HWND hwnd = NULL;
    DWORD pid = 0;

    if (g_dialog && (!IsWindow( g_dialog ) || !IsWindowVisible( g_dialog )))
    {
        snprintf( out, sizeof(out), "closed=0x%llx\r\n", (unsigned long long)(ULONG_PTR)g_dialog );
        write_text_file( DIALOG_TMP_PATH, out );
        MoveFileExW( DIALOG_TMP_PATH, DIALOG_PATH, MOVEFILE_REPLACE_EXISTING );
        agent_log( "dialog 0x%llx closed", (unsigned long long)(ULONG_PTR)g_dialog );
        g_dialog = NULL;
    }
    if (!g_child_n) return;
    EnumWindows( find_dialog_proc, (LPARAM)&hwnd );
    /* ml878: a dialog opened over the one shown takes its place (see above). */
    if (!hwnd || hwnd == g_dialog) return;

    g_dialog = hwnd;
    GetWindowThreadProcessId( hwnd, &pid );
    title[0] = 0;
    GetWindowTextW( hwnd, title, ARRAYSIZE(title) );
    memset( &info, 0, sizeof(info) );
    EnumChildWindows( hwnd, dialog_child_proc, (LPARAM)&info );
    /* ml878: seq= makes every announcement new to the app, which skips a file
     * it has already read: the same dialog shown again after a dialog over it
     * closed must not look like the copy it saw before. */
    snprintf( out, sizeof(out), "hwnd=0x%llx\r\nseq=%u\r\nsimple=%d\r\n", (unsigned long long)(ULONG_PTR)hwnd,
              ++seq, !info.complex && info.enabled_buttons > 0 );
    append_lines( out, sizeof(out), "title=", title );
    strncat( out, info.text, sizeof(out) - strlen( out ) - 1 );
    strncat( out, info.buttons, sizeof(out) - strlen( out ) - 1 );
    strncat( out, info.force, sizeof(out) - strlen( out ) - 1 );   /* ml879 */
    write_text_file( DIALOG_TMP_PATH, out );
    MoveFileExW( DIALOG_TMP_PATH, DIALOG_PATH, MOVEFILE_REPLACE_EXISTING );
    /* ml880: the app no longer shows alerts for these (the user asked never to
     * see them again; a game session shows the window itself since ml879), so
     * dialog.txt goes unread and this line is the record. */
    agent_log( "dialog 0x%llx from pid %lu:\n%s", (unsigned long long)(ULONG_PTR)hwnd,
               (unsigned long)pid, out );
}

static void handle_dialog_answer( void )
{
    char *text = read_text_file( DIALOG_ANSWER_PATH );
    char hv[32], bv[16];

    DeleteFileW( DIALOG_ANSWER_PATH );
    if (!text) return;
    if (get_field( text, "hwnd", hv, sizeof(hv) ) && get_field( text, "button", bv, sizeof(bv) ))
    {
        HWND hwnd = (HWND)(ULONG_PTR)strtoull( hv, NULL, 16 );
        int id = atoi( bv );
        if (hwnd && hwnd == g_dialog && IsWindow( hwnd ))
        {
            PostMessageW( hwnd, WM_COMMAND, MAKEWPARAM( id, BN_CLICKED ), (LPARAM)GetDlgItem( hwnd, id ) );
            agent_log( "dialog %s: pressed button %d for the user", hv, id );
        }
        else agent_log( "dialog answer for %s ignored: that dialog is gone", hv );
    }
    HeapFree( GetProcessHeap(), 0, text );
}

int WINAPI wWinMain( HINSTANCE inst, HINSTANCE prev, LPWSTR cmdline, int show )
{
    char ready[64];
    unsigned int polls;

    CreateDirectoryW( AGENT_DIR, NULL );
    DeleteFileW( READY_PATH );
    DeleteFileW( REQUEST_PATH );
    DeleteFileW( RESULT_PATH );
    DeleteFileW( DEVCHANGE_PATH );   /* ml875: a notice from before this session */
    DeleteFileW( DIALOG_PATH );      /* ml876: likewise a dialog and its answer */
    DeleteFileW( DIALOG_ANSWER_PATH );
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
    for (polls = 0;; polls++)
    {
        Sleep( 200 );
        if (GetFileAttributesW( REQUEST_PATH ) != INVALID_FILE_ATTRIBUTES) handle_request();
        if (GetFileAttributesW( DEVCHANGE_PATH ) != INVALID_FILE_ATTRIBUTES) handle_devchange();   /* ml875 */
        if (GetFileAttributesW( DIALOG_ANSWER_PATH ) != INVALID_FILE_ATTRIBUTES) handle_dialog_answer();   /* ml876 */
        if (g_child_n && polls % 5 == 0) watch_orphans();   /* ml878: once a second, a no-op without orphans */
        if (g_child_n || g_dialog) relay_dialogs();
        if (g_child_n) reap_children();
    }
    return 0;
}
