import XCTest
import AVFoundation
@testable import Jinbao365

final class VideoPlaybackAudioTests: XCTestCase {
    func testPlayerCreationRestoresMovieAudioFromSilentModeCategories() throws {
        let session = AVAudioSession.sharedInstance()
        let previousCategory = session.category
        let previousMode = session.mode
        let previousOptions = session.categoryOptions
        defer { try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions) }

        // Creation is the production path used before either native or custom controls can play.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-unplayed.mov")
        for startingCategory in [AVAudioSession.Category.ambient, .soloAmbient] {
            try session.setCategory(startingCategory, mode: .default)
            let player = try MoviePlaybackPlayerFactory.makePlayer(url: url)
            defer { player.replaceCurrentItem(with: nil) }

            XCTAssertEqual(session.category, .playback)
            XCTAssertEqual(session.mode, .moviePlayback)
            XCTAssertTrue(session.categoryOptions.isEmpty, "Movie playback must not duck audio or override routing.")
            XCTAssertFalse(player.isMuted)
            XCTAssertEqual(player.volume, 1)
            XCTAssertEqual(player.rate, 0, "Opening a viewer must not start playback.")
            XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url, url)
        }
    }

    func testOriginalVideoImportPreservesAudibleTrackAndExactBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("video-audio-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic-tone.mov")
        try await writeMovieWithTone(to: source)

        let imported = try PhotoImport.store(file: source, filename: source.lastPathComponent,
                                             provenance: .fileSelected, directory: directory)
        XCTAssertEqual(imported.kind, "video")
        let original = try XCTUnwrap(imported.resources.first { $0.role == "video" })
        let storedURL = directory.appendingPathComponent(original.relativePath)
        let sourceBytes = try Data(contentsOf: source)
        XCTAssertEqual(try Data(contentsOf: storedURL), sourceBytes)
        XCTAssertEqual(original.sha256, Digest.sha256Hex(sourceBytes))
        XCTAssertNotEqual(imported.resources.first { $0.role == "preview" }?.relativePath, original.relativePath)

        let asset = AVURLAsset(url: storedURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(audioTracks.count, 1)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        XCTAssertTrue(reader.canAdd(output))
        reader.add(output)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "Audio reader failed")
        var decodedSamples = 0
        var hasNonzeroSamples = false
        while let sample = output.copyNextSampleBuffer() {
            decodedSamples += CMSampleBufferGetNumSamples(sample)
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample))
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            XCTAssertEqual(status, kCMBlockBufferNoErr)
            hasNonzeroSamples = hasNonzeroSamples || bytes.contains { $0 != 0 }
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "Audio decoding failed")
        XCTAssertGreaterThan(decodedSamples, 0)
        XCTAssertTrue(hasNonzeroSamples, "The imported audio must contain the generated tone, not silence.")
    }

    private func writeMovieWithTone(to url: URL) async throws {
        let sampleRate: Int32 = 44_100
        let samples = (0..<Int(sampleRate / 2)).map { index in
            Int16(sin(2 * Double.pi * 440 * Double(index) / Double(sampleRate)) * 8_000)
        }
        var format = AudioStreamBasicDescription(mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
            mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description), noErr)
        let audioFormat = try XCTUnwrap(description)
        var block: CMBlockBuffer?
        let sampleBytes = samples.withUnsafeBytes { Data($0) }
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: sampleBytes.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: sampleBytes.count, flags: 0, blockBufferOut: &block), kCMBlockBufferNoErr)
        let audioBlock = try XCTUnwrap(block)
        let copyStatus = sampleBytes.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: audioBlock,
                                          offsetIntoDestination: 0, dataLength: raw.count)
        }
        XCTAssertEqual(copyStatus, kCMBlockBufferNoErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
                                        presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 2
        var sampleBuffer: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: audioBlock,
            formatDescription: audioFormat, sampleCount: samples.count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer), noErr)
        let audioSample = try XCTUnwrap(sampleBuffer)

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
        guard writer.canAdd(video), writer.canAdd(audio) else { throw fixtureError("Synthetic movie tracks unavailable") }
        writer.add(video)
        writer.add(audio)
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
        ])
        guard writer.startWriting() else { throw writer.error ?? fixtureError("Synthetic movie writer failed") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<2 {
            try await waitUntilReady(video, writer: writer)
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 32, kCVPixelFormatType_32ARGB,
                                               nil, &buffer), kCVReturnSuccess)
            let pixelBuffer = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 127, CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            guard pixels.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 4)) else {
                throw writer.error ?? fixtureError("Synthetic video append failed")
            }
        }
        video.markAsFinished()
        try await waitUntilReady(audio, writer: writer)
        guard audio.append(audioSample) else { throw writer.error ?? fixtureError("Synthetic tone append failed") }
        audio.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 2))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? fixtureError("Synthetic movie incomplete") }
    }

    private func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter) async throws {
        for _ in 0..<1_000 {
            if input.isReadyForMoreMediaData { return }
            guard writer.status == .writing else { throw writer.error ?? fixtureError("Synthetic writer stopped") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw fixtureError("Synthetic movie encoder timed out")
    }

    private func fixtureError(_ message: String) -> NSError {
        NSError(domain: "VideoPlaybackAudioTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
