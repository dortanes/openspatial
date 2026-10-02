import Accelerate
import os
import simd

/// One sound that stands out: where it comes from and its share of the input's power.
struct SoundSource: Equatable {
    /// x to the right and z ahead, on the unit circle.
    var position: SIMD2<Float>
    /// 0 to 1.
    var share: Float
}

/// Finds the separate sounds in the input, before any upmixing, for the 3D view. Every frequency bin is given a
/// direction; the bins' power, gathered by direction, peaks where a sound sits, and each peak is one source.
/// Multichannel input places each bin by its speakers weighted by their power in that bin.
/// Stereo places each bin as a matrix surround decoder steers it: the level difference between the channels
/// gives left and right, their phase gives front and back. In phase is in front, a channel alone is at its
/// front speaker, and out of phase is behind, where matrix-encoded surround channels sit.
final class SoundSources {
    var current: [SoundSource] { sources.withLock { $0 } }

    private static let block = BinauralConvolver.blockSize
    /// Frames of 4096 samples, advanced by one block, resolve single harmonics, which mostly belong to one sound.
    private static let frameBins = 2048
    private static let frameSize = 2 * frameBins
    private static let binWidth = 48000 / Float(frameSize)
    private static let usedBins = bins(100, 16000)
    /// Directions are gathered into sectors of 5 degrees, the first starting straight behind on the left.
    private static let sectors = 72
    private static let sectorWidth: Float = 360 / Float(sectors)
    /// Sectors either side of a peak that belong to its source, and the nearest two sources may be.
    private static let reach = 3
    private static let separation = 5
    private static let most = 5
    /// A new source holds at least this part of the strongest peak and of the total power; one found in the
    /// previous block stays down to half of each.
    private static let relativePeak: Float = 0.08
    private static let leastShare: Float = 0.03
    private static let keep: Float = 0.5
    /// Powers follow over about 300 ms.
    private static let follow = 1 - exp(-Float(block) / (0.3 * 48000))
    /// Degrees from straight ahead of a front speaker, where a stereo channel alone plays.
    private static let frontSpeaker = Float(SurroundChannel.frontRight.azimuth)
    /// Below this power per sample there are no sources.
    private static let quiet: Float = 1e-7
    private static let frontLeft = SurroundChannel.allCases.firstIndex(of: .frontLeft)!
    private static let frontRight = SurroundChannel.allCases.firstIndex(of: .frontRight)!
    /// Each speaker's direction as x to the right and z ahead; the subwoofer has none.
    private static let directions = SurroundChannel.allCases.map { channel -> SIMD2<Float>? in
        guard channel != .subwoofer else { return nil }
        let radians = Float(channel.azimuth * .pi / 180)
        return [sin(radians), cos(radians)]
    }

    private let sources = OSAllocatedUnfairLock(initialState: [SoundSource]())
    private let fft = PackedFFT(bins: SoundSources.frameBins)
    private let window, frame: UnsafeMutablePointer<Float>
    /// Each speaker's latest frame of samples, and its spectrum and power per bin.
    private let history, re, im, power: UnsafeMutablePointer<Float>
    /// Per sector: the power in this block, and followed over time.
    private var blockPower = [Float](repeating: 0, count: sectors)
    private var gathered = [Float](repeating: 0, count: sectors)
    /// The sectors of the sources found in the previous block.
    private var held: [Int] = []

    init() {
        let n = Self.frameSize
        let speakers = SurroundChannel.allCases.count
        window = PairSplitter.zeroed(n)
        for i in 0..<n {
            window[i] = 0.5 - 0.5 * cos(2 * .pi * Float(i) / Float(n))
        }
        frame = PairSplitter.zeroed(n)
        re = PairSplitter.zeroed(speakers * Self.frameBins)
        im = PairSplitter.zeroed(speakers * Self.frameBins)
        history = PairSplitter.zeroed(speakers * n)
        power = PairSplitter.zeroed(speakers * Self.frameBins)
    }

    deinit {
        for pointer in [window, frame, re, im, history, power] {
            pointer.deallocate()
        }
    }

    /// Takes one block of the routed input, one plane per speaker in `SurroundChannel` order. Worker thread only.
    func analyze(_ planes: UnsafePointer<Float>) {
        let block = Self.block
        var total: Float = 0, otherPower: Float = 0
        for (speaker, direction) in Self.directions.enumerated() where direction != nil {
            var level: Float = 0
            vDSP_measqv(planes + speaker * block, 1, &level, vDSP_Length(block))
            total += level
            if speaker != Self.frontLeft && speaker != Self.frontRight {
                otherPower += level
            }
        }
        guard total > Self.quiet else {
            for sector in 0..<Self.sectors {
                gathered[sector] = 0
            }
            held = []
            sources.withLock { $0 = [] }
            return
        }
        for sector in 0..<Self.sectors {
            blockPower[sector] = 0
        }
        if otherPower <= Self.quiet {
            gatherStereo(planes)
        } else {
            gatherSurround(planes)
        }
        var sum: Float = 0
        for sector in 0..<Self.sectors {
            gathered[sector] += (blockPower[sector] - gathered[sector]) * Self.follow
            sum += gathered[sector]
        }
        let peaks = peaks(sum)
        held = peaks.map(\.sector)
        let found = peaks.map { peak in
            let radians = peak.azimuth * .pi / 180
            return SoundSource(position: [sin(radians), cos(radians)], share: peak.share)
        }
        sources.withLock { $0 = found }
    }

