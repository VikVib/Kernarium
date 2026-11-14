// SPDX-License-Identifier: GPL-2.0-or-later

/// What the process could get from iOS when a run failed, and what that most
/// likely means. The application measures it; this type only explains it, so
/// the explanation can be tested without a device.
public struct StartDiagnosis: Equatable, Sendable {
    /// Whether the app's provisioning profile grants an entitlement: nil when
    /// the app carries no profile (an App Store or TestFlight install, or a
    /// build the profile could not be read from).
    public var extendedVirtualAddressing: Bool?
    public var increasedMemoryLimit: Bool?
    /// What `os_proc_available_memory` reported, in MiB.
    public var availableMemoryMiB: Int
    /// The largest single block of address space the process could reserve,
    /// in MiB.
    public var largestReservationMiB: Int
    /// The guest RAM the run asked for, in MiB.
    public var guestMemoryMiB: Int

    public init(
        extendedVirtualAddressing: Bool?, increasedMemoryLimit: Bool?,
        availableMemoryMiB: Int, largestReservationMiB: Int, guestMemoryMiB: Int
    ) {
        self.extendedVirtualAddressing = extendedVirtualAddressing
        self.increasedMemoryLimit = increasedMemoryLimit
        self.availableMemoryMiB = availableMemoryMiB
        self.largestReservationMiB = largestReservationMiB
        self.guestMemoryMiB = guestMemoryMiB
    }

    /// The runtime's errors, from `enum uml_emulator_error`, negated.
    public static func name(ofResult result: Int32) -> String? {
        switch result {
        case -1: "invalid argument"
        case -2: "out of memory"
        case -3: "unsupported"
        case -4: "runtime error"
        default: nil
        }
    }

    /// The guest's memory window holds its RAM and about as much again for the
    /// kernel, so a reservation under twice the RAM cannot hold it.
    public var windowTooSmall: Bool {
        largestReservationMiB < guestMemoryMiB * 2
    }

    /// One plain sentence on the most likely cause of a run that ended with
    /// `result` after `uptimeSeconds`, or nil when nothing measured explains it.
    public func hint(result: Int32, uptimeSeconds: Int?) -> String? {
        let atStart = (uptimeSeconds ?? 0) <= 5
        if result == -4, atStart, extendedVirtualAddressing == false {
            return "iOS would not give Andarium enough address space for the guest. "
                + "The app was signed without the Extended Virtual Addressing entitlement, "
                + "which usually happens when it is sideloaded with a free Apple ID. "
                + "Sign it with the entitlements in Required-entitlements.plist."
        }
        if result == -4, atStart, windowTooSmall {
            return "iOS only let Andarium reserve \(Formats.size(mib: largestReservationMiB)) of address space, "
                + "and a \(Formats.size(mib: guestMemoryMiB)) guest needs about twice its memory. "
                + "Choose less memory for the guest and try again."
        }
        if result == -2 || availableMemoryMiB < guestMemoryMiB {
            let limit = increasedMemoryLimit == false
                ? " The app was signed without the Increased Memory Limit entitlement, which lowers that limit."
                : ""
            return "iOS lets Andarium use \(Formats.size(mib: availableMemoryMiB)) more memory, "
                + "less than the \(Formats.size(mib: guestMemoryMiB)) the guest asked for. "
                + "Choose less memory for the guest.\(limit)"
        }
        return nil
    }

    /// The measurements, one per line, for the copied report.
    public var lines: [String] {
        func granted(_ value: Bool?) -> String {
            switch value {
            case true?: "yes"
            case false?: "MISSING"
            case nil: "unknown (no provisioning profile)"
            }
        }
        return [
            "Extended Virtual Addressing: \(granted(extendedVirtualAddressing))",
            "Increased Memory Limit: \(granted(increasedMemoryLimit))",
            "Memory iOS allows now: \(Formats.size(mib: availableMemoryMiB))",
            "Largest address block: \(Formats.size(mib: largestReservationMiB))",
        ]
    }
}
