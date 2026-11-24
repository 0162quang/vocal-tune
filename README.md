# VocalTune

Auto-tune thu âm hát cho iPhone (iOS 18, tối ưu XS Max). Kế hoạch chi tiết nằm trong Doc đi kèm.

## Chạy test DSP (không cần Mac/Xcode)
    g++ -std=c++17 -O2 Tests/dsp_test.cpp App/DSP/VocalDSP.cpp -I App/DSP -o dsp_test && ./dsp_test

## Build
Codemagic: dùng `codemagic.yaml` (xcodegen sinh project, archive không ký, ra `VocalTune.ipa` để bạn tự ký).
Đổi `com.example.vocaltune` trong `project.yml` thành bundle id của bạn.

## Trạng thái
- DSP C++ đã test trên host: snap nốt, giữ/làm phẳng vibrato, đi thẳng khi không có giọng, độ trễ, CPU.
- Mã Swift/SwiftUI CHƯA được biên dịch (không có Xcode ở môi trường tạo ra nó). Lần build đầu có thể cần sửa lỗi nhỏ.
- Chưa đo độ trễ, pin, nhiệt trên máy thật.
- Chưa có: input MIDI, tự nhận key, Control Center, Live Activity.
