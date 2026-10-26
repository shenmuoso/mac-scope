import CoreAudio
import Foundation

struct AudioRenderFormat: Equatable, Sendable {
  var channels: Int
  var isFloat32: Bool
  var isNonInterleaved: Bool
  var sampleRate: Double = 48_000

  static func make(_ description: AudioStreamBasicDescription) -> AudioRenderFormat {
    let flags = description.mFormatFlags
    return AudioRenderFormat(
      channels: Int(description.mChannelsPerFrame),
      isFloat32: description.mFormatID == kAudioFormatLinearPCM
        && description.mBitsPerChannel == 32
        && (flags & kAudioFormatFlagIsFloat) != 0,
      isNonInterleaved: (flags & kAudioFormatFlagIsNonInterleaved) != 0,
      sampleRate: description.mSampleRate
    )
  }
}

enum AppAudioGain {
  static func render(
    input: UnsafePointer<AudioBufferList>,
    inputFormat: AudioRenderFormat,
    output: UnsafeMutablePointer<AudioBufferList>,
    outputFormat: AudioRenderFormat,
    gain: Float,
    effect: (any AppAudioSampleEffect)? = nil
  ) {
    let outputBuffers = UnsafeMutableAudioBufferListPointer(output)
    for buffer in outputBuffers {
      guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
      memset(data, 0, Int(buffer.mDataByteSize))
    }
    guard inputFormat.isFloat32, outputFormat.isFloat32, gain > 0 else { return }
    guard inputFormat.channels > 0, outputFormat.channels > 0 else { return }

    let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let frames = min(
      frameCount(inputBuffers, format: inputFormat),
      frameCount(outputBuffers, format: outputFormat)
    )
    guard frames > 0 else { return }
    effect?.beginBuffer(sampleRate: inputFormat.sampleRate)

    for frame in 0..<frames {
      let leftIn = read(buffers: inputBuffers, format: inputFormat, channel: 0, frame: frame)
      let rightIn = inputFormat.channels > 1
        ? read(buffers: inputBuffers, format: inputFormat, channel: 1, frame: frame)
        : leftIn
      let left = (effect?.process(channel: 0, sample: leftIn) ?? leftIn) * gain
      let right = (effect?.process(channel: 1, sample: rightIn) ?? rightIn) * gain
      if outputFormat.channels == 1 {
        write((left + right) / 2, buffers: outputBuffers, format: outputFormat, channel: 0, frame: frame)
      } else {
        for channel in 0..<outputFormat.channels {
          write(
            channel.isMultiple(of: 2) ? left : right,
            buffers: outputBuffers,
            format: outputFormat,
            channel: channel,
            frame: frame
          )
        }
      }
    }
  }

  static func peaks(
    input: UnsafePointer<AudioBufferList>,
    format: AudioRenderFormat
  ) -> (left: Float, right: Float) {
    guard format.isFloat32, format.channels > 0 else { return (0, 0) }
    let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let frames = frameCount(buffers, format: format)
    var left: Float = 0
    var right: Float = 0
    for frame in 0..<frames {
      left = max(left, abs(read(buffers: buffers, format: format, channel: 0, frame: frame)))
      if format.channels > 1 {
        right = max(right, abs(read(buffers: buffers, format: format, channel: 1, frame: frame)))
      } else {
        right = left
      }
    }
    return (left, right)
  }

  static func renderSamples(
    input: [[Float]],
    inputInterleaved: Bool,
    outputChannelCount: Int,
    outputInterleaved: Bool,
    gain: Float
  ) -> [[Float]] {
    let inputChannels = input.count
    let frames = input.map(\.count).min() ?? 0
    let inputList = makeList(
      channels: input,
      interleaved: inputInterleaved
    )
    defer { freeList(inputList, interleaved: inputInterleaved, channels: inputChannels) }

    let silent = Array(repeating: Array(repeating: Float(0), count: frames), count: outputChannelCount)
    let outputList = makeList(channels: silent, interleaved: outputInterleaved)
    defer { freeList(outputList, interleaved: outputInterleaved, channels: outputChannelCount) }

    render(
      input: inputList.unsafePointer,
      inputFormat: AudioRenderFormat(
        channels: inputChannels,
        isFloat32: true,
        isNonInterleaved: !inputInterleaved
      ),
      output: outputList.unsafeMutablePointer,
      outputFormat: AudioRenderFormat(
        channels: outputChannelCount,
        isFloat32: true,
        isNonInterleaved: !outputInterleaved
      ),
      gain: gain
    )
    return readList(outputList, channels: outputChannelCount, frames: frames, interleaved: outputInterleaved)
  }

