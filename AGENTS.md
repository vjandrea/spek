# AGENTS.md

Spek: acoustic spectrum analyser, C++11. Decodes audio with FFmpeg (libavformat/libavcodec/libavutil), renders the GUI with wxWidgets >= 3.1.7. Cross-platform: Linux/BSD, Windows, macOS.

Upstream: `alexkay/spek` (Alexander Kojevnikov, maintainer). This checkout's `origin` remote is `vjandrea/spek`, a fork, so treat upstream issues/PRs as belonging to `alexkay/spek` unless told otherwise.

## Build

Autotools project, not CMake.

```
./autogen.sh   # from a git checkout, generates configure
./configure
make
```

Binary lands at `src/spek`. `sudo make install` to install system-wide.

Useful configure flags: `--enable-valgrind` runs the test suite under valgrind (auto-detected if valgrind is present).

Dependencies to build: `libavformat`, `libavcodec`, `libavutil` (FFmpeg, versions pinned in `configure.ac`), wxWidgets >= 3.1.7, gettext >= 0.21.

**FFmpeg 7+ compatibility (fixed, know this before touching `spek-fft.cc`):** `libavcodec/avfft.h`'s real-DFT API (`av_rdft_*`) was removed by FFmpeg. `spek-fft.cc` now uses the replacement, `libavutil/tx.h`'s `AV_TX_FLOAT_RDFT` (`av_tx_init`/`av_tx_fn`/`av_tx_uninit`). Two things about that API that aren't obvious from its docs:
- It's out-of-place (separate in/out buffers) and returns N/2+1 plain `AVComplexFloat` values (DC and Nyquist both with `.im == 0`), not the old single-array Hermitian-packed layout, so no more manual unpacking.
- **The in/out buffers must be allocated with `av_malloc`, not a `std::vector`, `new[]`, or similar.** FFmpeg's SIMD transform code assumes SIMD-width alignment (`AV_TX_UNALIGNED` isn't set); a `std::vector`'s default allocator doesn't guarantee that. This segfaults immediately on x86_64 (AVX) and works by pure luck on arm64 (NEON): it'll look fine in local testing on Apple Silicon and then crash in CI on Linux/Windows. Ask me how I know.

## Source layout

- `src/` : the app. `libspek.a` (audio/FFT/pipeline/palette/utils, no GUI deps) links into the `spek` binary (GUI: window, spectrogram, ruler, preferences, artwork). See `src/Makefile.am` for the exact file split.
- `tests/` : `test` (unit tests: `test-audio.cc`, `test-fft.cc`, `test-utils.cc`) and `perf` (perf harness), run via `make check`. Custom minimal test framework in `tests/test.h`/`test.cc` (no gtest/catch2) : `test(message, expected, actual)`. Sample audio fixtures live in `tests/samples/`.
- `data/` : desktop file, metainfo, icons (per-size dirs).
- `po/` : gettext translations, many languages already present; `po/POTFILES.in` lists translatable sources.
- `dist/` : per-platform packaging (`debian/`, `freebsd/`, `osx/` bundle script + Info.plist, `win/` NSIS/WiX bundle + installer assets). Not part of the app build.
- `man/`, `MANUAL.md`, `web/` : documentation and the spek.cc website assets.

## Testing

```
make check
```

Runs `tests/test` (and `tests/perf`). Add new unit tests as functions in the matching `tests/test-*.cc` file and register them in `tests/test.h`/`test.cc`; don't introduce a new test framework.

**FFmpeg-version-dependent fixtures:** `tests/test-audio.cc`'s MP3 duration and the AAC fixture's decoded sample count are not exact-match assertions, they're ranges (`duration_max` param on `test_info()`, `samples_min` param on `test_read()`). Different FFmpeg versions disagree on whether decoding trims a codec's encoder priming/gapless-padding samples (Ubuntu 24.04's FFmpeg 6.1: no; Homebrew's FFmpeg 8.1.1: yes). Spek just forwards whatever `avformat`/`avcodec` report, so there's no single "correct" exact value across the CI matrix; if you touch this file, don't tighten those back to exact `test()` calls without checking both directions first.

## Code style

