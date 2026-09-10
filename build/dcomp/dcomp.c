/* dcomp.c — stub DirectComposition (dcomp.dll) for Madeira, ARM64EC.
 *
 * Rhythm Doctor's multiwindow_unity.dll plugin imports dcomp.dll for its
 * window-moving effects. The bundle has no dcomp, so the import failed,
 * the plugin never loaded, the game's window helper threw and the logo
 * scene sat on a black window forever (Player.log: DllNotFoundException
 * multiwindow_unity → NullReferenceException in scnLogo.Awake).
 *
 * This DLL exists so such plugins LOAD. Every public entry point is
 * exported. The device factories hand back one object that answers
 * QueryInterface for anything (IUnknown, IDCompositionDevice/2/3,
 * IDCompositionDesktopDevice, IDCompositionDeviceDebug) and whose methods
 * all return E_NOTIMPL, except Commit/WaitForCommitCompletion which
 * succeed. Callers that create a device and then fail to create visuals
 * see ordinary HRESULT failures instead of a missing DLL. No compositing
 * happens: there is no DirectComposition on this port.
 *
 * Built by build/dcomp/build.sh with llvm-mingw's arm64ec target into
 * app/Madeira/arm64ec-windows/dcomp.dll. */

#define WIN32_LEAN_AND_MEAN
#define COBJMACROS
#include <windows.h>
#include <objbase.h>

/* A vtable large enough for any DirectComposition device interface
 * (IDCompositionDevice3 has ~50 slots). Slot 0-2 are IUnknown, slot 3 is
 * Commit and slot 4 WaitForCommitCompletion on every device interface;
 * everything else is a method that reports E_NOTIMPL without touching
 * its arguments, which is ABI-safe: the caller owns the argument area. */
#define STUB_SLOTS 96

typedef struct stub_device
{
    const void **vtbl;
    LONG ref;
} stub_device;

static HRESULT STDMETHODCALLTYPE stub_notimpl( void *iface )
{
    (void)iface;
    return E_NOTIMPL;
}

static HRESULT STDMETHODCALLTYPE stub_ok( void *iface )
{
    (void)iface;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE stub_QueryInterface( void *iface, REFIID riid, void **out )
{
    stub_device *dev = iface;
    (void)riid;
    if (!out) return E_POINTER;
    *out = dev;
    InterlockedIncrement( &dev->ref );
    return S_OK;
}

static ULONG STDMETHODCALLTYPE stub_AddRef( void *iface )
{
    stub_device *dev = iface;
    return InterlockedIncrement( &dev->ref );
}

static ULONG STDMETHODCALLTYPE stub_Release( void *iface )
{
    stub_device *dev = iface;
    LONG ref = InterlockedDecrement( &dev->ref );
    if (!ref) HeapFree( GetProcessHeap(), 0, dev );
    return ref;
}

static const void *stub_vtbl[STUB_SLOTS];
static LONG stub_vtbl_ready;

static void init_vtbl( void )
{
    if (InterlockedCompareExchange( &stub_vtbl_ready, 1, 0 )) return;
    for (int i = 0; i < STUB_SLOTS; i++) stub_vtbl[i] = (const void *)stub_notimpl;
    stub_vtbl[0] = (const void *)stub_QueryInterface;
    stub_vtbl[1] = (const void *)stub_AddRef;
    stub_vtbl[2] = (const void *)stub_Release;
    stub_vtbl[3] = (const void *)stub_ok;   /* Commit */
    stub_vtbl[4] = (const void *)stub_ok;   /* WaitForCommitCompletion */
}

static HRESULT create_stub_device( void **out )
{
    stub_device *dev;
    if (!out) return E_POINTER;
    init_vtbl();
    dev = HeapAlloc( GetProcessHeap(), HEAP_ZERO_MEMORY, sizeof(*dev) );
    if (!dev) return E_OUTOFMEMORY;
    dev->vtbl = stub_vtbl;
    dev->ref = 1;
    *out = dev;
    return S_OK;
}

/* ---- exports (dcomp.dll public surface) -------------------------------- */

HRESULT WINAPI DCompositionCreateDevice( void *dxgi_device, REFIID iid, void **device )
{
    (void)dxgi_device; (void)iid;
    return create_stub_device( device );
}

HRESULT WINAPI DCompositionCreateDevice2( IUnknown *rendering_device, REFIID iid, void **device )
{
    (void)rendering_device; (void)iid;
    return create_stub_device( device );
}

HRESULT WINAPI DCompositionCreateDevice3( IUnknown *rendering_device, REFIID iid, void **device )
{
    (void)rendering_device; (void)iid;
    return create_stub_device( device );
}

HRESULT WINAPI DCompositionCreateSurfaceHandle( DWORD desired_access, SECURITY_ATTRIBUTES *attributes, HANDLE *handle )
{
    (void)desired_access; (void)attributes;
    if (handle) *handle = NULL;
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionAttachMouseDragToHwnd( void *visual, HWND hwnd, BOOL enable )
{
    (void)visual; (void)hwnd; (void)enable;
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionAttachMouseWheelToHwnd( void *visual, HWND hwnd, BOOL enable )
{
    (void)visual; (void)hwnd; (void)enable;
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionBoostCompositorClock( BOOL enable )
{
    (void)enable;
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionGetFrameId( int kind, ULONGLONG *frame_id )
{
    (void)kind;
    if (frame_id) *frame_id = 0;
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionGetStatistics( ULONGLONG frame_id, void *stats, UINT count, void *ids, UINT *actual )
{
    (void)frame_id; (void)stats; (void)count; (void)ids;
    if (actual) *actual = 0;
    return E_NOTIMPL;
}

HRESULT WINAPI DCompositionGetTargetStatistics( ULONGLONG frame_id, const void *target_id, void *stats )
{
    (void)frame_id; (void)target_id; (void)stats;
    return E_NOTIMPL;
}

DWORD WINAPI DCompositionWaitForCompositorClock( UINT count, const HANDLE *handles, DWORD timeout )
{
    (void)count; (void)handles;
    /* Callers use this like WaitForSingleObject on the vblank; behave as
     * a plain timeout-driven sleep so loops built on it still advance. */
    if (timeout && timeout != INFINITE) Sleep( timeout > 16 ? 16 : timeout );
    else Sleep( 16 );
    return WAIT_TIMEOUT;
}

BOOL WINAPI DllMain( HINSTANCE inst, DWORD reason, LPVOID reserved )
{
    (void)reserved;
    if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls( inst );
    return TRUE;
}
