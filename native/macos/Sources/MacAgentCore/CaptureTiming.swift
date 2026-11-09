public struct CaptureTiming {
    public struct Means {
        public let captureMilliseconds: Double
        public let conversionMilliseconds: Double
        public let sendMilliseconds: Double
        /// Time from the loop iteration start until the pending capture was
        /// available (snapshot pipeline) or until the next pushed frame arrived
        /// (stream mode). Purely informational; not part of capture itself.
        public let waitMilliseconds: Double
    }
    private let windowSize: Int
    private var count = 0
    private var captureTotal = 0.0
    private var conversionTotal = 0.0
    private var sendTotal = 0.0
    private var waitTotal = 0.0

    public init(windowSize: Int) {
        precondition(windowSize > 0)
        self.windowSize = windowSize
    }

    public mutating func record(capture: UInt64, conversion: UInt64, send: UInt64) -> Means? {
        record(capture: capture, conversion: conversion, send: send, wait: 0)
    }

    public mutating func record(capture: UInt64, conversion: UInt64, send: UInt64,
                                wait: UInt64) -> Means? {
        count += 1
        captureTotal += Double(capture)
        conversionTotal += Double(conversion)
        sendTotal += Double(send)
        waitTotal += Double(wait)
        guard count == windowSize else { return nil }
        let divisor = Double(count) * 1_000_000
        let means = Means(captureMilliseconds: captureTotal / divisor,
                          conversionMilliseconds: conversionTotal / divisor,
                          sendMilliseconds: sendTotal / divisor,
                          waitMilliseconds: waitTotal / divisor)
        count = 0
        captureTotal = 0
        conversionTotal = 0
        sendTotal = 0
        waitTotal = 0
        return means
    }
}

/// Simple running statistics used by the capture benchmark.
public struct CaptureBenchmark {
    public struct Stats {
        public let count: Int
        public let meanMilliseconds: Double
        public let minMilliseconds: Double
        public let maxMilliseconds: Double

        public var framesPerSecond: Double {
            meanMilliseconds > 0 ? 1_000 / meanMilliseconds : 0
        }

        public var describe: String {
            String(format: "n=%d mean=%.2fms min=%.2fms max=%.2fms fps=%.1f",
                   count, meanMilliseconds, minMilliseconds, maxMilliseconds, framesPerSecond)
        }
    }

    private var count = 0
    private var total = 0.0
    private var minimum = Double.greatestFiniteMagnitude
    private var maximum = 0.0

    public init() {}

    public mutating func record(nanoseconds: UInt64) {
        let milliseconds = Double(nanoseconds) / 1_000_000
        count += 1
        total += milliseconds
        minimum = min(minimum, milliseconds)
        maximum = max(maximum, milliseconds)
    }

    public mutating func reset() {
        count = 0
        total = 0
        minimum = Double.greatestFiniteMagnitude
        maximum = 0
    }

    public var stats: Stats? {
        guard count > 0 else { return nil }
        return Stats(count: count, meanMilliseconds: total / Double(count),
                     minMilliseconds: minimum, maxMilliseconds: maximum)
    }
}
