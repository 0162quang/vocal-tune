// Lõi DSP: YIN, bộ tune, PSOLA, hiệu ứng. Không cấp phát trong process().
#pragma once
#include "VocalDSP.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace vt {

constexpr float kPi = 3.14159265358979323846f;
inline float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }
inline float dbToLin(float db) { return std::pow(10.0f, db * 0.05f); }
inline float softClip(float x) {
    const float a = std::fabs(x);
    if (a < 0.9f) return x;
    const float o = 0.9f + 0.1f * std::tanh((a - 0.9f) * 10.0f);
    return x < 0 ? -o : o;
}

struct Biquad {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void lowpass(float fs, float fc, float q) {
        const float w = 2 * kPi * fc / fs, c = std::cos(w), s = std::sin(w);
        const float al = s / (2 * q), a0 = 1 + al;
        b0 = (1 - c) * 0.5f / a0; b1 = (1 - c) / a0; b2 = b0;
        a1 = -2 * c / a0; a2 = (1 - al) / a0;
    }
    void highpass(float fs, float fc, float q) {
        const float w = 2 * kPi * fc / fs, c = std::cos(w), s = std::sin(w);
        const float al = s / (2 * q), a0 = 1 + al;
        b0 = (1 + c) * 0.5f / a0; b1 = -(1 + c) / a0; b2 = b0;
        a1 = -2 * c / a0; a2 = (1 - al) / a0;
    }
    inline float process(float x) {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
};

// Ring SPSC không khóa (một bên ghi, một bên đọc).
class Ring {
public:
    explicit Ring(size_t capPow2 = 1 << 16) : buf_(capPow2), mask_(capPow2 - 1) {}
    size_t write(const float* x, size_t n) {
        const size_t w = w_.load(std::memory_order_relaxed), r = r_.load(std::memory_order_acquire);
        n = std::min(n, buf_.size() - (w - r));
        for (size_t i = 0; i < n; ++i) buf_[(w + i) & mask_] = x[i];
        w_.store(w + n, std::memory_order_release);
        return n;
    }
    size_t avail() const { return w_.load(std::memory_order_acquire) - r_.load(std::memory_order_relaxed); }
    size_t read(float* y, size_t n) {
        const size_t r = r_.load(std::memory_order_relaxed), w = w_.load(std::memory_order_acquire);
        n = std::min(n, w - r);
        for (size_t i = 0; i < n; ++i) y[i] = buf_[(r + i) & mask_];
        r_.store(r + n, std::memory_order_release);
        return n;
    }
    void skip(size_t n) {
        const size_t r = r_.load(std::memory_order_relaxed), w = w_.load(std::memory_order_acquire);
        r_.store(r + std::min(n, w - r), std::memory_order_release);
    }
private:
    std::vector<float> buf_;
    size_t mask_;
    std::atomic<size_t> w_{0}, r_{0};
};

struct Estimate { float f0 = 0, cmnd = 1, rms = 0; bool voiced = false; };

// YIN trên tín hiệu hạ mẫu ~16 kHz.
class PitchDetector {
public:
    void prepare(float sr) {
        dec_ = std::max(1, (int)std::lround(sr / 16000.0f));
        fs_ = sr / dec_; sr_ = sr;
        const float fc = std::min(3500.0f, 0.35f * fs_);
        for (auto& b : lp_) b.lowpass(sr, fc, 0.7071f);
        tauMax_ = (int)std::ceil(fs_ / 70.0f) + 2;
        tauMin_ = std::max(2, (int)(fs_ / 1000.0f));
        W_ = (int)std::ceil(0.024f * fs_);
        len_ = W_ + tauMax_;
        store_.assign(len_ + 2048, 0.f);
        cm_.assign(tauMax_ + 2, 1.f);
        setHopMs(8.f);
        reset();
    }
    void reset() {
        std::fill(store_.begin(), store_.end(), 0.f);
        wp_ = len_; filled_ = 0; phase_ = 0; hopCnt_ = 0; wasVoiced_ = false;
        for (auto& b : lp_) b.z1 = b.z2 = 0;
    }
    void setHopMs(float ms) { hop_ = std::max(16, (int)std::ceil(ms * 0.001f * fs_)); }
    float hopSeconds() const { return (float)(hop_ * dec_) / sr_; }

