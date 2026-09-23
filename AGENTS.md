# Spek project context

Spek is a cross-platform C++ acoustic-spectrum analyser. It uses FFmpeg for
audio decoding and wxWidgets for its desktop GUI. The project uses GNU
Autotools (Autoconf/Automake/Libtool) and targets Unix-like systems, macOS,
and Windows.

Upstream: `alexkay/spek` (Alexander Kojevnikov, maintainer). This checkout's
`origin` remote is `vjandrea/spek`, a fork; `upstream` is `alexkay/spek`.
Treat upstream issues/PRs as belonging to `alexkay/spek` unless told
otherwise. This is a mature, low-velocity project: before proposing a fix,
check whether it's already fixed on a newer tag/branch, and **check the PR
triage below before writing a fix for a build/CI/FFmpeg problem**: several
already have open, unmerged PRs.

## Repository map

- `src/`: application source and the `spek` executable.
- `tests/`: C++ test suite and committed audio fixtures in `tests/samples/`.
- `data/`: icons, desktop integration, and other application data.
- `po/`: gettext translations.
- `dist/`: packaging scripts and platform-specific release assets:
  `dist/osx/`, `dist/win/`, and Debian metadata.
- `.github/workflows/ci.yml`: Linux/macOS/Windows build-and-test CI (lives on
  `feat/ci`, not yet merged to `master`; there was no CI at all before this).
- `.github/workflows/release.yml`: source tarball, universal (arm64 +
  x86_64) macOS `.dmg`, and MXE-cross-compiled Windows `.msi` release
  artifacts, attached to a draft GitHub Release for manual review.

## Local development

```sh
./autogen.sh
make -j$(nproc)
make check -j$(nproc)
```

`./autogen.sh` runs `autoreconf -fiv` then `configure`; use it after changing
`configure.ac`, `Makefile.am`, gettext files, or Autotools inputs. Needs
Autoconf, Automake, Libtool, pkg-config, gettext, wxWidgets >= 3.1.7, and
FFmpeg dev libraries (`libavformat`, `libavcodec`, `libavutil`). The CI
workflow is the source of truth for current package names per platform.

`configure` generates `Makefile`, `config.h`, platform packaging outputs, and
`web/version`; don't hand-edit these, they're gitignored. `make distcheck` is
the release-quality source-tarball check.

## CI and release behavior

`ci.yml` runs on push/PR to `master` and on manual `workflow_dispatch`; a
feature-branch push alone does not trigger it (`pull_request` does, if a PR
is open). `release.yml` runs on `v*` tags or manual dispatch with a
`tag_name` input (must not collide with a branch name). **A workflow file
must already exist on the default branch for manual dispatch to be offered
at all** (UI, CLI, and API alike): a tag push doesn't have that restriction,
which is how `release.yml` gets tested from `feat/ci` before merging:
`git tag v0.0.0-test feat/ci && git push origin v0.0.0-test`, then delete
the tag and draft release afterward.

**GitHub Actions cache is scoped strictly per git ref, with no fallback
across different tag names** (confirmed against GitHub's own docs). Reuse
the *same* test tag name across iterations (delete and recreate it) rather
than incrementing to a new one each time, or every test starts with zero
cache and every MXE-dependent iteration costs a full ~40 to 70 minute
rebuild for nothing.

## Hard-won build/CI findings

These cost real iteration cycles (some multiple ~40 to 70 minute CI round
trips) to track down. Read before touching the related area.

### FFmpeg 7+ compatibility (`spek-fft.cc`)

`libavcodec/avfft.h`'s real-DFT API (`av_rdft_init`/`av_rdft_calc`/
`av_rdft_end`) was removed by FFmpeg. Ported to the replacement,
`libavutil/tx.h`'s `AV_TX_FLOAT_RDFT` (`av_tx_init`/`av_tx_fn`/
`av_tx_uninit`). Two things about that API that aren't obvious from its
docs:

- It's out-of-place (separate in/out buffers) and returns N/2+1 plain
  `AVComplexFloat` values (DC and Nyquist both with `.im == 0`), not the old
  single-array Hermitian-packed layout, so no manual unpacking needed.
