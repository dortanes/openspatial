import Accelerate
import AVFoundation
import os
import Synchronization

/// Binaural responses of one source over a set of positions, laid out as [position][ear][tap].
struct ResponseTable {
    let positions: Int
    let length: Int
    let samples: [Float]

    init(contentsOf url: URL, positions: Int, length: Int) throws {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard samples.count == positions * 2 * length else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.positions = positions
        self.length = length
    }
}

/// A control room measured with a dummy head.
struct MeasuredRoomData {
    /// One loudspeaker re-aimed around the head; positions are source azimuths in degrees, clockwise from ahead.
    let ring: ResponseTable

    static func load(from directory: URL) throws -> MeasuredRoomData {
        struct Header: Decodable {
            let length: Int
            let ringSize: Int
        }
        let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: directory.appending(path: "cr1.json")))
        return MeasuredRoomData(
            ring: try ResponseTable(contentsOf: directory.appending(path: "cr1_ring.f32"), positions: header.ringSize, length: header.length)
        )
    }
}

/// Real FFT of 2 × blockSize samples in vDSP's packed layout: re[0] holds DC, im[0] holds Nyquist.
final class PackedFFT {
    static let bins = BinauralConvolver.blockSize
    /// vDSP's real forward DFT scales by 2 and the inverse by the FFT length,
    /// so forward, multiply and inverse scale the result by 4 × FFT length.
    static let roundTripScale = 1 / Float(8 * BinauralConvolver.blockSize)
    /// Forward then inverse alone scales the result by 2 × FFT length.
    static let transformScale = 1 / Float(4 * BinauralConvolver.blockSize)

    private let bins: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let splitRe, splitIm: UnsafeMutablePointer<Float>

    /// A transform of 2 × `bins` samples; the scale factors above hold for the default size only.
    init(bins: Int = PackedFFT.bins) {
        self.bins = bins
        forwardSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(2 * bins), .FORWARD)!
        inverseSetup = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(2 * bins), .INVERSE)!
        splitRe = .allocate(capacity: bins)
        splitIm = .allocate(capacity: bins)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
        splitRe.deallocate()
        splitIm.deallocate()
    }

    func forward(_ samples: UnsafeMutablePointer<Float>, re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>) {
        var split = DSPSplitComplex(realp: splitRe, imagp: splitIm)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: bins) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins)) }
        vDSP_DFT_Execute(forwardSetup, splitRe, splitIm, re, im)
    }

    func inverse(re: UnsafeMutablePointer<Float>, im: UnsafeMutablePointer<Float>, into samples: UnsafeMutablePointer<Float>) {
        vDSP_DFT_Execute(inverseSetup, re, im, splitRe, splitIm)
        var split = DSPSplitComplex(realp: splitRe, imagp: splitIm)
        samples.withMemoryRebound(to: DSPComplex.self, capacity: bins) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(bins)) }
    }
}

/// Frequency-domain partitions of a response table, shared by every source that uses the table.
final class FilterBank {
    let positions: Int
    let partitions: Int
    /// [position][ear][partition][bin].
    let re, im: UnsafeMutablePointer<Float>

    init(table: ResponseTable) {
        let block = BinauralConvolver.blockSize
        let bins = PackedFFT.bins
        positions = table.positions
        partitions = (table.length + block - 1) / block
        let count = table.positions * 2 * partitions * bins
        re = .allocate(capacity: count)
        im = .allocate(capacity: count)
        let fft = PackedFFT()
        let frame = UnsafeMutablePointer<Float>.allocate(capacity: 2 * block)
        defer { frame.deallocate() }
        table.samples.withUnsafeBufferPointer { samples in
            for response in 0..<(table.positions * 2) {
                for p in 0..<partitions {
                    frame.initialize(repeating: 0, count: 2 * block)
                    let start = p * block
                    frame.update(from: samples.baseAddress! + response * table.length + start, count: min(block, table.length - start))
                    let offset = (response * partitions + p) * bins
                    fft.forward(frame, re: re + offset, im: im + offset)
                }
            }
        }
    }

