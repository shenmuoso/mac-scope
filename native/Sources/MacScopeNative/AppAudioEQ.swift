import Foundation
import os

enum AppAudioEQ {
  static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
  static let flat = Array(repeating: 0.0, count: frequencies.count)

  static func normalized(_ gains: [Double]) -> [Double] {
    var values = gains.map { min(12, max(-12, $0)) }
    if values.count < frequencies.count {
      values.append(contentsOf: Array(repeating: 0, count: frequencies.count - values.count))
    }
    return Array(values.prefix(frequencies.count))
  }

  static func isFlat(_ gains: [Double]) -> Bool {
    normalized(gains).allSatisfy { abs($0) < 0.05 }
  }

  static func render(samples: [Float], gains: [Double], sampleRate: Double) -> [Float] {
    let processor = AppAudioEQProcessor()
    processor.setGains(gains)
    processor.beginBuffer(sampleRate: sampleRate)
    return samples.map { processor.process(channel: 0, sample: $0) }
  }
}

protocol AppAudioSampleEffect: AnyObject {
  func beginBuffer(sampleRate: Double)
  func process(channel: Int, sample: Float) -> Float
}

final class AppAudioEQProcessor: AppAudioSampleEffect, @unchecked Sendable {
  private let settings = OSAllocatedUnfairLock(initialState: AppAudioEQ.flat)
  private var filters = Array(
    repeating: Array(repeating: Biquad(), count: AppAudioEQ.frequencies.count),
    count: 2
  )
  private var applied = AppAudioEQ.flat
  private var appliedRate = 0.0

  func setGains(_ gains: [Double]) {
    let normalized = AppAudioEQ.normalized(gains)
    settings.withLock { $0 = normalized }
  }

  func beginBuffer(sampleRate: Double) {
    let gains = settings.withLock { $0 }
    guard sampleRate > 0, gains != applied || sampleRate != appliedRate else { return }
    applied = gains
    appliedRate = sampleRate
    for channel in filters.indices {
      for band in filters[channel].indices {
        filters[channel][band] = Biquad.peaking(
          gainDB: gains[band],
          frequency: AppAudioEQ.frequencies[band],
          sampleRate: sampleRate
        )
      }
    }
  }

  func process(channel: Int, sample: Float) -> Float {
    guard !AppAudioEQ.isFlat(applied) else { return sample }
    let index = min(max(channel, 0), filters.count - 1)
    var value = sample
    for band in filters[index].indices {
      value = filters[index][band].process(value)
    }
    return value
  }
}

private struct Biquad {
  var b0: Float = 1
  var b1: Float = 0
  var b2: Float = 0
  var a1: Float = 0
  var a2: Float = 0
  var z1: Float = 0
  var z2: Float = 0

  static func peaking(gainDB: Double, frequency: Double, sampleRate: Double, q: Double = 1.414) -> Biquad {
    guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2 else { return Biquad() }
    let a = pow(10, gainDB / 40)
    let omega = 2 * Double.pi * frequency / sampleRate
    let alpha = sin(omega) / (2 * q)
    let cosine = cos(omega)
    let a0 = 1 + alpha / a
    guard a0 != 0 else { return Biquad() }
    return Biquad(
      b0: Float((1 + alpha * a) / a0),
      b1: Float((-2 * cosine) / a0),
      b2: Float((1 - alpha * a) / a0),
      a1: Float((-2 * cosine) / a0),
      a2: Float((1 - alpha / a) / a0)
    )
  }

  mutating func process(_ sample: Float) -> Float {
    let output = b0 * sample + z1
    z1 = b1 * sample - a1 * output + z2
    z2 = b2 * sample - a2 * output
    return output
  }
}
