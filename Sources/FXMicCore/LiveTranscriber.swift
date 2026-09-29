import AVFoundation
import Foundation
import Speech

public struct TranscriptUpdate {
    public let locale: String
    public let text: String
    public let confidence: Double
    public let isFinal: Bool
}

public struct UtteranceResult {
    public let text: String
    public let locale: String
    public let confidence: Double
    public let alternatives: [(locale: String, text: String, confidence: Double)]
    public init(text: String, locale: String, confidence: Double, alternatives: [(locale: String, text: String, confidence: Double)]) {
        self.text = text; self.locale = locale; self.confidence = confidence; self.alternatives = alternatives
    }
}

/// On-device transcription in several locales at once. Every utterance gets fresh analyzers (models stay
/// loaded for the process lifetime), so audio from one utterance can never leak into the next, and a
/// stuck finalization only costs a timeout.
@available(macOS 26, *)
public final class LiveTranscriber {
    private final class LaneState {
        var finals: [String] = []
        var finalConfidence: [Double] = []
        var volatileText = ""
        var volatileConfidence = 0.0
        var done = false
    }

    private struct Lane {
        let locale: String
        let analyzer: SpeechAnalyzer
        let continuation: AsyncStream<AnalyzerInput>.Continuation
        let state: LaneState
        let resultsTask: Task<Void, Never>
    }

    private let localeIDs: [String]
    private let onUpdate: (TranscriptUpdate) -> Void
    private let stateQueue = DispatchQueue(label: "fxmic.transcriber.state")
    private var analyzerFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var lanes: [Lane] = []
    private var lanesCreatedAt = Date.distantPast
    /// Pre-built lanes older than this are thrown away before use: idle analyzers go stale.
    public var maxLaneAge: TimeInterval = 120
    private var creating = false
    private var pendingInputs: [AVAudioPCMBuffer] = []     // audio that arrived while the lanes were being built
    private var utteranceSerial = 0

