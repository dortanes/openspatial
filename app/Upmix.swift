import Accelerate
import GameplayKit

/// Splits a channel pair in the frequency domain, one block at a time: what is common to both channels,
/// each channel without it, and each channel's diffuse part. When widening, each channel without the common
/// part also gives up what sits far to its side, as a wide signal of the same power.
/// Analysis and synthesis use square-root Hann windows at 50% overlap, so each channel without
/// the common part plus the common part reconstructs that channel exactly, one block late.
final class PairSplitter {
    /// Spectral statistics average over about 50 ms of blocks.
    private let smoothing: Float = 0.8
    /// Exponent on similarity for the common part: higher keeps only near-identical content in it.
    private let commonFocus: Float
    /// Pan, from 0 in the middle to 1 at one side, where widening starts: a side holding 9 times the other's power.
    /// Even a sound in one channel only gives the side speaker a quarter of its power, so the front pair still
    /// sounds in front.
    private let wideFrom: Float = 0.8
    private let wideShare: Float = 0.25

    private let block = BinauralConvolver.blockSize
    private let bins = PackedFFT.bins
    private let fft = PackedFFT()
    private let window: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let leftRe, leftIm, rightRe, rightIm: UnsafeMutablePointer<Float>
    private let powerLeft, powerRight, crossRe, crossIm: UnsafeMutablePointer<Float>
    private let outputRe, outputIm, tails, results: UnsafeMutablePointer<Float>
    private let widens: Bool
    private let outputs: Int

    /// The latest block of each output, valid until the next `split`.
    var left: UnsafePointer<Float> { UnsafePointer(results) }
    var right: UnsafePointer<Float> { UnsafePointer(results + block) }
    var common: UnsafePointer<Float> { UnsafePointer(results + 2 * block) }
    var diffuseLeft: UnsafePointer<Float> { UnsafePointer(results + 3 * block) }
    var diffuseRight: UnsafePointer<Float> { UnsafePointer(results + 4 * block) }
    /// Silent unless the splitter widens.
    var wideLeft: UnsafePointer<Float> { UnsafePointer(results + 5 * block) }
    var wideRight: UnsafePointer<Float> { UnsafePointer(results + 6 * block) }

    init(widens: Bool = false, commonFocus: Float = 8) {
        self.widens = widens
        self.commonFocus = commonFocus
        outputs = widens ? 7 : 5
        let n = 2 * block
        window = Self.zeroed(n)
        for i in 0..<n {
            window[i] = sin(Float.pi * Float(i) / Float(n))
        }
        history = Self.zeroed(2 * n)
        frame = Self.zeroed(n)
        leftRe = Self.zeroed(bins)
        leftIm = Self.zeroed(bins)
        rightRe = Self.zeroed(bins)
        rightIm = Self.zeroed(bins)
        powerLeft = Self.zeroed(bins)
        powerRight = Self.zeroed(bins)
        crossRe = Self.zeroed(bins)
        crossIm = Self.zeroed(bins)
        outputRe = Self.zeroed(7 * bins)
        outputIm = Self.zeroed(7 * bins)
        tails = Self.zeroed(7 * block)
        results = Self.zeroed(7 * block)
    }

    deinit {
        for pointer in [window, history, frame, leftRe, leftIm, rightRe, rightIm, powerLeft, powerRight, crossRe, crossIm, outputRe, outputIm, tails, results] {
            pointer.deallocate()
        }
    }

    /// Splits one block of the pair.
    func split(_ leftInput: UnsafePointer<Float>, _ rightInput: UnsafePointer<Float>) {
        analyze(leftInput, history: history, re: leftRe, im: leftIm)
        analyze(rightInput, history: history + 2 * block, re: rightRe, im: rightIm)
        separate()
        for output in 0..<outputs {
            synthesize(output)
        }
    }

