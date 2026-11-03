import Foundation
import AppKit

func selfTests() throws {
    var count = 0
    func check(_ value: @autoclosure () -> Bool,_ name:String) throws {
        guard value() else { throw FanError("FAIL: "+name) }; count += 1
    }
    func rejected(_ action:() throws -> Void) throws {
        do { try action() } catch { count += 1; return }; throw FanError("Expected rejection")
    }
    try check(MemoryLayout<SMCKeyData_t>.stride == 80,"SMC ABI size")
    try check(SMCValue(type:"flt ",bytes:[0,0,128,63]).number == 1,"float decoding")
    try check(SMCValue(type:"fpe2",bytes:[0x25,0x80]).number == 2400,"fan decoding")
    try check(SMCValue(type:"ui8 ",bytes:[0]).number == 0,"zero fan mode")
    try check(SMCValue(type:"sp78",bytes:[0xff,0]).number == -1,"signed temperature")
    let h = DemoHardware(), engine = ControlEngine(h)
    let now = Date.timeIntervalSinceReferenceDate
    _ = try engine.command(Command(action:"status"))
    try check(h.state.fans.allSatisfy { $0.mode == 0 } && h.restored == 0,"read-only startup")
    try rejected { _ = try engine.command(Command(action:"manual",targets:["0":0,"1":2600])) }
    try rejected { _ = try engine.command(Command(action:"manual",targets:["0":99999,"1":2600])) }
    try rejected { _ = try engine.command(Command(action:"manual",targets:["0":2400])) }
    try rejected { _ = try engine.command(Command(action:"curve",low:60,high:65)) }
    try check(h.state.fans.allSatisfy { $0.mode == 0 },"validation before writes")
    _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200]))
    try check(engine.owned == [0,1] && h.state.fans[0].target == 3000,"manual command")
    h.state.temperature = 95; engine.tick()
    try check(engine.mode == "manual" && engine.owned == [0,1],"manual persists above 90 C")
    _ = try engine.command(Command(action:"manual",targets:["0":3500,"1":3400]))
    try check(h.state.fans[0].target == 3500,"manual accepts new hot target")
    try rejected { _ = try engine.command(Command(action:"curve",low:50,high:80)) }
    h.state.temperature = 50
    _ = try engine.command(Command(action:"curve",low:50,high:80))
    try check(h.state.fans[0].target == 1200,"curve lower bound")
    h.state.temperature = 80; engine.tick(now:now+2)
    try check(h.state.fans[0].target == 6000,"curve rises immediately")
    h.state.temperature = 50; engine.tick(now:now+4)
    try check(h.state.fans[0].target == 5800,"curve gradual fall")
    engine.tick(now:now+4.1)
    try check(h.state.fans[0].target == 5800,"duplicate poll does not accelerate descent")
    engine.tick(now:now+20)
    try check(engine.owned.isEmpty,"lost heartbeat restores")
    _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200]))
    h.state.temperature = nil; engine.tick()
    try check(engine.mode == "manual" && engine.owned == [0,1],"manual persists without temperature")
    _ = try engine.command(Command(action:"system"))
    _ = try engine.command(Command(action:"manual",targets:["0":3100,"1":3200]))
    try check(h.state.fans[0].target == 3100,"manual starts without sensor")
    h.state.temperature = 50; h.failWrite = true
    try rejected { _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200])) }
    try check(engine.owned.isEmpty && h.state.fans.allSatisfy { $0.mode == 0 },"partial write rollback")
    h.failWrite = false; h.state.fans[0].mode = 1
    try rejected { _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200])) }
    try check(h.state.fans[0].mode == 1,"does not take over another controller")
    h.state.fans[0].mode = 0
    _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200]))
    h.state.fans[1].mode = 0; engine.tick()
    try check(engine.owned.isEmpty,"external mode change restores")
    _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200]))
    _ = try engine.command(Command(action:"system"))
    try check(engine.owned.isEmpty && engine.mode == "system","system button restoration")
    _ = try engine.command(Command(action:"manual",targets:["0":3000,"1":3200]))
    h.failRestore = true; h.state.fans[0].rpm = nil; engine.tick()
    try check(!engine.owned.isEmpty && engine.mode == "recovering", "failed restoration remains owned for retries")
    h.failRestore = false; engine.tick()
    try check(engine.owned.isEmpty, "restoration retries succeed")
    try rejected { _ = try engine.command(Command(action:"arbitrary-smc-write")) }
    // Use an isolated directory so tests can never change the real login item.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let item = LoginItem(identifier: "io.github.fengdu.test", directory: directory)
    try item.setEnabled(true)
    let data = try Data(contentsOf: item.url)
    let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    guard item.enabled, plist?["RunAtLoad"] as? Bool == true,
          plist?["ProgramArguments"] as? [String] == [Bundle.main.executableURL!.path, "--background"] else {
        throw FanError("Invalid quiet login item")
    }
    try item.setEnabled(false)
    guard !item.enabled else { throw FanError("Could not remove login item") }
    print("PASS: \(count) safety/encoding checks; all hardware simulated")
}