    bool push(float x, Estimate& e) {
        const float y = lp_[1].process(lp_[0].process(x));
        if (++phase_ < dec_) return false;
        phase_ = 0;
        if (wp_ == (int)store_.size()) {
            std::memmove(store_.data(), store_.data() + wp_ - len_, len_ * sizeof(float));
            wp_ = len_;
        }
        store_[wp_++] = y;
        if (filled_ < len_) ++filled_;
        if (++hopCnt_ < hop_) return false;
        hopCnt_ = 0;
        if (filled_ < len_) return false;
        analyze(e);
        return true;
    }
private:
    void analyze(Estimate& e) {
        const float* x = store_.data() + wp_ - len_;
        float en = 0;
        for (int j = 0; j < W_; ++j) en += x[j] * x[j];
        e.rms = std::sqrt(en / W_);
        float run = 0;
        cm_[0] = 1.f;
        for (int tau = 1; tau <= tauMax_; ++tau) {
            const float* xt = x + tau;
            float s = 0;
            for (int j = 0; j < W_; ++j) { const float d = x[j] - xt[j]; s += d * d; }
            run += s;
            cm_[tau] = run > 1e-9f ? s * tau / run : 1.f;
        }
        int tau = -1;
        for (int t = tauMin_; t < tauMax_; ++t) {
            if (cm_[t] < 0.15f) {
                while (t + 1 < tauMax_ && cm_[t + 1] < cm_[t]) ++t;
                tau = t; break;
            }
        }
        if (tau < 0) {
            float best = 1e9f;
            for (int t = tauMin_; t < tauMax_; ++t) if (cm_[t] < best) { best = cm_[t]; tau = t; }
        }
        float tf = (float)tau;
        if (tau > 1 && tau < tauMax_) {
            const float s0 = cm_[tau - 1], s1 = cm_[tau], s2 = cm_[tau + 1];
            const float den = s0 + s2 - 2 * s1;
            if (std::fabs(den) > 1e-9f) tf += clampf(0.5f * (s0 - s2) / den, -1.f, 1.f);
        }
        e.f0 = fs_ / tf;
        e.cmnd = cm_[tau];
        e.voiced = e.cmnd < (wasVoiced_ ? 0.3f : 0.2f) && e.rms > 0.002f;
        wasVoiced_ = e.voiced;
    }
    Biquad lp_[2];
    std::vector<float> store_, cm_;
    int dec_ = 3, tauMax_ = 0, tauMin_ = 0, W_ = 0, len_ = 0, hop_ = 128;
    int wp_ = 0, filled_ = 0, phase_ = 0, hopCnt_ = 0;
    float fs_ = 16000, sr_ = 48000;
    bool wasVoiced_ = false;
};

// Từ cao độ dò được đến độ dịch (nửa cung).
class Tuner {
public:
    struct Out { float shift, inMidi, target; };
    void reset() { have_ = false; hn_ = 0; }
    Out update(float f0, const VTParams& p, float hopSec) {
        const float midi = 69.f + 12.f * std::log2(f0 / p.refA4);
        hist_[hn_ % 3] = midi; ++hn_;
        float fast = midi;
        if (hn_ >= 3) {
            const float a = hist_[0], b = hist_[1], c = hist_[2];
            fast = std::max(std::min(a, b), std::min(std::max(a, b), c));
        }
        const bool onset = !have_;
        if (onset) {
            slow_ = fast; note_ = pick(fast, p); have_ = true;
        } else {
            slow_ += (fast - slow_) * (1.f - std::exp(-hopSec / 0.15f));
            const int cand = pick(fast, p);
            if (p.manualNote >= 0) note_ = cand;
            else if (cand != note_ && (!allowed(note_, p) ||
                     std::fabs(fast - (float)cand) + 0.3f < std::fabs(fast - (float)note_))) {
                note_ = cand; slow_ = fast;
            }
        }
        const float keep = clampf(p.vibratoKeep, 0.f, 1.f);
        // trung vị chỉ dùng để chọn nốt; làm phẳng dùng cao độ thô để không thêm trễ
        const float ref = keep * slow_ + (1.f - keep) * midi;
        float err = (float)note_ - ref;
        if (p.flexCents > 0.5f) {
            const float e = std::fabs(err) * 100.f;
            if (e < p.flexCents) { const float k = e / p.flexCents; err *= k * k; }
        }
        const float cTarget = err * clampf(p.amount, 0.f, 1.f);
        if (onset || p.retuneMs <= 0.5f) c_ = cTarget;
        else c_ += (1.f - std::exp(-hopSec * 1000.f / p.retuneMs)) * (cTarget - c_);
        return { c_ + p.transposeSemis + p.detuneCents * 0.01f, fast, (float)note_ + p.transposeSemis };
    }
private:
    static bool allowed(int note, const VTParams& p) { return (p.noteMask >> (((note % 12) + 12) % 12)) & 1u; }
    static int pick(float x, const VTParams& p) {
        const int base = (int)std::lround(x);
        if (p.manualNote >= 0) {
            int best = base, bd = 99;
            for (int k = base - 6; k <= base + 6; ++k)
                if (((k % 12) + 12) % 12 == p.manualNote % 12 && std::abs(k - base) < bd) { best = k; bd = std::abs(k - base); }
            return best;
        }
        if ((p.noteMask & 0xFFFu) == 0) return base;
        int best = base; float bd = 1e9f;
        for (int k = base - 6; k <= base + 6; ++k)
            if (allowed(k, p)) { const float d = std::fabs((float)k - x); if (d < bd) { bd = d; best = k; } }
        return best;
    }
    float hist_[3] = {0, 0, 0}, slow_ = 0, c_ = 0;
    int note_ = 60, hn_ = 0;
    bool have_ = false;
};

// TD-PSOLA streaming, không cần dò epoch: mắt lưới phân tích có bước bằng chu kỳ.
class Psola {
public:
    void prepare(int tmax) {
        tmax_ = tmax;
        D_ = (int)std::ceil(2.3f * tmax) + 16;
        in_.assign(kN, 0.f); out_.assign(kN, 0.f);
        for (int j = 0; j < kW; ++j) win_[j] = 0.5f * (1.f + std::cos(kPi * j / (kW - 1)));
        reset();
    }
    void reset() {
        std::fill(in_.begin(), in_.end(), 0.f); std::fill(out_.begin(), out_.end(), 0.f);
        n_ = 0; c_ = 0; aCur_ = 0; voiced_ = false; T0_ = 240; ratio_ = 1; fs_ = 1;
    }
    int latency() const { return D_; }
    void setControl(float T0, bool v, float ratio, float formant) {
        voiced_ = v; T0_ = clampf(T0, 32.f, (float)tmax_); ratio_ = ratio; fs_ = clampf(formant, 0.8f, 1.26f);
    }
    void setVoiced(bool v) { voiced_ = v; }

