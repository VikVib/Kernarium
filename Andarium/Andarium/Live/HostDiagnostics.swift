// SPDX-License-Identifier: GPL-2.0-or-later
import AndariumCore
import Darwin
import Foundation
import Synchronization

/// Measures what iOS gives this process, for the failure screen
/// (`StartDiagnosis`): which entitlements the provisioning profile grants, how
/// much memory is left, and the largest block of address space the process can
/// reserve. A sideloaded build signed with a free Apple ID lacks the two
/// entitlements Andarium needs, and the runtime only reports that as -4.
nonisolated enum HostDiagnostics {
    static func measure(guestMemoryMiB: Int) -> StartDiagnosis {
        let entitlements = profileEntitlements()
        return StartDiagnosis(
            extendedVirtualAddressing: entitlements.map {
                $0["com.apple.developer.kernel.extended-virtual-addressing"] as? Bool == true
            },
            increasedMemoryLimit: entitlements.map {
                $0["com.apple.developer.kernel.increased-memory-limit"] as? Bool == true
            },
            availableMemoryMiB: Int(remainingMemoryBytes() >> 20),
            largestReservationMiB: largestReservationMiB(),
            guestMemoryMiB: guestMemoryMiB
        )
    }

    /// The Entitlements dictionary of `embedded.mobileprovision`, a property
    /// list inside a CMS envelope; nil when the app has no profile.
    static func profileEntitlements() -> [String: Any]? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let profile = plist as? [String: Any]
        else { return nil }
        return profile["Entitlements"] as? [String: Any] ?? [:]
    }

    /// How much more memory iOS lets the process use before it ends it.
    static func remainingMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        let words = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, Int(count) >= words else { return 0 }
        return info.limit_bytes_remaining
    }

    /// The largest inaccessible mapping the process can make, found by
    /// halving between 0 and 64 GiB to a 128 MiB step. Each probe is unmapped
    /// at once and reserves no memory.
    static func largestReservationMiB() -> Int {
        let step = 128
        var low = 0
        var high = 64 * 1024 / step
        while low < high {
            let middle = (low + high + 1) / 2
            if canReserve(bytes: (middle * step) << 20) {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low * step
    }

    private static func canReserve(bytes: Int) -> Bool {
        guard let mapped = mmap(nil, bytes, PROT_NONE, MAP_PRIVATE | MAP_ANON | MAP_NORESERVE, -1, 0),
              mapped != UnsafeMutableRawPointer(bitPattern: -1)
        else { return false }
        munmap(mapped, bytes)
        return true
    }
}

/// Keeps the last lines the process writes to standard output and standard
/// error, which the runtime uses for its own errors, so the failure screen can
/// show them. Everything still reaches the original standard error.
nonisolated final class LogCapture: Sendable {
    static let shared = LogCapture()
    private static let keptLines = 40
    private static let longestLine = 300

    /// Nonisolated like the class: the target's default isolation is the main
    /// actor, and the capture thread updates this.
    nonisolated private struct State: Sendable {
        var started = false
        var lines: [String] = []
        var partial = Data()
    }

    private let state = Mutex(State())

    func start() {
        let first = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard first else { return }
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return }
        let original = dup(STDERR_FILENO)
        guard original >= 0 else {
            close(ends[0])
            close(ends[1])
            return
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        fflush(stdout)
        dup2(ends[1], STDOUT_FILENO)
        dup2(ends[1], STDERR_FILENO)
        close(ends[1])
        let source = ends[0]
        let thread = Thread { [self] in pump(from: source, to: original) }
        thread.name = "Andarium log capture"
        thread.start()
    }

    /// The kept lines, oldest first.
    func recentLines() -> [String] {
        state.withLock { state in
            state.partial.isEmpty ? state.lines : state.lines + [String(decoding: state.partial, as: UTF8.self)]
        }
    }

    private func pump(from source: Int32, to original: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            buffer.withUnsafeBytes { bytes in
                var offset = 0
                while offset < count {
                    let written = write(original, bytes.baseAddress! + offset, count - offset)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else { break }
                    offset += written
                }
            }
            keep(Data(buffer[0..<count]))
        }
    }

    private func keep(_ chunk: Data) {
        state.withLock { state in
            state.partial.append(chunk)
            while let newline = state.partial.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: state.partial[state.partial.startIndex..<newline], as: UTF8.self)
                state.partial.removeSubrange(state.partial.startIndex...newline)
                guard !line.isEmpty else { continue }
                state.lines.append(String(line.prefix(Self.longestLine)))
            }
            if state.partial.count > Self.longestLine * 4 {
                state.partial.removeAll()
            }
            if state.lines.count > Self.keptLines {
                state.lines.removeFirst(state.lines.count - Self.keptLines)
            }
        }
    }
}
