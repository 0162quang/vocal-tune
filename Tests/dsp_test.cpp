// Test DSP trên máy host: clang++ -std=c++17 -O2 Tests/dsp_test.cpp App/DSP/VocalDSP.cpp -I App/DSP
#include "VocalDSP.h"
#include <chrono>
#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <vector>

static const float SR = 48000.f;
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { ++failures; std::printf("  FAIL: "); std::printf(__VA_ARGS__); std::printf("\n"); } } while (0)

// Giọng tổng hợp: chuỗi xung qua 2 bộ cộng hưởng (formant).
static std::vector<float> voice(float sec, std::function<float(float)> f0) {
    const int n = (int)(sec * SR);
    std::vector<float> x(n);
    struct Res { float a1, a2, y1 = 0, y2 = 0; };
    auto mk = [](float f, float bw) { const float r = std::exp(-3.14159265f * bw / SR); return Res{2 * r * std::cos(2 * 3.14159265f * f / SR), -r * r}; };
    Res r1 = mk(700, 130), r2 = mk(1220, 90);
    std::mt19937 rng(1); std::uniform_real_distribution<float> nd(-1, 1);
    double ph = 0; float peak = 1e-9f;
    for (int i = 0; i < n; ++i) {
        const float t = i / SR;
        ph += f0(t) / SR;
        float e = 0; if (ph >= 1.0) { ph -= 1.0; e = 1.f; }
        e += nd(rng) * 1e-3f;
        float y1 = e + r1.a1 * r1.y1 + r1.a2 * r1.y2; r1.y2 = r1.y1; r1.y1 = y1;
        float y2 = e + r2.a1 * r2.y1 + r2.a2 * r2.y2; r2.y2 = r2.y1; r2.y1 = y2;
        x[i] = y1 + 0.5f * y2; peak = std::fmax(peak, std::fabs(x[i]));
    }
    for (auto& v : x) v *= 0.5f / peak;
    return x;
}

// Đo f0 bằng tự tương quan chuẩn hóa (độc lập với YIN trong engine).
static float measureF0(const float* x, int n) {
    const int lo = (int)(SR / 500), hi = (int)(SR / 90);
    std::vector<float> c(hi + 3, 0);
    float best = -1;
    for (int lag = lo - 1; lag <= hi + 1; ++lag) {
        double s = 0, e1 = 1e-12, e2 = 1e-12;
        for (int i = 0; i + lag < n; ++i) { s += x[i] * x[i + lag]; e1 += x[i] * x[i]; e2 += x[i + lag] * x[i + lag]; }
        c[lag] = (float)(s / std::sqrt(e1 * e2));
        if (lag >= lo && lag <= hi && c[lag] > best) best = c[lag];
    }
    // đỉnh cục bộ đầu tiên đạt >= 90% đỉnh cao nhất (tránh chọn bội của chu kỳ)
    int bestLag = lo;
    for (int lag = lo; lag <= hi; ++lag)
        if (c[lag] >= 0.9f * best && c[lag] >= c[lag - 1] && c[lag] >= c[lag + 1]) { bestLag = lag; break; }
    float l = (float)bestLag;
    float a = c[bestLag - 1], b = c[bestLag], d = c[bestLag + 1], den = a + d - 2 * b;
    if (std::fabs(den) > 1e-9f) l += 0.5f * (a - d) / den;
    return SR / l;
}
static float cents(float f, float ref) { return 1200.f * std::log2(f / ref); }

static std::vector<float> run(void* h, const std::vector<float>& in) {
    std::vector<float> out(in.size());
    for (size_t i = 0; i < in.size(); i += 256) vt_process(h, in.data() + i, out.data() + i, (int)std::min<size_t>(256, in.size() - i));
    return out;
}
// Tính f0 trên các cửa sổ liên tiếp, trả về trung bình và độ lệch chuẩn (cent so với ref).
static void trace(const std::vector<float>& y, int D, float t0, float t1, float ref, float& mean, float& sd) {
    std::vector<float> v;
    for (int s = (int)(t0 * SR) + D; s + 2048 < (int)(t1 * SR) + D && s + 2048 < (int)y.size(); s += 1024) v.push_back(cents(measureF0(&y[s], 2048), ref));
    double m = 0; for (float a : v) m += a; m /= v.size();
    double q = 0; for (float a : v) q += (a - m) * (a - m);
    mean = (float)m; sd = (float)std::sqrt(q / v.size());
}

