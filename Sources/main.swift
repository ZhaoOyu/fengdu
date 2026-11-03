import AppKit
import Foundation

let arguments = CommandLine.arguments
func fatalMessage(_ error: Error) -> Never {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
}
do {
    if arguments.contains("--helper") || arguments.contains("--helper-demo") {
        guard arguments.count == 4, let owner = UInt32(arguments[3]) else { throw FanError("用法：--helper <会话目录> <用户 UID>") }
        try runHelper(directory:arguments[2],owner:owner,demo:arguments[1] == "--helper-demo")
    } else if arguments.contains("--diagnose") {
        let state = try MacHardware().snapshot()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        print(String(data:try encoder.encode(state),encoding:.utf8)!)
    } else if arguments.contains("--ui-test") {
        try uiSelfTests()
    } else if arguments.contains("--self-test") {
        try selfTests()
    } else {
        let app = NSApplication.shared
        if let i = arguments.firstIndex(where: { $0 == "--render" || $0 == "--render-live" }), arguments.count > i+1 {
            let live = arguments[i] == "--render-live"
            let delegate = FanApp(demo:!live); try delegate.render(to:arguments[i+1],live:live)
        } else {
            let demo = arguments.contains("--demo")
            let id = Bundle.main.bundleIdentifier ?? "io.github.fengdu.FanControl"
            if !demo && NSRunningApplication.runningApplications(withBundleIdentifier:id).contains(where: { $0.processIdentifier != getpid() }) {
                DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("io.github.fengdu.show"),object:nil,userInfo:nil,deliverImmediately:true)
                exit(0)
            }
            let delegate = FanApp(demo:demo); app.delegate = delegate; app.run()
            withExtendedLifetime(delegate) {}
        }
    }
} catch { fatalMessage(error) }
