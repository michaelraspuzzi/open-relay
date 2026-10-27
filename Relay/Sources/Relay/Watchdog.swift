import Darwin
import Foundation

/// Relay's own memory guard. On 2026-10-03 a SwiftUI layout loop pinned the main thread and grew the process to
/// 130 GB before macOS gave up and the laptop had to be force-quit. A hung main thread can't save itself, so this
/// runs on its own thread: when the footprint passes the limit it logs what happened and ends the process at once.
/// Cards are already on disk (Store saves on every change) and the sidecar exits with its claude children when
/// Relay goes, so coming back is a relaunch away. RELAY_MEMORY_LIMIT_GB overrides the limit.
enum Watchdog {
    static let limitBytes: UInt64 = {
        let gb = ProcessInfo.processInfo.environment["RELAY_MEMORY_LIMIT_GB"].flatMap(Double.init) ?? 6
        return UInt64(gb * 1_073_741_824)
    }()

    static func start() {
        let thread = Thread {
            var warned = false
            while true {
                Thread.sleep(forTimeInterval: 2)
                guard let footprint = footprint() else { continue }
                if footprint > limitBytes / 2, !warned {
                    warned = true
                    log("memory: \(footprint >> 20) MB, half the \(limitBytes >> 20) MB limit")
                }
                if footprint > limitBytes {
                    log("memory: \(footprint >> 20) MB, over the \(limitBytes >> 20) MB limit; quitting to protect the Mac (main thread \(mainThreadResponsive() ? "responsive" : "hung"))")
                    _exit(70)
                }
            }
        }
        thread.name = "relay.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }

    /// Appends to the sidecar log without going near the main actor, which may be the thing that's stuck.
    private static func log(_ message: String) {
        let path = NSHomeDirectory() + "/Library/Logs/Relay/sidecar.log"
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("[\(Date.now.formatted(.iso8601))] relay watchdog: \(message)\n".utf8))
        try? handle.close()
    }

    /// Physical footprint, the number Activity Monitor shows as Memory.
    private static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Whether the main thread answers within half a second (for the log line; a layout loop never does).
    private static func mainThreadResponsive() -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { done.signal() }
        return done.wait(timeout: .now() + 0.5) == .success
    }
}
