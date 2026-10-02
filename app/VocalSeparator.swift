import Accelerate
import AVFoundation
import CoreML
import CryptoKit
import os
import Synchronization

/// A failure to download, check or run the separation model.
struct ModelError: Error {
    let message: String
}

/// The vocals specialist of HT-Demucs FT, rewritten to run entirely on the Neural Engine (separation/export.py).
/// It separates one window of 7.8 s of 44.1 kHz stereo; the STFT and the input statistics stay here, in full precision.
final class VocalModel {
    static let sampleRate = 44100.0
    /// Samples per window, the segment length the model was trained on.
    static let length = 343_980

    private static let fftSize = 4096
    private static let hop = 1024
    private static let bins = 2048
    private static let frames = 336
    /// Samples the Demucs STFT reflects in front of the signal before its first frame.
    private static let pad = 1536
    /// The model's waveform input folds the window into 8 rows of 43,008 samples.
    private static let foldedLength = 8 * 43008
    /// Hann windows at a quarter-window hop add up to 1.5 when squared.
    private static let envelope: Float = 1.5

    private let model: MLModel
    private let fft = PackedFFT(bins: VocalModel.fftSize / 2)
    private let window: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private let re, im: UnsafeMutablePointer<Float>
    /// Work planes in single precision; the model reads and writes half precision.
    private let spectrum: UnsafeMutablePointer<Float>
    private let wave: UnsafeMutablePointer<Float>
    private let spectrumHalf, waveHalf: UnsafeMutablePointer<Float16>
    private let spectrumInput, waveInput: MLMultiArray

