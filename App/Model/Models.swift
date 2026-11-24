import Foundation

enum ScaleType: String, CaseIterable, Codable, Identifiable {
    case chromatic, major, minor, pentMajor, pentMinor, blues, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .chromatic: return "Chromatic"
        case .major: return "Major"
        case .minor: return "Minor"
        case .pentMajor: return "Pent. Major"
        case .pentMinor: return "Pent. Minor"
        case .blues: return "Blues"
        case .custom: return "Custom"
        }
    }
    var intervals: [Int] {
        switch self {
        case .chromatic, .custom: return Array(0..<12)
        case .major: return [0, 2, 4, 5, 7, 9, 11]
        case .minor: return [0, 2, 3, 5, 7, 8, 10]
        case .pentMajor: return [0, 2, 4, 7, 9]
        case .pentMinor: return [0, 3, 5, 7, 10]
        case .blues: return [0, 3, 5, 6, 7, 10]
        }
    }
}

enum VoiceRange: Int, CaseIterable, Codable, Identifiable {
    case low = 0, mid = 1, high = 2
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .low: return "Trầm"
        case .mid: return "Trung"
        case .high: return "Cao"
        }
    }
    var detail: String {
        switch self {
        case .low: return "từ 80 Hz · trễ cao nhất"
        case .mid: return "từ 110 Hz · mặc định"
        case .high: return "từ 160 Hz · trễ thấp nhất"
        }
    }
}

let noteNames = ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"]

struct TuneSettings: Codable, Equatable {
    var retuneMs = 80.0
    var amount = 1.0
    var flexCents = 0.0
    var vibratoKeep = 1.0
    var formantSemis = 0.0
    var transpose = 0
    var detune = 0.0
    var refA4 = 440.0
    var keyRoot = 0
    var scale: ScaleType = .chromatic
    var customMask: UInt16 = 0x0FFF
    var range: VoiceRange = .mid
    var inputGainDb = 0.0
    var gateDb = -80.0
    var comp = 0.3
    var reverbMix = 0.15
    var reverbSize = 0.5
    var delayMix = 0.0
    var delayMs = 320.0
    var delayFeedback = 0.3
    var outputGainDb = 0.0
    var beatGain = 0.8
    var vocalGain = 1.0
    var bypass = false

    var noteMask: UInt16 {
        if scale == .custom { return customMask }
        var m: UInt16 = 0
        for i in scale.intervals { m |= 1 << UInt16((keyRoot + i) % 12) }
        return m
    }

    func vtParams(lowPower: Bool) -> VTParams {
        var p = VTParams()
        vt_default_params(&p)
        p.retuneMs = Float(retuneMs)
        p.amount = Float(amount)
        p.flexCents = Float(flexCents)
        p.vibratoKeep = Float(vibratoKeep)
        p.formant = Float(pow(2.0, formantSemis / 12.0))
        p.transposeSemis = Float(transpose)
        p.detuneCents = Float(detune)
        p.refA4 = Float(refA4)
        p.noteMask = UInt32(noteMask)
        p.manualNote = -1
        p.inputGainDb = Float(inputGainDb)
        p.gateDb = Float(gateDb)
        p.compAmount = Float(comp)
        p.reverbMix = Float(reverbMix)
        p.reverbSize = Float(reverbSize)
        p.delayMix = Float(delayMix)
        p.delayMs = Float(delayMs)
        p.delayFeedback = Float(delayFeedback)
        p.outputGainDb = Float(outputGainDb)
        p.bypass = bypass ? 1 : 0
        p.lowPower = lowPower ? 1 : 0
        return p
    }
}

struct Preset: Identifiable {
    let id: String
    let name: String
    let apply: (inout TuneSettings) -> Void

    static let all: [Preset] = [
        Preset(id: "natural", name: "Natural") { s in
            s.bypass = false; s.retuneMs = 120; s.amount = 0.8; s.flexCents = 25; s.vibratoKeep = 1
            s.formantSemis = 0; s.comp = 0.3; s.reverbMix = 0.12; s.delayMix = 0
        },
        Preset(id: "pop", name: "Pop Polish") { s in
            s.bypass = false; s.retuneMs = 45; s.amount = 1; s.flexCents = 12; s.vibratoKeep = 1
            s.formantSemis = 0; s.comp = 0.5; s.reverbMix = 0.2; s.delayMix = 0.08; s.delayMs = 280
        },
        Preset(id: "ballad", name: "Ballad") { s in
            s.bypass = false; s.retuneMs = 160; s.amount = 0.75; s.flexCents = 30; s.vibratoKeep = 1
            s.formantSemis = 0; s.comp = 0.25; s.reverbMix = 0.3; s.reverbSize = 0.75; s.delayMix = 0
        },
        Preset(id: "trap", name: "Trap Hard") { s in
            s.bypass = false; s.retuneMs = 8; s.amount = 1; s.flexCents = 0; s.vibratoKeep = 0.3
            s.formantSemis = 0; s.comp = 0.6; s.reverbMix = 0.12; s.delayMix = 0.15; s.delayMs = 360
        },
        Preset(id: "robot", name: "Robot") { s in
            s.bypass = false; s.retuneMs = 0; s.amount = 1; s.flexCents = 0; s.vibratoKeep = 0
            s.formantSemis = 0; s.comp = 0.5; s.reverbMix = 0.1; s.delayMix = 0
        },
        Preset(id: "bypass", name: "Gốc") { s in
            s.bypass = true
        },
    ]
}

struct Take: Identifiable, Codable, Equatable {
    var id: UUID
    var date: Date
    var duration: Double
    var settings: TuneSettings
    var beatFile: String?
    var latencyCompMs: Double
    var sampleRate: Double
    var rendered: Bool = false

    var title: String { date.formatted(date: .abbreviated, time: .shortened) }
}
