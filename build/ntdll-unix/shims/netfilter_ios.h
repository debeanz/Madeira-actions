/* ml824 host lookup filter for the ws2_32 unix side.
 *
 * Force-included (-include) into $WINE_SRC/dlls/ws2_32/unixlib.c only, so it
 * wraps that file's getaddrinfo() calls without patching the wine submodule.
 * The Windows declarations there are WS_getaddrinfo (USE_WS_PREFIX, and WS()
 * pastes with ##, which does not expand this macro), so nothing collides.
 *
 * Why: Unity 2018.4's built-in libcurl job (UnityWebRequest) fetches Unity's
 * cloud config from config.uca.cloud.unity3d.com:443. On this port the connect
 * fails (EHOSTUNREACH) and the curl loop never gives up: 0.1.77's spin snapshot
 * put "Background Job.Worker N" at guest RIP UnityPlayer+0x112e4e1, inside
 * libcurl's timer tree, with that host name in its state, burning a whole core
 * for the entire session and past quit. None of these telemetry/config hosts
 * is needed to play, so the lookup fails at once (NXDOMAIN) and the request
 * ends with an ordinary resolve error instead of spinning.
 *
 * Kill switch: MADEIRA_UNITY_TELEMETRY_BLOCK=0
 * (Documents/madeira-unity-telemetry.txt containing "0"). */
#ifndef MADEIRA_NETFILTER_IOS_H
#define MADEIRA_NETFILTER_IOS_H

#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int madeira_host_blocked( const char *node )
{
    static const char *const suffixes[] = { ".cloud.unity3d.com" };
    static const char *const exact[]    = { "stats.unity3d.com" };
    static int enabled = -1;
    char host[256];
    size_t n, i;

    if (!node || !*node) return 0;
    if (enabled < 0)
    {
        const char *e = getenv( "MADEIRA_UNITY_TELEMETRY_BLOCK" );
        enabled = !(e && e[0] == '0');
    }
    if (!enabled) return 0;

    n = strlen( node );
    if (n >= sizeof(host)) return 0;
    memcpy( host, node, n + 1 );
    if (n && host[n - 1] == '.') host[--n] = 0;      /* fully qualified form */

    for (i = 0; i < sizeof(exact) / sizeof(exact[0]); i++)
        if (!strcasecmp( host, exact[i] )) return 1;
    for (i = 0; i < sizeof(suffixes) / sizeof(suffixes[0]); i++)
    {
        size_t m = strlen( suffixes[i] );
        if (n > m && !strcasecmp( host + n - m, suffixes[i] )) return 1;
    }
    return 0;
}

static int madeira_getaddrinfo( const char *node, const char *service,
                                const struct addrinfo *hints, struct addrinfo **res )
{
    if (madeira_host_blocked( node ))
    {
        static int logged;
        if (logged < 16)
        {
            logged++;
            dprintf( 2, "[netfilter] ml824 '%s' -> NXDOMAIN (Unity telemetry; "
                        "madeira-unity-telemetry.txt=0 to allow)\n", node );
        }
        if (res) *res = NULL;
        return EAI_NONAME;
    }
    return getaddrinfo( node, service, hints, res );
}

#define getaddrinfo madeira_getaddrinfo

#endif /* MADEIRA_NETFILTER_IOS_H */