  static func peakSamples(_ channels: [[Float]], interleaved: Bool) -> (left: Float, right: Float) {
    let list = makeList(channels: channels, interleaved: interleaved)
    defer { freeList(list, interleaved: interleaved, channels: channels.count) }
    return peaks(
      input: list.unsafePointer,
      format: AudioRenderFormat(
        channels: channels.count,
        isFloat32: true,
        isNonInterleaved: !interleaved
      )
    )
  }

  private static func frameCount(
    _ buffers: UnsafeMutableAudioBufferListPointer,
    format: AudioRenderFormat
  ) -> Int {
    guard format.channels > 0 else { return 0 }
    if format.isNonInterleaved {
      guard let buffer = buffers.first else { return 0 }
      return Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
    }
    guard let buffer = buffers.first else { return 0 }
    return Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * format.channels)
  }

  private static func read(
    buffers: UnsafeMutableAudioBufferListPointer,
    format: AudioRenderFormat,
    channel: Int,
    frame: Int
  ) -> Float {
    if format.isNonInterleaved {
      guard channel < buffers.count, let data = buffers[channel].mData else { return 0 }
      return data.assumingMemoryBound(to: Float.self)[frame]
    }
    guard let data = buffers.first?.mData else { return 0 }
    return data.assumingMemoryBound(to: Float.self)[frame * format.channels + channel]
  }

  private static func write(
    _ value: Float,
    buffers: UnsafeMutableAudioBufferListPointer,
    format: AudioRenderFormat,
    channel: Int,
    frame: Int
  ) {
    if format.isNonInterleaved {
      guard channel < buffers.count, let data = buffers[channel].mData else { return }
      data.assumingMemoryBound(to: Float.self)[frame] = value
      return
    }
    guard let data = buffers.first?.mData else { return }
    data.assumingMemoryBound(to: Float.self)[frame * format.channels + channel] = value
  }

  private static func makeList(
    channels: [[Float]],
    interleaved: Bool
  ) -> UnsafeMutableAudioBufferListPointer {
    let channelCount = channels.count
    let frames = channels.first?.count ?? 0
    let bufferCount = interleaved ? 1 : max(channelCount, 1)
    let list = AudioBufferList.allocate(maximumBuffers: bufferCount)
    if interleaved {
      let data = UnsafeMutablePointer<Float>.allocate(capacity: max(frames * channelCount, 1))
      for frame in 0..<frames {
        for channel in 0..<channelCount {
          data[frame * channelCount + channel] = channels[channel][frame]
        }
      }
      list[0] = AudioBuffer(
        mNumberChannels: UInt32(channelCount),
        mDataByteSize: UInt32(frames * channelCount * MemoryLayout<Float>.size),
        mData: UnsafeMutableRawPointer(data)
      )
    } else {
      for channel in 0..<channelCount {
        let data = UnsafeMutablePointer<Float>.allocate(capacity: max(frames, 1))
        for frame in 0..<frames {
          data[frame] = channels[channel][frame]
        }
        list[channel] = AudioBuffer(
          mNumberChannels: 1,
          mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
          mData: UnsafeMutableRawPointer(data)
        )
      }
    }
    return list
  }

  private static func readList(
    _ list: UnsafeMutableAudioBufferListPointer,
    channels: Int,
    frames: Int,
    interleaved: Bool
  ) -> [[Float]] {
    var result = Array(repeating: Array(repeating: Float(0), count: frames), count: channels)
    for frame in 0..<frames {
      for channel in 0..<channels {
        if interleaved {
          guard let data = list.first?.mData else { continue }
          result[channel][frame] = data.assumingMemoryBound(to: Float.self)[frame * channels + channel]
        } else if channel < list.count, let data = list[channel].mData {
          result[channel][frame] = data.assumingMemoryBound(to: Float.self)[frame]
        }
      }
    }
    return result
  }

  private static func freeList(
    _ list: UnsafeMutableAudioBufferListPointer,
    interleaved: Bool,
    channels: Int
  ) {
    let bufferCount = interleaved ? 1 : channels
    for index in 0..<bufferCount where index < list.count {
      list[index].mData?.assumingMemoryBound(to: Float.self).deallocate()
    }
    list.unsafeMutablePointer.deallocate()
  }
}