- C++11 (`-std=gnu++11`), `-Wall -Wextra` enabled; keep changes warning-clean.
- Files: `spek-<component>.cc`/`.h`, lowercase-hyphenated.
- No exceptions-heavy style; this is a small, fairly old, conservative C++ codebase, prefer matching existing patterns over introducing new idioms (smart pointers, templates, etc. are used sparingly today).

## CI/CD

`.github/workflows/ci.yml` (build + `make check` on every push/PR to `master`, plus manual `workflow_dispatch`) and `.github/workflows/release.yml` (on a `v*` tag push, or `workflow_dispatch` with a `tag_name` input for a test run) exist on the `feat/ci` branch, not yet merged to `master`. There was no CI at all before this; `master` is kept exactly aligned with `upstream/master` (see the `upstream` remote, `git@github.com:alexkay/spek.git`) on purpose, so this work lives on a branch instead.

- `ci.yml`: Linux (apt), macOS (Homebrew, Apple Silicon only, see the runner-label note below), Windows (MSYS2/mingw64, native build, not the MXE cross-compile the real release uses, chosen for CI speed).
- `release.yml`: source tarball (`make distcheck`), a universal (arm64 + x86_64) macOS `.dmg`, and a Windows `.msi` via the documented MXE cross-compile + WiX pipeline, all attached to one draft GitHub Release for manual review before publishing.
- Testing `workflow_dispatch` before a workflow file is merged to the default branch doesn't work, not via the UI, CLI, or API: GitHub only shows/accepts manual dispatches for workflows that already exist on `master`. A tag push doesn't have that restriction (it just uses whatever workflow file exists at that ref), which is how `release.yml` got tested from `feat/ci` without merging: `git tag v0.0.0-test feat/ci && git push origin v0.0.0-test`. Delete the tag and the resulting draft release afterward.

### Platform gotchas (all fixed, but easy to reintroduce)

- **macOS `ACLOCAL_PATH`:** `brew --prefix wxwidgets` returns `/opt/homebrew/opt/wxwidgets`, a symlink into the versioned Cellar dir (needed for `aclocal` to find `AM_PATH_WXCONFIG`/`wxwin.m4`). macOS's BSD `find` does not follow a symlink given as the starting path by default (GNU `find` on Linux does); `find -L` is required, or `find` silently walks nothing and `ACLOCAL_PATH` ends up empty. This is the same failure `dist/osx/README.md`'s manual `ln -s ... wxwin.m4` step works around; the CI fix (`find -L "$(brew --prefix wxwidgets)" -name wxwin.m4`) is the same fix without hardcoding a wx version number.
- **macOS keg-only `gettext` disables NLS silently:** Homebrew's `gettext` is keg-only (not linked into the default include/lib paths). `PATH` alone makes its CLI tools (`msgfmt` etc.) findable, which is enough for `configure` to *look* like it's finding gettext, but `configure`'s separate link check ("checking for GNU gettext in libintl") needs `-I.../gettext/include`/`-L.../gettext/lib` too. Without them it fails quietly and `configure` reports "checking whether to use NLS... no", which means `po/` never builds `.gmo` files, which only breaks something visibly if a later step actually needs them (`dist/osx/bundle.sh`'s per-language `cp` loop; nothing in `make check` touches `po/` output, so this was invisible until `release.yml` first actually ran `bundle.sh`). Fix: also `export CPPFLAGS="-I$(brew --prefix gettext)/include"` and `LDFLAGS="-L$(brew --prefix gettext)/lib"` alongside the `PATH` fix.
- **`src/Makefile.am`:** `spek_CXXFLAGS` (the top-level `spek` GUI binary) didn't include `$(AVUTIL_CFLAGS)`, only `libspek_a_CXXFLAGS` did, even though `spek-spectrogram.cc` (built as part of `spek`, not `libspek.a`) includes `spek-fft.h`, which needs `libavutil/mem.h`. Worked by accident on Linux, where system package headers live on the default compiler search path; never on macOS/Windows, where Homebrew/MSYS2 headers need an explicit `-I`. Fixed, but if a new `libav*` header shows up in a `spek_SOURCES` file, check both `CXXFLAGS` blocks.
- **Windows/MSYS2 `pacman` and `mingw-w64-x86_64-ffmpeg`:** that package's dependency chain now pulls in `ggml`/`whisper.cpp`/`openblas` (FFmpeg's AI/speech filters), and a provider ambiguity for `fc-libs` (two providers: `gcc-libgfortran` vs `libgfortran`) can pin an older `gcc-libs` than the rest of the transaction wants, silently skipping `ffmpeg`'s install. Installing `mingw-w64-x86_64-libgfortran` explicitly steers `pacman`'s solver around it. If this breaks again, it's a transient upstream mingw64-repo inconsistency (a toolchain version bump not yet fully rebuilt across dependents), not something wrong in this repo.
- **Windows link failure against a DLL-built wx:** `spek-events.h`/`spek-events.cc` and `spek-window.cc` declare two custom wx event types (`SPEK_HAVE_SAMPLE`, `SPEK_NOTIFY_EVENT`). They used to use wx's `DECLARE_EVENT_TYPE`/`DEFINE_EVENT_TYPE` macros, which apply wx's own `WXDLLIMPEXP_CORE` dllimport/dllexport decoration, correct for wx's own event types, not for ones Spek defines itself. Harmless when wx is statically linked (the real Windows release, via MXE's `.static` target); breaks the link (`undefined reference to __imp_SPEK_HAVE_SAMPLE`) against a dynamically-linked wx (MSYS2's `mingw-w64-x86_64-wxwidgets3.2-msw` package, used for the fast native CI build). Now declared/defined as plain `extern const wxEventType ...` instead, sidestepping wx's DLL macros entirely. Don't reach for `DECLARE_EVENT_TYPE`/`DEFINE_EVENT_TYPE` for a new custom event type; use the same plain-extern pattern (or, better, wx's modern `wxDECLARE_EVENT`/`wxDEFINE_EVENT`, not used here yet).
- **GitHub Actions macOS runner labels:** `macos-13` and `macos-14` were removed from GitHub's hosted runner fleet ("only the latest 2 macOS versions" are kept); a job pinned to `macos-13` just sits queued forever, not slow, genuinely stuck, with zero error until you notice. The only remaining Intel label, `macos-15-large`, is a paid "large" runner and bills even on public repos (`"recent account payments have failed or your spending limit needs to be increased"` if none is on file). `release.yml` avoids paying for it: it cross-builds x86_64 on the free `macos-15` (Apple Silicon) runner via a second Homebrew installed under Rosetta 2 at `/usr/local` (Homebrew's own documented coexistence design alongside the native `/opt/homebrew`; see `docs.brew.sh/FAQ`), then `lipo`s the two `.app` bundles together (`dist/osx/lipo-universal.sh`). This whole labeling scheme will need bumping again once macOS 15 ages out the same way; watch for jobs that queue forever with no error.

