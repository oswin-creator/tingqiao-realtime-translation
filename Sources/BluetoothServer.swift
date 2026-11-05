import Foundation
import CoreBluetooth

final class BluetoothCaptionServer: NSObject, CBPeripheralManagerDelegate {
    private let queue = DispatchQueue(label: "cn.tingqiao.bluetooth")
    private var manager: CBPeripheralManager?
    private var dataCharacteristic: CBMutableCharacteristic?
    private var enabled = false
    private var serviceReady = false
    private var code = ""
    private var stream = UUID().uuidString
    private var sequence: UInt32 = 0
    private var snapshot = PhoneSnapshot(status: "准备就绪", running: false, captions: [], pending: 0)
    private var timer: DispatchSourceTimer?
    private var failedAuthentications = 0
    private var failedSince = Date()
    private lazy var trust: BluetoothTrust = {
        if CommandLine.arguments.contains("--ui-preview") { return BluetoothTrust(defaults: UserDefaults(suiteName: "cn.tingqiao.preview.bluetooth")!) }
        return BluetoothTrust()
    }()
    private final class Client {
        let central: CBCentral
        var authorized = false
        var peer: BluetoothPeer?
        var previous: PhoneSnapshot?
        var target: PhoneSnapshot?
        var frames: [Data] = []
        var next = 0
        var message: UInt32 = 0
        var waitingSince: Date?
        var retries = 0
        var assistant: AssistantReply?
        var assistantRequests: [String] = []
        init(_ central: CBCentral) { self.central = central }
    }
    private var clients: [UUID: Client] = [:]
    var onState: ((String, Int) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onPeers: (([BluetoothPeer]) -> Void)?
    var onAssistantRequest: ((AssistantRequest, @escaping (AssistantReply) -> Void) -> Void)?
    func refreshPeers() { queue.async { self.onPeers?(self.trust.peers) } }
    func forget(_ id: String) {
        queue.async {
            self.trust.remove(id)
            for client in self.clients.values where client.peer?.id == id { client.authorized = false; client.peer = nil; client.frames = [] }
            self.onPeers?(self.trust.peers); self.report("已取消设备配对")
        }
    }
    func start(code: String) {
        queue.async { [self] in
            guard !self.enabled else { return }
            self.enabled = true; self.code = code; self.stream = UUID().uuidString; self.sequence = 0
            self.failedAuthentications = 0; self.failedSince = Date()
            if self.manager == nil { self.manager = CBPeripheralManager(delegate: self, queue: self.queue) }
            else { self.prepare() }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.tick() }; timer.resume(); self.timer = timer
        }
    }
    func stop() {
        queue.sync {
            enabled = false; timer?.cancel(); timer = nil
            manager?.stopAdvertising(); manager?.removeAllServices(); serviceReady = false
            clients.removeAll(); dataCharacteristic = nil; code = ""
            report("蓝牙字幕未开启")
        }
    }
    func publish(_ snapshot: PhoneSnapshot) { queue.async { self.snapshot = snapshot; self.sendPending() } }
    private func report(_ status: String) { onState?(status, clients.values.filter(\.authorized).count) }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard enabled else { return }
        onDiagnostic?("Bluetooth state: \(peripheral.state.rawValue)")
        serviceReady = false; dataCharacteristic = nil; clients.removeAll()
        prepare()
    }
    private func prepare() {
        guard enabled, let manager else { return }
        switch manager.state {
        case .poweredOn:
            guard !serviceReady, dataCharacteristic == nil else { return }
            manager.removeAllServices()
            let control = CBMutableCharacteristic(type: CBUUID(string: BluetoothWire.control), properties: [.write], value: nil, permissions: [.writeable, .writeEncryptionRequired])
            let data = CBMutableCharacteristic(type: CBUUID(string: BluetoothWire.subtitles), properties: [.notify, .notifyEncryptionRequired], value: nil, permissions: [])
            let service = CBMutableService(type: CBUUID(string: BluetoothWire.service), primary: true)
            service.characteristics = [control, data]; dataCharacteristic = data
            manager.add(service); report("正在准备蓝牙字幕…")
        case .unauthorized: report("请在系统设置中允许听桥使用蓝牙")
        case .poweredOff: report("请打开 Mac 蓝牙")
        case .unsupported: report("这台 Mac 暂不支持蓝牙字幕")
        default: report("正在等待蓝牙就绪…")
        }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard enabled else { return }
        if let error { dataCharacteristic = nil; report("蓝牙服务启动失败：\(error.localizedDescription)"); return }
        serviceReady = true
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: "听桥 TingQiao", CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BluetoothWire.service)]])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { report("蓝牙广播失败：\(error.localizedDescription)") }
        else { report("等待安卓 App 扫描并输入配对码") }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard enabled, characteristic.uuid == dataCharacteristic?.uuid else { return }
        if clients.count >= 4 && clients[central.identifier] == nil { report("蓝牙连接数量已满"); return }
        onDiagnostic?("Subscribed, MTU payload \(central.maximumUpdateValueLength)")
        clients[central.identifier] = Client(central); report("手机已连接，等待核对配对码")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        clients.removeValue(forKey: central.identifier)
        onDiagnostic?("Unsubscribed")
        report(clients.values.contains(where: \.authorized) ? "蓝牙字幕已连接" : "手机已断开，等待自动重连")
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard enabled, request.characteristic.uuid == CBUUID(string: BluetoothWire.control), request.offset == 0,
                  let value = request.value, value.count <= 32, let command = String(data: value, encoding: .utf8),
                  let client = clients[request.central.identifier] else { peripheral.respond(to: request, withResult: .requestNotSupported); continue }
            if command.hasPrefix("AUTH:") {
                if Date().timeIntervalSince(failedSince) > 60 { failedAuthentications = 0; failedSince = Date() }
                guard failedAuthentications < 10, command == "AUTH:\(code)" else {
                    failedAuthentications += 1; peripheral.respond(to: request, withResult: .insufficientAuthorization); continue
                }
                do { client.peer = try trust.pair(centralID: request.central.identifier.uuidString) }
                catch { peripheral.respond(to: request, withResult: .insufficientResources); report(error.localizedDescription); continue }
                onPeers?(trust.peers)
                onDiagnostic?("Application pairing accepted")
                client.authorized = true; client.previous = nil; client.frames = []; client.waitingSince = nil
                peripheral.respond(to: request, withResult: .success); report("蓝牙字幕已连接")
                sendPending()
            } else if command.hasPrefix("KEY:"), let peer = trust.find(String(command.dropFirst(4))) {
                client.peer = peer; client.authorized = true; client.previous = nil; client.frames = []; client.waitingSince = nil
                peripheral.respond(to: request, withResult: .success); report("已记住的手机已连接"); sendPending()
            } else if client.authorized, command == "PING" {
                peripheral.respond(to: request, withResult: .success)
            } else if client.authorized, command == "SYNC" {
                client.previous = nil; client.frames = []; client.waitingSince = nil; client.retries = 0
                peripheral.respond(to: request, withResult: .success); sendPending()
            } else if client.authorized, let assistant = BluetoothWire.assistantRequest(command), let onAssistantRequest {
                peripheral.respond(to: request, withResult: .success)
                if client.assistantRequests.contains(assistant.id) { continue }
                client.assistantRequests.append(assistant.id)
                if client.assistantRequests.count > 32 { client.assistantRequests.removeFirst() }
                let centralID = request.central.identifier
                onAssistantRequest(assistant) { [weak self, weak client] reply in
                    guard let self, let client else { return }
                    self.queue.async {
                        guard self.clients[centralID] === client, client.authorized, client.assistantRequests.last == reply.id else { return }
                        client.assistant = reply
                        self.sendPending()
                    }
                }
            } else if client.authorized, let acknowledged = BluetoothWire.acknowledgement(command, current: client.message, waiting: client.waitingSince != nil) {
                // ACKs can arrive again after a retry or after a newer snapshot starts.
                // A valid stale ACK is harmless; rejecting it makes Android reconnect.
                if acknowledged.completes {
                    onDiagnostic?("ACK \(acknowledged.message) accepted")
                    client.previous = client.target; client.target = nil; client.frames = []; client.waitingSince = nil; client.retries = 0
                } else { onDiagnostic?("ACK \(acknowledged.message) duplicate/stale, ignored") }
                peripheral.respond(to: request, withResult: .success); sendPending()
            } else { peripheral.respond(to: request, withResult: .insufficientAuthorization) }
        }
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { sendPending() }
    private func tick() {
        guard enabled else { return }
        // An ACK confirms a complete UTF-8 message, not just individual radio packets.
        for client in clients.values where client.authorized {
            if let since = client.waitingSince, Date().timeIntervalSince(since) > 12 {
                client.retries += 1; client.waitingSince = nil; client.next = 0
                if client.retries > 4 { client.authorized = false; client.frames = []; report("手机暂时没有响应，请在安卓 App 重新连接") }
            }
        }
        if serviceReady, manager?.isAdvertising == false { manager?.startAdvertising([CBAdvertisementDataLocalNameKey: "听桥 TingQiao", CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: BluetoothWire.service)]]) }
        sendPending()
    }
    private func sendPending() {
        guard enabled, let manager, manager.state == .poweredOn, let characteristic = dataCharacteristic else { return }
        for client in clients.values where client.authorized && client.waitingSince == nil {
            if client.frames.isEmpty {
                sequence &+= 1
                var latest = snapshot
                latest.assistant = client.assistant
                guard var update = BluetoothWire.update(previous: client.previous, latest: latest, stream: stream, message: sequence) else { continue }
                if client.previous == nil {
                    update.pairingToken = client.peer?.token
                    update.computerID = trust.computerID
                    update.computerName = Host.current().localizedName ?? "听桥 Mac"
                }
                do {
                    let payload = try JSONEncoder().encode(update)
                    client.frames = try BluetoothWire.frames(payload, message: sequence, maximumLength: client.central.maximumUpdateValueLength)
                    client.target = latest; client.message = sequence; client.next = 0
                    onDiagnostic?("Send \(update.kind) message \(sequence), \(client.frames.count) frames")
                } catch { report("字幕暂时无法发送：\(error.localizedDescription)"); continue }
            }
            while client.next < client.frames.count {
                guard manager.updateValue(client.frames[client.next], for: characteristic, onSubscribedCentrals: [client.central]) else { return }
                client.next += 1
            }
            client.waitingSince = Date()
        }
    }
}