    deinit {
        re.deallocate()
        im.deallocate()
    }
}

/// Uniformly partitioned overlap-save convolution of several mono sources into two ears.
/// Each source reads one filter bank; moving a source crossfades to its new responses over one block.
final class BinauralConvolver {
    static let blockSize = 512
    /// Partitions treated as direct sound and early reflections: the first 10.7 ms at 48 kHz.
    /// In the measured room the first discrete echo arrives at 13 ms, after this boundary.
    static let earlyPartitions = 1

    private let block = BinauralConvolver.blockSize
    private let bins = PackedFFT.bins
    private let sources: Int
    private let partitions: Int
    private let fft = PackedFFT()
    private let filters: [FilterBank]
    /// Per source: input spectra ring of [slot][bin].
    private let inputRe, inputIm: [UnsafeMutablePointer<Float>]
    /// Per source: the previous and current input block.
    private let history: [UnsafeMutablePointer<Float>]
    private let accRe, accIm: UnsafeMutablePointer<Float>
    private let lateRe, lateIm: UnsafeMutablePointer<Float>
    private let time: UnsafeMutablePointer<Float>
    private let fadeLeft, fadeRight: UnsafeMutablePointer<Float>
    private let ramp: UnsafeMutablePointer<Float>
    private let current: UnsafeMutablePointer<Int>
    private let next: UnsafeMutablePointer<Int>
    private let targets: OSAllocatedUnfairLock<[Int]>
    /// Gain on everything after the early partitions, stored as the bit pattern of a Float.
    private let lateGain = Atomic<UInt32>(Float(1).bitPattern)
    private var slot = 0

    /// One source per entry of `filters`; sources may share a bank.
    init(filters: [FilterBank]) {
        let block = BinauralConvolver.blockSize
        let partitionCount = filters[0].partitions
        precondition(filters.allSatisfy { $0.partitions == partitionCount })
        self.filters = filters
        sources = filters.count
        partitions = partitionCount
        inputRe = filters.map { _ in Self.zeroed(partitionCount * block) }
        inputIm = filters.map { _ in Self.zeroed(partitionCount * block) }
        history = filters.map { _ in Self.zeroed(2 * block) }
        accRe = Self.zeroed(block)
        accIm = Self.zeroed(block)
        lateRe = Self.zeroed(block)
        lateIm = Self.zeroed(block)
        time = Self.zeroed(2 * block)
        fadeLeft = Self.zeroed(block)
        fadeRight = Self.zeroed(block)
        ramp = Self.zeroed(block)
        for i in 0..<block {
            ramp[i] = Float(i + 1) / Float(block)
        }
        current = .allocate(capacity: filters.count)
        current.initialize(repeating: 0, count: filters.count)
        next = .allocate(capacity: filters.count)
        next.initialize(repeating: 0, count: filters.count)
        targets = OSAllocatedUnfairLock(initialState: [Int](repeating: 0, count: filters.count))
    }

    deinit {
        for pointer in inputRe + inputIm + history + [accRe, accIm, lateRe, lateIm, time, fadeLeft, fadeRight, ramp] {
            pointer.deallocate()
        }
        current.deallocate()
        next.deallocate()
    }

    /// Moves a source to a position in its filter bank. Safe from any thread.
    func setPosition(_ position: Int, source: Int) {
        targets.withLock { $0[source] = position }
    }