    init(contentsOf url: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: configuration)
        window = .allocate(capacity: Self.fftSize)
        for n in 0..<Self.fftSize {
            window[n] = 0.5 - 0.5 * cos(2 * .pi * Float(n) / Float(Self.fftSize))
        }
        frame = .allocate(capacity: Self.fftSize)
        re = .allocate(capacity: Self.bins)
        im = .allocate(capacity: Self.bins)
        let spectrumCount = 4 * Self.bins * Self.frames
        spectrum = .allocate(capacity: spectrumCount)
        wave = .allocate(capacity: 2 * Self.foldedLength)
        wave.initialize(repeating: 0, count: 2 * Self.foldedLength)
        spectrumHalf = .allocate(capacity: spectrumCount)
        waveHalf = .allocate(capacity: 2 * Self.foldedLength)
        spectrumInput = try MLMultiArray(
            dataPointer: spectrumHalf, shape: [1, 4, NSNumber(value: Self.bins), NSNumber(value: Self.frames)], dataType: .float16,
            strides: [NSNumber(value: spectrumCount), NSNumber(value: Self.bins * Self.frames), NSNumber(value: Self.frames), 1]
        )
        waveInput = try MLMultiArray(
            dataPointer: waveHalf, shape: [1, 2, 8, 43008], dataType: .float16,
            strides: [NSNumber(value: 2 * Self.foldedLength), NSNumber(value: Self.foldedLength), 43008, 1]
        )
    }

    deinit {
        for pointer in [window, frame, re, im, spectrum, wave] {
            pointer.deallocate()
        }
        spectrumHalf.deallocate()
        waveHalf.deallocate()
    }

    /// Separates the vocals of `range` within a window: `window` holds `length` samples per channel, left then right;
    /// `vocals` receives `range.count` samples per channel, left then right.
    func separate(_ window: UnsafePointer<Float>, range: Range<Int>, into vocals: UnsafeMutablePointer<Float>) throws {
        for channel in 0..<2 {
            analyze(window + channel * Self.length, into: spectrum + 2 * channel * Self.bins * Self.frames)
        }
        let spectrumCount = 4 * Self.bins * Self.frames
        let (mean, std) = Self.statistics(spectrum, count: spectrumCount)
        Self.normalize(spectrum, count: spectrumCount, mean: mean, std: std)
        for channel in 0..<2 {
            (wave + channel * Self.foldedLength).update(from: window + channel * Self.length, count: Self.length)
        }
        let (waveMean, waveStd) = Self.statistics(window, count: 2 * Self.length)
        for channel in 0..<2 {
            Self.normalize(wave + channel * Self.foldedLength, count: Self.length, mean: waveMean, std: waveStd)
        }
        Self.convert(spectrum, to: spectrumHalf, count: spectrumCount)
        Self.convert(wave, to: waveHalf, count: 2 * Self.foldedLength)

        let input = try MLDictionaryFeatureProvider(dictionary: ["spectrum": spectrumInput, "mix": waveInput])
        let output = try model.prediction(from: input)
        guard let vocalsSpectrum = output.featureValue(for: "vocals_spectrum")?.multiArrayValue,
              let vocalsWave = output.featureValue(for: "vocals_wave")?.multiArrayValue,
              vocalsSpectrum.dataType == .float16, vocalsWave.dataType == .float16
        else { throw ModelError(message: "The separation model returned unexpected outputs.") }

        // Outputs may pad their rows, so they are read through their strides into the work planes.
        let spectrumStrides = vocalsSpectrum.strides.map(\.intValue)
        vocalsSpectrum.withUnsafeBufferPointer(ofType: Float16.self) { source in
            for plane in 0..<4 {
                for bin in 0..<Self.bins {
                    Self.convert(
                        source.baseAddress! + plane * spectrumStrides[1] + bin * spectrumStrides[2],
                        to: spectrum + (plane * Self.bins + bin) * Self.frames, count: Self.frames
                    )
                }
            }
        }
        let waveStrides = vocalsWave.strides.map(\.intValue)
        vocalsWave.withUnsafeBufferPointer(ofType: Float16.self) { source in
            for channel in 0..<2 {
                var index = range.lowerBound
                while index < range.upperBound {
                    let row = index / 43008, column = index % 43008
                    let count = min(43008 - column, range.upperBound - index)
                    Self.convert(
                        source.baseAddress! + channel * waveStrides[1] + row * waveStrides[2] + column,
                        to: wave + channel * Self.foldedLength + index, count: count
                    )
                    index += count
                }
            }
        }
        for channel in 0..<2 {
            let out = vocals + channel * range.count
            synthesize(spectrum + 2 * channel * Self.bins * Self.frames, mean: mean, std: std, range: range, into: out)
            // vocals = inverse STFT + wave * std + mean
            var scale = waveStd, offset = waveMean
            vDSP_vsma(wave + channel * Self.foldedLength + range.lowerBound, 1, &scale, out, 1, out, 1, vDSP_Length(range.count))
            vDSP_vsadd(out, 1, &offset, out, 1, vDSP_Length(range.count))
        }
    }

    private static func convert(_ source: UnsafePointer<Float>, to destination: UnsafeMutablePointer<Float16>, count: Int) {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        var to = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        vImageConvert_PlanarFtoPlanar16F(&from, &to, 0)
    }

    private static func convert(_ source: UnsafePointer<Float16>, to destination: UnsafeMutablePointer<Float>, count: Int) {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        var to = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
        vImageConvert_Planar16FtoPlanarF(&from, &to, 0)
    }

    /// The window's sample at `index`, mirrored at both ends without repeating the edge sample.
    private static func reflect(_ index: Int) -> Int {
        if index < 0 { return -index }
        if index >= length { return 2 * (length - 1) - index }
        return index
    }

    /// Fills real and imaginary planes [2][bin][frame] with the Demucs STFT of one channel.
    private func analyze(_ signal: UnsafePointer<Float>, into planes: UnsafeMutablePointer<Float>) {
        // vDSP's forward real DFT doubles the result; the STFT is normalised by 1/√4096.
        var scale: Float = 0.5 / 64
        let realPlane = planes, imaginaryPlane = planes + Self.bins * Self.frames
        for t in 0..<Self.frames {
            let start = t * Self.hop - Self.pad
            if start >= 0 && start + Self.fftSize <= Self.length {
                vDSP_vmul(signal + start, 1, window, 1, frame, 1, vDSP_Length(Self.fftSize))
            } else {
                for n in 0..<Self.fftSize {
                    frame[n] = window[n] * signal[Self.reflect(start + n)]
                }
            }
            fft.forward(frame, re: re, im: im)
            im[0] = 0  // im[0] holds the Nyquist bin, which Demucs drops; the DC bin has no imaginary part.
            vDSP_vsmul(re, 1, &scale, realPlane + t, Self.frames, vDSP_Length(Self.bins))
            vDSP_vsmul(im, 1, &scale, imaginaryPlane + t, Self.frames, vDSP_Length(Self.bins))
        }
    }

    /// Overlap-adds the inverse STFT of normalised planes over `range` into `out`.
    private func synthesize(_ planes: UnsafePointer<Float>, mean: Float, std: Float, range: Range<Int>, into out: UnsafeMutablePointer<Float>) {
        out.update(repeating: 0, count: range.count)
        let realPlane = planes, imaginaryPlane = planes + Self.bins * Self.frames
        let first = max(0, (range.lowerBound + Self.pad - Self.fftSize) / Self.hop)
        let last = min(Self.frames - 1, (range.upperBound - 1 + Self.pad) / Self.hop)
        var scale = std, offset = mean
        // vDSP's inverse real DFT returns the plain sum over bins; the inverse STFT scales it by 1/√4096
        // and divides by the overlap of the squared windows.
        var gain = 1 / (64 * Self.envelope)
        for t in first...last {
            vDSP_vsmsa(realPlane + t, Self.frames, &scale, &offset, re, 1, vDSP_Length(Self.bins))
            vDSP_vsmsa(imaginaryPlane + t, Self.frames, &scale, &offset, im, 1, vDSP_Length(Self.bins))
            im[0] = 0  // no Nyquist bin
            fft.inverse(re: re, im: im, into: frame)
            vDSP_vmul(frame, 1, window, 1, frame, 1, vDSP_Length(Self.fftSize))
            let start = t * Self.hop - Self.pad
            let from = max(start, range.lowerBound), to = min(start + Self.fftSize, range.upperBound)
            guard from < to else { continue }
            vDSP_vsma(frame + (from - start), 1, &gain, out + (from - range.lowerBound), 1, out + (from - range.lowerBound), 1, vDSP_Length(to - from))
        }
    }

    /// Mean and unbiased standard deviation, as PyTorch computes them.
    private static func statistics(_ values: UnsafePointer<Float>, count: Int) -> (mean: Float, std: Float) {
        var mean: Float = 0, meanSquare: Float = 0
        vDSP_meanv(values, 1, &mean, vDSP_Length(count))
        vDSP_measqv(values, 1, &meanSquare, vDSP_Length(count))
        let variance = max(0, Double(meanSquare) - Double(mean) * Double(mean)) * Double(count) / Double(count - 1)
        return (mean, Float(variance.squareRoot()))
    }

    private static func normalize(_ values: UnsafeMutablePointer<Float>, count: Int, mean: Float, std: Float) {
        var scale = 1 / (std + 1e-5), offset = -mean / (std + 1e-5)
        vDSP_vsmsa(values, 1, &scale, &offset, values, 1, vDSP_Length(count))
    }
}

