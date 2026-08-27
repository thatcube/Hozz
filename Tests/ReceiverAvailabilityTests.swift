import Network
import XCTest
@testable import HozzCore
@testable import HozzDeliver
@testable import HozzReceive

final class ReceiverAvailabilityTests: XCTestCase {
    func testBonjourDaemonFailureIsNotMisreadAsAPortCollision() {
        let unavailable = NWError.dns(
            Int32(kDNSServiceErr_ServiceNotRunning)
        )
        let defunct = NWError.dns(
            Int32(kDNSServiceErr_DefunctConnection)
        )

        XCTAssertTrue(
            HealthReceiver.isTransientServiceFailure(unavailable)
        )
        XCTAssertTrue(
            HealthReceiver.isTransientServiceFailure(defunct)
        )
        XCTAssertFalse(HealthReceiver.isPortInUse(unavailable))
        XCTAssertTrue(
            HealthReceiver.isPortInUse(.posix(.EADDRINUSE))
        )
    }

    func testASecondMacUsesItsOwnRecordRatherThanTheNewestOne() {
        let expected = SharedReceiver(
            name: "Hozz on Microsoft M4 Max",
            token: "this destination's token",
            endpoints: ["http://192.168.68.156:54330"],
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newerOtherMac = SharedReceiver(
            name: "Hozz on Brandon's MacBook Pro (2)",
            token: "another token",
            endpoints: ["http://192.168.68.44:54330"],
            updatedAt: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(
            DeliveryEngine.matchingReceiver(
                token: "this destination's token",
                // Most recent first, exactly as `publishedAll()` returns it.
                among: [newerOtherMac, expected]
            ),
            expected
        )
    }
}
