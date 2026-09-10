# Wine Mono (bundled .NET runtime)

CI downloads `wine-mono-<version>-x86.tar.xz` from dl.winehq.org and extracts
it here as `wine-mono-<version>/` before xcodebuild bundles this folder, so the
app ships with the .NET Framework runtime that Wine's mscoree needs for managed
executables (OneShot: World Machine Edition, FNA/XNA/MonoGame games, …).

The version must match `WINE_MONO_VERSION` in the Wine fork's
`dlls/mscoree/mscoree_private.h` (11.0.0 for the pinned Wine commit); mscoree
looks for `<WINEDATADIR>/mono/wine-mono-<version>/bin/libmono-2.0-x86_64.dll`,
and on iOS `WINEDATADIR` is the app bundle.

The extracted runtime is git-ignored (`wine-mono-*`); this file keeps the folder
present so local Xcode builds resolve the folder reference.
