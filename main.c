#include <errno.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct decoder {
    const int16_t *pcm;
    size_t frames, rate, channels, window, wpm;
    double *energy;
    size_t *runs;
    char *text, *candidate;
};

_Static_assert(offsetof(struct decoder, candidate) == 72 &&
               sizeof(struct decoder) == 80, "NASM decoder layout");
extern int decode_morse(const struct decoder *input);

static unsigned le16(const unsigned char *p)
{
    return (unsigned)p[0] | (unsigned)p[1] << 8;
}

static uint32_t le32(const unsigned char *p)
{
    return le16(p) | (uint32_t)le16(p + 2) << 16;
}

static const char *read_wav(FILE *file, struct decoder *d)
{
    unsigned char header[16];
    if (fread(header, 1, 12, file) != 12 ||
        memcmp(header, "RIFF", 4) || memcmp(header + 8, "WAVE", 4))
        return "expected a RIFF/WAVE file";

    uint32_t riff_size = le32(header + 4);
    if (fseek(file, 0, SEEK_END) != 0)
        return "cannot seek in WAV file";
    long file_size = ftell(file);
    if (file_size < 0 || riff_size < 4 ||
        (uint64_t)riff_size + 8 > (uint64_t)file_size)
        return "invalid or truncated RIFF container";

    long data_offset = 0;
    uint32_t data_size = 0;
    int have_format = 0;
    uint64_t end = (uint64_t)riff_size + 8;
    for (uint64_t offset = 12; offset < end;) {
        if (end - offset < 8 || fseek(file, (long)offset, SEEK_SET) ||
            fread(header, 1, 8, file) != 8)
            return "truncated WAV chunk header";
        uint32_t size = le32(header + 4);
        uint64_t payload = offset + 8;
        offset = payload + size + (size & 1);
        if (offset > end)
            return "truncated WAV chunk";

        if (!have_format && !memcmp(header, "fmt ", 4)) {
            if (size < 16 || fread(header, 1, 16, file) != 16)
                return "invalid WAV format chunk";
            d->channels = le16(header + 2);
            d->rate = le32(header + 4);
            if (le16(header) != 1 || le16(header + 14) != 16 ||
                (d->channels != 1 && d->channels != 2))
                return "expected 16-bit PCM WAV with one or two channels";
            if (!d->rate || le16(header + 12) != d->channels * 2 ||
                le32(header + 8) != d->rate * d->channels * 2)
                return "invalid WAV sample rate or frame layout";
            have_format = 1;
        } else if (!data_offset && !memcmp(header, "data", 4)) {
            data_offset = (long)payload;
            data_size = size;
        }
    }

    if (!have_format || !data_offset)
        return "WAV is missing a format or data chunk";
    if (data_size % (d->channels * 2))
        return "WAV data ends with an incomplete frame";
    if (!data_size)
        return "WAV contains no samples";

    int16_t *pcm = malloc(data_size);
    if (!pcm)
        return "out of memory";
    d->pcm = pcm;
    if (fseek(file, data_offset, SEEK_SET) ||
        fread(pcm, 1, data_size, file) != data_size)
        return "cannot read WAV samples";
    d->frames = data_size / (d->channels * 2);
    return NULL;
}

int main(int argc, char **argv)
{
    struct decoder d = {0};
    const char *path;
    if (argc == 2 && !strcmp(argv[1], "--help")) {
        puts("Usage: translate [--wpm 5-30] recording.wav");
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "--wpm")) {
        char *end;
        errno = 0;
        long speed = strtol(argv[2], &end, 10);
        if (errno || *end || speed < 5 || speed > 30) {
            fputs("translate: --wpm must be an integer from 5 to 30\n", stderr);
            return 1;
        }
        d.wpm = (size_t)speed;
        path = argv[3];
    } else if (argc == 2 && argv[1][0] != '-') {
        path = argv[1];
    } else {
        fputs("Usage: translate [--wpm 5-30] recording.wav\n", stderr);
        return 1;
    }

    FILE *file = fopen(path, "rb");
    if (!file) {
        perror(path);
        return 1;
    }
    const char *error = read_wav(file, &d);
    fclose(file);
    if (!error) {
        d.window = (d.rate + 100) / 200;
        if (!d.window)
            d.window = 1;
        size_t windows = (d.frames + d.window - 1) / d.window;
        d.energy = calloc(windows, sizeof(*d.energy));
        d.runs = calloc(windows, sizeof(*d.runs));
        d.text = malloc(windows + 1);
        d.candidate = malloc(windows + 1);
        if (!d.energy || !d.runs || !d.text || !d.candidate) {
            error = "out of memory";
        } else {
            int status = decode_morse(&d);
            if (status == 1)
                error = "no Morse tones detected";
            else if (status == 2)
                error = "ambiguous timing; supply the sending speed with --wpm";
            else if (puts(d.text) == EOF || fflush(stdout) == EOF)
                error = "cannot write decoded text";
        }
    }
    free((void *)d.pcm);
    free(d.energy);
    free(d.runs);
    free(d.text);
    free(d.candidate);
    if (error)
        fprintf(stderr, "translate: %s\n", error);
    return error != NULL;
}
