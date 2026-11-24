#include "VocalDSP.h"
#include "VocalDSPCore.hpp"
#include <memory>

using namespace vt;

namespace {

struct Engine {
    Engine(float sr, int range) : sr_(sr), mon_(1 << 15), dry_(1 << 19), wet_(1 << 19) {
        static const float fmin[3] = {80.f, 110.f, 160.f};
        tmax_ = (int)std::ceil(sr / fmin[std::max(0, std::min(2, range))]);
        det_.prepare(sr);
        psola_.prepare(tmax_);
        gate_.prepare(sr); comp_.prepare(sr); reverb_.prepare(sr); delay_.prepare(sr);
        hpf_.highpass(sr, 80.f, 0.7071f);
        scratch_.assign(4096, 0.f);
        vt_default_params(&slots_[0]); slots_[1] = slots_[0];
    }

    void setParams(const VTParams& in) {
        VTParams p = in;
        p.retuneMs = clampf(p.retuneMs, 0.f, 400.f);
        p.amount = clampf(p.amount, 0.f, 1.f);
        p.formant = clampf(p.formant, 0.8f, 1.26f);
        p.refA4 = clampf(p.refA4, 415.f, 466.f);
        const int next = 1 - active_.load(std::memory_order_relaxed);
        slots_[next] = p;
        active_.store(next, std::memory_order_release);
    }

    int latency() const { return psola_.latency(); }

    void reset() {
        det_.reset(); psola_.reset(); tuner_.reset();
        hpf_.z1 = hpf_.z2 = 0; hang_ = 0;
    }

    void onHop(const Estimate& e, const VTParams& p) {
        const float minF = sr_ / (float)tmax_;
        const bool voiced = e.voiced && e.f0 >= minF && e.f0 <= 1000.f;
        if (voiced) {
            hang_ = 0;
            const Tuner::Out o = tuner_.update(e.f0, p, det_.hopSeconds());
            if (p.bypass) {
                psola_.setVoiced(false);
            } else {
                const float ratio = clampf(std::pow(2.f, o.shift / 12.f), 0.5f, 2.f);
                psola_.setControl(sr_ / e.f0, true, ratio, p.formant);
            }
            tIn_.store(o.inMidi, std::memory_order_relaxed);
            tOut_.store(o.inMidi + o.shift, std::memory_order_relaxed);
            tTarget_.store(o.target, std::memory_order_relaxed);
            tVoiced_.store(1, std::memory_order_relaxed);
        } else if (++hang_ > 2) {
            psola_.setVoiced(false);
            tuner_.reset();
            tVoiced_.store(0, std::memory_order_relaxed);
        }
    }

    void process(const float* in, float* out, int n) {
        const VTParams p = slots_[active_.load(std::memory_order_acquire)];
        det_.setHopMs(p.lowPower ? 12.f : 8.f);
        const float inG = dbToLin(p.inputGainDb), outG = dbToLin(p.outputGainDb);
        const float gateThr = dbToLin(p.gateDb);
        const bool gateOn = p.gateDb > -80.f;
        const bool revOn = !p.lowPower && p.reverbMix > 0.002f;
        const bool dlyOn = !p.lowPower && p.delayMix > 0.002f;
        float peak = 0.f;
        for (int i = 0; i < n; ++i) {
            const float x = in[i] * inG;
            peak = std::max(peak, std::fabs(x));
            const float h = hpf_.process(x);
            const float g = gateOn ? gate_.process(h, gateThr) : h;
            Estimate e;
            if (det_.push(g, e)) onHop(e, p);
            float y = psola_.process1(g);
            y = comp_.process(y, p.compAmount);
            float s = y;
            if (revOn) s += reverb_.process(y, p.reverbSize) * p.reverbMix * 2.0f;
            if (dlyOn) s += delay_.process(y, p.delayMs, p.delayFeedback) * p.delayMix;
            out[i] = softClip(s * outG);
        }
        tLevel_.store(peak, std::memory_order_relaxed);
    }

