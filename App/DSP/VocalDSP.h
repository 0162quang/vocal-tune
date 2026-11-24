#ifndef VOCALDSP_H
#define VOCALDSP_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Tham số điều khiển. Điền mặc định bằng vt_default_params rồi sửa từng trường. */
typedef struct VTParams {
    float retuneMs;       /* 0..400, 0 = robot */
    float amount;         /* 0..1 */
    float flexCents;      /* 0..50, humanize */
    float vibratoKeep;    /* 0..1 */
    float formant;        /* tỉ lệ 0.8..1.26 */
    float transposeSemis; /* -12..12 */
    float detuneCents;    /* -50..50 */
    float refA4;          /* 415..466 */
    uint32_t noteMask;    /* bit i = pitch class i (C=0) được phép */
    int32_t manualNote;   /* -1 = tắt; >=0 = ép theo pitch class của nốt MIDI này */
    float inputGainDb;
    float gateDb;         /* <= -80 là tắt */
    float compAmount;     /* 0..1 */
    float reverbMix;      /* 0..1 */
    float reverbSize;     /* 0..1 */
    float delayMix;       /* 0..1 */
    float delayMs;        /* 20..1400 */
    float delayFeedback;  /* 0..0.9 */
    float outputGainDb;
    int32_t bypass;       /* 1 = chỉ trễ, không tune */
    int32_t lowPower;     /* 1 = tiết kiệm pin */
} VTParams;

typedef struct VTTelemetry {
    float inMidi;      /* cao độ gốc (nốt MIDI, thập phân) */
    float outMidi;     /* cao độ sau chỉnh */
    float targetMidi;  /* nốt đích */
    float level;       /* đỉnh tín hiệu vào của block gần nhất */
    int32_t voiced;
} VTTelemetry;

/* rangePreset: 0 = trầm (>=80Hz), 1 = trung (>=110Hz), 2 = cao (>=160Hz) */
void*   vt_create(float sampleRate, int32_t rangePreset);
void    vt_destroy(void* h);
void    vt_default_params(VTParams* p);
void    vt_set_params(void* h, const VTParams* p);
int32_t vt_latency(void* h);
void    vt_reset(void* h);

/* Realtime: mic -> DSP -> ring monitor (và ring ghi âm nếu đang thu) */
void    vt_capture(void* h, const float* in, int32_t frames);
int32_t vt_monitor(void* h, float* out, int32_t frames);

/* Ghi âm */
void    vt_set_recording(void* h, int32_t on);
int32_t vt_read_dry(void* h, float* dst, int32_t maxFrames);
int32_t vt_read_wet(void* h, float* dst, int32_t maxFrames);

/* Ngoại tuyến (studio render, test). out có độ trễ vt_latency mẫu. */
void vt_process(void* h, const float* in, float* out, int32_t frames);
void vt_get_telemetry(void* h, VTTelemetry* t);

#ifdef __cplusplus
}
#endif
#endif