int main() {
    const float A3 = 220.f;
    VTParams p;

    std::printf("[1] snap: giong lech -40 cent -> A3\n");
    {
        void* h = vt_create(SR, 1); const int D = vt_latency(h);
        vt_default_params(&p); p.noteMask = 1u << 9; p.retuneMs = 20.f; vt_set_params(h, &p);
        const float f = A3 * std::pow(2.f, -40.f / 1200.f);
        auto y = run(h, voice(2.f, [f](float) { return f; }));
        float m, sd; trace(y, D, 1.0f, 2.0f, A3, m, sd);
        std::printf("  mean=%.1f cent sd=%.1f (D=%d mau)\n", m, sd, D);
        CHECK(std::fabs(m) < 6.f, "lech trung binh %.1f cent", m);
        vt_destroy(h);
    }

    std::printf("[2] vibrato: giu vs lam phang\n");
    {
        auto f0 = [](float t) { return 220.f * std::pow(2.f, (-40.f + 30.f * std::sin(2 * 3.14159265f * 5.5f * t)) / 1200.f); };
        auto in = voice(3.f, f0);
        float mi, si; trace(in, 0, 1.0f, 3.0f, A3, mi, si);
        void* h = vt_create(SR, 1); const int D = vt_latency(h);
        vt_default_params(&p); p.noteMask = 1u << 9; p.retuneMs = 30.f; p.vibratoKeep = 1.f; vt_set_params(h, &p);
        auto y = run(h, in); float mk, sk; trace(y, D, 1.0f, 3.0f, A3, mk, sk);
        vt_reset(h); p.vibratoKeep = 0.f; p.retuneMs = 5.f; vt_set_params(h, &p);
        auto z = run(h, in); float mf, sf; trace(z, D, 1.0f, 3.0f, A3, mf, sf);
        std::printf("  vao: mean=%.1f sd=%.1f | giu: mean=%.1f sd=%.1f | phang: mean=%.1f sd=%.1f\n", mi, si, mk, sk, mf, sf);
        CHECK(std::fabs(mk) < 10.f, "tam vibrato (giu) lech %.1f", mk);
        CHECK(sk > 0.6f * si, "vibrato giu bi mat: %.1f vs %.1f", sk, si);
        CHECK(sf < 10.f, "lam phang van con sd=%.1f", sf);
        vt_destroy(h);
    }

    std::printf("[3] on dinh khi nhay nhieu nhac + khong NaN\n");
    {
        void* h = vt_create(SR, 1);
        vt_default_params(&p); p.retuneMs = 40.f; p.noteMask = 0x0AB5u; /* C major */ p.reverbMix = 0.2f; p.delayMix = 0.2f; p.compAmount = 0.5f; vt_set_params(h, &p);
        auto y = run(h, voice(4.f, [](float t) { return 130.f * std::pow(2.f, t * 0.5f); }));
        bool bad = false; float pk = 0; for (float v : y) { if (!std::isfinite(v)) bad = true; pk = std::fmax(pk, std::fabs(v)); }
        std::printf("  peak=%.2f\n", pk);
        CHECK(!bad, "co NaN/Inf"); CHECK(pk < 1.01f, "peak %.2f vuot gioi han", pk);
        vt_destroy(h);
    }

    std::printf("[4] tieng khong giong (nhieu) di thang\n");
    {
        void* h = vt_create(SR, 1); vt_default_params(&p); vt_set_params(h, &p);
        std::mt19937 rng(7); std::uniform_real_distribution<float> nd(-0.1f, 0.1f);
        std::vector<float> in(48000 * 2); for (auto& v : in) v = nd(rng);
        auto y = run(h, in); const int D = vt_latency(h);
        double ei = 0, eo = 0; for (size_t i = 48000; i < in.size() - D; ++i) { ei += in[i] * in[i]; eo += y[i + D] * y[i + D]; }
        const float ratio = (float)std::sqrt(eo / ei);
        std::printf("  rms ra/vao=%.2f\n", ratio);
        CHECK(ratio > 0.7f && ratio < 1.3f, "ti le rms %.2f", ratio);
        vt_destroy(h);
    }

    std::printf("[5] do tre: xung o che do bypass\n");
    {
        void* h = vt_create(SR, 1); vt_default_params(&p); p.bypass = 1; p.gateDb = -90; vt_set_params(h, &p);
        std::vector<float> in(12000, 0.f); in[3000] = 1.f; auto y = run(h, in);
        int pk = 0; float mv = 0; for (int i = 0; i < (int)y.size(); ++i) if (std::fabs(y[i]) > mv) { mv = std::fabs(y[i]); pk = i; }
        const int D = vt_latency(h);
        std::printf("  dinh tai %d (mong doi %d), bien do %.2f\n", pk, 3000 + D, mv);
        CHECK(std::abs(pk - (3000 + D)) <= 2, "do tre sai");
        CHECK(mv > 0.8f, "bien do xung %.2f", mv);
        vt_destroy(h);
    }

    std::printf("[6] CPU\n");
    {
        void* h = vt_create(SR, 1); vt_default_params(&p); p.reverbMix = 0.2f; p.delayMix = 0.2f; p.compAmount = 0.4f; p.retuneMs = 30; vt_set_params(h, &p);
        auto in = voice(10.f, [](float t) { return 200.f * std::pow(2.f, 0.3f * std::sin(t)); });
        auto t0 = std::chrono::steady_clock::now(); auto y = run(h, in);
        double dt = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        std::printf("  10 s audio trong %.3f s -> nhanh gap %.0f lan thoi gian thuc\n", dt, 10.0 / dt);
        CHECK(10.0 / dt > 20.0, "qua cham: %.1fx", 10.0 / dt);
        vt_destroy(h);
    }

    std::printf(failures ? "\n%d TEST FAIL\n" : "\nTAT CA TEST DAT\n", failures);
    return failures ? 1 : 0;
}
