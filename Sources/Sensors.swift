import Foundation

/// Optional IOKit/SMC sensors are sampled less frequently than the main counters.
/// An unsupported sensor remains nil, including on machines without a battery/fan.
final class Sensors {
    private var lastRead: TimeInterval = -.infinity
    private var cached = GJLSensors()

    func apply(to sample: inout MetricsSample, uptime: TimeInterval, force: Bool = false) {
        if force || uptime - lastRead >= 6 || lastRead == -.infinity {
            gjl_sensor_snapshot(&cached)
            lastRead = uptime
        }
        sample.gpuPercent = Self.valid(cached.gpu_percent, range: 0...100)
        sample.cpuTemperature = Self.valid(cached.cpu_temperature, range: 0.01...149.99)
        sample.cpuPower = Self.valid(cached.cpu_power, range: 0...999)
        sample.gpuPower = Self.valid(cached.gpu_power, range: 0...999)
        sample.fanRPM = Self.valid(cached.fan_rpm, range: 0...29999)
        sample.batteryPercent = Self.valid(cached.battery_percent, range: 0...100)
        sample.batteryCharging = cached.battery_charging != 0
        sample.batteryHealth = Self.valid(cached.battery_health, range: 0...100)
        sample.batteryCycles = cached.battery_cycles >= 0 ? Int(cached.battery_cycles) : nil
    }

    private static func valid(_ number: Double, range: ClosedRange<Double>) -> Double? {
        number.isFinite && range.contains(number) ? number : nil
    }
}