    static func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        return pointer
    }

    private func analyze(_ input: UnsafePointer<Float>, history: UnsafeMutablePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        history.update(from: history + block, count: block)
        (history + block).update(from: input, count: block)
        vDSP_vmul(history, 1, window, 1, frame, 1, vDSP_Length(2 * block))
        fft.forward(frame, re: re, im: im)
    }

    /// Fills the output spectra from the pair's spectra.
    private func separate() {
        let l = 0, r = bins, c = 2 * bins, dl = 3 * bins, dr = 4 * bins, wl = 5 * bins, wr = 6 * bins
        // Bin 0 packs the real DC and Nyquist values; they stay in their channels.
        for output in 2..<outputs {
            outputRe[output * bins] = 0
            outputIm[output * bins] = 0
        }
        outputRe[l] = leftRe[0]
        outputIm[l] = leftIm[0]
        outputRe[r] = rightRe[0]
        outputIm[r] = rightIm[0]
        let keep = smoothing, add = 1 - smoothing
        let tiny: Float = 1e-12
        for k in 1..<bins {
            let lr = leftRe[k], li = leftIm[k], rr = rightRe[k], ri = rightIm[k]
            powerLeft[k] = keep * powerLeft[k] + add * (lr * lr + li * li)
            powerRight[k] = keep * powerRight[k] + add * (rr * rr + ri * ri)
            // Left times the conjugate of right.
            crossRe[k] = keep * crossRe[k] + add * (lr * rr + li * ri)
            crossIm[k] = keep * crossIm[k] + add * (li * rr - lr * ri)
            let cross = (crossRe[k] * crossRe[k] + crossIm[k] * crossIm[k]).squareRoot()
            let total = powerLeft[k] + powerRight[k] + tiny
            // Balance is 1 for equal power in both channels and 0 for a sound in one channel only.
            let balance = 2 * (powerLeft[k] * powerRight[k]).squareRoot() / total
            // Similarity is coherence times balance: 1 only for the same sound at the same level in both channels.
            let similarity = min(2 * cross / total, balance)
            let commonGain = pow(similarity, commonFocus)
            // Diffuse content is balanced but incoherent; a sound in one channel is neither.
            // The difference is a power fraction, so its square root scales amplitude.
            let diffuseShare = (balance - similarity).squareRoot()
            let commonRe = commonGain * (lr + rr) / 2, commonIm = commonGain * (li + ri) / 2
            outputRe[c + k] = commonRe
            outputIm[c + k] = commonIm
            outputRe[dl + k] = diffuseShare * lr
            outputIm[dl + k] = diffuseShare * li
            outputRe[dr + k] = diffuseShare * rr
            outputIm[dr + k] = diffuseShare * ri
            var keepLeft: Float = 1, keepRight: Float = 1
            if widens {
                // Pan runs from -1 (right only) to 1 (left only); beyond `wideFrom` part of the side moves out,
                // up to `wideShare` of the power for a sound in one channel only, keeping the total power.
                let pan = (powerLeft[k] - powerRight[k]) / total
                let wideLeft = wideShare * max(0, min(1, (pan - wideFrom) / (1 - wideFrom)))
                let wideRight = wideShare * max(0, min(1, (-pan - wideFrom) / (1 - wideFrom)))
                keepLeft = (1 - wideLeft).squareRoot()
                keepRight = (1 - wideRight).squareRoot()
                outputRe[wl + k] = wideLeft.squareRoot() * (lr - commonRe)
                outputIm[wl + k] = wideLeft.squareRoot() * (li - commonIm)
                outputRe[wr + k] = wideRight.squareRoot() * (rr - commonRe)
                outputIm[wr + k] = wideRight.squareRoot() * (ri - commonIm)
            }
            outputRe[l + k] = keepLeft * (lr - commonRe)
            outputIm[l + k] = keepLeft * (li - commonIm)
            outputRe[r + k] = keepRight * (rr - commonRe)
            outputIm[r + k] = keepRight * (ri - commonIm)
        }
    }

    /// Inverse-transforms one output and overlap-adds it into its block of results.
    private func synthesize(_ output: Int) {
        let n = 2 * block
        fft.inverse(re: outputRe + output * bins, im: outputIm + output * bins, into: frame)
        var scale = PackedFFT.transformScale
        vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(n))
        vDSP_vsmul(frame, 1, &scale, frame, 1, vDSP_Length(n))
        let result = results + output * block, tail = tails + output * block
        vDSP_vadd(frame, 1, tail, 1, result, 1, vDSP_Length(block))
        tail.update(from: frame + block, count: block)
    }
}

