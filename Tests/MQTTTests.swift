import Foundation
import XCTest
@testable import HozzDeliver

/// MQTT is a binary protocol, so these assert the exact bytes against the
/// 3.1.1 specification rather than trusting a round trip through our own code.
final class MQTTTests: XCTestCase {
    private func destination(
        topic: String? = nil,
        username: String? = nil
    ) -> Destination {
        var headers: [String: String] = [:]
        if let topic { headers["topic"] = topic }
        if let username { headers["username"] = username }
        return Destination(
            name: "Broker",
            kind: .mqtt,
            format: .metrics,
            endpointURL: URL(string: "mqtt://broker.local:1883"),
            headers: headers
        )
    }

    // MARK: - CONNECT

    func testConnectPacketMatchesTheSpecification() {
        let packet = MQTTDeliveryChannel.connectPacket(
            clientID: "hozz-abc",
            username: nil,
            password: nil
        )
        let bytes = [UInt8](packet)

        XCTAssertEqual(bytes[0], 0x10, "CONNECT control packet type.")
        // Remaining length, then the protocol name as an MQTT string.
        XCTAssertEqual(Array(bytes[2...7]), [0x00, 0x04, 0x4D, 0x51, 0x54, 0x54])
        XCTAssertEqual(bytes[8], 0x04, "Protocol level 4 is MQTT 3.1.1.")
        XCTAssertEqual(bytes[9], 0x02, "Clean session, no credentials.")
        XCTAssertEqual(Array(bytes[10...11]), [0x00, 0x3C], "60 second keep-alive.")
    }

    func testConnectSetsCredentialFlagsWhenSupplied() {
        let packet = MQTTDeliveryChannel.connectPacket(
            clientID: "hozz-abc",
            username: "brandon",
            password: "hunter2"
        )
        let flags = [UInt8](packet)[9]

        XCTAssertEqual(flags & 0x80, 0x80, "Username flag must be set.")
        XCTAssertEqual(flags & 0x40, 0x40, "Password flag must be set.")
        XCTAssertEqual(flags & 0x02, 0x02, "Clean session stays set.")
    }

    func testCredentialsAppearAfterTheClientIdentifier() throws {
        let packet = MQTTDeliveryChannel.connectPacket(
            clientID: "hz",
            username: "user",
            password: "pass"
        )
        let text = String(decoding: packet, as: UTF8.self)
        let clientIndex = try XCTUnwrap(text.range(of: "hz"))
        let userIndex = try XCTUnwrap(text.range(of: "user"))
        let passIndex = try XCTUnwrap(text.range(of: "pass"))

        XCTAssertLessThan(clientIndex.lowerBound, userIndex.lowerBound)
        XCTAssertLessThan(userIndex.lowerBound, passIndex.lowerBound)
    }

    // MARK: - PUBLISH

