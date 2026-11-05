import Foundation
import Security

struct BluetoothPeer: Codable, Identifiable {
    var id: String
    var name: String
    var centralID: String? = nil
    var token: String
}

/// Kept separately from API credentials. Tokens only travel over encrypted BLE.
final class BluetoothTrust {
    private let defaults: UserDefaults
    private(set) var peers: [BluetoothPeer]
    let computerID: String
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        peers = defaults.data(forKey: "bluetooth.trustedPeers").flatMap { try? JSONDecoder().decode([BluetoothPeer].self, from: $0) } ?? []
        computerID = defaults.string(forKey: "bluetooth.computerID") ?? UUID().uuidString
        defaults.set(computerID, forKey: "bluetooth.computerID")
    }
    func find(_ token: String) -> BluetoothPeer? { peers.first { $0.token == token } }
    func pair(centralID: String) throws -> BluetoothPeer {
        if let existing = peers.first(where: { $0.centralID == centralID }) { return existing }
        guard peers.count < 20 else { throw BridgeError("已记住 20 台手机，请先取消一个旧配对。") }
        var bytes = [UInt8](repeating: 0, count: 12)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw BridgeError("无法生成设备配对凭据，请重试。") }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let peer = BluetoothPeer(id: UUID().uuidString, name: "安卓手机 · \(peers.count + 1)", centralID: centralID, token: token)
        peers.append(peer); save(); return peer
    }
    func remove(_ id: String) { peers.removeAll { $0.id == id }; save() }
    private func save() { defaults.set(try? JSONEncoder().encode(peers), forKey: "bluetooth.trustedPeers") }
}
