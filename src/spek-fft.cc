#include <cmath>

extern "C" {
#include <libavutil/tx.h>
}

#include "spek-fft.h"

class FFTPlanImpl : public FFTPlan
{
public:
    FFTPlanImpl(int nbits);
    ~FFTPlanImpl() override;

    void execute() override;

private:
    AVTXContext *ctx = nullptr;
    av_tx_fn tx_fn = nullptr;
    AVComplexFloat *freq;
};

std::unique_ptr<FFTPlan> FFT::create(int nbits)
{
    return std::unique_ptr<FFTPlan>(new FFTPlanImpl(nbits));
}

FFTPlanImpl::FFTPlanImpl(int nbits) : FFTPlan(nbits)
{
    // avfft.h's av_rdft_* (real DFT) API was removed by FFmpeg; this is its
    // replacement. Unlike the old in-place, packed-array RDFT, this produces
    // N/2+1 separate complex bins (including DC and Nyquist, both with a
    // zero imaginary part), out-of-place, unscaled (matching the old
    // av_rdft_calc, which didn't scale either).
    //
    // av_malloc, not std::vector: FFmpeg's SIMD tx implementations require
    // the in/out buffers aligned beyond what a default allocator guarantees
    // (same reason FFTPlan's own input buffer uses it). Skipping this
    // segfaults on x86_64/AVX; arm64/NEON happened to tolerate it.
    this->freq = (AVComplexFloat*) av_malloc(sizeof(AVComplexFloat) * this->get_output_size());

    float scale = 1.0f;
    av_tx_init(&this->ctx, &this->tx_fn, AV_TX_FLOAT_RDFT, 0, this->get_input_size(), &scale, 0);
}

FFTPlanImpl::~FFTPlanImpl()
{
    av_tx_uninit(&this->ctx);
    av_freep(&this->freq);
}

void FFTPlanImpl::execute()
{
    this->tx_fn(this->ctx, this->freq, this->get_input(), sizeof(float));

    // Calculate magnitudes.
    int n = this->get_input_size();
    float n2 = n * n;
    for (int i = 0; i <= n / 2; i++) {
        float re = this->freq[i].re;
        float im = this->freq[i].im;
        this->set_output(i, 10.0f * log10f((re * re + im * im) / n2));
    }
}