extension VocalModel {
    /// The compiled model once downloaded; it is too large to ship inside the app.
    static var location: URL {
        URL.applicationSupportDirectory
            .appending(path: Bundle.main.bundleIdentifier ?? "OpenSpatial")
            .appending(path: "HTDemucsVocals.mlmodelc")
    }

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: location.path)
    }

    /// The published archive of separation/export.py output, pinned by its SHA-256.
    private static let digest = "0fd5e706e34033e43f2d13534978a9747da728204be28fe8a53ae82c8c6d355c"

    /// Downloads the model package, checks it against its pinned digest, compiles it for this Mac
    /// and moves the result to `location`. Reports download progress from 0 to 1 at most once per percent.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appending(path: "HTDemucsVocals.mlpackage.zip")
        let running = OSAllocatedUnfairLock<URLSessionDownloadTask?>(initialState: nil)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var observation: NSKeyValueObservation?
                let task = URLSession.shared.downloadTask(with: AppLinks.separationModel) { url, response, error in
                    observation?.invalidate()
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard error == nil, let url, status == 200 else {
                        continuation.resume(throwing: error ?? ModelError(message: HTTPURLResponse.localizedString(forStatusCode: status)))
                        return
                    }
                    // The system deletes the downloaded file once this handler returns.
                    do {
                        try FileManager.default.moveItem(at: url, to: archive)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                let percent = OSAllocatedUnfairLock(initialState: -1)
                observation = task.progress.observe(\.fractionCompleted) { reported, _ in
                    let now = Int(reported.fractionCompleted * 100)
                    if percent.withLock({ last in defer { last = now }; return last != now }) {
                        progress(Double(now) / 100)
                    }
                }
                running.withLock { $0 = task }
                task.resume()
            }
        } onCancel: {
            running.withLock { $0?.cancel() }
        }
        guard try sha256(of: archive) == digest else {
            throw ModelError(message: String(localized: "error.separation.damaged"))
        }
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, folder.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw ModelError(message: String(localized: "error.separation.damaged"))
        }
        let compiled = try await MLModel.compileModel(at: folder.appending(path: "HTDemucsVocals.mlpackage"))
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: location)
        try FileManager.default.moveItem(at: compiled, to: location)
    }

    private static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty {
            hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Separates 48 kHz stereo into vocals and everything else. The model runs once a second on its own queue over
/// the latest 7.8 s, and each run keeps the second that ends half a second before the window's end, where the model
/// still hears what follows. The result plays about two seconds after the input.
final class VocalSeparator {
    /// Planes of `stems`: vocals left and right, then everything else left and right.
    static let planes = 4
    static let vocals = 0, rest = 2

    /// The latest block of each plane, valid until the next `process`.
    let stems: UnsafeMutablePointer<Float>

    /// New samples per model run: 1 s at 44.1 kHz.
    private static let hop = 44_100
    /// Samples between the kept output and the window's end: 0.5 s at 44.1 kHz.
    private static let lookahead = 22_050
    /// Samples of overlap crossfaded between consecutive runs: 46 ms at 44.1 kHz.
    private static let crossfade = 2_048
    /// Blocks played after the first result arrives before output starts, about 0.25 s, so a run
    /// that finishes a little late never leaves a gap.
    private static let margin = 24
    private static let length = VocalModel.length
    private static let region = (length - lookahead - hop - crossfade)..<(length - lookahead)

    private let block = BinauralConvolver.blockSize
    private let model: VocalModel
    private let queue = DispatchQueue(label: "vocal separation", qos: .userInitiated)
    private let downsampler, upsampler: AVAudioConverter
    private let blockIn, modelIn, finishedIn, blockOut: AVAudioPCMBuffer

    /// Worker only: input waiting to enter the window, the window, and separated output waiting to play.
    private let pending: PlanarQueue
    private let incoming: UnsafeMutablePointer<Float>
    private let history: UnsafeMutablePointer<Float>
    private let separated: PlanarQueue
    private var flowing = false
    private var waited = 0

    /// Shared: whether a run is in flight; the window copy belongs to the queue while it is.
    private let running = Atomic<Bool>(false)
    private let snapshot: UnsafeMutablePointer<Float>
    /// Shared: runs started before the latest reset drop their result.
    private let generation = Atomic<Int>(0)
    /// Shared: separated 44.1 kHz planes from the queue, waiting for the worker.
    private let finished = OSAllocatedUnfairLock<PlanarQueue>(uncheckedState: PlanarQueue(channels: VocalSeparator.planes, capacity: 4 * VocalSeparator.hop))

    /// Queue only: the vocals of the kept region, the region's planes, the overlap carried to the next run,
    /// and the gate's state, all reset with the generation.
    private let regionVocals: UnsafeMutablePointer<Float>
    private let current: UnsafeMutablePointer<Float>
    private let tail: UnsafeMutablePointer<Float>
    private var gate = VocalGate()
    private var stateGeneration = 0

    init(model url: URL) throws {
        model = try VocalModel(contentsOf: url)
        let rate = Double(48000)
        // Formats with more than two channels need a layout; the planes are plain discrete channels.
        guard let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | AudioChannelLayoutTag(Self.planes)),
              let input = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2),
              let modelInput = AVAudioFormat(standardFormatWithSampleRate: VocalModel.sampleRate, channels: 2)
        else { throw ModelError(message: "Audio formats for separation are unavailable.") }
        let modelOutput = AVAudioFormat(standardFormatWithSampleRate: VocalModel.sampleRate, channelLayout: layout)
        let output = AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
        guard let downsampler = AVAudioConverter(from: input, to: modelInput),
              let upsampler = AVAudioConverter(from: modelOutput, to: output),
              let blockIn = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(block)),
              let modelIn = AVAudioPCMBuffer(pcmFormat: modelInput, frameCapacity: AVAudioFrameCount(2 * block)),
              let finishedIn = AVAudioPCMBuffer(pcmFormat: modelOutput, frameCapacity: AVAudioFrameCount(4 * Self.hop)),
              let blockOut = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(5 * Self.hop))
        else { throw ModelError(message: "Audio formats for separation are unavailable.") }
        self.downsampler = downsampler
        self.upsampler = upsampler
        self.blockIn = blockIn
        self.modelIn = modelIn
        self.finishedIn = finishedIn
        self.blockOut = blockOut
        pending = PlanarQueue(channels: 2, capacity: 4 * Self.hop)
        separated = PlanarQueue(channels: Self.planes, capacity: 10 * 48000)
        stems = PairSplitter.zeroed(Self.planes * block)
        incoming = PairSplitter.zeroed(2 * Self.hop)
        history = PairSplitter.zeroed(2 * Self.length)
        snapshot = PairSplitter.zeroed(2 * Self.length)
        regionVocals = PairSplitter.zeroed(2 * Self.region.count)
        current = PairSplitter.zeroed(Self.planes * Self.region.count)
        tail = PairSplitter.zeroed(Self.planes * Self.crossfade)
    }

    deinit {
        // A run in flight holds the window copy and the queue-only buffers.
        queue.sync {}
        for pointer in [stems, incoming, history, snapshot, regionVocals, current, tail] {
            pointer.deallocate()
        }
    }

    /// Takes one block of the pair and fills `stems` with a block separated about two seconds earlier.
    /// Returns false, leaving `stems` unchanged, until separated output is ready to play.
    func process(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>) -> Bool {
        let channels = blockIn.floatChannelData!
        channels[0].update(from: left, count: block)
        channels[1].update(from: right, count: block)
        blockIn.frameLength = AVAudioFrameCount(block)
        Self.convert(blockIn, with: downsampler, into: modelIn)
        pending.append(modelIn)
        if pending.count >= Self.hop, !running.load(ordering: .acquiring) {
            startRun()
        }

        finished.withLock { queue in
            finishedIn.frameLength = 0
            queue.remove(min(queue.count, Int(finishedIn.frameCapacity)), into: finishedIn)
        }
        if finishedIn.frameLength > 0 {
            Self.convert(finishedIn, with: upsampler, into: blockOut)
            separated.append(blockOut)
        }

        if !flowing {
            if separated.count > 0 { waited += 1 }
            guard waited >= Self.margin else { return false }
            flowing = true
        }
        guard separated.count >= block else {
            flowing = false
            waited = 0
            return false
        }
        separated.remove(block, into: stems)
        return true
    }

    /// Forgets everything heard so far; output starts again about two seconds after the next input.
    func reset() {
        generation.add(1, ordering: .releasing)
        downsampler.reset()
        upsampler.reset()
        pending.removeAll()
        separated.removeAll()
        finished.withLock { $0.removeAll() }
        history.update(repeating: 0, count: 2 * Self.length)
        flowing = false
        waited = 0
    }

    private func startRun() {
        pending.remove(Self.hop, into: incoming)
        for channel in 0..<2 {
            let plane = history + channel * Self.length
            plane.update(from: plane + Self.hop, count: Self.length - Self.hop)
            (plane + Self.length - Self.hop).update(from: incoming + channel * Self.hop, count: Self.hop)
        }
        snapshot.update(from: history, count: 2 * Self.length)
        running.store(true, ordering: .releasing)
        let started = generation.load(ordering: .acquiring)
        queue.async { [self] in
            run(started)
            running.store(false, ordering: .releasing)
        }
    }

    /// Separates the kept region of the window copy and queues it, crossfaded into the previous run.
    private func run(_ started: Int) {
        let count = Self.region.count
        if started != stateGeneration {
            tail.update(repeating: 0, count: Self.planes * Self.crossfade)
            gate = VocalGate()
            stateGeneration = started
        }
        var peak: Float = 0
        vDSP_maxmgv(snapshot, 1, &peak, vDSP_Length(2 * Self.length))
        if peak < 1e-6 || (try? model.separate(snapshot, range: Self.region, into: regionVocals)) == nil {
            // Silence, or a failed run, passes the mix through as the rest rather than leaving a gap.
            regionVocals.update(repeating: 0, count: 2 * count)
        }
        for channel in 0..<2 {
            let vocals = regionVocals + channel * count
            let mix = snapshot + channel * Self.length + Self.region.lowerBound
            (current + (Self.vocals + channel) * count).update(from: vocals, count: count)
            vDSP_vsub(vocals, 1, mix, 1, current + (Self.rest + channel) * count, 1, vDSP_Length(count))
        }
        for plane in 0..<Self.planes {
            let samples = current + plane * count, carried = tail + plane * Self.crossfade
            for i in 0..<Self.crossfade {
                let fade = (Float(i) + 0.5) / Float(Self.crossfade)
                samples[i] = carried[i] + (samples[i] - carried[i]) * fade
            }
            carried.update(from: samples + Self.hop, count: Self.crossfade)
        }
        gate.apply(
            vocals: (current + Self.vocals * count, current + (Self.vocals + 1) * count),
            rest: (current + Self.rest * count, current + (Self.rest + 1) * count),
            frames: Self.hop
        )
        guard generation.load(ordering: .acquiring) == started else { return }
        finished.withLock { $0.append(current, stride: count, frames: Self.hop) }
    }

    private static func convert(_ source: AVAudioPCMBuffer, with converter: AVAudioConverter, into destination: AVAudioPCMBuffer) {
        var supplied = false
        var error: NSError?
        destination.frameLength = 0
        converter.convert(to: destination, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return source
        }
    }
}

