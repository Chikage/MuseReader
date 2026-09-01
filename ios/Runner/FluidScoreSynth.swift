import AVFoundation
import AudioToolbox
import Foundation

/** Streams the bundled MuseScore FluidSynth renderer through AVAudioEngine. */
final class FluidScoreSynth {
  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var rendering = false
  private var scratch = [Float]()

  @discardableResult
  func start(events: [[String: Any]], positionUs: Int64, speed: Double) -> Bool {
    stop()
    guard !events.isEmpty else { return false }
    guard let data = try? JSONSerialization.data(withJSONObject: events),
          let json = String(data: data, encoding: .utf8) else {
      return false
    }

    let started = json.withCString { pointer in
      muse_reader_audio_start_json(pointer, positionUs, speed) != 0
    }
    guard started else { return false }

    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)

    let sampleRate = Double(muse_reader_audio_sample_rate())
    guard let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate,
      channels: 2
    ) else {
      muse_reader_audio_stop()
      return false
    }

    let newEngine = AVAudioEngine()
    let newSourceNode = AVAudioSourceNode(format: format) { [weak self] isSilence, _, frameCount, outputData in
      guard let self else {
        isSilence.pointee = true
        return noErr
      }
      let rendered = self.render(frameCount: Int(frameCount), outputData: outputData)
      isSilence.pointee = ObjCBool(!rendered)
      return noErr
    }
    newEngine.attach(newSourceNode)
    newEngine.connect(newSourceNode, to: newEngine.mainMixerNode, format: format)

    lock.lock()
    engine = newEngine
    sourceNode = newSourceNode
    rendering = true
    lock.unlock()

    newEngine.prepare()
    do {
      try newEngine.start()
      return true
    } catch {
      stop()
      return false
    }
  }

  func stop() {
    lock.lock()
    let oldEngine = engine
    let oldSourceNode = sourceNode
    engine = nil
    sourceNode = nil
    rendering = false
    lock.unlock()

    oldEngine?.stop()
    if let oldSourceNode, let oldEngine {
      oldEngine.detach(oldSourceNode)
    }
    muse_reader_audio_stop()
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }

  private func render(
    frameCount: Int,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> Bool {
    guard frameCount > 0 else { return false }
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    lock.lock()
    guard rendering else {
      lock.unlock()
      clear(buffers: buffers)
      return false
    }

    let sampleCount = frameCount * 2
    if scratch.count != sampleCount {
      scratch = [Float](repeating: 0, count: sampleCount)
    } else {
      scratch.withUnsafeMutableBufferPointer { buffer in
        for index in buffer.indices {
          buffer[index] = 0
        }
      }
    }
    let rendered = scratch.withUnsafeMutableBufferPointer { buffer -> Int in
      guard let baseAddress = buffer.baseAddress else { return 0 }
      return Int(muse_reader_audio_render(baseAddress, frameCount))
    }
    copy(samples: scratch, to: buffers, frameCount: frameCount)
    lock.unlock()
    return rendered > 0
  }

  private func copy(
    samples: [Float],
    to buffers: UnsafeMutableAudioBufferListPointer,
    frameCount: Int
  ) {
    guard !buffers.isEmpty else { return }
    if buffers.count == 1,
       let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) {
      let channels = max(1, Int(buffers[0].mNumberChannels))
      if channels == 2 {
        samples.withUnsafeBufferPointer { source in
          data.update(from: source.baseAddress!, count: frameCount * 2)
        }
      } else {
        for frame in 0..<frameCount {
          for channel in 0..<channels {
            data[frame * channels + channel] = samples[frame * 2 + min(channel, 1)]
          }
        }
      }
      return
    }

    for (bufferIndex, buffer) in buffers.enumerated() {
      guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
      let channel = min(bufferIndex, 1)
      for frame in 0..<frameCount {
        data[frame] = samples[frame * 2 + channel]
      }
    }
  }

  private func clear(buffers: UnsafeMutableAudioBufferListPointer) {
    for buffer in buffers {
      if let data = buffer.mData {
        memset(data, 0, Int(buffer.mDataByteSize))
      }
    }
  }
}
