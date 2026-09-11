/* Stub wintypes.dll (ARM64EC) — the WinRT type helpers.
 *
 * Unity IL2CPP builds (Everything is Crab, 0.1.52 log) import
 * api-ms-win-core-winrt-robuffer-l1-1-0.dll from GameAssembly.dll; Wine's
 * api-set map resolves that to wintypes.dll, which the bundle did not ship,
 * so GameAssembly.dll failed to load (status c0000135) and the game died
 * before drawing. Desktop games never actually call the WinRT buffer
 * marshaler, so every entry point here just says "not implemented". */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#define E_NOTIMPL_ ((HRESULT)0x80004001L)

HRESULT WINAPI RoGetBufferMarshaler( void **marshaler )
{
    if (marshaler) *marshaler = NULL;
    return E_NOTIMPL_;
}

HRESULT WINAPI RoResolveNamespace( void *name, void *dir, DWORD paths_count, void **paths,
                                   DWORD *count, void **out, DWORD *sub_count, void **sub )
{
    if (count) *count = 0;
    if (sub_count) *sub_count = 0;
    return E_NOTIMPL_;
}

HRESULT WINAPI RoGetMetaDataFile( void *name, void *dispenser, void **path, void **import, DWORD *token )
{
    if (path) *path = NULL;
    if (import) *import = NULL;
    return E_NOTIMPL_;
}

HRESULT WINAPI RoParseTypeName( void *name, DWORD *count, void **parts )
{
    if (count) *count = 0;
    return E_NOTIMPL_;
}

HRESULT WINAPI RoIsApiContractPresent( void *name, USHORT major, USHORT minor, BOOL *present )
{
    if (present) *present = FALSE;
    return S_OK;
}

HRESULT WINAPI RoIsApiContractMajorVersionPresent( void *name, USHORT major, BOOL *present )
{
    if (present) *present = FALSE;
    return S_OK;
}

BOOL WINAPI DllMain( HINSTANCE inst, DWORD reason, void *reserved )
{
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls( inst );
    return TRUE;
}