/// Moves what the model calls vocals back into the rest while it is far quieter than the mix: there it is the
/// model's leakage of instruments, which crackles from the center speaker. On a mastered pop track sung passages
/// measured 2 to 8 dB below the mix and leakage about 31 dB below. Below -18 dB the gate expands 3:1, which kept
/// the leakage 11 dB lower while touching sung passages 1% of the time; harder settings cut audibly into soft vocals.
struct VocalGate {
    private static let threshold: Float = -18
    private static let ratio: Float = 3
    /// The deepest attenuation, in dB.
    private static let range: Float = -24
    /// A mix power under which everything counts as quiet: -50 dBFS, so model noise in silence stays shut.
    private static let floor: Float = 1e-5
    /// Powers follow over 30 ms; the gain opens within 5 ms and closes over 150 ms, at 44.1 kHz.
    private static let follow = 1 - exp(-1 / Float(0.030 * VocalModel.sampleRate))
    private static let open = 1 - exp(-1 / Float(0.005 * VocalModel.sampleRate))
    private static let close = 1 - exp(-1 / Float(0.150 * VocalModel.sampleRate))

    private var vocalsPower: Float = 0
    private var mixPower: Float = 0
    private var gain: Float = 1

    mutating func apply(
        vocals: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>),
        rest: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>),
        frames: Int
    ) {
        for i in 0..<frames {
            let left = vocals.0[i], right = vocals.1[i]
            let mixLeft = left + rest.0[i], mixRight = right + rest.1[i]
            vocalsPower += (left * left + right * right - vocalsPower) * Self.follow
            mixPower += (mixLeft * mixLeft + mixRight * mixRight - mixPower) * Self.follow
            let share = 10 * log10((vocalsPower + 1e-20) / (mixPower + Self.floor))
            let target = pow(10, max(Self.range, min(0, (share - Self.threshold) * (Self.ratio - 1))) / 20)
            gain += (target - gain) * (target > gain ? Self.open : Self.close)
            vocals.0[i] = left * gain
            vocals.1[i] = right * gain
            rest.0[i] += left - left * gain
            rest.1[i] += right - right * gain
        }
    }
}