    /// Steers each bin on a circle: x is the level difference and z the in-phase part, both relative to the
    /// bin's power, so a single sound lies on the circle. Its angle runs from 0 in phase through 90 for one
    /// channel alone to 180 out of phase, and maps onto the room through the front speaker.
    private func gatherStereo(_ planes: UnsafePointer<Float>) {
        let (left, right) = (Self.frontLeft, Self.frontRight)
        transform(left, planes)
        transform(right, planes)
        let bins = Self.frameBins
        let leftRe = re + left * bins, leftIm = im + left * bins, leftPower = power + left * bins
        let rightRe = re + right * bins, rightIm = im + right * bins, rightPower = power + right * bins
        for k in Self.usedBins {
            let sum = leftPower[k] + rightPower[k]
            guard sum > 0 else { continue }
            let x = (rightPower[k] - leftPower[k]) / sum
            let z = 2 * (leftRe[k] * rightRe[k] + leftIm[k] * rightIm[k]) / sum
            let steering = atan2(abs(x), z) * 180 / .pi
            let azimuth = steering <= 90
                ? steering / 90 * Self.frontSpeaker
                : Self.frontSpeaker + (steering - 90) / 90 * (180 - Self.frontSpeaker)
            blockPower[Self.sector(x < 0 ? -azimuth : azimuth)] += sum
        }
    }

    /// Places each bin at its speakers' directions weighted by their power. A bin spread evenly around the room
    /// has no direction and counts for little.
    private func gatherSurround(_ planes: UnsafePointer<Float>) {
        let bins = Self.frameBins
        let spectra = Self.directions.enumerated().compactMap { speaker, direction in
            direction.map { transform(speaker, planes); return (power + speaker * bins, $0) }
        }
        for k in Self.usedBins {
            var vector = SIMD2<Float>.zero, sum: Float = 0
            for (spectrum, direction) in spectra {
                vector += spectrum[k] * direction
                sum += spectrum[k]
            }
            let length = simd_length(vector)
            guard sum > 0, length > 0 else { continue }
            blockPower[Self.sector(atan2(vector.x, vector.y) * 180 / .pi)] += length
        }
    }

    /// The strongest peaks of the gathered power, at least `separation` sectors apart.
    private func peaks(_ sum: Float) -> [(sector: Int, azimuth: Float, share: Float)] {
        guard sum > 0 else { return [] }
        let blurred = (0..<Self.sectors).map { sector in
            (gathered[Self.wrap(sector - 2)] + gathered[Self.wrap(sector + 2)])
                + 2 * (gathered[Self.wrap(sector - 1)] + gathered[Self.wrap(sector + 1)])
                + 3 * gathered[sector]
        }
        let strongest = blurred.max() ?? 0
        let candidates = (0..<Self.sectors).filter { sector in
            let value = blurred[sector]
            return value >= Self.keep * Self.relativePeak * strongest
                && value > blurred[Self.wrap(sector - 1)] && value >= blurred[Self.wrap(sector + 1)]
        }.sorted { blurred[$0] > blurred[$1] }
        var accepted: [(sector: Int, azimuth: Float, share: Float)] = []
        for sector in candidates where accepted.count < Self.most {
            guard accepted.allSatisfy({ Self.distance($0.sector, sector) >= Self.separation }) else { continue }
            let share = (-Self.reach...Self.reach).reduce(Float(0)) { $0 + gathered[Self.wrap(sector + $1)] } / sum
            let isHeld = held.contains { Self.distance($0, sector) < Self.separation }
            let scale = isHeld ? Self.keep : 1
            guard blurred[sector] >= scale * Self.relativePeak * strongest, share >= scale * Self.leastShare else { continue }
            let before = blurred[Self.wrap(sector - 1)], after = blurred[Self.wrap(sector + 1)]
            let curvature = before - 2 * blurred[sector] + after
            let offset = curvature < 0 ? 0.5 * (before - after) / curvature : 0
            accepted.append((sector, (Float(sector) + 0.5 + offset) * Self.sectorWidth - 180, min(share, 1)))
        }
        return accepted
    }

    /// Moves one speaker's frame on by the block and fills its spectrum and power per bin, Hann-windowed.
    private func transform(_ speaker: Int, _ planes: UnsafePointer<Float>) {
        let block = Self.block, n = Self.frameSize, bins = Self.frameBins
        let history = history + speaker * n
        let re = re + speaker * bins, im = im + speaker * bins
        history.update(from: history + block, count: n - block)
        (history + n - block).update(from: planes + speaker * block, count: block)
        vDSP_vmul(history, 1, window, 1, frame, 1, vDSP_Length(n))
        fft.forward(frame, re: re, im: im)
        var split = DSPSplitComplex(realp: re, imagp: im)
        vDSP_zvmags(&split, 1, power + speaker * bins, 1, vDSP_Length(bins))
    }

    /// The sector holding a direction in degrees clockwise from straight ahead, -180 to 180.
    private static func sector(_ azimuth: Float) -> Int {
        wrap(Int(((azimuth + 180) / sectorWidth).rounded(.down)))
    }

    private static func wrap(_ sector: Int) -> Int {
        (sector % sectors + sectors) % sectors
    }

    private static func distance(_ a: Int, _ b: Int) -> Int {
        let difference = abs(a - b) % sectors
        return min(difference, sectors - difference)
    }

    private static func bins(_ low: Float, _ high: Float) -> ClosedRange<Int> {
        Int(low / binWidth)...Int(high / binWidth)
    }
}
