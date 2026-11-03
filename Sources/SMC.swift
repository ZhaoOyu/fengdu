// AppleSMC ABI layout adapted from Stats (MIT), see THIRD_PARTY_NOTICES.md.
import Foundation
import IOKit

internal struct SMCKeyData_t {
    typealias SMCBytes_t = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8)

    struct vers_t {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }

    struct LimitData_t {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    struct keyInfo_t {
        var dataSize: IOByteCount32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    var key: UInt32 = 0
    var vers = vers_t()
    var pLimitData = LimitData_t()
    var keyInfo = keyInfo_t()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes_t = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0),
                             UInt8(0), UInt8(0))
}

struct FanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
struct SMCValue {
    let type: String
    var bytes: [UInt8]
    var number: Double? {
        switch type {
        case "ui8 ": return bytes.first.map(Double.init)
        case "ui16": guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32": guard bytes.count >= 4 else { return nil }; return Double(bytes.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        case "fpe2": guard bytes.count >= 2 else { return nil }; return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4
        case "sp78": guard bytes.count >= 2 else { return nil }; return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "flt ":
            guard bytes.count == 4 else { return nil }
            let bits = bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
            let value = Double(Float(bitPattern: bits)); return value.isFinite ? value : nil
        default: return nil
        }
    }
}
final class SMC {
    private var connection: io_connect_t = 0
    private var info: [String: SMCKeyData_t.keyInfo_t] = [:]
    init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw FanError("未找到 AppleSMC；此设备可能不支持读取风扇") }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw FanError("无法打开 AppleSMC：\(result)") }
    }
    deinit { if connection != 0 { IOServiceClose(connection) } }
    private func call(_ input: SMCKeyData_t) throws -> SMCKeyData_t {
        var input = input, output = SMCKeyData_t()
        var length = MemoryLayout<SMCKeyData_t>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, length, &output, &length)
        guard result == KERN_SUCCESS, output.result == 0 else {
            throw FanError("SMC 拒绝操作（IO \(result)，SMC \(output.result)）")
        }
        return output
    }
    private func code(_ key: String) throws -> UInt32 {
        guard key.utf8.count == 4 else { throw FanError("无效的 SMC 键") }
        return key.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private func string(_ code: UInt32) -> String {
        String(bytes: [24,16,8,0].map { UInt8((code >> $0) & 255) }, encoding: .ascii) ?? "????"
    }
    func read(_ key: String) throws -> SMCValue {
        var input = SMCKeyData_t(); input.key = try code(key)
        if info[key] == nil {
            input.data8 = 9
            let metadata = try call(input).keyInfo
            guard (1...32).contains(metadata.dataSize) else { throw FanError("无效的 SMC 数据长度") }
            info[key] = metadata
        }
        input.keyInfo = info[key]!; input.data8 = 5
        var output = try call(input)
        let bytes = withUnsafeBytes(of: &output.bytes) { Array($0.prefix(Int(input.keyInfo.dataSize))) }
        return SMCValue(type: string(input.keyInfo.dataType), bytes: bytes)
    }
    func number(_ key: String) -> Double? { (try? read(key))?.number }
    func keys() throws -> [String] {
        guard let count = number("#KEY"), count >= 0, count <= 20000 else { throw FanError("无法枚举传感器") }
        return (0..<Int(count)).compactMap { index in
            var input = SMCKeyData_t(); input.data8 = 8; input.data32 = UInt32(index)
            return (try? call(input)).map { string($0.key) }
        }
    }
    // Deliberately no general-purpose write API exposed to the IPC client.
    private func write(_ key: String, bytes: [UInt8]) throws {
        guard geteuid() == 0 else { throw FanError("调节风扇需要管理员授权") }
        let value = try read(key)
        guard bytes.count == value.bytes.count else { throw FanError("SMC 写入长度不匹配") }
        var input = SMCKeyData_t(); input.key = try code(key); input.data8 = 6
        input.keyInfo.dataSize = UInt32(bytes.count)
        withUnsafeMutableBytes(of: &input.bytes) { buffer in for (i, b) in bytes.enumerated() { buffer[i] = b } }
        _ = try call(input)
    }
    func modeKey(_ id: Int) -> String { (try? read("F\(id)md")) != nil ? "F\(id)md" : "F\(id)Md" }
    func mode(_ id: Int) -> Int? {
        if let value = number(modeKey(id)) { return Int(value) }
        if let mask = number("FS! ") { return Int(mask) & (1 << id) == 0 ? 0 : 1 }
        return nil
    }
    func setMode(_ id: Int, manual: Bool) throws {
        guard (0...9).contains(id) else { throw FanError("无效风扇编号") }
        let key = modeKey(id)
        if var value = try? read(key), value.type == "ui8 ", value.bytes.count == 1 {
            value.bytes[0] = manual ? 1 : 0
            try write(key, bytes: value.bytes)
        } else if let mask = number("FS! ") {
            let updated = manual ? Int(mask) | (1 << id) : Int(mask) & ~(1 << id)
            try write("FS! ", bytes: [UInt8((updated >> 8) & 255), UInt8(updated & 255)])
        } else { throw FanError("此机型未提供受支持的风扇模式接口") }
        for i in 0...12 {
            let observed = mode(id)
            if manual ? observed == 1 : (observed == 0 || observed == 3) { return }
            if i < 12 { usleep(100_000) }
        }
        throw FanError("固件未确认模式切换；已请求恢复系统控制")
    }
    func setTarget(_ id: Int, rpm: Double) throws {
        guard (0...9).contains(id), rpm.isFinite, rpm >= 0, rpm <= 16000 else { throw FanError("无效转速") }
        let key = "F\(id)Tg", value = try read(key)
        let bytes: [UInt8]
        if value.type == "flt ", value.bytes.count == 4 {
            let bits = Float(rpm).bitPattern
            bytes = [0,8,16,24].map { UInt8((bits >> $0) & 255) }
        } else if value.type == "fpe2", value.bytes.count == 2 {
            let raw = UInt16((rpm * 4).rounded()); bytes = [UInt8(raw >> 8), UInt8(raw & 255)]
        } else { throw FanError("不支持此风扇的转速编码：\(value.type)") }
        try write(key, bytes: bytes)
        for i in 0...12 {
            if let confirmed = number(key), abs(confirmed - rpm) <= 5 { return }
            if i < 12 { usleep(100_000) }
        }
        throw FanError("目标转速读回不一致")
    }
}
extension SMC {
    func unlockThermalManager() throws {
        #if arch(arm64)
        guard let value = try? read("Ftst"), value.bytes.count == 1, value.bytes[0] == 0 else {
            throw FanError("固件不允许切换自定义控制，或已有其他工具控制风扇")
        }
        try write("Ftst", bytes: [1])
        usleep(2_500_000)
        #else
        throw FanError("风扇模式写入被固件拒绝")
        #endif
    }
    func clearAutomaticTarget(_ id: Int) throws {
        #if arch(arm64)
        let key = "F\(id)Tg", value = try read(key)
        guard value.type == "flt ", value.bytes.count == 4 else { throw FanError("未知的自动转速编码") }
        // Zero means remove the requested target only after automatic mode is set.
        try write(key, bytes: [0,0,0,0])
        #endif
    }
    func restoreThermalManager() throws {
        #if arch(arm64)
        try write("Ftst", bytes: [0])
        guard number("Ftst") == 0 else { throw FanError("系统热管理恢复尚未确认") }
        #endif
    }
}