    float process1(float x) {
        in_[n_ & kM] = x; ++n_;
        const int64_t m = n_ - D_;
        for (;;) {
            const int tg = voiced_ ? (int)std::ceil(T0_) : 240;
            if (c_ - tg > (double)m) break;
            grain(tg, m);
        }
        if (m < 0) return 0.f;
        const float y = out_[m & kM]; out_[m & kM] = 0.f;
        return y;
    }
private:
    void grain(int tg, int64_t m) {
        double a, step; float fs = 1.f, gain = 1.f;
        if (!voiced_) {
            a = c_; aCur_ = c_; step = tg;
        } else {
            if (aCur_ < c_ - 4.0 * T0_) aCur_ = c_;
            while (aCur_ + T0_ <= c_) aCur_ += T0_;
            a = aCur_; step = T0_ / ratio_; fs = fs_; gain = (float)(step / tg);
        }
        const int64_t ci = (int64_t)std::llround(c_);
        const float wscale = (float)(kW - 1) / (float)tg;
        for (int i = -tg; i <= tg; ++i) {
            const int64_t idx = ci + i;
            if (idx < m) continue;
            const double pos = a + (double)i * fs;
            const int64_t p0 = (int64_t)std::floor(pos);
            const float fr = (float)(pos - (double)p0);
            const float s = in_[p0 & kM] * (1.f - fr) + in_[(p0 + 1) & kM] * fr;
            const float w = win_[(int)((float)std::abs(i) * wscale + 0.5f)];
            out_[idx & kM] += s * w * gain;
        }
        c_ += step;
    }
    static constexpr int kN = 1 << 14, kW = 1024;
    static constexpr int64_t kM = kN - 1;
    std::vector<float> in_, out_;
    float win_[kW];
    int64_t n_ = 0;
    double c_ = 0, aCur_ = 0;
    int tmax_ = 400, D_ = 1000;
    float T0_ = 240, ratio_ = 1, fs_ = 1;
    bool voiced_ = false;
};

struct Gate {
    float env = 0, g = 1, aRel = 0, gAtk = 0, gRel = 0;
    bool open = true;
    void prepare(float sr) {
        aRel = 1.f - std::exp(-1.f / (sr * 0.05f));
        gAtk = 1.f - std::exp(-1.f / (sr * 0.002f));
        gRel = 1.f - std::exp(-1.f / (sr * 0.08f));
    }
    float process(float x, float thr) {
        const float a = std::fabs(x);
        env = a > env ? a : env + (a - env) * aRel;
        if (env > thr) open = true; else if (env < thr * 0.6f) open = false;
        const float t = open ? 1.f : 0.f;
        g += (t - g) * (t > g ? gAtk : gRel);
        return x * g;
    }
};

struct Comp {
    float env = 0, aA = 0, aR = 0;
    void prepare(float sr) {
        aA = 1.f - std::exp(-1.f / (sr * 0.005f));
        aR = 1.f - std::exp(-1.f / (sr * 0.1f));
    }
    float process(float x, float amount) {
        if (amount < 0.01f) return x;
        const float a = std::fabs(x);
        env += (a - env) * (a > env ? aA : aR);
        const float thDb = -10.f - 14.f * amount, ratio = 1.f + 3.f * amount;
        const float envDb = 20.f * std::log10(env + 1e-9f);
        const float over = envDb - thDb;
        const float gr = over > 0 ? over * (1.f - 1.f / ratio) : 0.f;
        const float makeup = -thDb * (1.f - 1.f / ratio) * 0.4f;
        return x * dbToLin(makeup - gr);
    }
};

class Reverb {
public:
    void prepare(float sr) {
        static const int ct[4] = {1116, 1188, 1277, 1356}, at[2] = {556, 441};
        const float k = sr / 44100.f;
        for (int i = 0; i < 4; ++i) { c_[i].b.assign((size_t)(ct[i] * k), 0.f); c_[i].i = 0; c_[i].st = 0; }
        for (int i = 0; i < 2; ++i) { a_[i].b.assign((size_t)(at[i] * k), 0.f); a_[i].i = 0; }
    }
    float process(float x, float size) {
        const float fb = 0.70f + 0.26f * clampf(size, 0.f, 1.f), in = x * 0.25f;
        float s = 0;
        for (auto& c : c_) {
            const float o = c.b[c.i];
            c.st = o * 0.65f + c.st * 0.35f;
            c.b[c.i] = in + c.st * fb;
            if (++c.i >= c.b.size()) c.i = 0;
            s += o;
        }
        for (auto& a : a_) {
            const float bo = a.b[a.i], o = -s + bo;
            a.b[a.i] = s + bo * 0.5f;
            if (++a.i >= a.b.size()) a.i = 0;
            s = o;
        }
        return s;
    }
private:
    struct C { std::vector<float> b; size_t i = 0; float st = 0; } c_[4];
    struct A { std::vector<float> b; size_t i = 0; } a_[2];
};

class Delay {
public:
    void prepare(float sr) { sr_ = sr; b_.assign((size_t)(sr * 1.5f) + 2, 0.f); w_ = 0; lp_ = 0; }
    float process(float x, float ms, float fb) {
        size_t d = (size_t)clampf(ms * 0.001f * sr_, 1.f, (float)(b_.size() - 1));
        size_t r = w_ >= d ? w_ - d : w_ + b_.size() - d;
        const float o = b_[r];
        lp_ += (o - lp_) * 0.4f;
        b_[w_] = x + lp_ * clampf(fb, 0.f, 0.9f);
        if (++w_ >= b_.size()) w_ = 0;
        return o;
    }
private:
    std::vector<float> b_; size_t w_ = 0; float lp_ = 0, sr_ = 48000;
};

} // namespace vt