    void capture(const float* in, int n) {
        while (n > 0) {
            const int c = std::min(n, (int)scratch_.size());
            process(in, scratch_.data(), c);
            mon_.write(scratch_.data(), (size_t)c);
            if (recording_.load(std::memory_order_acquire)) {
                dry_.write(in, (size_t)c);
                int skip = wetSkip_.load(std::memory_order_relaxed);
                if (skip > 0) {
                    const int s = std::min(skip, c);
                    wetSkip_.store(skip - s, std::memory_order_relaxed);
                    if (c > s) wet_.write(scratch_.data() + s, (size_t)(c - s));
                } else {
                    wet_.write(scratch_.data(), (size_t)c);
                }
            }
            in += c; n -= c;
        }
    }

    int monitor(float* out, int n) {
        const size_t avail = mon_.avail();
        if (avail > (size_t)n * 2) mon_.skip(avail - (size_t)n);
        const int got = (int)mon_.read(out, (size_t)n);
        for (int i = got; i < n; ++i) out[i] = 0.f;
        return got;
    }

    void setRecording(int on) {
        if (on) {
            dry_.skip(dry_.avail()); wet_.skip(wet_.avail());
            wetSkip_.store(latency(), std::memory_order_relaxed);
            recording_.store(true, std::memory_order_release);
        } else {
            recording_.store(false, std::memory_order_release);
        }
    }

    float sr_;
    int tmax_ = 400;
    PitchDetector det_;
    Tuner tuner_;
    Psola psola_;
    Gate gate_; Comp comp_; Reverb reverb_; Delay delay_;
    Biquad hpf_;
    Ring mon_, dry_, wet_;
    std::vector<float> scratch_;
    VTParams slots_[2];
    std::atomic<int> active_{0};
    std::atomic<bool> recording_{false};
    std::atomic<int> wetSkip_{0};
    std::atomic<float> tIn_{60.f}, tOut_{60.f}, tTarget_{60.f}, tLevel_{0.f};
    std::atomic<int> tVoiced_{0};
    int hang_ = 0;
};

inline Engine* E(void* h) { return static_cast<Engine*>(h); }

} // namespace

extern "C" {

void* vt_create(float sr, int32_t range) { return new Engine(sr, range); }
void vt_destroy(void* h) { delete E(h); }

void vt_default_params(VTParams* p) {
    std::memset(p, 0, sizeof(VTParams));
    p->retuneMs = 80.f; p->amount = 1.f; p->flexCents = 0.f; p->vibratoKeep = 1.f;
    p->formant = 1.f; p->refA4 = 440.f; p->noteMask = 0xFFFu; p->manualNote = -1;
    p->gateDb = -80.f; p->compAmount = 0.f; p->reverbSize = 0.5f;
    p->delayMs = 320.f; p->delayFeedback = 0.3f;
}

void vt_set_params(void* h, const VTParams* p) { E(h)->setParams(*p); }
int32_t vt_latency(void* h) { return E(h)->latency(); }
void vt_reset(void* h) { E(h)->reset(); }
void vt_capture(void* h, const float* in, int32_t n) { E(h)->capture(in, n); }
int32_t vt_monitor(void* h, float* out, int32_t n) { return E(h)->monitor(out, n); }
void vt_set_recording(void* h, int32_t on) { E(h)->setRecording(on); }
int32_t vt_read_dry(void* h, float* d, int32_t m) { return (int32_t)E(h)->dry_.read(d, (size_t)m); }
int32_t vt_read_wet(void* h, float* d, int32_t m) { return (int32_t)E(h)->wet_.read(d, (size_t)m); }

void vt_process(void* h, const float* in, float* out, int32_t n) {
    Engine* e = E(h);
    int32_t done = 0;
    while (done < n) {
        const int32_t c = std::min<int32_t>(n - done, 4096);
        e->process(in + done, out + done, c);
        done += c;
    }
}

void vt_get_telemetry(void* h, VTTelemetry* t) {
    Engine* e = E(h);
    t->inMidi = e->tIn_.load(std::memory_order_relaxed);
    t->outMidi = e->tOut_.load(std::memory_order_relaxed);
    t->targetMidi = e->tTarget_.load(std::memory_order_relaxed);
    t->level = e->tLevel_.load(std::memory_order_relaxed);
    t->voiced = e->tVoiced_.load(std::memory_order_relaxed);
}

} // extern "C"