    public init(locales: [String], onUpdate: @escaping (TranscriptUpdate) -> Void) async throws {
        self.localeIDs = locales
        self.onUpdate = onUpdate
        var probes: [SpeechTranscriber] = []
        for id in locales {
            let probe = LiveTranscriber.makeTranscriber(id)
            var status = await AssetInventory.status(forModules: [probe])
            if status != .installed {
                onUpdate(TranscriptUpdate(locale: id, text: "[asset status \(status), installing on-device model]", confidence: 0, isFinal: true))
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
                    try await request.downloadAndInstall()
                }
                status = await AssetInventory.status(forModules: [probe])
            }
            guard status == .installed else { throw TranscriberError.modelNotInstalled(id) }
            probes.append(probe)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: probes) else {
            throw TranscriberError.noAudioFormat
        }
        analyzerFormat = format
        // Warm up: build the first utterance's lanes now so the models are resident.
        await createLanes()
    }

    public var locales: [String] { localeIDs }
    public var inputFormatDescription: String {
        analyzerFormat.map { "\(Int($0.sampleRate)) Hz \($0.channelCount) ch \($0.commonFormat == .pcmFormatFloat32 ? "float32" : $0.commonFormat == .pcmFormatInt16 ? "int16" : "fmt\($0.commonFormat.rawValue)")" } ?? "?"
    }

    private static func makeTranscriber(_ id: String) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: Locale(identifier: id),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.transcriptionConfidence])
    }

    private func createLanes() async {
        guard let format = analyzerFormat else { return }
        let proceed: Bool = stateQueue.sync {
            if creating || !lanes.isEmpty { return false }
            creating = true
            return true
        }
        guard proceed else { return }
        utteranceSerial += 1
        var fresh: [Lane] = []
        for id in localeIDs {
            let transcriber = LiveTranscriber.makeTranscriber(id)
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime))
            let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
            let state = LaneState()
            do {
                try await analyzer.prepareToAnalyze(in: format)
                try await analyzer.start(inputSequence: stream)
            } catch {
                onUpdate(TranscriptUpdate(locale: id, text: "[start error: \(error)]", confidence: 0, isFinal: true))
                continue
            }
            let task = Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result, locale: id, state: state)
                    }
                } catch {
                    self?.onUpdate(TranscriptUpdate(locale: id, text: "[results error: \(error)]", confidence: 0, isFinal: true))
                }
                self?.stateQueue.sync { state.done = true }
            }
            fresh.append(Lane(locale: id, analyzer: analyzer, continuation: continuation, state: state, resultsTask: task))
        }
        let backlog: [AVAudioPCMBuffer] = stateQueue.sync {
            lanes = fresh
            lanesCreatedAt = Date()
            creating = false
            let b = pendingInputs
            pendingInputs = []
            return b
        }
        // Deliver audio that was captured while the lanes were still being built.
        for buffer in backlog { yield(buffer, to: fresh) }
    }

    private func yield(_ outBuffer: AVAudioPCMBuffer, to current: [Lane]) {
        guard let outFormat = analyzerFormat else { return }
        for (i, lane) in current.enumerated() {
            let buffer: AVAudioPCMBuffer
            if i == 0 { buffer = outBuffer } else {
                guard let copy = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outBuffer.frameLength) else { continue }
                copy.frameLength = outBuffer.frameLength
                let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: outBuffer.audioBufferList))
                let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for (s, d) in zip(src, dst) where s.mData != nil && d.mData != nil {
                    memcpy(d.mData, s.mData, Int(min(s.mDataByteSize, d.mDataByteSize)))
                }
                buffer = copy
            }
            lane.continuation.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// Call when the gate opens. Lanes are normally pre-built; if not, they are built now in the background
    /// and the audio queues up in the streams until they start.
    public func startUtterance() {
        let stale: [Lane] = stateQueue.sync {
            guard !lanes.isEmpty, Date().timeIntervalSince(lanesCreatedAt) > maxLaneAge else { return [] }
            let old = lanes
            lanes = []
            return old
        }
        if !stale.isEmpty {
            onUpdate(TranscriptUpdate(locale: "", text: "[stale recognizer sessions replaced]", confidence: 0, isFinal: true))
            for lane in stale {
                lane.continuation.finish()
                lane.resultsTask.cancel()
                let analyzer = lane.analyzer
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        let ready = stateQueue.sync { !lanes.isEmpty || creating }
        if !ready { Task { await self.createLanes() } }
    }

    /// Drops any pre-built lanes (used on hang-up); the next utterance builds fresh ones.
    public func dropLanes() {
        let old: [Lane] = stateQueue.sync { let o = lanes; lanes = []; pendingInputs = []; return o }
        for lane in old {
            lane.continuation.finish()
            lane.resultsTask.cancel()
            let analyzer = lane.analyzer
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Feed mono float samples at `sampleRate`. Safe to call from the capture queue.
    public func feed(_ samples: [Float], sampleRate: Double) {
        guard let outFormat = analyzerFormat else { return }
        let inFormat = converterInputFormat ?? AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        if converter == nil || converterInputFormat?.sampleRate != sampleRate {
            converterInputFormat = inFormat
            converter = AVAudioConverter(from: inFormat, to: outFormat)
        }
        guard let converter,
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let ratio = outFormat.sampleRate / sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up) + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return inBuffer
        }
        guard error == nil, outBuffer.frameLength > 0 else { return }
        let current: [Lane] = stateQueue.sync {
            if lanes.isEmpty {
                if pendingInputs.count < 200 { pendingInputs.append(outBuffer) }   // up to ~2 s of backlog
                return []
            }
            return lanes
        }
        if !current.isEmpty { yield(outBuffer, to: current) }
    }

    /// Ends the current utterance: closes the streams, finalizes with a timeout, picks the best locale,
    /// and pre-builds lanes for the next utterance.
    public func finishUtterance() async -> UtteranceResult {
        let current: [Lane] = stateQueue.sync { let c = lanes; lanes = []; return c }
        for lane in current { lane.continuation.finish() }
        for lane in current {
            let analyzer = lane.analyzer
            do {
                try await withTimeout(seconds: 2.5) { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            } catch {
                onUpdate(TranscriptUpdate(locale: lane.locale, text: "[finalize: \(error)]", confidence: 0, isFinal: true))
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        let anyText = stateQueue.sync { current.contains { !$0.state.volatileText.isEmpty || !$0.state.finals.isEmpty } }
        let deadline = Date().addingTimeInterval(anyText ? 1.5 : 0.3)
        while Date() < deadline {
            let done = stateQueue.sync { current.allSatisfy { $0.state.done } }
            if done { break }
            try? await Task.sleep(for: .milliseconds(15))
        }
        var candidates: [(locale: String, text: String, confidence: Double)] = []
        stateQueue.sync {
            for lane in current {
                let s = lane.state
                let finalText = s.finals.joined(separator: " ")
                if !finalText.isEmpty {
                    let weights = zip(s.finals, s.finalConfidence).map { (Double($0.count), $1) }
                    let total = weights.reduce(0) { $0 + $1.0 }
                    let conf = total > 0 ? weights.reduce(0) { $0 + $1.0 * $1.1 } / total : 0
                    candidates.append((lane.locale, finalText, conf))
                } else if !s.volatileText.isEmpty {
                    candidates.append((lane.locale, s.volatileText, s.volatileConfidence))
                }
            }
        }
        for lane in current { lane.resultsTask.cancel() }
        let best = candidates.max { a, b in
            if abs(a.confidence - b.confidence) > 0.02 { return a.confidence < b.confidence }
            return a.text.count < b.text.count
        }
        stateQueue.sync { pendingInputs = [] }   // audio between utterances is not wanted
        Task { await self.createLanes() }
        return UtteranceResult(text: best?.text ?? "", locale: best?.locale ?? "", confidence: best?.confidence ?? 0, alternatives: candidates)
    }

    public func stop() async {
        let current: [Lane] = stateQueue.sync { let c = lanes; lanes = []; return c }
        for lane in current {
            lane.continuation.finish()
            await lane.analyzer.cancelAndFinishNow()
            lane.resultsTask.cancel()
        }
    }

    private func handle(_ result: SpeechTranscriber.Result, locale: String, state: LaneState) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
        var weighted = 0.0, total = 0.0
        for run in result.text.runs {
            let length = Double(result.text[run.range].characters.count)
            if let c = run.transcriptionConfidence { weighted += c * length; total += length }
        }
        let confidence = total > 0 ? weighted / total : 0
        var snapshotText = ""
        var snapshotConfidence = 0.0
        stateQueue.sync {
            if result.isFinal {
                if !text.isEmpty {
                    state.finals.append(text)
                    state.finalConfidence.append(confidence)
                }
                state.volatileText = ""
                snapshotText = state.finals.joined(separator: " ")
                snapshotConfidence = confidence
            } else {
                state.volatileText = text
                state.volatileConfidence = confidence
                snapshotText = (state.finals + [text]).filter { !$0.isEmpty }.joined(separator: " ")
                snapshotConfidence = confidence
            }
        }
        onUpdate(TranscriptUpdate(locale: locale, text: snapshotText, confidence: snapshotConfidence, isFinal: result.isFinal))
    }
}

public enum TranscriberError: Error, CustomStringConvertible {
    case modelNotInstalled(String)
    case noAudioFormat
    case timeout
    public var description: String {
        switch self {
        case .modelNotInstalled(let l): return "speech model for \(l) is not installed"
        case .noAudioFormat: return "no compatible analyzer audio format"
        case .timeout: return "timed out"
        }
    }
}

/// Races `operation` against a deadline without waiting for it if it cannot be cancelled.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let (stream, continuation) = AsyncStream<Result<T, Error>>.makeStream()
    Task.detached {
        do { continuation.yield(.success(try await operation())) } catch { continuation.yield(.failure(error)) }
        continuation.finish()
    }
    return try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            for await r in stream { return try r.get() }
            throw TranscriberError.timeout
        }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw TranscriberError.timeout
        }
        guard let first = try await group.next() else { throw TranscriberError.timeout }
        group.cancelAll()
        return first
    }
}
