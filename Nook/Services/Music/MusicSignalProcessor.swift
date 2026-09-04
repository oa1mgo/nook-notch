import Accelerate
import Foundation

/// Frequency-domain metrics used by Music Edge Glow and the compact spectrum.
/// This type owns all scratch buffers so steady-state analysis does not allocate.
nonisolated final class MusicSignalProcessor {
    struct Output: Equatable, Sendable {
        let level: Float
        let bands: [Float]
        /// Unsmooth low-frequency strength used only by Music Glow.
        let bassLevel: Float
        /// Positive low-frequency rise, independent from the display bars.
        let bassFlux: Float
        let hasSignal: Bool
    }

    private let fftSize = 2_048
    private let hopSize = 1_024
    private let halfSize = 1_024
    private let setup: vDSP_DFT_Setup

    private var sampleRate: Double
    private var inputWindow: [Float]
    private var windowedInput: [Float]
    private var hannWindow: [Float]
    private var inputEven: [Float]
    private var inputOdd: [Float]
    private var outputReal: [Float]
    private var outputImaginary: [Float]
    private var magnitudes: [Float]
    private var windowFill = 0

    private var smoothedLevel: Float = 0
    private var smoothedBands = [Float](repeating: 0, count: 4)
    private var bandPeaks = [Float](repeating: 0.000_01, count: 4)
    private var previousBassMagnitudes: [Float]
    private var hasPreviousSpectrum = false

    init?(sampleRate: Double = 48_000) {
        guard let setup = vDSP_DFT_zrop_CreateSetup(
            nil,
            vDSP_Length(fftSize),
            vDSP_DFT_Direction.FORWARD
        ) else {
            return nil
        }

        self.setup = setup
        self.sampleRate = sampleRate
        inputWindow = [Float](repeating: 0, count: fftSize)
        windowedInput = [Float](repeating: 0, count: fftSize)
        hannWindow = [Float](repeating: 0, count: fftSize)
        inputEven = [Float](repeating: 0, count: halfSize)
        inputOdd = [Float](repeating: 0, count: halfSize)
        outputReal = [Float](repeating: 0, count: halfSize)
        outputImaginary = [Float](repeating: 0, count: halfSize)
        magnitudes = [Float](repeating: 0, count: halfSize)
        previousBassMagnitudes = [Float](repeating: 0, count: halfSize)
        vDSP_hann_window(&hannWindow, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_DFT_DestroySetup(setup)
    }

    func reset(sampleRate: Double) {
        self.sampleRate = sampleRate
        inputWindow = [Float](repeating: 0, count: fftSize)
        windowFill = 0
        smoothedLevel = 0
        smoothedBands = [Float](repeating: 0, count: 4)
        bandPeaks = [Float](repeating: 0.000_01, count: 4)
        previousBassMagnitudes = [Float](repeating: 0, count: halfSize)
        hasPreviousSpectrum = false
    }

    func ingest(
        _ samples: UnsafeBufferPointer<Float>,
        onOutput: (Output) -> Void
    ) {
        var sourceIndex = 0
        while sourceIndex < samples.count {
            let copyCount = min(fftSize - windowFill, samples.count - sourceIndex)
            inputWindow.withUnsafeMutableBufferPointer { destination in
                guard let destinationBase = destination.baseAddress,
                      let sourceBase = samples.baseAddress else { return }
                destinationBase
                    .advanced(by: windowFill)
                    .update(from: sourceBase.advanced(by: sourceIndex), count: copyCount)
            }
            windowFill += copyCount
            sourceIndex += copyCount

            if windowFill == fftSize {
                onOutput(analyzeCurrentWindow())
                inputWindow.withUnsafeMutableBufferPointer { buffer in
                    guard let base = buffer.baseAddress else { return }
                    memmove(base, base.advanced(by: hopSize), hopSize * MemoryLayout<Float>.size)
                }
                windowFill = hopSize
            }
        }
    }

    private func analyzeCurrentWindow() -> Output {
        var rms: Float = 0
        vDSP_rmsqv(inputWindow, 1, &rms, vDSP_Length(fftSize))
        let levelTarget = Self.normalizedDecibels(rms, floor: -55, ceiling: -8)
        smoothedLevel = smooth(current: smoothedLevel, target: levelTarget, attack: 0.58, release: 0.12)

        vDSP_vmul(
            inputWindow,
            1,
            hannWindow,
            1,
            &windowedInput,
            1,
            vDSP_Length(fftSize)
        )

        for index in 0..<halfSize {
            inputEven[index] = windowedInput[index * 2]
            inputOdd[index] = windowedInput[index * 2 + 1]
        }

        vDSP_DFT_Execute(
            setup,
            inputEven,
            inputOdd,
            &outputReal,
            &outputImaginary
        )

        let magnitudeScale = Float(1.0 / Double(fftSize))
        for bin in 1..<halfSize {
            let magnitude = hypotf(outputReal[bin], outputImaginary[bin]) * magnitudeScale
            magnitudes[bin] = magnitude
        }

        let bandRanges: [(Float, Float)] = [
            (40, 160),
            (160, 600),
            (600, 2_400),
            (2_400, 9_000)
        ]
        var bassLevel: Float = 0
        var bassFlux: Float = 0
        for (index, range) in bandRanges.enumerated() {
            let lower = max(
                1,
                Int(ceil(Double(range.0) * Double(fftSize) / sampleRate))
            )
            let upper = min(
                halfSize - 1,
                Int(floor(Double(range.1) * Double(fftSize) / sampleRate))
            )
            guard upper >= lower else { continue }

            var energy: Float = 0
            for bin in lower...upper {
                energy += magnitudes[bin] * magnitudes[bin]
            }
            energy = sqrtf(energy / Float(upper - lower + 1))
            bandPeaks[index] = max(energy, bandPeaks[index] * 0.995)
            let relativeEnergy = min(max(energy / max(bandPeaks[index], 0.000_01), 0), 1)
            let target = powf(relativeEnergy, 0.62) * (0.22 + smoothedLevel * 0.78)
            if index == 0 {
                // Keep the glow input separate from the display bars. This
                // strength is normalized but not time-smoothed, so an onset
                // cannot be delayed by the compact spectrum animation.
                bassLevel = target

                if hasPreviousSpectrum {
                    var positiveFluxSquared: Float = 0
                    for bin in lower...upper {
                        let positiveRise = max(
                            magnitudes[bin] - previousBassMagnitudes[bin],
                            0
                        )
                        positiveFluxSquared += positiveRise * positiveRise
                    }
                    let fluxRMS = sqrtf(positiveFluxSquared / Float(upper - lower + 1))
                    bassFlux = min(max(fluxRMS / max(energy, 0.000_000_1), 0), 1)
                }

                for bin in lower...upper {
                    previousBassMagnitudes[bin] = magnitudes[bin]
                }
            }
            smoothedBands[index] = smooth(
                current: smoothedBands[index],
                target: target,
                attack: 0.62,
                release: 0.16
            )
        }
        hasPreviousSpectrum = true

        return Output(
            level: smoothedLevel,
            bands: smoothedBands,
            bassLevel: bassLevel,
            bassFlux: bassFlux,
            hasSignal: rms > 0.000_5
        )
    }

    private func smooth(
        current: Float,
        target: Float,
        attack: Float,
        release: Float
    ) -> Float {
        current + (target - current) * (target >= current ? attack : release)
    }

    private static func normalizedDecibels(
        _ amplitude: Float,
        floor: Float,
        ceiling: Float
    ) -> Float {
        let decibels = 20 * log10f(max(amplitude, 0.000_000_1))
        return min(max((decibels - floor) / (ceiling - floor), 0), 1)
    }
}