/// Planar samples queued in arrival order, for one thread at a time.
private final class PlanarQueue {
    let channels: Int
    private let capacity: Int
    private let samples: UnsafeMutablePointer<Float>
    private(set) var count = 0

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        samples = PairSplitter.zeroed(channels * capacity)
    }

    deinit {
        samples.deallocate()
    }

    /// Appends `frames` frames of planes `stride` samples apart; frames beyond the capacity are dropped.
    func append(_ planes: UnsafePointer<Float>, stride: Int, frames: Int) {
        let kept = min(frames, capacity - count)
        for channel in 0..<channels {
            (samples + channel * capacity + count).update(from: planes + channel * stride, count: kept)
        }
        count += kept
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let kept = min(Int(buffer.frameLength), capacity - count)
        let source = buffer.floatChannelData!
        for channel in 0..<channels {
            (samples + channel * capacity + count).update(from: source[channel], count: kept)
        }
        count += kept
    }

    /// Moves the oldest `frames` frames into planar `out`, channel after channel.
    func remove(_ frames: Int, into out: UnsafeMutablePointer<Float>) {
        for channel in 0..<channels {
            let plane = samples + channel * capacity
            (out + channel * frames).update(from: plane, count: frames)
            plane.update(from: plane + frames, count: count - frames)
        }
        count -= frames
    }

    /// Moves the oldest `frames` frames into a buffer with the same channels.
    func remove(_ frames: Int, into buffer: AVAudioPCMBuffer) {
        let destination = buffer.floatChannelData!
        for channel in 0..<channels {
            let plane = samples + channel * capacity
            destination[channel].update(from: plane, count: frames)
            plane.update(from: plane + frames, count: count - frames)
        }
        count -= frames
        buffer.frameLength = AVAudioFrameCount(frames)
    }

    func removeAll() {
        count = 0
    }
}
