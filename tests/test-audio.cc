#include <map>

#include "spek-audio.h"

#include "test.h"

struct FileInfo
{
    AudioError error;
    std::string codec_name;
    int bit_rate;
    int sample_rate;
    int bits_per_sample;
    int channels;
    double duration;
    int samples;
};

static void test_info(AudioFile *file, const FileInfo& info, double duration_max = -1.0)
{
    test("error", info.error, file->get_error());
    test(file->get_codec_name(), true, !file->get_codec_name().compare(
        0, info.codec_name.length(), info.codec_name
    ));
    test("bit rate", info.bit_rate, file->get_bit_rate());
    test("sample rate", info.sample_rate, file->get_sample_rate());
    test("bps", info.bits_per_sample, file->get_bits_per_sample());
    test("channels", info.channels, file->get_channels());

    // Some FFmpeg versions trim LAME/Xing gapless-playback padding from an
    // MP3's reported duration, some don't; Spek just forwards whatever
    // avformat computes, so accept either when duration_max is given.
    double actual = file->get_duration();
    double max_duration = duration_max >= 0.0 ? duration_max : info.duration;
    test("duration in range", true, actual >= info.duration - 1e-5 && actual <= max_duration + 1e-5);
}

static void test_read(AudioFile *file, int samples, int samples_min = -1)
{
    if (!file->get_error()) {
        file->start(0, 1024);
    }

    int samples_read = 0;
    double power = 0.0;
    int len;
    while ((len = file->read()) > 0) {
        samples_read += len;
        for (int i = 0; i < len; ++i) {
            float level = file->get_buffer()[i];
            power += level * level;
        }
    }

    // Some FFmpeg versions decode and discard a codec's encoder
    // priming/padding samples, some return them; Spek just reads whatever
    // avcodec produces, so accept either when samples_min is given.
    int min_samples = samples_min >= 0 ? samples_min : samples;
    test("samples in range", true, samples_read >= min_samples && samples_read <= samples);

    if (samples > 0) {
        power /= samples_read;
        test("error", 0, len);
        test("power", 0.0, power);
    } else {
        test("error", -1, len);
    }
}

void test_audio()
{
    // Frame-count duration of a 5-frame MP3, for FFmpeg versions that don't
    // trim gapless padding; see test_info().
    const double MP3_T_MAX = 5.0 * 1152 / 44100;
    const double AAC_T = (10240 + 628) / 2.0 / 44100;
    const double DCA_T = 8.0 * 21180 / 1411216; // file size / bit rate
    const double AC3_T = 8.0 * 2490 / 190764; // file size / bit rate

    std::map<std::string, FileInfo> files = {
        {"no.file",
            {AudioError::CANNOT_OPEN_FILE, "", 0, 0, 0, 0, 0.0, 0}},
        {"1ch-96000Hz-24bps.flac",
            {AudioError::OK, "FLAC", 0, 96000, 24, 1, 0.1, 96000 / 10}},
        {"2ch-48000Hz-16bps.flac",
            {AudioError::OK, "FLAC", 0, 48000, 16, 2, 0.1, 48000 / 10}},
        {"1ch-96000Hz-24bps.ape",
            {AudioError::OK, "Monkey", 0, 96000, 24, 1, 0.1, 96000 / 10}},
        {"2ch-48000Hz-16bps.ape",
            {AudioError::OK, "Monkey", 0, 48000, 16, 2, 0.1, 48000 / 10}},
        {"2ch-44100Hz-16bps.m4a",
            {AudioError::OK, "ALAC", 0, 44100, 16, 2, 0.1, 44100 / 10}},
        {"1ch-96000Hz-24bps.wv",
            {AudioError::OK, "WavPack", 0, 96000, 24, 1, 0.1, 96000 / 10}},
        {"2ch-48000Hz-16bps.wv",
            {AudioError::OK, "WavPack", 0, 48000, 16, 2, 0.1, 48000 / 10}},
        {"2ch-44100Hz-16bps.wav",
            {AudioError::OK, "PCM", 0, 44100, 16, 2, 0.1, 44100 / 10}},
        {"2ch-44100Hz-128cbr.mp3",
            {AudioError::OK, "MP3", 128000, 44100, 0, 2, 0.1, 44100 / 10}},
        {"2ch-44100Hz-320cbr.mp3",
            {AudioError::OK, "MP3", 320000, 44100, 0, 2, 0.1, 44100 / 10}},
        {"2ch-44100Hz-V0.mp3",
            {AudioError::OK, "MP3", 201329, 44100, 0, 2, 0.1, 44100 / 10}},
        {"2ch-44100Hz-V2.mp3",
            {AudioError::OK, "MP3", 150124, 44100, 0, 2, 0.1, 44100 / 10}},
        {"2ch-44100Hz-q100.m4a",
            {AudioError::OK, "AAC", 159649, 44100, 0, 2, AAC_T, 5120}},
        {"2ch-44100Hz-q5.ogg",
            {AudioError::OK, "Vorbis", 160000, 44100, 0, 2, 0.1, 4282}},
        {"2ch-44100Hz.dts",
            {AudioError::OK, "DCA", 1411200, 44100, 0, 2, DCA_T, 5120}},
        {"2ch-44100Hz.ac3",
            {AudioError::OK, "ATSC A/52", 192000, 44100, 0, 2, AC3_T, 4608}},
        {"2ch-44100Hz-std.mpc",
            {AudioError::OK, "Musepack", 0, 44100, 0, 2, 0.0, 5760}},
        {"2ch-44100Hz-v1.wma",
            {AudioError::OK, "Windows Media Audio 1", 128000, 44100, 0, 2, 0.138, 4 * 1024}},
        {"2ch-44100Hz-v2.wma",
            {AudioError::OK, "Windows Media Audio 2", 128000, 44100, 0, 2, 0.138, 4 * 1024}},
    };

    // Nominal content length (0.1s @ 44100Hz) of the AAC fixture, for
    // FFmpeg versions that discard its encoder priming/padding; see
    // test_read().
    const int AAC_SAMPLES_MIN = 4410;

    Audio audio;
    for (const auto& item : files) {
        auto name = item.first;
        auto info = item.second;
        auto file = audio.open(SAMPLES_DIR "/" + name, 0);
        bool is_mp3 = name.size() >= 4 && name.compare(name.size() - 4, 4, ".mp3") == 0;
        bool is_aac = name == "2ch-44100Hz-q100.m4a";
        run(
            "audio info: " + name,
            [&] () { test_info(file.get(), info, is_mp3 ? MP3_T_MAX : -1.0); }
        );
        run(
            "audio read: " + name,
            [&] () { test_read(file.get(), info.samples, is_aac ? AAC_SAMPLES_MIN : -1); }
        );
    }
}
