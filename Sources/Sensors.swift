import Foundation

/// Optional IOKit/SMC sensors are sampled less frequently than the main counters.
/// An unsupported sensor remains nil, including on machines without a battery/fan.
final class Sensors {
    private let read: (inout GJLSensors) -> Void
    private var lastRead: TimeInterval = -.infinity
    private var cached = GJLSensors()
    private var readDate = Date.distantPast
    private var lastBattery: BatterySnapshot?
    private var lastFans: [FanDescriptor]?

    init(read: @escaping (inout GJLSensors) -> Void = { gjl_sensor_snapshot(&$0) }) { self.read = read }

    func apply(to sample: inout MetricsSample, uptime: TimeInterval, force: Bool = false) {
        if force || uptime - lastRead >= 6 || lastRead == -.infinity {
            read(&cached)
            lastRead = uptime
            readDate = sample.timestamp
        }
        sample.gpuPercent = Self.valid(cached.gpu_percent, range: 0...100)
        sample.cpuTemperature = Self.valid(cached.cpu_temperature, range: 0.01...149.99)
        sample.cpuPower = Self.valid(cached.cpu_power, range: 0...999)
        sample.gpuPower = Self.valid(cached.gpu_power, range: 0...999)
        sample.fanRPM = Self.valid(cached.fan_rpm, range: 0...29999)
        sample.batteryPercent = Self.valid(cached.battery_percent, range: 0...100)
        sample.batteryCharging = cached.battery_charging == 1
        sample.batteryHealth = Self.valid(cached.battery_health, range: 0...100)
        sample.batteryCycles = cached.battery_cycles >= 0 ? Int(cached.battery_cycles) : nil
        let publicSource = "IOPowerSources（公开只读）"
        let registrySource = "AppleSmartBattery IORegistry（只读兼容字段，非控制 API）"
        let absent = cached.battery_present == 0 ? "未发现内置电池" : "系统未提供此项或读取失败"
        func number(_ value: Double?, _ unit: String, _ source: String) -> MetricReading<Double> {
            MetricReading(value: value, unit: unit, timestamp: readDate, source: source, availabilityReason: value == nil ? "系统未提供此项或读取失败" : nil)
        }
        func flag(_ value: Int32) -> MetricReading<Bool> {
            MetricReading(value: value >= 0 ? value == 1 : nil, unit: "", timestamp: readDate, source: publicSource,
                          availabilityReason: value < 0 ? absent : nil)
        }
        let health = withUnsafePointer(to: &cached.battery_condition) { $0.withMemoryRebound(to: CChar.self, capacity: 128) { String(cString: $0) } }
        var battery = BatterySnapshot(timestamp: readDate,
            present: flag(cached.battery_present), percent: number(sample.batteryPercent, "%", publicSource),
            externalPower: flag(cached.battery_ac_power), charging: flag(cached.battery_charging),
            healthPercent: number(sample.batteryHealth, "%", registrySource),
            healthCondition: MetricReading(value: health.isEmpty ? nil : health, unit: "", timestamp: readDate, source: publicSource, availabilityReason: health.isEmpty ? absent : nil),
            cycles: MetricReading(value: sample.batteryCycles, unit: "次", timestamp: readDate, source: registrySource, availabilityReason: sample.batteryCycles == nil ? absent : nil),
            temperature: number(Self.valid(cached.battery_temperature, range: -20...100), "°C", publicSource),
            minutesToEmpty: number(cached.battery_ac_power == 0 ? Self.valid(cached.battery_minutes_empty, range: 1...100_000) : nil, "分钟", publicSource),
            minutesToFull: number(cached.battery_charging == 1 ? Self.valid(cached.battery_minutes_full, range: 1...100_000) : nil, "分钟", publicSource))
        if cached.battery_present != 0 {
            battery.present = battery.present.retaining(lastBattery?.present)
            battery.percent = battery.percent.retaining(lastBattery?.percent)
            battery.temperature = battery.temperature.retaining(lastBattery?.temperature)
            battery.healthPercent = battery.healthPercent.retaining(lastBattery?.healthPercent)
            battery.cycles = battery.cycles.retaining(lastBattery?.cycles)
            battery.externalPower = battery.externalPower.retaining(lastBattery?.externalPower)
            battery.charging = battery.charging.retaining(lastBattery?.charging)
            battery.healthCondition = battery.healthCondition.retaining(lastBattery?.healthCondition)
        }
        sample.batterySnapshot = battery; lastBattery = battery
        let sensorSource = cached.cpu_temperature_source == 1 ? "IOHID 只读温度（非公开兼容接口）" : "AppleSMC 已有只读适配（非公开协议）"
        sample.readings = [
            "gpu": number(sample.gpuPercent, "%", "IOAccelerator PerformanceStatistics（只读兼容字段）"),
            "temperature": number(sample.cpuTemperature, "°C", sensorSource),
            "cpuPower": number(sample.cpuPower, "W", "已适配 Intel SMC PCPC（只读）"),
            "gpuPower": number(sample.gpuPower, "W", "无已验证读取来源"),
            "fan": number(sample.fanRPM, "RPM", "AppleSMC 已发现风扇转速（只读）")
        ]
        let speeds = withUnsafeBytes(of: &cached.fan_speeds) { Array($0.bindMemory(to: Double.self)) }
        if cached.fan_count >= 0 {
            sample.fanDescriptors = (0..<Int(cached.fan_count)).map { index in
                let id = "smc-fan-\(index)"
                let reading = number(Self.valid(speeds[index], range: 0...29999), "RPM", "AppleSMC F\(String(index, radix: 16).uppercased())Ac（只读）")
                    .retaining(lastFans?.first { $0.id == id }?.speed)
                return FanDescriptor(id: id, name: "风扇 \(index + 1)", speed: reading)
            }
        } else {
            sample.fanDescriptors = lastFans?.map { fan in
                var previous = fan; previous.speed.isStale = true; previous.speed.availabilityReason = "风扇读取失败；保留旧值"
                return previous
            }
        }
        lastFans = sample.fanDescriptors
    }

    private static func valid(_ number: Double, range: ClosedRange<Double>) -> Double? {
        number.isFinite && range.contains(number) ? number : nil
    }
}
