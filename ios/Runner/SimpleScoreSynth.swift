import AVFoundation
import AudioToolbox

final class SimpleScoreSynth {
  private struct ToneEvent {
    let startUs: Double
    let endUs: Double
    let pitch: Int
    let velocity: Double
  }

  private let lock = NSLock()
  private var engine: AVAudioEngine?
  private var sourceNode: AVAudioSourceNode?
  private var events: [ToneEvent] = []
  private var basePositionUs = 0.0
  private var speed = 1.0
  private var frameCursor: Int64 = 0
  private var sampleRate = 44_100.0

  func start(events rawEvents: [[String: Any]], positionUs: Int64, speed: Double) {
    let events = rawEvents.compactMap { raw -> ToneEvent? in
      guard
        let start = (raw["startUs"] as? NSNumber)?.doubleValue,
        let end = (raw["endUs"] as? NSNumber)?.doubleValue
      else { return nil }
      let pitch = (raw["pitch"] as? NSNumber)?.intValue ?? 60
      let velocity = (raw["velocity"] as? NSNumber)?.doubleValue ?? 80
      return ToneEvent(
        startUs: start,
        endUs: max(start + 1, end),
        pitch: pitch,
        velocity: velocity
      )
    }
    stop()
    guard !events.isEmpty else { return }

    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .default, options: [])
    try? session.setActive(true)

    guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
      return
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
    self.events = events
    basePositionUs = Double(positionUs)
    self.speed = max(0.1, speed)
    frameCursor = 0
    sampleRate = format.sampleRate
    engine = newEngine
    sourceNode = newSourceNode
    lock.unlock()

    newEngine.prepare()
    do {
      try newEngine.start()
    } catch {
      stop()
    }
  }

  func stop() {
    lock.lock()
    let oldEngine = engine
    let oldSourceNode = sourceNode
    engine = nil
    sourceNode = nil
    events.removeAll(keepingCapacity: true)
    frameCursor = 0
    lock.unlock()

    oldEngine?.stop()
    if let oldSourceNode, let oldEngine {
      oldEngine.detach(oldSourceNode)
    }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  private func render(
    frameCount: Int,
    outputData: UnsafeMutablePointer<AudioBufferList>
  ) -> Bool {
    guard frameCount > 0 else { return false }
    let buffers = UnsafeMutableAudioBufferListPointer(outputData)
    lock.lock()
    defer { lock.unlock() }
    guard !events.isEmpty else {
      clear(buffers: buffers)
      return false
    }
    let firstFrame = frameCursor
    frameCursor += Int64(frameCount)
    let currentEvents = events
    let currentBase = basePositionUs
    let currentSpeed = speed
    let currentRate = sampleRate

    var rendered = false
    for buffer in buffers {
      guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
      let channels = max(1, Int(buffer.mNumberChannels))
      for frame in 0..<frameCount {
        let timeUs = currentBase +
          Double(firstFrame + Int64(frame)) / currentRate * 1_000_000 * currentSpeed
        let sample = sampleAt(events: currentEvents, timeUs: timeUs)
        rendered = rendered || sample != 0
        if channels == 1 {
          data[frame] = Float(sample)
        } else {
          for channel in 0..<channels {
            data[frame * channels + channel] = Float(sample)
          }
        }
      }
    }
    return rendered
  }

  private func clear(buffers: UnsafeMutableAudioBufferListPointer) {
    for buffer in buffers {
      if let data = buffer.mData {
        memset(data, 0, Int(buffer.mDataByteSize))
      }
    }
  }

  private func sampleAt(events: [ToneEvent], timeUs: Double) -> Double {
    var sum = 0.0
    var active = 0
    for event in events {
      guard timeUs >= event.startUs, timeUs < event.endUs else { continue }
      active += 1
      let elapsed = timeUs - event.startUs
      let duration = event.endUs - event.startUs
      let attack = min(1.0, elapsed / 12_000.0)
      let release = min(1.0, (duration - elapsed) / 35_000.0)
      let envelope = min(attack, release)
      let frequency = 440.0 * pow(2.0, Double(event.pitch - 69) / 12.0)
      sum += sin(2.0 * .pi * frequency * elapsed / 1_000_000.0) *
        envelope * event.velocity / 127.0
    }
    guard active > 0 else { return 0 }
    return max(-0.95, min(0.95, sum / sqrt(Double(active)) * 0.22))
  }
}
