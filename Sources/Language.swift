import Foundation

enum AppLanguage {
    static let choices = ["system", "zh-Hans", "en"]
    private static let testing = !Set(CommandLine.arguments).isDisjoint(with: ["--demo", "--ui-test", "--self-test"])
    private static var demoChoice = "system"
    static var choice: String {
        get {
            if testing { return demoChoice }
            let saved = UserDefaults.standard.string(forKey: "interfaceLanguage") ?? "system"
            return choices.contains(saved) ? saved : "system"
        }
        set {
            guard choices.contains(newValue) else { return }
            if testing { demoChoice = newValue }
            else { UserDefaults.standard.set(newValue, forKey: "interfaceLanguage") }
        }
    }
    static var english: Bool {
        let identifier = choice == "system" ? Locale.preferredLanguages.first ?? "en" : choice
        return !identifier.lowercased().hasPrefix("zh")
    }
    static var locale: Locale { Locale(identifier: english ? "en" : "zh-Hans") }
    static var names: [String] { [english ? "System default" : "跟随系统", "简体中文", "English"] }
}

// Fixed UI labels and fragments of hardware messages sent across process boundaries.
private let englishText: [String: String] = [
    "：": ": ",
    "，": ", ",
    "）": ")",
    "SMC 写入长度不匹配": "SMC write length mismatch",
    "SMC 拒绝操作（IO": "SMC rejected operation (IO",
    "SMC 最高读数": "Highest SMC reading",
    "SMC 温度读数": "SMC temperature",
    "不安全的控制会话目录": "Unsafe control session directory",
    "不支持此风扇的转速编码：": "Unsupported fan speed encoding: ",
    "之间的整数 RPM": " RPM (whole numbers)",
    "刷新": "Refresh",
    "另一个工具正在控制风扇，请先恢复自动模式": "Another app controls the fans. Restore automatic mode first.",
    "右侧风扇": "Right fan",
    "固件不允许切换自定义控制，或已有其他工具控制风扇": "Firmware refused manual control or another app owns the fans.",
    "固件未确认模式切换；已请求恢复系统控制": "Firmware did not confirm the mode. System control requested.",
    "圆环": "Ring",
    "外部手动控制": "External control",
    "左侧风扇": "Left fan",
    "已恢复系统控制": "System control restored",
    "已恢复系统自动": "System control restored",
    "已恢复系统自动调节": "System fan control restored",
    "已有手动控制，请先在原工具恢复自动并退出": "Another app controls the fans. Restore automatic control there first.",
    "已有风度控制会话运行": "A Fengdu control session is already running.",
    "当前：": "Mode: ",
    "恢复系统": "Restore Auto",
    "恢复系统控制失败，将继续重试：": "Could not restore system control. Retrying: ",
    "手动调速 · 输入目标后按回车": "Manual speed · Press Return to apply",
    "手动转速": "Manual RPM",
    "手动转速已写入并读回；实际 RPM 持续监测": "Target confirmed. Monitoring actual RPM.",
    "按温度曲线自动调节 · 每 2 秒更新": "Following the fan curve · Updates every 2 seconds",
    "授权未完成，未更改风扇控制": "Authorization cancelled. Fan control was not changed.",
    "控制模式发生变化，已恢复系统自动": "Control mode changed. System control restored.",
    "控制消息超出长度限制": "Control message too large",
    "控制连接写入失败": "Could not write to control connection",
    "控制连接已中断或超时": "Control connection interrupted or timed out",
    "控制连接超时或电脑休眠，已恢复系统自动": "Connection expired or Mac slept. System control restored.",
    "散热风扇": "Cooling fan",
    "无效的 SMC 数据长度": "Invalid SMC data length",
    "无效的 SMC 键": "Invalid SMC key",
    "无效的会话用户": "Invalid session user",
    "无效转速": "Invalid RPM",
    "无效风扇编号": "Invalid fan number",
    "无法保护会话目录": "Could not secure session directory",
    "无法创建控制连接": "Could not create control connection",
    "无法创建本地控制服务": "Could not create local service",
    "无法建立受保护的本地控制服务": "Could not start secure control service",
    "无法打开 AppleSMC：": "Could not open AppleSMC: ",
    "无法打开控制会话目录": "Could not open session directory",
    "无法枚举传感器": "Could not enumerate sensors",
    "无法读取风扇数量；此 Mac 暂不支持": "Cannot read fan count. This Mac may be unsupported.",
    "无法进入控制会话目录": "Could not enter session directory",
    "无风扇 Mac 或不受支持的机型无法调节。": "Fan control requires a supported Mac with a fan.",
    "显示内容": "Show in menu bar",
    "显示目标转速": "Show target RPM",
    "显示风扇图标": "Show fan icon",
    "暂不可用": "Unavailable",
    "未发现可用风扇": "No controllable fans",
    "未发现风扇；无风扇 Mac 无法调节转速": "No fans detected. Fanless Macs do not support speed control.",
    "未找到 AppleSMC；此设备可能不支持读取风扇": "AppleSMC not found. Fan readings may be unsupported.",
    "未知指令": "Unknown command",
    "未知的自动转速编码": "Unknown automatic speed encoding",
    "未知风扇": "Unknown fan",
    "模拟写入失败": "Simulated write failed",
    "模拟恢复失败": "Simulated restore failed",
    "模拟设备": "Simulated device",
    "正在处理，请稍候…": "Working…",
    "正在恢复系统控制": "Restoring system control",
    "正在恢复系统控制，请稍候": "Restoring system control. Please wait.",
    "正在读取真实风扇与温度…": "Reading fans and temperature…",
    "此机型未提供受支持的风扇模式接口": "This Mac does not expose a supported fan control interface.",
    "温度不可用或过高，无法启用温度曲线": "Temperature is unavailable or too high for a fan curve.",
    "温度不可用；仍可手动调速，温度曲线暂不可用": "Temperature unavailable. Manual control is available; fan curves need a reading.",
    "温度曲线": "Fan curve",
    "温度曲线参数无效；起点与满速温度至少相差 10°C": "Invalid curve. Leave at least 10°C between start and full speed.",
    "温度过高或不可用，已恢复系统自动": "Temperature too high or unavailable. System control restored.",
    "满速温度": "Full speed",
    "满速温度至少比起调温度高 10°C": "Full-speed temperature must be at least 10°C above the start.",
    "演示": "Demo",
    "点选要显示的区域，至少保留一项": "Select at least one item to show",
    "登录系统时启动": "Open at login",
    "目标 RPM，输入后按回车": " target RPM. Press Return to apply.",
    "目标转速": " target RPM",
    "目标转速读回不一致": "Target RPM readback mismatch",
    "系统报告较高热压力，已恢复系统自动": "High thermal pressure. System control restored.",
    "系统热压力较高，请保持系统自动调节": "High thermal pressure. Use system control.",
    "系统热管理恢复尚未确认": "System thermal control not yet confirmed",
    "系统自动": "System auto",
    "系统自动调节": "System fan control",
    "自动模式未确认": "automatic mode not confirmed",
    "芯片温度": "Chip temperature",
    "范围": "Range",
    "菜单栏样式": "Menu bar style",
    "请输入": "Enter",
    "读取中": "Reading…",
    "读取或写入失败，已请求恢复系统控制": "Could not read or write fan settings. System control requested.",
    "读数过期": "Stale reading",
    "调节失败，已请求恢复系统控制": "Adjustment failed. System control requested.",
    "调节模式": "Control mode",
    "调节风扇需要管理员授权": "Fan control requires administrator approval.",
    "起调温度": "Start temp",
    "跑道": "Track",
    "转速必须在每个风扇的允许范围内": "Target RPM must be within each fan’s limits.",
    "辅助控制程序尚未连接，请先授权": "Helper not connected. Authorize control first.",
    "辅助控制程序需要管理员权限": "The helper requires administrator privileges.",
    "辅助程序无法启动，请确认没有另一个风度控制会话": "Could not start the helper. Check for another Fengdu session.",
    "辅助程序未返回有效读数": "Helper returned an invalid reading",
    "辅助程序身份验证失败": "Helper identity check failed",
    "输入后按回车": "Press Return to apply",
    "输入目标 RPM，按回车生效": "Enter target RPM and press Return",
    "退出": "Quit",
    "通信路径过长": "Connection path too long",
    "预览渲染失败": "Preview rendering failed",
    "风度": "Fengdu",
    "风扇": "Fan",
    "风扇模式写入被固件拒绝": "Firmware refused the fan mode change",
    "风扇读数不可用": "Fan readings unavailable",
    "风扇读数失效，已恢复系统自动": "Fan readings lost. System control restored.",
    "首个风扇的目标转速；AUTO 表示自动调节": "First fan target RPM. AUTO means automatic control.",
    "默认：": "Auto: ",
]
private let fragments = try! NSRegularExpression(pattern: englishText.keys
    .sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))

func tr(_ text: String) -> String {
    guard AppLanguage.english else { return text }
    if let value = englishText[text] { return value }
    let source = text as NSString
    let matches = fragments.matches(in: text, range: NSRange(location: 0, length: source.length))
    guard !matches.isEmpty else { return text }
    let result = NSMutableString(string: text)
    for m in matches.reversed() {
        if let translated = englishText[source.substring(with: m.range)] {
            result.replaceCharacters(in: m.range, with: translated)
        }
    }
    return result as String
}
