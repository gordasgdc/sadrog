// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation
import AudioToolbox

/// Voice presets built ONLY from the Audio Units macOS ships (high-pass filter, dynamics processor, peak limiter) and run through the same out-of-process host as
/// any other plugin. SADROG contains no DSP of its own here: a preset is a chain of ordinary `AudioEffect` entries with their parameters set, so every entry can be
/// bypassed, reordered, removed, opened in its own window and reset like any other effect.
///
/// What the pieces do (and do not do):
/// - High-pass filter: removes rumble and hum below the cut-off. It does not remove noise inside the voice band.
/// - Dynamics processor: a compressor above `threshold` (the `headroom` sets how far above it the gain reduction ends) and a conservative expander below
///   `expansionThreshold`. The expander only lowers very quiet passages between words: it is NOT noise removal and does not know voice from noise.
/// - Peak limiter: stops short peaks from going past 0 dBFS.
public enum VoicePreset: String, CaseIterable, Sendable {
    case highPassOnly, cleanVoice, podcast, limiterOnly

    public static let highPass = AUComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_HighPassFilter, manufacturer: kAudioUnitManufacturer_Apple)
    public static let dynamics = AUComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_DynamicsProcessor, manufacturer: kAudioUnitManufacturer_Apple)
    public static let limiter = AUComponentID(type: kAudioUnitType_Effect, subtype: kAudioUnitSubType_PeakLimiter, manufacturer: kAudioUnitManufacturer_Apple)

    /// (component, parameter address → value) of each stage, in processing order.
    public var stages: [(AUComponentID, [AUParameterAddress: AUValue])] {
        func hp(_ hz: AUValue) -> (AUComponentID, [AUParameterAddress: AUValue]) { (Self.highPass, [AUParameterAddress(kHipassParam_CutoffFrequency): hz, AUParameterAddress(kHipassParam_Resonance): 0]) }
        func dyn(thr: AUValue, head: AUValue, expRatio: AUValue, expThr: AUValue, atk: AUValue, rel: AUValue, gain: AUValue) -> (AUComponentID, [AUParameterAddress: AUValue]) {
            (Self.dynamics, [AUParameterAddress(kDynamicsProcessorParam_Threshold): thr, AUParameterAddress(kDynamicsProcessorParam_HeadRoom): head,
                             AUParameterAddress(kDynamicsProcessorParam_ExpansionRatio): expRatio, AUParameterAddress(kDynamicsProcessorParam_ExpansionThreshold): expThr,
                             AUParameterAddress(kDynamicsProcessorParam_AttackTime): atk, AUParameterAddress(kDynamicsProcessorParam_ReleaseTime): rel, AUParameterAddress(kDynamicsProcessorParam_OverallGain): gain])
        }
        let lim: (AUComponentID, [AUParameterAddress: AUValue]) = (Self.limiter, [AUParameterAddress(kLimiterParam_AttackTime): 0.005, AUParameterAddress(kLimiterParam_DecayTime): 0.05, AUParameterAddress(kLimiterParam_PreGain): 0])
        switch self {
        case .highPassOnly: return [hp(80)]
        case .cleanVoice: return [hp(80), dyn(thr: -24, head: 6, expRatio: 1.5, expThr: -55, atk: 0.010, rel: 0.150, gain: 2), lim]
        case .podcast: return [hp(90), dyn(thr: -20, head: 5, expRatio: 2, expThr: -50, atk: 0.008, rel: 0.200, gain: 3), lim]
        case .limiterOnly: return [lim]
        }
    }

    /// Instantiates each Audio Unit (out of process), sets the parameters and captures its full state, exactly as the plugin window would.
    public func effects() throws -> [AudioEffect] {
        try stages.map { id, params in
            let u = try AUCatalog.instantiate(id)
            for (a, v) in params { u.auAudioUnit.parameterTree?.parameter(withAddress: a)?.setValue(v, originator: nil) }
            guard let info = AUCatalog.installed(id) else { throw EffectError.instantiate("plugin") }
            return AudioEffect(component: id, name: info.name, manufacturerName: info.manufacturerName, componentVersion: info.version, state: AudioEffect.encode(state: u.auAudioUnit.fullState))
        }
    }
    /// Entries that belong to a voice preset (Apple’s three units), used to reset them without touching other plugins.
    public static func isVoiceStage(_ e: AudioEffect) -> Bool { [highPass, dynamics, limiter].contains(e.component) }
}

extension ProjectEditor {
    /// Replaces the voice stages already on source `k` with `preset` (other plugins keep their place, before them); `nil` removes the voice stages. One undo step.
    public func setVoicePreset(_ preset: VoicePreset?, source k: Int, media: String? = nil, effects built: [AudioEffect]? = nil) throws {
        let m = media ?? project.primaryMedia
        let others = (project.recording(m).effects[k] ?? []).filter { !VoicePreset.isVoiceStage($0) }
        let new = try built ?? preset?.effects() ?? []
        setEffects(k, others + new, media: m)
    }
}
