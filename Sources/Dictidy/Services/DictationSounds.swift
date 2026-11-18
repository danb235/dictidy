import Accelerate
import AudioToolbox
import AVFoundation

/// The three dictation cues, all built-in macOS sounds played as system sounds, so they follow the
/// user's alert volume and Sound Effects output device:
/// - start: Tink, once the microphone is actually live.
/// - stop: Purr at reduced volume, when recording ends. Quiet, because Pop follows shortly after.
/// - done: Pop, the moment the dictated text is pasted. Nothing plays if nothing is pasted, so its
///   absence is itself a signal that the dictation produced no text.
@MainActor
final class DictationSounds {
    enum Cue { case start, stop, done }

    /// Purr's level relative to the original (about 6 dB quieter).
    private static let stopGain: Float = 0.5

    private lazy var startID = Self.systemSound(named: "Tink")
    private lazy var stopID = Self.quietSystemSound(named: "Purr", gain: Self.stopGain)
        ?? Self.systemSound(named: "Purr")
    private lazy var doneID = Self.systemSound(named: "Pop")

    func play(_ cue: Cue) {
        switch cue {
        case .start: AudioServicesPlaySystemSound(startID)
        case .stop: AudioServicesPlaySystemSound(stopID)
        case .done: AudioServicesPlaySystemSound(doneID)
        }
    }

    private static func systemSoundURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
    }

    private static func systemSound(named name: String) -> SystemSoundID {
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(systemSoundURL(name) as CFURL, &id)
        return id
    }

    /// System sounds have no volume control, so make (once) and cache an attenuated copy of the
    /// built-in sound, then register that file. Returns nil on any failure; the caller falls back to
    /// the full-volume original.
    private static func quietSystemSound(named name: String, gain: Float) -> SystemSoundID? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = caches.appendingPathComponent("com.opensource.dictidy/Sounds", isDirectory: true)
        let destination = folder.appendingPathComponent("\(name)-\(Int((gain * 100).rounded())).caf")

        if !FileManager.default.fileExists(atPath: destination.path) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try writeAttenuatedCopy(of: systemSoundURL(name), to: destination, gain: gain)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                return nil
            }
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(destination as CFURL, &id)
        return status == kAudioServicesNoError ? id : nil
    }

    private static func writeAttenuatedCopy(of source: URL, to destination: URL, gain: Float) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.length)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try input.read(into: buffer)
        guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
        var scale = gain
        for channel in 0..<Int(format.channelCount) {
            vDSP_vsmul(channels[channel], 1, &scale, channels[channel], 1, vDSP_Length(buffer.frameLength))
        }
        // Write beside the destination, then move into place, so a partial file is never registered.
        // AVAudioFile picks the container from the extension, so the temporary name keeps ".caf".
        let partial = destination.deletingPathExtension().appendingPathExtension("partial.caf")
        try? FileManager.default.removeItem(at: partial)
        do {
            // Store in the original sound's file format; AVAudioFile converts from the float buffer.
            let output = try AVAudioFile(forWriting: partial, settings: input.fileFormat.settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            try output.write(from: buffer)
        }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
}
