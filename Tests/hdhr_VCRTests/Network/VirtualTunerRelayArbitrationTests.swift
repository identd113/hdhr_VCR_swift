import Testing
import Foundation
@testable import hdhr_VCR

// MARK: - One FEED relay per physical tuner
//
// If two Macs record from the same shared tuner, both could advertise a Recording FEED relay for it.
// Only one may stay live: the Mac that started recording that tuner first keeps it, the other backs
// off (`VirtualTunerService.conflictShouldYield`). Both Macs run the same function against each
// other's data, so the properties that matter are *exactly one side yields* and *a known start beats
// an unknown one* — the second was a real review finding (a nil start used to lose or win on hostname
// luck). The relay's DeviceID is derived from the source tuner, so both Macs mint the same ID for the
// same tuner — that's what makes the conflict detectable at all.

@Suite("VirtualTunerService.conflictShouldYield / shared relay ID")
struct VirtualTunerRelayArbitrationTests {

    private let early = Date(timeIntervalSince1970: 1_000_000)
    private let late  = Date(timeIntervalSince1970: 1_000_500)

    private func yields(_ ours: Date?, _ theirs: Date?, us: String = "alpha", them: String = "bravo") -> Bool {
        VirtualTunerService.conflictShouldYield(ourStart: ours, theirStart: theirs, ourHostname: us, theirHostname: them)
    }

    @Test func theMacThatStartedFirstKeepsTheRelay() {
        #expect(yields(early, late) == false)   // we started first → we keep it
        #expect(yields(late, early) == true)    // they started first → we back off
    }

    @Test func startTimeBeatsHostname_inBothDirections() {
        // "alpha" < "bravo" would win a hostname tie-break, but a later start must still lose.
        #expect(yields(late, early, us: "alpha", them: "bravo") == true)
        #expect(yields(early, late, us: "zulu", them: "bravo") == false)
    }

    @Test func aKnownStartBeatsAnUnknownOne() {
        #expect(yields(nil, late) == true)      // no proof we started first, they can prove a (late) start
        #expect(yields(early, nil) == false)    // we can prove it, they can't
        // regardless of hostname order
        #expect(yields(nil, late, us: "alpha", them: "zulu") == true)
        #expect(yields(early, nil, us: "zulu", them: "alpha") == false)
    }

    @Test func exactTie_fallsBackToHostname_andExactlyOneSideYields() {
        let a = yields(early, early, us: "alpha", them: "bravo")
        let b = yields(early, early, us: "bravo", them: "alpha")
        #expect(a != b)
        // both unknown behaves the same way
        let c = yields(nil, nil, us: "alpha", them: "bravo")
        let d = yields(nil, nil, us: "bravo", them: "alpha")
        #expect(c != d)
    }

    @Test func isSymmetric_exactlyOneSideBacksOff_acrossEveryCombination() {
        let starts: [Date?] = [nil, early, late]
        for ours in starts {
            for theirs in starts {
                let weYield = yields(ours, theirs, us: "alpha", them: "bravo")
                let theyYield = yields(theirs, ours, us: "bravo", them: "alpha")
                #expect(weYield != theyYield, "ours=\(String(describing: ours)) theirs=\(String(describing: theirs)): both or neither backed off")
            }
        }
    }

    @Test func bothMacsDeriveTheSameRelayIDForTheSameSourceTuner() {
        let one = VirtualTunerService.relayDeviceID(sourceDeviceID: "105404BE")
        let two = VirtualTunerService.relayDeviceID(sourceDeviceID: "105404BE")
        #expect(one == two)
        #expect(one == "FEED04BE")
        // a different tuner gets a different relay
        #expect(VirtualTunerService.relayDeviceID(sourceDeviceID: "10540ABC") != one)
    }
}