- **The in/out buffers must be allocated with `av_malloc`, not a
  `std::vector`, `new[]`, or similar.** FFmpeg's SIMD transform code assumes
  SIMD-width alignment (`AV_TX_UNALIGNED` isn't set); a `std::vector`'s
  default allocator doesn't guarantee that. Using one for the output buffer
  segfaulted immediately on x86_64 (AVX) and worked by pure luck on arm64
  (NEON): looked fine in local Apple Silicon testing, then crashed in CI on
  Linux and Windows. Verified the eventual fix (raw `av_malloc`/`av_freep`,
  matching the input buffer's existing pattern) against `tests/test-fft.cc`
  (DC, silence, and single-bin sine magnitude all match the old
  implementation exactly, across every FFT size the suite covers) and under
  ASan+UBSan.
- `spek-audio.h` used `int64_t` without including `<cstdint>` (masked on
  platforms where some other header pulls it in transitively).
- `src/Makefile.am`'s `spek_CXXFLAGS` (the top-level GUI binary) never
  included `$(AVUTIL_CFLAGS)`, only `libspek_a_CXXFLAGS` did, even though
  `spek-spectrogram.cc` (built into `spek`, not `libspek.a`) includes
  `spek-fft.h`, which needs `libavutil/mem.h`. Worked by luck on Linux,
  where system headers are on the default include path; never on
  macOS/Windows.

See "PR triage" below: at least two other people independently ported the
same file the same way (one AI-assisted); worth cross-checking before
submitting our own version upstream.

### Windows link failure against a DLL-built wxWidgets

`spek-events.h`/`.cc` and `spek-window.cc` declared two custom wx event
types with `DECLARE_EVENT_TYPE`/`DEFINE_EVENT_TYPE`. Those macros apply wx's
own `WXDLLIMPEXP_CORE` dllimport/dllexport decoration, correct for wx's own
event types, not for ones Spek defines itself. Harmless when wx is
statically linked (the real Windows release, via MXE's `.static` target);
breaks the link (`undefined reference to __imp_SPEK_HAVE_SAMPLE`) against a
dynamically-linked wx (MSYS2's `mingw-w64-x86_64-wxwidgets3.2-msw` package,
used for the fast native Windows CI build in `ci.yml`). Fixed by declaring
and defining them as plain `extern const wxEventType ...` instead.

### FFmpeg-version-dependent test fixtures

`tests/test-audio.cc`'s MP3 duration and the AAC fixture's decoded sample
count are ranges (`duration_max` param on `test_info()`, `samples_min` on
`test_read()`), not exact matches. Different FFmpeg versions disagree on
whether decoding trims a codec's encoder priming/gapless-padding samples
(Ubuntu 24.04's FFmpeg 6.1: no; Homebrew's FFmpeg 8.1.1: yes). Spek just
forwards whatever `avformat`/`avcodec` report; there's no single "correct"
exact value across the CI matrix. Don't tighten these back to exact `test()`
calls without checking both directions first.

### macOS: keg-only Homebrew dependencies

- **`ACLOCAL_PATH`**: `brew --prefix wxwidgets` returns
  `/opt/homebrew/opt/wxwidgets`, a symlink into the versioned Cellar dir.
  macOS's BSD `find` does not follow a symlink given as the starting path by
  default (GNU `find` on Linux does); `find -L` is required, or `find`
  silently walks nothing. This is the exact failure `dist/osx/README.md`'s
  old manual `ln -s ... wxwin.m4` step existed to work around.
- **Keg-only `gettext` disables NLS silently**: `PATH` alone (for `msgfmt`
  etc.) is not enough. `configure`'s separate libintl link check needs
  `CPPFLAGS="-I$(brew --prefix gettext)/include"` and
  `LDFLAGS="-L$(brew --prefix gettext)/lib"` too, or it fails quietly
  ("checking whether to use NLS... no"), `po/` never builds `.gmo` files,
  and `bundle.sh`'s per-language `cp` loop fails on the first language.
  Nothing in `make check` touches `po/` output, so this was invisible until
  `release.yml` first actually ran `bundle.sh` for real.

### macOS: Homebrew dropped Intel support entirely (dead end, then a working alternative)

`macos-13`/`macos-14` were removed from GitHub's hosted runner fleet
("only the latest 2 macOS versions" are kept: a job pinned to `macos-13`
just sits queued forever, no error, until you notice). The only remaining
Intel label, `macos-15-large`, is a paid "large" runner that bills even on
public repos, no exception.

The obvious free-runner workaround (cross-build x86_64 on the free
`macos-15` Apple Silicon runner via a second Homebrew installed under
Rosetta 2 at `/usr/local`) **does not work**: Homebrew's installer now
hard-refuses any non-arm64 host outright ("Homebrew on macOS is only
supported on Apple Silicon processors!", confirmed directly against
install.sh's source), and its *bottles* for x86_64 macOS are gone too
(checked `ffmpeg`'s and `wxwidgets`' live bottle listings: arm64-only).
Homebrew stopped publishing Intel bottles for both formulas only around
2026-09-10 to 19, so the version gap isn't as large as "Homebrew dropped
Intel" makes it sound, but the registry's mutable tags were rewritten in
place (confirmed: an old Intel bottle blob is still fetchable by its exact
recorded digest, but the tag's manifest index no longer lists it), so even
pinning an old `homebrew-core` commit wouldn't restore normal `brew install`
resolution without unsupported digest-bypass plumbing.

**What actually works**: build FFmpeg and wxWidgets from their own upstream
source, no Homebrew involved for this slice at all, natively cross-compiled
via clang's `-arch x86_64` (Rosetta is only needed to *run* x86_64 code, not
to *compile* it: a compiler targeting a different architecture doesn't need
to execute as that architecture). `dist/osx/build-deps-x86_64.sh` builds a
decode-only FFmpeg (same trimming `dist/win/mxe.diff` does for the Windows
build: Spek only needs `libavformat`/`libavcodec`/`libavutil`, no external
codec libs, since every format the test suite decodes has a built-in FFmpeg
decoder) and a static wxWidgets, idempotently into `./deps-x86_64` so CI can
cache it (~150MB, well within cache limits). `release.yml` builds `src/spek`
against that for x86_64, then `lipo`s it directly into the arm64 `.app`'s
existing executable, no need to merge or duplicate Resources (translations,
icons, ...), those are architecture-independent and the arm64 pass already
has them correct. Verified locally end to end (both deps build with the
right `.o` architecture, `codesign -dv` reports "Mach-O universal (arm64
x86_64)" on the merged binary, and it launches without crashing) before
wiring into CI.

One `wx-config` quirk found along the way: when wx is configured with an
explicit `--host`, its own generated `wx-config` emits the bundled
third-party libs' `-l` flags correctly host-suffixed
(`-lwxtiff-3.3-x86_64-apple-darwin`), but the core wx libraries' full paths
without the suffix, even though the actual files are suffixed. Worked
around with symlinks (`libwx_baseu-3.3.a` to
`libwx_baseu-3.3-x86_64-apple-darwin.a` etc.) rather than patching
wx-config's generated script.

### GitHub Actions housekeeping

- `ubuntu-latest` is pinned to `ubuntu-24.04` in every job. Package
  names/versions shifting under a moving OS target was the single most
  common failure mode setting this up. The label migrates to Ubuntu 26 on
  2026-10-19; bump deliberately and tested when that's actually wanted, not
  automatically.
- `softprops/action-gh-release@v2`, `actions/checkout@v4`,
  `actions/upload-artifact@v4`, `actions/download-artifact@v4`, and
  `actions/cache@v4` were all still on Node 20 (GitHub force-runs them on
  Node 24 anyway, hence the deprecation warning on every run). Bumped to
  `@v3`/`@v7`/`@v7`/`@v8`/`@v6` respectively: pure runtime bumps, no
  input/behavior changes for how this repo uses them.

## Windows release build (MXE)

The Windows release job in `release.yml` builds MXE beside the repository,
at `../mxe` (`dist/win/bundle.sh` hardcodes this: from `dist/win`, its
`../../../mxe/usr` path resolves to the sibling directory, matching the
documented manual workflow in `dist/win/README.md`: clone `mxe` and `spek`
side by side). Keep the checkout, cache path, and script layout aligned if
this ever changes.

**MXE is a rolling repo with no releases/tags, and `dist/win/mxe.diff` is a
literal patch against one specific past state of two files it touches**
(`src/ffmpeg-1-fixes.patch`, `src/ffmpeg.mk`). A fresh `git clone` off
MXE's current `master` will eventually (and did) reorganize those files out
from under it, so the patch stops applying. Found the actual base commit by
walking each file's GitHub history for content matching `mxe.diff`'s "-"
side exactly: `MXE_REF=3bfb859de48d7d6325f2e9b8a1d03b00a0e8d829` ("ffmpeg:
build fixes", 2022-04-03). `release.yml` does a shallow fetch of just that
commit (`git init ../mxe && git remote add origin ... && git fetch --depth 1
origin "$MXE_REF" && git checkout FETCH_HEAD`, since a plain
`git clone --depth <n> <sha>` isn't supported) rather than `git clone` off
`master`. Bump `MXE_REF` (and regenerate `mxe.diff` against the new commit)
only when a newer MXE ffmpeg/wxwidgets recipe is actually needed.

### Attempts and findings, in the order they were hit

1. GLib (an MXE host-side build tool dependency) failed to download PCRE1
   from SourceForge during its `meson.build` fallback fetch. A 3-attempt
   retry loop was tried first and failed identically all three times: not
   transient. Root cause: we only had `libpcre2-dev` installed, not the
   legacy `libpcre3-dev` (PCRE1) GLib 2.70.2 actually wants; without it,
   GLib can't find system PCRE1 via pkg-config and falls back to a network
   fetch that reliably fails from GitHub-hosted runner IPs specifically
   (confirmed: the exact same URL downloaded fine from an unrelated
   residential IP at the same moment). Installing `libpcre3-dev` removes
   the network dependency entirely. The retry loop stayed in, as cheap
   insurance against other genuinely transient failures in a build this
   size; MXE's package system tracks completed packages with stamp files,
   so a retry resumes rather than starting over.
2. `gnutls` (a target-side dependency pulled in by `libbluray`, unrelated to
   ffmpeg's own `--enable-gnutls`, which `mxe.diff` removes) ran `gtkdocize`
   during `autoreconf` regardless of whether docs get built
   ("Can't exec gtkdocize"). Needed `gtk-doc-tools`. While looking at this,
   noticed `libclang-dev` and `python-is-python3` are both in MXE's own
   documented Ubuntu requirements list but were missing entirely; added
   them too rather than hit them in a separate, equally slow round trip.
3. After the MXE build itself finally succeeded, `dist/win/bundle.sh`
   failed on `realpath: ./dist/win/../../../mxe/usr: No such file or
   directory`: MXE was being cloned *inside* the checkout (`git init mxe`)
   rather than as the sibling directory `bundle.sh` expects. Fixed by
   cloning to `../mxe` instead (and follow-on: `git apply
   ../dist/win/mxe.diff` inside that step needed to become an absolute
   path captured via `$PWD` *before* the `cd ../mxe`, since the relative
   reference no longer resolved once cwd changed).
4. `windres` then failed: `can't open file 'wx/msw/amd64_dpi_aware_pmv2.manifest'`.
   `spek.rc` sets `wxUSE_DPI_AWARE_MANIFEST=2`; wx's own `wx.rc` references
   that manifest file, which exists in wx 3.1.4's own source tree (the
   version MXE's pinned recipe builds) but isn't copied into the installed
   prefix by `make install`, only regular headers are. Added our own copy,
   verbatim from wx 3.1.4's source, under `dist/win/manifest-fix/` mirroring
   wx.rc's expected relative path, and pointed `windres` at it with an
   extra `-I`. Doesn't change `spek.rc`'s actual DPI-awareness setting or
   depend on MXE's install being complete.
5. Finally, `autoreconf` failed the same way the macOS build once did:
   `possibly undefined macro: AM_PATH_WXCONFIG`. Same root cause as the
   macOS `ACLOCAL_PATH` finding above: `aclocal` doesn't scan MXE's install
   prefix by default. Never surfaced in the documented manual workflow,
   presumably because a developer's own shell already has this set from
   MXE's own build process; the CI invocation starts clean.

### Verification status (as of 2026-09-22)

The MXE build itself (pthreads, ffmpeg, wxwidgets, gnutls, everything) has
succeeded end to end at least once in real CI, confirming findings 1 and 2
above. Findings 3 through 5 (sibling directory, DPI manifest, final
ACLOCAL_PATH fix) are each individually plausible and locally
syntax-checked, but **have not yet been confirmed together in a single
successful end-to-end CI run** of `dist/win/bundle.sh` producing a working
`spek.exe`. The next step is running `release.yml` against current
`feat/ci` (reusing one test tag name, per the cache-scoping note above, so
the ~40 to 70 minute MXE rebuild doesn't repeat for nothing) and reading the
actual `Cross-compile spek.exe and test.exe` step to confirm no further
issue is hiding behind the last one found. Don't assume finding 5 was the
last blocker without that evidence.

## Issue triage (alexkay/spek, 134 open issues, surveyed 2026-09-21)

Refreshed 2026-09-22: issue count and newest issue (#353) unchanged, so this
triage is still current. Re-check before relying on it further out.

Since `vjandrea` isn't a collaborator on `alexkay/spek`, this is read-only
triage for prioritization, not actions taken (no labeling/closing).

**Critical: build is broken on current toolchains.** One real bug wearing
6+ issue numbers: FFmpeg 7/8 removed `avfft.h`. #352, #341, #335, #300,
#312, #309, #297, #308. Now has *three* independent open-PR fixes (see PR
triage) plus our own `feat/ci` branch.

**macOS: broken on current hardware/OS**, same root cause across all six,
no notarized universal/arm64 macOS build shipped: #332 (Apple Silicon
support), #347 ("support ending for Intel-based apps"), #324 (Sequoia
Gatekeeper flags it as malware), #318, #316, #302 (won't install on
Sequoia/Sonoma), #274 (no drag-to-Applications icon). PR #345 addresses the
arm64 build side of this cluster (not notarization/code-signing).

**Duplicate feature-request clusters** (long-standing, high demand):
logarithmic frequency scale (#11, most-commented open issue, #186);
batch processing (#9, #131, #144, #320, #343); remember window
size/position (#19, #163, #296); save/remember preferences (#40, #279,
#293); show bitrate/encoding info (#5, #43, #67, #174, #246); CLI/
automation/export (#169, #225, #319).

**Windows/Linux packaging clusters**: file-association/"open with" missing
(#61, #75, #85, #86, #204, #288, #317); Linux packaging (#339 Arch broken,
#326 Flatpak locale, #336 dead RPMFusion link in README, already partially
addressed by PR #301's README fix).

**Real, narrow bugs worth a look**: #328/#298 spectrum doesn't refresh on
channel switch, **has an open one-line fix, PR #321** (`offset = sample *
channels + channel`), just needs merging, don't re-diagnose from scratch.
#280 "U" keybind broken; #286 `icon.IsOk()` crash; #110 overwrites output
with no warning (data-loss UX bug); #349 negative window padding clips the
spectrogram; #154/#234 incorrect spectrum on Opus/32-bit WavPack; #329/#336/
#353 trivial doc fixes (dead Help link, dead RPMFusion link, stale README
screenshots).

**Stale, low-traction** (2012 to 2017, 0 to 1 comments, dead since ~2013):
#8, #12, #14, #16, #22, #25, #29, #30, #34, #41, #47, #95, #98, #101, #121,
#125, #185, #239, #250, #259, #272, #283, #287, #291, #294, #306, #311,
#315, #331, #350: mostly the maintainer's own original wishlist, no
external demand since. A maintainer call, not ours to act on.

## PR triage (alexkay/spek, 16 open PRs, surveyed 2026-09-22)

**Why this exists**: after independently arriving at fixes for the FFmpeg
7+ build break and the macOS Apple Silicon bundle, checked open PRs and
found close, exact overlap with at least two of them, already submitted by
other contributors months ago and never merged. Check this list before
writing a new fix for anything build/CI/FFmpeg-shaped: the work may already
be done and just waiting on the maintainer.

### Directly overlapping our changeset

- **#344** "Replace avfft.h with libavutil/tx.h for FFT calculation"
  (chenshuo, AI-generated via Gemini-CLI, opened 2026-03-06). Same
  migration we did, same target API. Correctly uses `av_malloc` for the
  output buffer (avoids the alignment segfault we hit and fixed), either
  by chance or the model followed a reasonable idiom; not explicitly
  verified by its author against any test. Uses `AVComplexFloat*` output
  and `sizeof(float)`-equivalent semantics, close to our final
  implementation.
- **#338** "Fix compatibility with FFmpeg 8" (hannesbraun, opened
  2025-10-09). Different approach: aims to keep building against older
  FFmpeg too. Also correctly `av_malloc`s its buffer. **Possible
  correctness issue**: passes `sizeof(AVComplexFloat)` (8 bytes) as the
  transform stride for the *forward* (real-input) transform; the
  documented semantics and the only official usage example found
  (`ffplay.c`) both use `sizeof(float)` (spacing between input *samples*,
  not complex pairs) for this direction. Not run or verified ourselves:
  flag and check before reusing, don't assume it's wrong outright.
- **#337** "Add missing cstdint include" (hannesbraun, opened 2025-10-09).
  Identical one-line fix to ours (`#include <cstdint>` in `spek-audio.h`).
- **#345** "Make macOS build work on Apple Silicon (arm64) Homebrew"
  (jakeobsen, opened 2026-05-01). Extremely close to our
  `dist/osx/bundle.sh`/`src/Makefile.am` fix: same `brew --prefix`
  discovery, same `ACLOCAL_PATH` export reasoning, same `CPPFLAGS`/
  `LDFLAGS` gettext fix, same `AVFORMAT_CFLAGS`/`AVCODEC_CFLAGS`/
  `AVUTIL_CFLAGS` addition to `spek_CXXFLAGS`. **Fixes something we
  don't**: resolves `@rpath/...` library references (e.g. `libwebp` to
  `libsharpyuv`) in the dependency-bundling loop, not just literal
  `$BREW_PREFIX`-prefixed paths; without it, some dependency chains can
  produce a `.app` that crashes at launch on a clean machine with a
  missing `@rpath` dylib. Worth backporting that specific fix into our own
  `bundle.sh` regardless of what happens with this PR. Explicitly depends
  on #338 for FFmpeg 8 support and deliberately didn't duplicate it: good
  prior art for how to scope a PR around existing open work.
- **#333** "Fix build with recent autotools" (bjornfor, opened
  2025-07-16). Adds `AC_CONFIG_MACRO_DIRS([m4])` to `configure.ac`. Fixes
  a *different* symptom of the same macro-discovery family of problem:
  `aclocal`/`autoreconf` failing to find `AM_GNU_GETTEXT`/
  `AM_GNU_GETTEXT_VERSION` (gettext's own macros, copied into the
  project's local `m4/` by `autopoint` but never declared as a search
  path) on newer Autoconf (reported against Nix's 2.72). This is
  complementary to, not a replacement for, our `ACLOCAL_PATH` exports:
  those point at *externally* installed wx/gettext macros (Homebrew/MXE
  kegs), this fixes discovery of macros already *inside* the checkout. If
  merged upstream, doesn't remove the need for our `ACLOCAL_PATH` fixes.
- **#271** "GitHub Action to build for macOS" (samuello1228, 2023-02-09,
  stale). Targets `macos-11`/`macos-12`, both long since removed from
  GitHub's hosted fleet, same deprecation pattern we hit with
  `macos-13`/`14`. Hardcodes `/usr/local` for the `wxwin.m4` symlink
  (Intel-only, no Apple Silicon handling at all, no FFmpeg 8 fix, no
  gettext fix). Effectively dead; useful only as evidence the runner-label
  churn is a recurring, expected cost of this kind of CI, not a one-off.
- **#268** "GitHub Action to automatically generate a ZIP with the
  files+MSI every push" (sylikc, 2023-02-06, stale, but detailed and
  informative). A full two-stage Windows MXE pipeline, same shape as
  ours. Worth knowing about even though it predates and doesn't fix our
  MXE findings above:
  - Uses `ubuntu-22.04` (older than our pinned `ubuntu-24.04`).
  - **Same MXE-pinning gap we hit**: plain `git clone` off MXE `master`
    with no ref pin, so this workflow almost certainly bit-rots the exact
    same way ours did (`mxe.diff` stops applying) as MXE's own repo moves
    on. It predates our `MXE_REF` pinning fix.
  - Different, notable technique for the sibling-directory requirement:
    clones MXE *inside* the checkout (`path: mxe` in the cache step, kept
    simple) then symlinks it out (`ln -s $(pwd)/mxe ../mxe`) to satisfy
    `bundle.sh`'s hardcoded expectation, rather than cloning directly to
    `../mxe` the way we do. Arguably cleaner for cache-path purposes
    (keeps the cached path inside the checkout, a more conventional
    `actions/cache` usage): worth considering adopting.
  - Independently confirms our found `ACLOCAL_PATH` fix's target
    directory: patches `autogen.sh` via `sed` to add
    `-I ../mxe/usr/x86_64-w64-mingw32.static/share/aclocal/` directly to
    the `autoreconf` invocation, i.e. the *target-specific* (`$HOST`)
    aclocal dir, not just the generic one. Cross-check our own
    `ACLOCAL_PATH` export covers this exact path.
  - No `libpcre3-dev`/`gtk-doc-tools`/`libclang-dev`/`python-is-python3`,
    no DPI-manifest handling: likely predates whatever MXE package
    version bump introduced those blockers, or was never run to full
    green against current MXE.

### Relevant to the issue triage, not our changeset

- **#321** "fix non-planar sample offset calculation" (Safari77, opened
  2025-01-18). One-line fix (`offset = sample * channels + channel`) for
  exactly the #328/#298 channel-switch bug flagged in the issue triage.
  Already noted there; don't re-fix, just don't forget it's pending.
- **#301** "INSTALL.md: mention CPATH for nested libav*" (mara004,
  2024-01-16). Minor doc fix for Fedora's nested `libav*` header layout,
  plus removes a dead RPMFusion link (overlaps issue #336). No code
  overlap with our work.

### Unrelated to build/CI (noted for completeness, not analyzed further)

#348 (nb.po translation fixes), #346 (Blackman-Harris window math fix),
#323/#322 (metainfo/NEWS files), #146/#105/#71 (old feature/bug PRs).

## Comparative analysis: our changeset vs. the field

Multiple independent contributors (plus us) converged on the *same* root
causes for the FFmpeg 7+ break and the macOS Apple Silicon break: strong
signal these are correctly diagnosed, not something to second-guess. Where
we differ from the existing open PRs:

- **Scope**: every existing PR is a narrow, single-purpose fix (one file,
  one platform). Ours bundles the equivalent fixes *plus* full CI/release
  automation (`ci.yml`, `release.yml`, the Windows MXE pipeline, the
  from-source x86_64 macOS build) that doesn't exist upstream at all
  today, apart from the two stale 2023 CI attempts (#271, #268). When
  preparing an upstream PR, consider whether the maintainer would rather
  review focused fixes (matching the existing PRs' shape, easier to merge
  piecemeal) versus one large CI-plus-fixes PR: **ask the user before
  assuming either**, this is a real maintainer-relationship decision, not
  a technical one.
- **Verification depth**: ours is the only avfft.h migration verified
  against the project's own `test-fft.cc` *and* ASan/UBSan. On closer
  reading of both diffs (not just their titles), neither #344 nor #338
  actually has the output-buffer alignment bug we hit and fixed: both
  already allocate via `av_malloc`, not a `std::vector` or similar, so
  that specific finding doesn't apply to either as a review comment. #344's
  stride parameter also matches the documented/`ffplay.c`-precedented
  `sizeof(float)`; #338's doesn't (see the PR triage entry above), which is
  the one still-open, unconfirmed correctness question across all three
  implementations. Draft review comment for both PRs: `REVIEW.md`.
- **Gaps in our own work found via this comparison**: #345's `@rpath`
  dependency-resolution fix (libwebp to libsharpyuv) is not in our
  `bundle.sh` and should be backported regardless of what happens with
  that PR: it's a real correctness gap for some Homebrew dependency
  chains, not just a style difference. #333's `AC_CONFIG_MACRO_DIRS([m4])`
  is a more root-cause fix for gettext macro discovery than anything we
  did (we never hit that exact symptom, so never fixed it) and is
  probably worth adding regardless of upstream's response to that PR.
- **Open question, not yet resolved**: whether to (a) submit our CI/build
  work as new PRs referencing/building on the existing ones, (b) wait and
  see if the maintainer merges the existing PRs first and rebase, or (c)
  reach out to the existing PR authors before duplicating effort further.
  Do not push a competing PR upstream without discussing this with the
  user first: that's exactly the "unvoluntarily copied work" scenario this
  triage exists to avoid.
