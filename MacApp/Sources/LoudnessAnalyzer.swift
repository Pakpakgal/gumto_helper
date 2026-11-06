@preconcurrency import AVFoundation
import Foundation

/// EBU R128 / ITU-R BS.1770 방식의 K-weighting과 게이팅으로 통합 음량을 계산한다.
/// 피크 값은 오버샘플링하지 않은 sample peak이다.
enum LoudnessAnalyzer {
    private struct Biquad {
        let b0: Double
        let b1: Double
        let b2: Double
        let a1: Double
        let a2: Double
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            return y
        }
    }

    private struct ChannelFilter {
        // 48 kHz에서 사용하는 BS.1770 K-weighting 계수.
        var shelf = Biquad(
            b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
            a1: -1.69065929318241, a2: 0.73248077421585
        )
        var highPass = Biquad(
            b0: 1, b1: -2, b2: 1,
            a1: -1.99004745483398, a2: 0.99007225036621
        )

        mutating func process(_ value: Double) -> Double {
            highPass.process(shelf.process(value))
        }
    }

    static func measure(url: URL) async -> LoudnessResult? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else { return nil }
        do {
            let reader = try AVAssetReader(asset: asset)
            let sampleRate = 48_000
            let channels = 2
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return nil }
            reader.add(output)
            guard reader.startReading() else { return nil }

            let hopFrames = sampleRate / 10 // 100 ms
            var filters = [ChannelFilter](repeating: ChannelFilter(), count: channels)
            var hopEnergy = 0.0
            var hopCount = 0
            var hops: [Double] = []
            var peak = 0.0

            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                      let pointer else { continue }
                let floatCount = length / MemoryLayout<Float>.size
                let values = UnsafeRawPointer(pointer).bindMemory(to: Float.self, capacity: floatCount)
                var index = 0
                while index + channels <= floatCount {
                    var frameEnergy = 0.0
                    for channel in 0..<channels {
                        let value = Double(values[index + channel])
                        peak = max(peak, abs(value))
                        let weighted = filters[channel].process(value)
                        frameEnergy += weighted * weighted
                    }
                    hopEnergy += frameEnergy
                    hopCount += 1
                    if hopCount == hopFrames {
                        hops.append(hopEnergy / Double(hopFrames))
                        hopEnergy = 0
                        hopCount = 0
                    }
                    index += channels
                }
            }
            guard reader.status != .failed else {
                AppLogger.log(
                    level: .warning,
                    category: "음량 분석",
                    message: "오디오 트랙을 읽는 중 오류가 발생하여 음량 결과를 생략했습니다.",
                    error: reader.error,
                    videoURL: url
                )
                return nil
            }
            if hopCount > 0 { hops.append(hopEnergy / Double(hopCount)) }
            guard !hops.isEmpty else { return nil }

            // 400 ms 블록, 100 ms hop (75% overlap).
            var blockEnergies: [Double] = []
            if hops.count < 4 {
                blockEnergies = [hops.reduce(0, +) / Double(hops.count)]
            } else {
                for index in 3..<hops.count {
                    blockEnergies.append(hops[(index - 3)...index].reduce(0, +) / 4)
                }
            }
            let absoluteGated = blockEnergies.filter { loudness(for: $0) >= -70 }
            guard !absoluteGated.isEmpty else { return nil }
            let preliminary = loudness(for: absoluteGated.reduce(0, +) / Double(absoluteGated.count))
            let relativeGate = preliminary - 10
            let gated = absoluteGated.filter { loudness(for: $0) >= relativeGate }
            guard !gated.isEmpty else { return nil }
            let integrated = loudness(for: gated.reduce(0, +) / Double(gated.count))
            let peakDBFS = peak > 0 ? 20 * log10(peak) : -Double.infinity
            return LoudnessResult(integratedLUFS: integrated, samplePeakDBFS: peakDBFS)
        } catch is CancellationError {
            return nil
        } catch {
            AppLogger.log(
                level: .warning,
                category: "음량 분석",
                message: "음량 측정에 실패했습니다.",
                error: error,
                videoURL: url
            )
            return nil
        }
    }

    private static func loudness(for energy: Double) -> Double {
        guard energy > 0 else { return -Double.infinity }
        return -0.691 + 10 * log10(energy)
    }
}