/// Recent samples of one signal, read back at fixed delays in whole blocks.
final class DelayLine {
    private let block = BinauralConvolver.blockSize
    private let length: Int
    private let samples: UnsafeMutablePointer<Float>

    init(maximumDelay: Int) {
        length = maximumDelay + BinauralConvolver.blockSize
        samples = PairSplitter.zeroed(length)
    }

    deinit {
        samples.deallocate()
    }

    func push(_ input: UnsafePointer<Float>) {
        samples.update(from: samples + block, count: length - block)
        (samples + length - block).update(from: input, count: block)
    }

    /// Adds the block that was pushed `delay` samples ago, scaled by `gain`, to `output`.
    func add(delay: Int, gain: Float, to output: UnsafeMutablePointer<Float>) {
        var gain = gain
        vDSP_vsma(samples + length - block - delay, 1, &gain, output, 1, output, 1, vDSP_Length(block))
    }
}

/// Feeds the speakers a source leaves silent, working on the speaker planes in `SurroundChannel` order.
final class SpeakerFiller {
    private static let frontLeft = SurroundChannel.allCases.firstIndex(of: .frontLeft)!
    private static let frontRight = SurroundChannel.allCases.firstIndex(of: .frontRight)!
    private static let center = SurroundChannel.allCases.firstIndex(of: .center)!
    private static let sideLeft = SurroundChannel.allCases.firstIndex(of: .sideLeft)!
    private static let sideRight = SurroundChannel.allCases.firstIndex(of: .sideRight)!
    private static let backLeft = SurroundChannel.allCases.firstIndex(of: .backLeft)!
    private static let backRight = SurroundChannel.allCases.firstIndex(of: .backRight)!

    /// Diffuse feeds trail the speakers in front of them so the image stays put: 5 ms, then 10 ms.
    private static let shortDelay = 240
    private static let longDelay = 480
    /// Splitting a signal between two speakers gives each half its power.
    private static let half: Float = 0.707

    /// The diffuse part of a stereo pair reaches each side and back speaker through its own velvet-noise
    /// decorrelator: one tap of random sign per millisecond for 30 ms, decaying about 37 dB, so the four speakers carry
    /// four unrelated versions of the room rather than delayed copies of one signal. Samples at 48 kHz.
    private static let decorrelatorTaps = 30
    private static let decorrelatorSegment = 48
    private static let decorrelatorDecay: Float = 336
    private static let sideLeftTaps = decorrelator(seed: 1, onset: shortDelay)
    private static let sideRightTaps = decorrelator(seed: 2, onset: shortDelay)
    private static let backLeftTaps = decorrelator(seed: 3, onset: longDelay)
    private static let backRightTaps = decorrelator(seed: 4, onset: longDelay)
    private static let diffuseHistory = longDelay + decorrelatorTaps * decorrelatorSegment

    private let block = BinauralConvolver.blockSize
    private let stereo = PairSplitter(widens: true)
    private let stereoDiffuseLeft = DelayLine(maximumDelay: SpeakerFiller.diffuseHistory)
    private let stereoDiffuseRight = DelayLine(maximumDelay: SpeakerFiller.diffuseHistory)
    private let surround = PairSplitter()
    private let surroundDiffuseLeft = DelayLine(maximumDelay: SpeakerFiller.shortDelay)
    private let surroundDiffuseRight = DelayLine(maximumDelay: SpeakerFiller.shortDelay)
    /// The model's left and right vocals never match exactly, so a near-identity test would starve the center:
    /// on a mastered pop track focus 8 left the center 17% of the vocals' energy, focus 0.5 keeps 73%.
    private let vocals = PairSplitter(commonFocus: 0.5)
    private let accompaniment = PairSplitter(widens: true)

