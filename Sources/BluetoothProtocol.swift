import Foundation

struct BluetoothUpdate: Codable {
    var pairingToken: String? = nil
    var computerID: String? = nil
    var computerName: String? = nil
    var version = 1
    var stream: String
    var message: UInt32
    var kind: String
    var status: String
    var running: Bool
    var pending: Int
    var captions: [Caption]
    var removed: [UUID]
    var assistant: AssistantReply? = nil
}

enum BluetoothWire {
    static let service = "C6B20001-6561-4E90-8A5F-54494E475149"
    static let control = "C6B20002-6561-4E90-8A5F-54494E475149"
    static let subtitles = "C6B20003-6561-4E90-8A5F-54494E475149"
    static let maximumPayload = 262144
    static func update(previous: PhoneSnapshot?, latest: PhoneSnapshot, stream: String, message: UInt32) -> BluetoothUpdate? {
        let old = Dictionary((previous?.captions ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let ids = Set(latest.captions.map(\.id))
        let changed = latest.captions.filter { old[$0.id] != $0 }
        let removed = (previous?.captions ?? []).map(\.id).filter { !ids.contains($0) }
        if let previous, changed.isEmpty, removed.isEmpty, previous.status == latest.status, previous.running == latest.running, previous.pending == latest.pending, previous.assistant == latest.assistant { return nil }
        return BluetoothUpdate(stream: stream, message: message, kind: previous == nil ? "snapshot" : "patch", status: latest.status, running: latest.running, pending: latest.pending, captions: previous == nil ? latest.captions : changed, removed: removed, assistant: previous?.assistant == latest.assistant ? nil : latest.assistant)
    }
    static func assistantRequest(_ command: String) -> AssistantRequest? {
        let parts = command.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "QA", parts[1] == "A" || parts[1] == "E" else { return nil }
        return AssistantRequest(action: parts[1] == "A" ? "answer" : "explain", id: String(parts[2]))
    }
    static func acknowledgement(_ command: String) -> UInt32? {
        guard command.hasPrefix("ACK:") else { return nil }
        return UInt32(command.dropFirst(4))
    }
    static func acknowledgement(_ command: String, current: UInt32, waiting: Bool) -> (message: UInt32, completes: Bool)? {
        guard let message = acknowledgement(command) else { return nil }
        return (message, waiting && message == current)
    }
    static func frames(_ payload: Data, message: UInt32, maximumLength: Int) throws -> [Data] {
        guard payload.count <= maximumPayload, maximumLength >= 20 else { throw BridgeError("蓝牙字幕包过大或连接容量不足。") }
        let chunk = min(512, maximumLength) - 12
        let count = max(1, (payload.count + chunk - 1) / chunk)
        guard count <= 65535 else { throw BridgeError("蓝牙字幕分包过多。") }
        return (0..<count).map { index in
            var data = Data([0x54, 0x51, 1, 0, UInt8((message >> 24) & 255), UInt8((message >> 16) & 255), UInt8((message >> 8) & 255), UInt8(message & 255), UInt8((index >> 8) & 255), UInt8(index & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
            let start = index * chunk
            data.append(payload.subdata(in: start..<min(payload.count, start + chunk)))
            return data
        }
    }
}
