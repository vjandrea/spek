# REVIEW.md

Draft PR/issue comments for `alexkay/spek`, prepared for manual review and
posting. Nothing here has been posted. This file, like `AGENTS.md`, lives
only on the `agents` branch: never merge it into `master` or include it in
an upstream PR.

## Comment for PR #338 ("Fix compatibility with FFmpeg 8")

Possible bug in the transform call's stride parameter, worth a second look
before this merges:

```cpp
this->tx(this->cx, this->tmp, this->get_input(), sizeof(AVComplexFloat));
```

`libavutil/tx.h`'s docs for `AV_TX_FLOAT_RDFT` say, for the forward
(real-to-complex) direction: "stride must be the spacing between two
samples in bytes", referring to the *input* array, which here is `N`
contiguous real `float` samples (4 bytes each), not complex pairs. The one
official usage example in the FFmpeg tree, `fftools/ffplay.c`'s audio
visualizer (same real-to-complex forward transform, same purpose), passes
`sizeof(float)`:

```cpp
s->rdft_fn(s->rdft, data[ch], data_in[ch], sizeof(float));
```

Passing `sizeof(AVComplexFloat)` (8 bytes) here would make the transform
step through the input two floats at a time, i.e. only read every other
sample. If that's right, the spectrogram would be built from half the
actual audio, with the rest silently skipped, which wouldn't necessarily be
obvious from output that "looks like a spectrogram" without checking
against a known reference signal.

I haven't run this PR's code myself to confirm the practical effect, just
flagging the discrepancy against the documented semantics and the only
official example I could find, in case it's worth a second pair of eyes
before this merges. Happy to help verify if useful:
`tests/test-fft.cc` already has known-good magnitude assertions (a
single-bin sine wave should land at exactly -6.02 dB and nowhere else) that
would catch this directly if run against this PR's branch.

## Comment for PR #344 ("Replace avfft.h with libavutil/tx.h for FFT calculation")

On review, no correctness concerns found. This correctly allocates the
output buffer with `av_malloc` (matters because FFmpeg's SIMD tx
implementations assume SIMD-width alignment that a `std::vector` or
similar wouldn't guarantee: we hit a segfault from exactly that mistake in
our own first pass at this same port, on x86_64/AVX specifically, invisible
on arm64/NEON where it happened to work by luck) and uses the documented
`sizeof(float)` stride for the forward transform. This looks equivalent to,
and as correct as, a version of this same fix we verified independently
against `tests/test-fft.cc` (DC, silence, and single-bin sine magnitude all
matching the pre-FFmpeg-7 implementation exactly, across every FFT size the
suite covers) and under ASan/UBSan.

Worth noting for whoever reviews this: this is now the third independently
written port of this exact fix (this PR, #338, and unreleased work from
us), all landing on essentially the same approach. That's a good sign the
diagnosis and the general approach are right, even where the
implementations differ in detail.

## Notes on posting these

- Post only if/when we decide not to duplicate #338/#344 with a fourth PR
  of our own; see the "Comparative analysis" section of `AGENTS.md` for the
  open question this depends on.
- If posted, post as plain review comments on the existing PRs, not as a
  new issue or a competing PR. The goal is to help get one of the existing,
  already-good-faith PRs merged, not to draw attention to a fourth
  implementation.
- Reads fine standalone even without ever opening our own CI/release PRs;
  it doesn't reference or depend on unpublished work.
