import AppKit

final class FlippedView: NSView { override var isFlipped: Bool { true }; override var acceptsFirstResponder: Bool { true } }
func icon(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }
func quoteShell(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func statusIcon(_ state: Snapshot, stale: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 26, height: 24))
    image.lockFocus()
    let fraction = targetFraction(state,stale:stale)
    for (alpha, sweep) in [(0.25,296.0),(1.0,(fraction ?? 0)*296)] where sweep > 0 {
        NSColor.black.withAlphaComponent(alpha).setStroke()
        let path = NSBezierPath(); path.lineWidth = 2.4; path.lineCapStyle = .round
        path.appendArc(withCenter: NSPoint(x: 13,y: 12),radius: 10.7,startAngle: 238,endAngle: 238-sweep,clockwise: true); path.stroke()
    }
    icon("fanblades.fill")?.draw(in:NSRect(x:6.5,y:5.5,width:13,height:13))
    image.unlockFocus(); image.isTemplate = true; return image
}
final class FanApp: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let demo: Bool
    let worker = DispatchQueue(label:"io.github.fengdu.io")
    let popover = NSPopover()
    let status = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    var hardware: FanHardware?
    var demoEngine: ControlEngine?
    var sessionDirectory: String?
    var snapshot = Snapshot(message:"正在读取真实风扇与温度…")
    var stale = false, busy = false, closed = false
    var selection: String { snapshot.mode }
    var refreshing = false, revision = 0
    var inputs: [Int:NSTextField] = [:]
    var timer: Timer?
    var content = FlippedView()
    var material = NSVisualEffectView()
    var rows: [Int:(NSSlider,NSTextField,NSTextField)] = [:]
    var buttons: [String:NSButton] = [:]
    var messageLabel = NSTextField(labelWithString:"")
    var tempLabel = NSTextField(labelWithString:"")
    var modeLabel = NSTextField(labelWithString:"")
    var detailLabel = NSTextField(labelWithString:"")
    var style: IndicatorStyle = .ring
    // Bits 0/1 correspond to the two independently selectable preview regions.
    var visibleParts = 3
    var previewButtons: [NSButton] = []
    var stylePicker = NSSegmentedControl()
    var systemButton = NSButton()
    var lowField = NSPopUpButton(), highField = NSPopUpButton()
    var preferredLow = 50.0, preferredHigh: Double?
    var appliedLow: Double?, appliedHigh: Double?
    var high: Double? {
        if selection == "curve", let appliedHigh { return appliedHigh }
        return preferredHigh ?? snapshot.temperature.map { $0.rounded() + 20 }
    }
    var low: Double {
        if selection == "curve", let appliedLow { return appliedLow }
        return min(preferredLow, (high ?? 145) - 10)
    }
    func syncThresholds() {
        let lo = Int(low)
        if lowField.item(withTitle:"\(lo)°C") == nil { lowField.addItem(withTitle:"\(lo)°C") }
        lowField.selectItem(withTitle:"\(lo)°C")
        let suggested = snapshot.temperature.map { $0.rounded() + 20 }
        let autoValue = selection == "curve" && preferredHigh == nil ? appliedHigh : suggested
        let title = autoValue.map { "\(Int($0))°C" } ?? "—"
        highField.item(at:0)?.title = "默认：" + title
        if let custom = preferredHigh { highField.selectItem(withTitle:"\(Int(custom))°C") }
        else { highField.selectItem(at:0) }
    }
    var rowIDs: [Int] = []
    var preview = false
    init(demo: Bool) { self.demo = demo; super.init() }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        status.button?.target = self; status.button?.action = #selector(toggle)
        if !demo {
            let savedParts = UserDefaults.standard.integer(forKey:"indicatorParts")
            visibleParts = (1...3).contains(savedParts) ? savedParts : 3
            style = IndicatorStyle(rawValue: UserDefaults.standard.string(forKey:"indicatorStyle") ?? "") ?? .ring
            preferredHigh = UserDefaults.standard.object(forKey:"curveHigh") as? Double
            preferredLow = UserDefaults.standard.object(forKey:"curveLow") as? Double ?? 50
        }
        popover.delegate = self
        popover.behavior = .transient; popover.animates = true
        let vc = NSViewController(); popover.contentViewController = vc
        build(); update()
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(show),name:NSNotification.Name("io.github.fengdu.show"),object:nil)
        timer = Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.refresh() }
        refresh()
        if !CommandLine.arguments.contains("--background") { show() }
    }
    @discardableResult func label(_ text:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ size:CGFloat = 13,_ bold:Bool = false,_ secondary:Bool = false,_ h:CGFloat = 22) -> NSTextField {
        let view = NSTextField(labelWithString:text); view.frame = NSRect(x:x,y:y,width:w,height:h)
        view.font = .systemFont(ofSize:size,weight:bold ? .semibold : .regular)
        view.textColor = secondary ? .secondaryLabelColor : .labelColor
        view.maximumNumberOfLines = h > 24 ? 3 : 1; view.lineBreakMode = h > 24 ? .byWordWrapping : .byTruncatingTail
        content.addSubview(view); return view
    }
    func glyph(_ name:String,_ x:CGFloat,_ y:CGFloat,_ size:CGFloat = 22) {
        let v = NSImageView(frame:NSRect(x:x,y:y,width:size,height:size)); v.image = icon(name); v.contentTintColor = .secondaryLabelColor; content.addSubview(v)
    }
    func divider(_ y:CGFloat) { let v = NSBox(frame:NSRect(x:18,y:y,width:324,height:1)); v.boxType = .separator; content.addSubview(v) }
    @discardableResult func button(_ text:String,_ action:Selector,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat) -> NSButton {
        let b = NSButton(title:text,target:self,action:action); b.bezelStyle = .rounded; b.font = .systemFont(ofSize:12)
        b.frame = NSRect(x:x,y:y,width:w,height:28); content.addSubview(b); return b
    }
    func build() {
        rowIDs = snapshot.fans.map(\.id)
        let rowHeight = CGFloat(max(1,rowIDs.count))*92, height = 430+rowHeight
        material = NSVisualEffectView(frame:NSRect(x:0,y:0,width:360,height:min(height,700)))
        material.material = .popover; material.blendingMode = .behindWindow; material.state = .active
        let scroll = NSScrollView(frame:material.bounds); scroll.drawsBackground = false; scroll.hasVerticalScroller = height > 700; scroll.autohidesScrollers = true
        content = FlippedView(frame:NSRect(x:0,y:0,width:360,height:height)); scroll.documentView = content; material.addSubview(scroll)
        glyph("fanblades",20,18); label(demo ? "风度 · 演示" : "风度",54,17,200,17,true)
        let v = label("v\(appVersion)",275,21,65,11,false,true); v.alignment = .right
        divider(54)
        glyph("thermometer.medium",20,71)
        label("芯片温度",54,68,180,13,true)
        tempLabel = label("—",243,67,97,19,true); tempLabel.alignment = .right
        detailLabel = label("SMC 温度读数",54,94,286,10,false,true)
        divider(120)
        rows.removeAll(); inputs.removeAll()
        for (index, fan) in snapshot.fans.enumerated() {
            let y = 135 + CGFloat(index)*92
            glyph("fanblades",20,y+1); label(fan.name,54,y,160,14,true)
            let rpm = label("— RPM",209,y,131,16,true); rpm.alignment = .right
            let details = label("",54,y+27,286,10,false,true)
            let input = NSTextField(frame:NSRect(x:268,y:y+46,width:72,height:24))
            input.tag = fan.id; input.alignment = .right; input.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
            input.target = self; input.action = #selector(enterRPM(_:)); input.cell?.sendsActionOnEndEditing = false
            input.setAccessibilityLabel(fan.name+"目标 RPM，输入后按回车"); input.toolTip = "输入目标 RPM，按回车生效"
            inputs[fan.id] = input; content.addSubview(input)
            let slider = NSSlider(value:fan.rpm ?? fan.safeMinimum,minValue:fan.safeMinimum,maxValue:max(fan.safeMinimum+1,fan.maximum ?? 6000),target:self,action:#selector(slide(_:)))
            slider.frame = NSRect(x:54,y:y+48,width:286,height:22); slider.tag = fan.id; slider.isContinuous = false
            slider.setAccessibilityLabel(fan.name+"目标转速")
            content.addSubview(slider); rows[fan.id] = (slider,rpm,details); divider(y+79)
        }
        if snapshot.fans.isEmpty { label("未发现可用风扇",54,143,286,14,true); label("无风扇 Mac 或不受支持的机型无法调节。",54,174,286,11,false,true,36) }
        let y = 120+rowHeight
        label("调节模式",20,y+14,100,12,true)
        modeLabel = label("",125,y+14,215,11,false,true); modeLabel.alignment = .right
        buttons.removeAll()
        for (i,pair) in [("system","系统自动"),("manual","手动转速"),("curve","温度曲线")].enumerated() {
            let b = button(pair.1,#selector(selectMode(_:)),18+CGFloat(i)*109,y+41,106); b.identifier = NSUserInterfaceItemIdentifier(pair.0); b.setButtonType(.pushOnPushOff); buttons[pair.0] = b
        }
        label("起调温度",20,y+83,64,11,false,true)
        lowField = NSPopUpButton(frame:NSRect(x:82,y:y+76,width:83,height:28),pullsDown:false)
        lowField.addItems(withTitles:[35,40,45,50,55,60,65].map { "\($0)°C" }); lowField.selectItem(withTitle:"\(Int(low))°C"); lowField.target = self; lowField.action = #selector(curveChanged); content.addSubview(lowField)
        label("满速温度",170,y+83,60,11,false,true)
        highField = NSPopUpButton(frame:NSRect(x:229,y:y+76,width:111,height:28),pullsDown:false)
        highField.addItem(withTitle:"默认：—"); highField.addItems(withTitles:[65,70,75,80,85].map { "\($0)°C" }); highField.target = self; highField.action = #selector(curveChanged); content.addSubview(highField)
        messageLabel = label("",20,y+115,320,11,false,true,38)
        divider(y+157)
        label("菜单栏样式",20,y+170,110,12,true)
        stylePicker = NSSegmentedControl(labels:["圆环","跑道"],trackingMode:.selectOne,target:self,action:#selector(changeStyle(_:)))
        stylePicker.frame = NSRect(x:172,y:y+164,width:168,height:27)
        stylePicker.setAccessibilityLabel("菜单栏样式"); stylePicker.selectedSegment = style == .track ? 1 : 0
        content.addSubview(stylePicker)
        label("显示内容",20,y+208,100,12,true)
        previewButtons = [button("",#selector(togglePart(_:)),172,y+201,52),
                          button("",#selector(togglePart(_:)),225,y+201,115)]
        for (idx,b) in previewButtons.enumerated() {
            b.tag = 1 << idx; b.setButtonType(.pushOnPushOff)
            b.isBordered = false; b.wantsLayer = true; b.layer?.cornerRadius = 6
            b.setAccessibilityLabel(idx == 0 ? "显示风扇图标" : "显示目标转速")
            b.toolTip = "点选要显示的区域，至少保留一项"
        }
        previewButtons[0].image = icon("fanblades.fill")
        divider(y+247)
        button("刷新",#selector(refreshClick),18,y+262,96)
        systemButton = button("恢复系统",#selector(restore),122,y+262,112)
        button("退出",#selector(quit),242,y+262,100)
        popover.contentViewController?.view = material; popover.contentSize = material.frame.size
    }
    @objc func changeStyle(_ sender:NSSegmentedControl) {
        style = sender.selectedSegment == 1 ? .track : .ring
        if !demo { UserDefaults.standard.set(style.rawValue,forKey:"indicatorStyle") }
        update()
    }
    @objc func togglePart(_ sender:NSButton) {
        let next = visibleParts ^ sender.tag
        if next != 0 {
            visibleParts = next
            if !demo { UserDefaults.standard.set(next,forKey:"indicatorParts") }
        }
        update()
    }
    func update() {
        if rowIDs != snapshot.fans.map(\.id) { build() }
        let reading: String
        if stale || snapshot.fans.isEmpty || selection == "recovering" { reading = "—" }
        else if selection == "curve" || (selection == "system" && snapshot.fans.allSatisfy({ [0,3].contains($0.mode ?? -1) })) { reading = "AUTO" }
        else if ["manual","external"].contains(selection), let rpm = snapshot.fans.first?.target { reading = "\(Int(rpm.rounded())) RPM" }
        else { reading = "—" }
        let display = (demo ? "演示 " : "") + reading
        let fanVisible = visibleParts & 1 != 0, speedVisible = visibleParts & 2 != 0
        for b in previewButtons {
            let selected = visibleParts & b.tag != 0
            b.state = selected ? .on : .off
            b.layer?.backgroundColor = (selected ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
            b.contentTintColor = selected ? .white : .secondaryLabelColor
            if b.tag == 2 { b.title = reading }
        }
        if style == .track {
            status.button?.title = !speedVisible && demo ? " 演示" : ""
            status.button?.image = trackIcon(reading:display,fraction:targetFraction(snapshot,stale:stale),showFan:fanVisible,showSpeed:speedVisible)
            status.button?.imagePosition = !speedVisible && demo ? .imageLeading : .imageOnly
        } else {
            status.button?.image = fanVisible ? statusIcon(snapshot,stale:stale) : nil
            status.button?.title = speedVisible ? (fanVisible ? " · " : "") + display : (demo ? " 演示" : "")
            status.button?.imagePosition = !fanVisible ? .noImage : (speedVisible || demo ? .imageLeading : .imageOnly)
        }
        status.button?.setAccessibilityLabel("风度 · " + display)
        status.button?.font = .monospacedDigitSystemFont(ofSize:12,weight:.semibold)
        status.button?.toolTip = "风度：首个风扇的目标转速；AUTO 表示自动调节"
        tempLabel.stringValue = stale ? "—" : snapshot.temperature.map { String(format:"%.0f°C",$0) } ?? "—"
        detailLabel.stringValue = "SMC 最高读数" + (snapshot.sensor.map { " · \($0)" } ?? " · 暂不可用")
        let modes = ["system":"当前：系统自动","manual":"当前：手动转速","curve":"当前：温度曲线","external":"当前：外部手动控制","recovering":"正在恢复系统控制"]
        modeLabel.stringValue = modes[snapshot.mode] ?? "读取中"
        for fan in snapshot.fans {
            guard let (slider,value,details) = rows[fan.id] else { continue }
            let target = fan.target ?? fan.safeMinimum
            let manual = selection == "manual"
            slider.frame.size.width = manual ? 205 : 286
            slider.doubleValue = target; slider.isEnabled = manual && fan.controllable && !busy && !stale
            if let input = inputs[fan.id] {
                input.isHidden = !manual; input.isEnabled = slider.isEnabled
                if input.currentEditor() == nil { input.stringValue = fan.target.map { String(Int($0.rounded())) } ?? "" }
            }
            value.stringValue = stale ? "读数过期" : fan.rpm.map { "\(Int($0.rounded())) RPM" } ?? "— RPM"
            details.stringValue = "范围 \(Int(fan.safeMinimum))–\(Int(fan.maximum ?? 0)) RPM" + (manual ? " · 输入后按回车" : "")
        }
        for (key,b) in buttons {
            b.state = selection == key ? .on : .off; b.isEnabled = canSelect(key)
            b.bezelColor = selection == key ? .controlAccentColor : nil
            b.image = selection == key ? icon("checkmark.circle.fill") : nil
            b.imagePosition = .imageLeading
            b.contentTintColor = selection == key ? .controlAccentColor : nil
        }
        lowField.isEnabled = selection == "curve" && !busy; highField.isEnabled = selection == "curve" && !busy
        syncThresholds()
        systemButton.isEnabled = !busy && (snapshot.controlled || sessionDirectory != nil || demo)
        messageLabel.stringValue = (demo ? "模拟设备 · " : "") + (busy ? "正在处理，请稍候…" : snapshot.message)
        messageLabel.textColor = snapshot.error ? .systemOrange : .secondaryLabelColor
    }
    func receive(_ state:Snapshot) {
        snapshot = state; stale = false; busy = false; update()
    }
    func fail(_ error:Error, stale:Bool = false) {
        busy = false; self.stale = stale; snapshot.message = error.localizedDescription; snapshot.error = true; update()
    }
    func refresh() {
        guard !busy && !closed && !refreshing else { return }; refreshing = true
        let ticket = revision
        let directory = sessionDirectory
        worker.async {
            do {
                let state: Snapshot
                if self.demo {
                    if self.demoEngine == nil { self.demoEngine = ControlEngine(DemoHardware()) }
                    state = try self.demoEngine!.command(Command(action:"status"))
                } else if let dir = directory {
                    state = try request(Command(action:"status"),path:dir+"/control.sock")
                } else {
                    if self.hardware == nil { self.hardware = try MacHardware() }
                    state = try self.hardware!.snapshot()
                }
                DispatchQueue.main.async { self.refreshing = false; if ticket == self.revision { self.receive(state) } }
            } catch { DispatchQueue.main.async {
                self.refreshing = false; guard ticket == self.revision else { return }
                if directory != nil { self.sessionDirectory = nil }
                self.fail(error,stale:true)
            } }
        }
    }
    func canSelect(_ mode:String) -> Bool {
        guard !busy, !stale, !snapshot.fans.isEmpty, selection != "external", selection != "recovering" else { return false }
        return mode == "system" || (snapshot.fans.allSatisfy { $0.controllable } && (mode != "curve" || (snapshot.temperature.map { $0 < 90 } ?? false)))
    }
    func manualCommand(changing id:Int? = nil,to rpm:Double = 0) -> Command {
        var targets = [String:Double]()
        for f in snapshot.fans {
            targets[String(f.id)] = f.id == id ? rpm : min(f.maximum ?? f.safeMinimum,max(f.safeMinimum,(f.target ?? f.rpm ?? f.safeMinimum).rounded()))
        }
        return Command(action:"manual",targets:targets)
    }
    @objc func selectMode(_ sender:NSButton) {
        guard let mode = sender.identifier?.rawValue, canSelect(mode), mode != selection else { update(); return }
        perform(mode == "manual" ? manualCommand() : Command(action:mode,low:low,high:high))
    }
    @objc func slide(_ sender:NSSlider) {
        guard selection == "manual", canSelect("manual") else { return }
        perform(manualCommand(changing:sender.tag,to:sender.doubleValue.rounded()))
    }
    @objc func enterRPM(_ sender:NSTextField) {
        guard selection == "manual", canSelect("manual"), let f = snapshot.fans.first(where:{ $0.id == sender.tag }) else { return }
        let text = sender.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(text),
              Double(n) >= f.safeMinimum, Double(n) <= (f.maximum ?? 0) else {
            fail(FanError("请输入 \(Int(ceil(f.safeMinimum)))–\(Int(floor(f.maximum ?? 0))) 之间的整数 RPM")); sender.selectText(nil); return
        }
        sender.window?.makeFirstResponder(nil)
        perform(manualCommand(changing:f.id,to:Double(n)))
    }
    @objc func curveChanged() {
        guard selection == "curve", !busy else { return }
        let lo = Double(lowField.titleOfSelectedItem!.replacingOccurrences(of:"°C",with:""))!
        let custom = highField.indexOfSelectedItem == 0 ? nil : Double(highField.titleOfSelectedItem!.replacingOccurrences(of:"°C",with:""))
        let defaultValue = preferredHigh == nil ? appliedHigh : snapshot.temperature.map { $0.rounded()+20 }
        guard let hi = custom ?? defaultValue, hi-lo >= 10 else {
            syncThresholds(); fail(FanError("满速温度至少比起调温度高 10°C")); return
        }
        perform(Command(action:"curve",low:lo,high:hi),onSuccess:{
            self.preferredLow = lo; self.preferredHigh = custom
            if !self.demo {
                UserDefaults.standard.set(lo,forKey:"curveLow")
                if let custom { UserDefaults.standard.set(custom,forKey:"curveHigh") }
                else { UserDefaults.standard.removeObject(forKey:"curveHigh") }
            }
        })
    }
    func authorize() throws -> String {
        let dir = "/private/tmp/fengdu-"+UUID().uuidString
        try FileManager.default.createDirectory(atPath:dir,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let executable = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let shell = quoteShell(executable)+" --helper "+quoteShell(dir)+" \(getuid()) >/dev/null 2>&1 &"
        let script = "do shell script \""+shell.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\" with administrator privileges"
        let p = Process(); p.executableURL = URL(fileURLWithPath:"/usr/bin/osascript"); p.arguments = ["-e",script]
        let pipe = Pipe(); p.standardError = pipe; p.standardOutput = FileHandle.nullDevice; try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { try? FileManager.default.removeItem(atPath:dir); throw FanError("授权未完成，未更改风扇控制") }
        for _ in 0..<40 {
            if (try? request(Command(action:"status"),path:dir+"/control.sock")) != nil { return dir }
            Thread.sleep(forTimeInterval:0.1)
        }
        throw FanError("辅助程序无法启动，请确认没有另一个风度控制会话")
    }
    func perform(_ command:Command, onSuccess:(()->Void)? = nil, completion:(()->Void)? = nil) {
        guard !busy else { return }; revision += 1; busy = true; update()
        let directory = sessionDirectory
        worker.async {
            do {
                let state:Snapshot
                if self.demo {
                    if self.demoEngine == nil { self.demoEngine = ControlEngine(DemoHardware()) }
                    state = try self.demoEngine!.command(command)
                } else if directory == nil && ["system","quit"].contains(command.action) {
                    if self.hardware == nil { self.hardware = try MacHardware() }; state = try self.hardware!.snapshot()
                } else {
                    let dir = try directory ?? self.authorize()
                    DispatchQueue.main.async { self.sessionDirectory = dir }
                    state = try request(command,path:dir+"/control.sock")
                }
                DispatchQueue.main.async { if command.action == "curve" { self.appliedLow = command.low; self.appliedHigh = command.high }; onSuccess?(); self.receive(state); completion?() }
            } catch { DispatchQueue.main.async { self.fail(error); completion?() } }
        }
    }
    @objc func refreshClick() { refresh() }
    @objc func restore() { perform(Command(action:"system")) }
    @objc func willSleep() {
        // A queued command cannot survive sleep: helper independently checks the time gap/lease.
        if !busy { restore() }
    }
    @objc func toggle() { if popover.isShown { popover.performClose(nil) } else { show() } }
    func popoverDidShow(_ notification: Notification) {
        guard let window = content.window else { return }
        window.initialFirstResponder = content
        window.makeFirstResponder(content)
    }
    @objc func show() { NSApp.activate(ignoringOtherApps:true); if let b = status.button { popover.show(relativeTo:b.bounds,of:b,preferredEdge:.minY) } }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { show(); return true }
    @objc func quit() {
        guard !busy else { return }
        timer?.invalidate()
        perform(Command(action:"quit"),completion:{ self.closed = true; NSApp.terminate(nil) })
    }
    func applicationWillTerminate(_ notification:Notification) {
        timer?.invalidate()
        // Synchronous normal-quit restoration; watchdog also handles force-quit/disconnection.
        if let dir = sessionDirectory { _ = try? request(Command(action:"quit"),path:dir+"/control.sock") }
    }
    func render(to directory:String, live:Bool = false) throws {
        preview = true; NSApp.setActivationPolicy(.accessory); NSApp.activate(ignoringOtherApps:true)
        snapshot = try live ? MacHardware().snapshot() : DemoHardware().snapshot(); if !live { snapshot.mode = "manual"; snapshot.controlled = true; snapshot.message = "手动调速 · 输入目标后按回车" }
        popover.contentViewController = NSViewController(); build(); update()
        for (name,appearance) in [("light",NSAppearance.Name.aqua),("dark",NSAppearance.Name.darkAqua)] {
            material.appearance = NSAppearance(named:appearance)
            let window = NSWindow(contentRect:material.frame,styleMask:[.titled],backing:.buffered,defer:false)
            window.isReleasedWhenClosed = false; window.contentView = material; window.appearance = material.appearance
            window.makeKeyAndOrderFront(nil); RunLoop.main.run(until:Date().addingTimeInterval(0.1)); update()
            window.displayIfNeeded(); material.layoutSubtreeIfNeeded()
            guard let rep = material.bitmapImageRepForCachingDisplay(in:material.bounds) else { throw FanError("预览渲染失败") }
            material.cacheDisplay(in:material.bounds,to:rep)
            try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory+"/fengdu-\(name).png"))
            window.orderOut(nil)
        }
    }
}