    func testPublishIsQoSZeroAndRetained() {
        let packet = MQTTDeliveryChannel.publishPacket(
            topic: "hozz/step_count",
            payload: Data(#"{"qty":100}"#.utf8)
        )
        let header = [UInt8](packet)[0]

        XCTAssertEqual(header & 0xF0, 0x30, "PUBLISH control packet type.")
        XCTAssertEqual(header & 0x06, 0x00, "QoS 0.")
        XCTAssertEqual(
            header & 0x01,
            0x01,
            "Retained, so a subscriber connecting later still sees a value."
        )
    }

    func testPublishCarriesTheTopicAndPayloadIntact() throws {
        let payload = Data(#"{"qty":42}"#.utf8)
        let packet = MQTTDeliveryChannel.publishPacket(
            topic: "hozz/heart_rate",
            payload: payload
        )
        let text = String(decoding: packet, as: UTF8.self)

        XCTAssertTrue(text.contains("hozz/heart_rate"))
        XCTAssertTrue(text.hasSuffix(#"{"qty":42}"#))
    }

    /// The length field is seven bits per byte with the high bit as a
    /// continuation flag, so a payload over 127 bytes is where a naive
    /// implementation breaks.
    func testRemainingLengthUsesVariableByteEncoding() {
        let small = MQTTDeliveryChannel.publishPacket(
            topic: "t",
            payload: Data(repeating: 0x41, count: 10)
        )
        let large = MQTTDeliveryChannel.publishPacket(
            topic: "t",
            payload: Data(repeating: 0x41, count: 300)
        )

        XCTAssertEqual([UInt8](small)[1], 13, "3 topic bytes plus 10 payload.")
        // 303 = 0xAF + 0x02 continuation.
        XCTAssertEqual([UInt8](large)[1] & 0x80, 0x80, "Continuation bit set.")
        XCTAssertEqual(Int([UInt8](large)[1] & 0x7F), 303 % 128)
        XCTAssertEqual(Int([UInt8](large)[2]), 303 / 128)
    }

    // MARK: - Topics

    func testEachMetricGetsItsOwnRetainedTopic() {
        let payload = Data("""
        {"data":{"metrics":[
          {"name":"step_count","units":"count","data":[{"qty":100,"date":"a"},{"qty":200,"date":"b"}]},
          {"name":"heart_rate","units":"count/min","data":[{"qty":60,"date":"a"}]}
        ]}}
        """.utf8)
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 3,
            payload: payload,
            format: .metrics
        )

        let topics = MQTTDeliveryChannel.topics(for: batch, destination: destination())
        let names = topics.map(\.topic)

        XCTAssertTrue(names.contains("hozz/batch"))
        XCTAssertTrue(names.contains("hozz/step_count"))
        XCTAssertTrue(names.contains("hozz/heart_rate"))

        // The per-metric topic carries the latest point, which is what a Home
        // Assistant sensor subscribes to.
        let steps = try? XCTUnwrap(topics.first { $0.topic == "hozz/step_count" })
        let decoded = steps.flatMap {
            try? JSONSerialization.jsonObject(with: $0.payload) as? [String: Any]
        }
        XCTAssertEqual(decoded?["qty"] as? Int, 200)
    }

    func testTheTopicRootCanBeChanged() {
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 0,
            payload: Data("{}".utf8),
            format: .metrics
        )

        let topics = MQTTDeliveryChannel.topics(
            for: batch,
            destination: destination(topic: "home/health")
        )

        XCTAssertEqual(topics.first?.topic, "home/health/batch")
    }

    func testAnUnparsablePayloadStillPublishesTheBatch() {
        let batch = DeliveryBatch(
            id: UUID(),
            sequence: 0,
            createdAt: .now,
            recordCount: 0,
            payload: Data("not json".utf8),
            format: .metrics
        )

        let topics = MQTTDeliveryChannel.topics(for: batch, destination: destination())

        XCTAssertEqual(topics.count, 1)
        XCTAssertEqual(topics.first?.topic, "hozz/batch")
    }

    // MARK: - Presets

    func testEveryPresetProducesAUsableDestination() {
        for preset in DestinationPreset.allCases {
            let destination = preset.makeDestination()
            XCTAssertEqual(destination.kind, preset.kind)
            XCTAssertEqual(destination.format, preset.format)
            XCTAssertFalse(destination.name.isEmpty)
            XCTAssertFalse(preset.steps.isEmpty, "\(preset) must explain itself.")
        }
    }

    /// Home Assistant and MQTT default to the payload shape their ecosystems
    /// already parse, so an existing dashboard keeps working.
    func testHomeAssistantAndMQTTDefaultToTheCompatibleFormat() {
        XCTAssertEqual(DestinationPreset.homeAssistant.format, .metrics)
        XCTAssertEqual(DestinationPreset.mqtt.format, .metrics)
        XCTAssertEqual(DestinationPreset.homeAssistant.kind, .restAPI)
    }

    func testOnlyTheFolderPresetIsRecommended() {
        let recommended = DestinationPreset.allCases.filter(\.isRecommended)
        XCTAssertEqual(recommended, [.folder])
    }
}
