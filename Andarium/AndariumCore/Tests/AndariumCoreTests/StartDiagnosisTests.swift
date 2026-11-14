// SPDX-License-Identifier: GPL-2.0-or-later

import Testing
@testable import AndariumCore

struct StartDiagnosisTests {
    private let system = SystemInfo(
        version: "17", release: "20261031-los24-r4",
        kernel: "Linux 6.18.54", architecture: "arm64, 4 KiB pages", appVersion: "1.0 (1)"
    )
    private let guest = Guest(cores: 2, memoryMiB: 1536, capacityGiB: 8)

    private func diagnosis(
        extended: Bool? = true, increased: Bool? = true, available: Int = 6144, block: Int = 65536
    ) -> StartDiagnosis {
        StartDiagnosis(
            extendedVirtualAddressing: extended, increasedMemoryLimit: increased,
            availableMemoryMiB: available, largestReservationMiB: block, guestMemoryMiB: 1536
        )
    }

    @Test func aMissingAddressingEntitlementExplainsAnImmediateRuntimeError() throws {
        let hint = try #require(diagnosis(extended: false, block: 2048).hint(result: -4, uptimeSeconds: 0))
        #expect(hint.contains("Extended Virtual Addressing"))
        #expect(hint.contains("free Apple ID"))
    }

    @Test func aSmallAddressBlockSuggestsLessMemory() throws {
        let hint = try #require(diagnosis(extended: nil, block: 2048).hint(result: -4, uptimeSeconds: 0))
        #expect(hint.contains("Choose less memory"))
    }

    @Test func tooLittleMemoryNamesTheMissingLimitEntitlement() throws {
        let hint = try #require(diagnosis(increased: false, available: 1024).hint(result: -2, uptimeSeconds: 0))
        #expect(hint.contains("Increased Memory Limit"))
    }

    @Test func aHealthyHostGivesNoHint() {
        #expect(diagnosis().hint(result: -4, uptimeSeconds: 0) == nil)
        #expect(diagnosis(extended: false).hint(result: -4, uptimeSeconds: 600) == nil)
    }

    @Test func theReportNamesTheErrorAndCarriesTheMeasurementsAndLog() {
        let end = RunEnd(
            result: -4, diagnosis: diagnosis(extended: false, block: 2048),
            recentLog: ["UML: cannot reserve a 4294967296-byte native kernel window"]
        )
        let report = end.report(appVersion: "1.0 (1)", system: system, guest: guest, uptimeSeconds: 0)
        #expect(report.contains("Guest ended: runtime result -4 (runtime error) after"))
        #expect(report.contains("Likely cause: iOS would not give Andarium enough address space"))
        #expect(report.contains("Extended Virtual Addressing: MISSING"))
        #expect(report.contains("Increased Memory Limit: yes"))
        #expect(report.contains("Recent log:\nUML: cannot reserve"))
    }
}