    /// Scales the room's late reverberation; 1 keeps the measured room. Safe from any thread.
    func setLateGain(_ gain: Float) {
        lateGain.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Convolves one block. `inputs` holds `blockSize` samples per source, source after source. Render thread only.
    func process(inputs: UnsafePointer<Float>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) {
        for source in 0..<sources {
            push(inputs + source * block, source: source)
        }
        render(positions: current, outLeft: outLeft, outRight: outRight)
        let moved = targets.withLockIfAvailable { targets -> Bool in
            var moved = false
            for source in 0..<sources {
                next[source] = targets[source]
                moved = moved || next[source] != current[source]
            }
            return moved
        } ?? false
        if moved {
            render(positions: next, outLeft: fadeLeft, outRight: fadeRight)
            for i in 0..<block {
                outLeft[i] += (fadeLeft[i] - outLeft[i]) * ramp[i]
                outRight[i] += (fadeRight[i] - outRight[i]) * ramp[i]
            }
            current.update(from: next, count: sources)
        }
        slot = (slot + 1) % partitions
    }

    private static func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: count)
        pointer.initialize(repeating: 0, count: count)
        return pointer
    }

    private func push(_ input: UnsafePointer<Float>, source: Int) {
        let frame = history[source]
        frame.update(from: frame + block, count: block)
        (frame + block).update(from: input, count: block)
        let offset = slot * bins
        fft.forward(frame, re: inputRe[source] + offset, im: inputIm[source] + offset)
    }

    private func render(positions: UnsafePointer<Int>, outLeft: UnsafeMutablePointer<Float>, outRight: UnsafeMutablePointer<Float>) {
        render(positions: positions, ear: 0, into: outLeft)
        render(positions: positions, ear: 1, into: outRight)
    }

    private func render(positions: UnsafePointer<Int>, ear: Int, into out: UnsafeMutablePointer<Float>) {
        accRe.update(repeating: 0, count: bins)
        accIm.update(repeating: 0, count: bins)
        lateRe.update(repeating: 0, count: bins)
        lateIm.update(repeating: 0, count: bins)
        var gain = Float(bitPattern: lateGain.load(ordering: .relaxed))
        let used = gain == 0 ? min(partitions, Self.earlyPartitions) : partitions
        for source in 0..<sources {
            let bank = filters[source]
            for p in 0..<used {
                let x = ((slot - p + partitions) % partitions) * bins
                let h = ((positions[source] * 2 + ear) * partitions + p) * bins
                let early = p < Self.earlyPartitions
                accumulate(inputRe[source] + x, inputIm[source] + x, bank.re + h, bank.im + h, into: early ? accRe : lateRe, early ? accIm : lateIm)
            }
        }
        // Scaling the packed spectrum by a real gain also scales its DC and Nyquist values correctly.
        vDSP_vsma(lateRe, 1, &gain, accRe, 1, accRe, 1, vDSP_Length(bins))
        vDSP_vsma(lateIm, 1, &gain, accIm, 1, accIm, 1, vDSP_Length(bins))
        fft.inverse(re: accRe, im: accIm, into: time)
        var factor = PackedFFT.roundTripScale
        vDSP_vsmul(time + block, 1, &factor, out, 1, vDSP_Length(block))
    }

    private func accumulate(
        _ xRe: UnsafeMutablePointer<Float>,
        _ xIm: UnsafeMutablePointer<Float>,
        _ hRe: UnsafeMutablePointer<Float>,
        _ hIm: UnsafeMutablePointer<Float>,
        into sumRe: UnsafeMutablePointer<Float>,
        _ sumIm: UnsafeMutablePointer<Float>
    ) {
        // Bin 0 packs two real values, so it multiplies component-wise.
        let dc = sumRe[0] + xRe[0] * hRe[0]
        let nyquist = sumIm[0] + xIm[0] * hIm[0]
        var x = DSPSplitComplex(realp: xRe, imagp: xIm)
        var h = DSPSplitComplex(realp: hRe, imagp: hIm)
        var sum = DSPSplitComplex(realp: sumRe, imagp: sumIm)
        vDSP_zvma(&x, 1, &h, 1, &sum, 1, &sum, 1, vDSP_Length(bins))
        sumRe[0] = dc
        sumIm[0] = nyquist
    }
}

/// Supplies the input of a binaural player on the audio render thread.
protocol BlockSource: AnyObject {
    /// Writes `frames` samples for each of `sources` channels, channel after channel. Returns false for silence.
    func fill(_ inputs: UnsafeMutablePointer<Float>, sources: Int, frames: Int) -> Bool
}

