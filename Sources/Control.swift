import Foundation

let appVersion = "0.1.6"
struct Fan: Codable, Equatable {
    let id: Int
    let name: String
    var rpm: Double?
    var minimum: Double?
    var maximum: Double?
    var target: Double?
    var mode: Int?
    var controllable: Bool {
        guard let lo = minimum, let hi = maximum, let rpm = rpm else { return false }
        return lo.isFinite && hi.isFinite && rpm.isFinite && lo >= 0 && hi > max(lo, 1000) && hi <= 16000 && mode != nil
    }
    var safeMinimum: Double { max(minimum ?? 0, 1000) }
}
struct Snapshot: Codable {
    var fans: [Fan] = []
    var temperature: Double?
    var sensor: String?
    var mode = "system"
    var message = "系统自动调节"
    var error = false
    var controlled = false
    var demo = false
}
struct Command: Codable {
    var action: String
    var targets: [String: Double]?
    var low: Double?
    var high: Double?
}
protocol FanHardware: AnyObject {
    func snapshot() throws -> Snapshot
    func setTarget(_ id: Int, rpm: Double) throws
    func setManual(_ id: Int) throws
    func restore(_ ids: Set<Int>) throws
}
final class MacHardware: FanHardware {
    let smc: SMC
    let temperatureKeys: [String]
    var unlocked = false
    init() throws {
        smc = try SMC()
        temperatureKeys = ((try? smc.keys()) ?? []).filter { ["TC","TG","Tp","Tc","Tg"].contains(String($0.prefix(2))) }
    }
    func snapshot() throws -> Snapshot {
        guard let count = smc.number("FNum"), (0...10).contains(count) else { throw FanError("无法读取风扇数量；此 Mac 暂不支持") }
        var s = Snapshot()
        s.fans = (0..<Int(count)).map { id in
            Fan(id: id, name: Int(count) == 1 ? "散热风扇" : "风扇 \(id + 1)", rpm: smc.number("F\(id)Ac"), minimum: smc.number("F\(id)Mn"), maximum: smc.number("F\(id)Mx"), target: smc.number("F\(id)Tg"), mode: smc.mode(id))
        }
        let readings = temperatureKeys.compactMap { key -> (String,Double)? in
            guard let value = smc.number(key), (1...125).contains(value) else { return nil }
            return (key,value)
        }
        if let hottest = readings.max(by: { $0.1 < $1.1 }) { s.sensor = hottest.0; s.temperature = hottest.1 }
        if s.fans.isEmpty { s.message = "未发现风扇；无风扇 Mac 无法调节转速" }
        else if s.fans.contains(where: { $0.mode == 1 }) { s.mode = "external"; s.message = "已有手动控制，请先在原工具恢复自动并退出" }
        if s.temperature == nil && !s.fans.isEmpty && s.mode != "external" { s.message = "温度不可用；仍可手动调速，温度曲线暂不可用" }
        return s
    }
    func setTarget(_ id: Int, rpm: Double) throws { try smc.setTarget(id, rpm: rpm) }
    func setManual(_ id: Int) throws {
        do { try smc.setMode(id, manual: true) }
        catch {
            #if arch(arm64)
            if !unlocked {
                guard smc.number("Ftst") == 0 else { throw error }
                // Mark before attempting: even a partially accepted unlock must be undone.
                unlocked = true
                try smc.unlockThermalManager()
            }
            var last = error
            for _ in 0..<12 {
                do { try smc.setMode(id, manual: true); return }
                catch { last = error; usleep(100_000) }
            }
            throw last
            #else
            throw error
            #endif
        }
    }
    func restore(_ ids: Set<Int>) throws {
        var failures: [String] = []
        for id in ids.sorted() {
            do { try smc.setMode(id, manual: false); try smc.clearAutomaticTarget(id) }
            catch { failures.append(error.localizedDescription) }
        }
        if unlocked {
            do { try smc.restoreThermalManager(); unlocked = false }
            catch { failures.append(error.localizedDescription) }
        }
        // Firmware may use either auto(0) or thermal-manager(3).
        for id in ids where ![0,3].contains(smc.mode(id) ?? -1) { failures.append("风扇 \(id + 1) 自动模式未确认") }
        if !failures.isEmpty { throw FanError(failures.joined(separator: "；")) }
    }
}
final class DemoHardware: FanHardware {
    var state = Snapshot(fans: [Fan(id: 0,name: "左侧风扇",rpm: 2400,minimum: 1200,maximum: 6000,target: 2400,mode: 0), Fan(id: 1,name: "右侧风扇",rpm: 2600,minimum: 1200,maximum: 6200,target: 2600,mode: 0)],temperature: 52,sensor: "演示",demo: true)
    var failWrite = false
    var failRestore = false
    var restored = 0
    func snapshot() throws -> Snapshot { state }
    func setTarget(_ id: Int, rpm: Double) throws {
        if failWrite { throw FanError("模拟写入失败") }
        guard let i = state.fans.firstIndex(where: { $0.id == id }) else { throw FanError("未知风扇") }
        state.fans[i].target = rpm; state.fans[i].rpm = rpm
    }
    func setManual(_ id: Int) throws { state.fans[id].mode = 1 }
    func restore(_ ids: Set<Int>) throws { if failRestore { throw FanError("模拟恢复失败") }; restored += 1; for id in ids { state.fans[id].mode = 0 } }
}
final class ControlEngine {
    let hardware: FanHardware
    private(set) var owned: Set<Int> = []
    private(set) var mode = "system"
    private(set) var message: String?
    private(set) var failed = false
    var targets: [Int: Double] = [:]
    var low = 50.0, high = 80.0
    var lastHeartbeat: TimeInterval
    var lastControlUpdate: TimeInterval = 0
    var lastTick: TimeInterval
    init(_ hardware: FanHardware, now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        self.hardware = hardware; lastHeartbeat = now; lastTick = now
    }
    static func curveRPM(_ temperature: Double, fan: Fan, low: Double, high: Double) -> Double {
        let fraction = min(1, max(0, (temperature - low) / (high - low)))
        return (fan.safeMinimum + ((fan.maximum ?? fan.safeMinimum) - fan.safeMinimum) * fraction).rounded()
    }
    func restore(_ reason: String = "已恢复系统自动调节") throws {
        if owned.isEmpty { mode = "system"; targets.removeAll(); message = nil; failed = false; return }
        try hardware.restore(owned)
        owned.removeAll(); targets.removeAll(); mode = "system"; message = reason; failed = false
    }
    func protect(_ reason: String) {
        do { try restore(reason); failed = true }
        catch { message = "恢复系统控制失败，将继续重试：\(error.localizedDescription)"; failed = true; mode = "recovering" }
    }
    func command(_ command: Command, now: TimeInterval = Date.timeIntervalSinceReferenceDate) throws -> Snapshot {
        guard ["status","system","manual","curve","quit"].contains(command.action) else { throw FanError("未知指令") }
        // Check expiry before accepting a late heartbeat. Reconnection never re-applies old settings.
        tick(now: now)
        if command.action == "status" { lastHeartbeat = now; return try snapshot() }
        if command.action == "system" || command.action == "quit" { try restore(); lastHeartbeat = now; return try snapshot() }
        guard mode != "recovering" else { throw FanError("正在恢复系统控制，请稍候") }
        let current = try hardware.snapshot()
        guard !current.fans.isEmpty, current.fans.allSatisfy({ $0.controllable }) else { throw FanError("风扇读数不可用") }
        if owned.isEmpty && current.fans.contains(where: { $0.mode == 1 }) { throw FanError("另一个工具正在控制风扇，请先恢复自动模式") }
        if command.action == "curve" {
            guard let lo = command.low, let hi = command.high, lo.isFinite, hi.isFinite,
                  (1...65).contains(lo), (21...145).contains(hi), hi - lo >= 10 else { throw FanError("温度曲线参数无效；起点与满速温度至少相差 10°C") }
            low = lo; high = hi
        }
        var requested: [Int: Double] = [:]
        for fan in current.fans {
            let rpm: Double?
            if command.action == "curve" {
                guard let t = current.temperature, t < 90 else { throw FanError("温度不可用或过高，无法启用温度曲线") }
                rpm = Self.curveRPM(t, fan: fan, low: low, high: high)
            } else { rpm = command.targets?[String(fan.id)] }
            guard let rpm = rpm, rpm.isFinite, rpm >= fan.safeMinimum, rpm <= fan.maximum! else { throw FanError("转速必须在每个风扇的允许范围内") }
            requested[fan.id] = rpm.rounded()
        }
        do {
            for fan in current.fans {
                owned.insert(fan.id) // Track partial writes for rollback.
                try hardware.setManual(fan.id)
                try hardware.setTarget(fan.id, rpm: requested[fan.id]!)
            }
            mode = command.action; targets = requested; failed = false
            message = mode == "manual" ? "手动转速已写入并读回；实际 RPM 持续监测" : "按温度曲线自动调节 · 每 2 秒更新"
            lastHeartbeat = Date.timeIntervalSinceReferenceDate
        } catch { protect("调节失败，已请求恢复系统控制"); throw error }
        return try snapshot()
    }
    func tick(now: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        defer { lastTick = now }
        guard !owned.isEmpty else { return }
        if mode == "recovering" { protect("已恢复系统控制"); return }
        if now - lastHeartbeat > 8 || now - lastTick > 8 || now < lastTick {
            protect("控制连接超时或电脑休眠，已恢复系统自动"); return
        }
        do {
            let s = try hardware.snapshot()
            guard owned == Set(s.fans.map(\.id)), s.fans.allSatisfy({ $0.controllable }) else {
                protect("风扇读数失效，已恢复系统自动"); return
            }
            guard s.fans.allSatisfy({ $0.mode == 1 }) else { protect("控制模式发生变化，已恢复系统自动"); return }
            if mode == "curve" {
                guard let t = s.temperature, t < 90 else { protect("温度过高或不可用，已恢复系统自动"); return }
                guard now - lastControlUpdate >= 2 else { return }
                lastControlUpdate = now
                for fan in s.fans {
                    let next = Self.curveRPM(t, fan: fan, low: low, high: high)
                    let previous = targets[fan.id] ?? next
                    // Rise immediately; decrease at most 200 RPM per polling cycle.
                    let rpm = next >= previous ? next : max(next, previous - 200)
                    if abs(rpm - previous) >= 50 {
                        try hardware.setTarget(fan.id, rpm: rpm); targets[fan.id] = rpm
                    }
                }
            }
        } catch { protect("读取或写入失败，已请求恢复系统控制") }
    }
    func snapshot() throws -> Snapshot {
        var s = try hardware.snapshot(); if !owned.isEmpty || s.mode != "external" { s.mode = mode }; s.controlled = !owned.isEmpty
        if let message = message { s.message = message }; s.error = failed
        return s
    }
}