    /// Stereo in the front pair to all seven speakers: common content to the center, the rest to the fronts
    /// except what sits far to one side, which plays from that side, and the diffuse part to the sides and the back.
    func spreadStereo(_ sources: UnsafeMutablePointer<Float>) {
        stereo.split(plane(sources, Self.frontLeft), plane(sources, Self.frontRight))
        plane(sources, Self.frontLeft).update(from: stereo.left, count: block)
        plane(sources, Self.frontRight).update(from: stereo.right, count: block)
        plane(sources, Self.center).update(from: stereo.common, count: block)
        placeDiffuse(of: stereo, in: sources)
        addWide(of: stereo, in: sources)
    }

    /// Separated vocals and the rest in place of the stereo they came from. The vocals' common part, the lead,
    /// plays from the center, and what the vocals spread to each side, such as doubles, harmonies and echoes,
    /// from the side speakers. The rest splits like stereo, its common part between the fronts.
    func spreadStems(_ sources: UnsafeMutablePointer<Float>, stems: UnsafePointer<Float>) {
        let vocalsLeft = stems + VocalSeparator.vocals * block, restLeft = stems + VocalSeparator.rest * block
        vocals.split(vocalsLeft, vocalsLeft + block)
        accompaniment.split(restLeft, restLeft + block)
        let n = vDSP_Length(block)
        var gain = Self.half
        for (speaker, side) in [(Self.frontLeft, accompaniment.left), (Self.frontRight, accompaniment.right)] {
            let output = plane(sources, speaker)
            output.update(from: side, count: block)
            vDSP_vsma(accompaniment.common, 1, &gain, output, 1, output, 1, n)
        }
        plane(sources, Self.center).update(from: vocals.common, count: block)
        placeDiffuse(of: accompaniment, in: sources)
        addWide(of: accompaniment, in: sources)
        vDSP_vadd(plane(sources, Self.sideLeft), 1, vocals.left, 1, plane(sources, Self.sideLeft), 1, n)
        vDSP_vadd(plane(sources, Self.sideRight), 1, vocals.right, 1, plane(sources, Self.sideRight), 1, n)
    }

    /// What a widening split moved out of the fronts, to the side speakers.
    private func addWide(of pair: PairSplitter, in sources: UnsafeMutablePointer<Float>) {
        let n = vDSP_Length(block)
        vDSP_vadd(plane(sources, Self.sideLeft), 1, pair.wideLeft, 1, plane(sources, Self.sideLeft), 1, n)
        vDSP_vadd(plane(sources, Self.sideRight), 1, pair.wideRight, 1, plane(sources, Self.sideRight), 1, n)
    }

    /// The diffuse part of a split pair to the sides and, later, the back, each through its own decorrelator;
    /// the onsets keep the image in front.
    private func placeDiffuse(of pair: PairSplitter, in sources: UnsafeMutablePointer<Float>) {
        stereoDiffuseLeft.push(pair.diffuseLeft)
        stereoDiffuseRight.push(pair.diffuseRight)
        for (line, taps, speaker) in [
            (stereoDiffuseLeft, Self.sideLeftTaps, Self.sideLeft),
            (stereoDiffuseRight, Self.sideRightTaps, Self.sideRight),
            (stereoDiffuseLeft, Self.backLeftTaps, Self.backLeft),
            (stereoDiffuseRight, Self.backRightTaps, Self.backRight),
        ] {
            let output = plane(sources, speaker)
            output.update(repeating: 0, count: block)
            for tap in taps {
                line.add(delay: tap.delay, gain: tap.gain, to: output)
            }
        }
    }

    /// Velvet-noise taps after `onset` samples, scaled to the same power as a single tap of `half`.
    /// A fixed seed keeps every launch sounding the same.
    private static func decorrelator(seed: UInt64, onset: Int) -> [(delay: Int, gain: Float)] {
        let random = GKMersenneTwisterRandomSource(seed: seed)
        var taps: [(delay: Int, gain: Float)] = []
        for segment in 0..<decorrelatorTaps {
            let position = segment * decorrelatorSegment + random.nextInt(upperBound: decorrelatorSegment)
            let sign: Float = random.nextBool() ? 1 : -1
            taps.append((onset + position, sign * exp(-Float(position) / decorrelatorDecay)))
        }
        let power = taps.reduce(0) { $0 + $1.gain * $1.gain }
        let scale = half / power.squareRoot()
        return taps.map { ($0.delay, $0.gain * scale) }
    }