/// Renders a block source through a binaural convolver on the audio render thread, one channel per source.
final class BinauralPlayer {
    private(set) var node: AVAudioSourceNode!
    private let convolver: BinauralConvolver
    private let source: BlockSource
    private let sources: Int
    private let active = Atomic<Bool>(false)
    private let block = BinauralConvolver.blockSize
    private let inputs, outLeft, outRight: UnsafeMutablePointer<Float>
    private var readIndex = BinauralConvolver.blockSize
    /// Linear gain per source, for up to eight sources.
    private let gains = OSAllocatedUnfairLock(initialState: SIMD8<Float>(repeating: 1))
    /// Render thread only: the gains in use, kept when the lock is busy.
    private var appliedGains = SIMD8<Float>(repeating: 1)
    /// When set, sources fold down to plain stereo instead of the binaural rendering.
    private let bypass = Atomic<Bool>(false)
    private let downmixLeft, downmixRight: [Float]

    /// One source channel per entry of `filters`, each folding into stereo with its `downmix` gains when bypassed.
    init(filters: [FilterBank], source: BlockSource, downmix: [(left: Float, right: Float)]) {
        precondition(downmix.count == filters.count)
        convolver = BinauralConvolver(filters: filters)
        self.source = source
        sources = filters.count
        downmixLeft = downmix.map(\.left)
        downmixRight = downmix.map(\.right)
        inputs = .allocate(capacity: filters.count * block)
        outLeft = .allocate(capacity: block)
        outRight = .allocate(capacity: block)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        node = AVAudioSourceNode(format: format) { [unowned self] _, _, frameCount, bufferList in
            render(frames: Int(frameCount), into: bufferList)
            return noErr
        }
    }

    deinit {
        for pointer in [inputs, outLeft, outRight] {
            pointer.deallocate()
        }
    }

    func setActive(_ on: Bool) {
        active.store(on, ordering: .relaxed)
    }

    /// Plays plain stereo instead of the binaural rendering; the convolver keeps running so switching back is seamless.
    func setBypass(_ on: Bool) {
        bypass.store(on, ordering: .relaxed)
    }

    func setPosition(_ position: Int, source: Int) {
        convolver.setPosition(position, source: source)
    }

    func setLateGain(_ gain: Float) {
        convolver.setLateGain(gain)
    }

    /// Sets a linear gain for each source in order; sources beyond the list keep unity gain.
    func setGains(_ values: [Float]) {
        var next = SIMD8<Float>(repeating: 1)
        for (source, gain) in values.prefix(next.scalarCount).enumerated() {
            next[source] = gain
        }
        gains.withLock { [next] in $0 = next }
    }

    private func render(frames: Int, into bufferList: UnsafeMutablePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        guard active.load(ordering: .relaxed) else {
            left.update(repeating: 0, count: frames)
            right.update(repeating: 0, count: frames)
            return
        }
        var written = 0
        while written < frames {
            if readIndex == block {
                nextBlock()
                readIndex = 0
            }
            let count = min(block - readIndex, frames - written)
            (left + written).update(from: outLeft + readIndex, count: count)
            (right + written).update(from: outRight + readIndex, count: count)
            written += count
            readIndex += count
        }
    }

    private func nextBlock() {
        if !source.fill(inputs, sources: sources, frames: block) {
            inputs.update(repeating: 0, count: sources * block)
        }
        if let current = gains.withLockIfAvailable({ $0 }) {
            appliedGains = current
        }
        for source in 0..<min(sources, appliedGains.scalarCount) where appliedGains[source] != 1 {
            var gain = appliedGains[source]
            vDSP_vsmul(inputs + source * block, 1, &gain, inputs + source * block, 1, vDSP_Length(block))
        }
        convolver.process(inputs: inputs, outLeft: outLeft, outRight: outRight)
        guard bypass.load(ordering: .relaxed) else { return }
        outLeft.update(repeating: 0, count: block)
        outRight.update(repeating: 0, count: block)
        for source in 0..<sources {
            var left = downmixLeft[source], right = downmixRight[source]
            vDSP_vsma(inputs + source * block, 1, &left, outLeft, 1, outLeft, 1, vDSP_Length(block))
            vDSP_vsma(inputs + source * block, 1, &right, outRight, 1, outRight, 1, vDSP_Length(block))
        }
    }
}