### Known open issue: `dist/win/mxe.diff` doesn't apply to current MXE

`release.yml`'s `windows-cross-compile` job (`git clone --depth 1 https://github.com/mxe/mxe.git` then `git apply ../dist/win/mxe.diff`) fails: `error: src/ffmpeg-1-fixes.patch: No such file or directory`, `patch does not apply`. MXE is a rolling repo (no releases/tags to pin), and `dist/win/mxe.diff` (checked into this repo) was generated against some specific historical MXE commit that isn't `master` anymore; MXE has since reorganized its ffmpeg patch files. Not investigated further yet: needs either finding the MXE commit `mxe.diff` actually applies to (and pinning `git clone` to it instead of `--depth 1` off `master`), or regenerating `mxe.diff` against current MXE. `source-tarball` passed end to end. The macOS job's gettext/NLS fix (see above) is verified locally for the native arm64 half only (`bundle.sh` and `make-dmg.sh` both complete, correctly, with real dependency bundling and a valid `.dmg`); the Rosetta x86_64 half and the `lipo-universal.sh` merge haven't actually run successfully anywhere yet, since the run that would have exercised them failed earlier (before this gettext fix). The Windows `.msi` leg (`windows-cross-compile` + `windows-msi`) is the one part of `release.yml` still known-broken, per this section.

## Working with upstream issues/PRs

- Treat `alexkay/spek` as the issue tracker and PR target unless the user says to use the fork instead.
- This is a mature, low-velocity C++ project; before proposing a fix, check whether it's already fixed on a newer tag/branch, and whether the issue is platform-specific (Windows/macOS packaging issues are common and live under `dist/`).
- Respect the GPLv3 license (see `CREDITS.md`, `LICENSE`, `lic/`).