    /// A surround pair on the sides to the sides and the back: content common to both surrounds lies behind
    /// and moves to both back speakers, the sides keep the rest, and the diffuse part also reaches the back.
    /// The surrounds play one block late, after the fronts.
    func fillBack(_ sources: UnsafeMutablePointer<Float>) {
        surround.split(plane(sources, Self.sideLeft), plane(sources, Self.sideRight))
        plane(sources, Self.sideLeft).update(from: surround.left, count: block)
        plane(sources, Self.sideRight).update(from: surround.right, count: block)
        surroundDiffuseLeft.push(surround.diffuseLeft)
        surroundDiffuseRight.push(surround.diffuseRight)
        var gain = Self.half
        vDSP_vsmul(surround.common, 1, &gain, plane(sources, Self.backLeft), 1, vDSP_Length(block))
        vDSP_vsmul(surround.common, 1, &gain, plane(sources, Self.backRight), 1, vDSP_Length(block))
        surroundDiffuseLeft.add(delay: Self.shortDelay, gain: Self.half, to: plane(sources, Self.backLeft))
        surroundDiffuseRight.add(delay: Self.shortDelay, gain: Self.half, to: plane(sources, Self.backRight))
    }

    private func plane(_ sources: UnsafeMutablePointer<Float>, _ speaker: Int) -> UnsafeMutablePointer<Float> {
        sources + speaker * block
    }
}

/// Bass management: every speaker's content below 80 Hz moves to the subwoofer. Linkwitz-Riley crossovers of
/// the fourth order sum back to a flat response, so the bass keeps its level until the subwoofer's is changed.
final class BassCrossover {
    private static let frequency = 80.0
    private static let sampleRate = 48000.0
    private static let subwoofer = SurroundChannel.allCases.firstIndex(of: .subwoofer)!
    private static let mains = SurroundChannel.allCases.indices.filter { $0 != subwoofer }

    private let block = BinauralConvolver.blockSize
    private let lowPass, highPass: vDSP_biquad_Setup
    /// Filter state per main speaker: two sections need six values each way.
    private let lowState, highState: UnsafeMutablePointer<Float>
    private let scratch: UnsafeMutablePointer<Float>

    init() {
        // A fourth-order Linkwitz-Riley filter is two identical second-order Butterworth sections (Q = 1/√2).
        let w = 2 * Double.pi * Self.frequency / Self.sampleRate
        let alpha = sin(w) / (2 * 0.5.squareRoot())
        let a0 = 1 + alpha
        let feedback = [-2 * cos(w) / a0, (1 - alpha) / a0]
        let low = [(1 - cos(w)) / 2 / a0, (1 - cos(w)) / a0, (1 - cos(w)) / 2 / a0] + feedback
        let high = [(1 + cos(w)) / 2 / a0, -(1 + cos(w)) / a0, (1 + cos(w)) / 2 / a0] + feedback
        lowPass = vDSP_biquad_CreateSetup(low + low, 2)!
        highPass = vDSP_biquad_CreateSetup(high + high, 2)!
        lowState = PairSplitter.zeroed(Self.mains.count * 6)
        highState = PairSplitter.zeroed(Self.mains.count * 6)
        scratch = PairSplitter.zeroed(block)
    }

    deinit {
        vDSP_biquad_DestroySetup(lowPass)
        vDSP_biquad_DestroySetup(highPass)
        for pointer in [lowState, highState, scratch] {
            pointer.deallocate()
        }
    }

    func process(_ planes: UnsafeMutablePointer<Float>) {
        let n = vDSP_Length(block)
        let subwoofer = planes + Self.subwoofer * block
        for (slot, speaker) in Self.mains.enumerated() {
            let plane = planes + speaker * block
            vDSP_biquad(lowPass, lowState + slot * 6, plane, 1, scratch, 1, n)
            vDSP_vadd(subwoofer, 1, scratch, 1, subwoofer, 1, n)
            vDSP_biquad(highPass, highState + slot * 6, plane, 1, scratch, 1, n)
            plane.update(from: scratch, count: block)
        }
    }
}