func uiSelfTests() throws {
    let app = NSApplication.shared
    let panel = FanApp(demo:true)
    app.delegate = panel
    panel.applicationDidFinishLaunching(Notification(name:NSApplication.didFinishLaunchingNotification))
    func wait() throws {
        let deadline = Date().addingTimeInterval(5)
        while (panel.busy || panel.refreshing) && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.02)) }
        guard !panel.busy && !panel.refreshing else { throw FanError("UI worker timeout") }
    }
    defer { panel.timer?.invalidate(); panel.popover.close(); NSStatusBar.system.removeStatusItem(panel.status) }
    try wait()
    guard panel.rows.count == 2, panel.snapshot.demo else { throw FanError("UI demo discovery failed") }
    guard panel.status.button!.title.hasSuffix("AUTO") else { throw FanError("Missing system AUTO") }
    panel.buttons["manual"]!.performClick(nil); try wait()
    guard panel.snapshot.mode == "manual" else { throw FanError("One-click manual failed") }
    let input = panel.inputs[0]!
    input.stringValue = "3400"; _ = input.sendAction(input.action,to:input.target); try wait()
    guard panel.snapshot.fans[0].target == 3400, panel.snapshot.fans[1].target == 2600 else { throw FanError("Numeric RPM failed") }
    panel.snapshot.fans[0].rpm = 2150; panel.update()
    guard panel.status.button!.title.hasSuffix("3400 RPM") else { throw FanError("Displayed actual instead of target") }
    panel.stylePicker.selectedSegment = 1; _ = panel.stylePicker.sendAction(panel.stylePicker.action,to:panel.stylePicker.target)
    guard panel.style == .track, panel.status.button!.title.isEmpty,
          panel.status.button!.accessibilityLabel()?.hasSuffix("3400 RPM") == true,
          abs((targetFraction(panel.snapshot,stale:false) ?? 0) - 3400.0/6000) < 0.0001,
          panel.snapshot.mode == "manual" else { throw FanError("Target track display failed") }
    let fullWidth = panel.status.button!.image!.size.width
    panel.previewButtons[1].performClick(nil)
    guard panel.visibleParts == 1, panel.status.button!.image!.size.width < fullWidth else { throw FanError("Icon-only track failed") }
    panel.previewButtons[0].performClick(nil)
    guard panel.visibleParts == 1 && panel.previewButtons[0].state == .on else { throw FanError("Empty indicator allowed") }
    panel.previewButtons[1].performClick(nil); panel.previewButtons[0].performClick(nil)
    guard panel.visibleParts == 2, panel.status.button!.image!.size.width < fullWidth else { throw FanError("Speed-only track failed") }
    panel.stylePicker.selectedSegment = 0; _ = panel.stylePicker.sendAction(panel.stylePicker.action,to:panel.stylePicker.target)
    guard panel.status.button!.title.hasSuffix("3400 RPM") else { throw FanError("Ring toggle failed") }
    input.stringValue = "99999"; panel.enterRPM(input)
    guard !panel.busy, panel.snapshot.fans[0].target == 3400, panel.snapshot.error else { throw FanError("Invalid RPM accepted") }
    let slider = panel.rows[0]!.0; slider.doubleValue = 3250; panel.slide(slider); try wait()
    guard panel.snapshot.fans[0].target == 3250 else { throw FanError("Slider commit failed") }
    panel.popover.animates = false; panel.show()
    guard let win = input.window, win.makeFirstResponder(input), input.currentEditor() != nil else { throw FanError("RPM field not editable") }
    panel.update()
    guard input.currentEditor() != nil else { throw FanError("Refresh stole editing focus") }
    panel.popover.close(); panel.show(); RunLoop.main.run(until:Date().addingTimeInterval(0.15))
    guard input.currentEditor() == nil else { throw FanError("Reopen focused RPM field") }
    panel.demoEngine.flatMap { $0.hardware as? DemoHardware }?.state.temperature = 84
    panel.refresh(); try wait()
    guard panel.high == 104 else { throw FanError("Default not current +20") }
    panel.buttons["curve"]!.performClick(nil); try wait()
    guard panel.demoEngine?.high == 104 else { throw FanError("Helper did not apply dynamic default") }
    panel.demoEngine.flatMap { $0.hardware as? DemoHardware }?.state.temperature = 85
    panel.refresh(); try wait()
    guard panel.high == 104 else { throw FanError("Active threshold drifted") }
    panel.highField.selectItem(withTitle:"80°C"); panel.curveChanged(); try wait()
    guard panel.preferredHigh == 80, panel.demoEngine?.high == 80 else { throw FanError("Custom threshold lost") }
    guard panel.snapshot.mode == "curve", panel.status.button!.title.hasSuffix("AUTO") else { throw FanError("Curve UI failed") }
    panel.buttons["system"]!.performClick(nil); try wait()
    guard !panel.snapshot.controlled, panel.snapshot.mode == "system", input.isHidden else { throw FanError("Restore UI failed") }
    panel.fail(FanError("Test stale reading"),stale:true)
    guard !panel.buttons["manual"]!.isEnabled, panel.tempLabel.stringValue == "—" else { throw FanError("Stale UI protection failed") }
    print("PASS: one-click modes, numeric RPM validation, slider commit, confirmed target vs actual, AUTO and stale states (simulated)")
}
