import Foundation
import Network
import Darwin

struct PhoneSnapshot: Codable {
    var app = "听桥"
    var status: String
    var running: Bool
    var captions: [Caption]
    var pending: Int
    var assistant: AssistantReply? = nil
}

final class PhoneServer {
    private let queue = DispatchQueue(label: "cn.tingqiao.phone")
    private var listener: NWListener?
    private var connections: [UUID: NWConnection] = [:]
    private var snapshot = Data("{}".utf8)
    private var token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var html: Data
    private var assistantReplies: [String: AssistantReply] = [:]
    private var assistantOrder: [String] = []
    var onReady: ((UInt16) -> Void)?
    var onError: ((String) -> Void)?
    var onAssistantRequest: ((AssistantRequest, @escaping (AssistantReply) -> Void) -> Void)?

    init() {
        html = (Bundle.main.url(forResource: "phone", withExtension: "html").flatMap { try? Data(contentsOf: $0) }) ?? Data("phone.html missing".utf8)
    }
    func start() throws {
        try queue.sync {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let server = try NWListener(using: parameters, on: .any)
        listener = server
        server.stateUpdateHandler = { [weak self, weak server] state in
            switch state {
            case .ready: if let port = server?.port?.rawValue { self?.onReady?(port) }
            case .failed(let error):
                self?.onError?("手机字幕服务失败：\(error.localizedDescription)")
                self?.listener?.cancel(); self?.listener = nil
            default: break
            }
        }
        server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        server.start(queue: queue)
        }
    }
    func stop() {
        queue.sync {
            self.listener?.cancel(); self.listener = nil
            self.connections.values.forEach { $0.cancel() }; self.connections = [:]
            self.token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            self.assistantReplies.removeAll(); self.assistantOrder.removeAll()
        }
    }
    func publish(_ value: PhoneSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        queue.async { self.snapshot = data }
    }
    func pairingURL(port: UInt16) -> String {
        queue.sync { "http://\(Self.localAddress()):\(port)/#\(token)" }
    }
    private func accept(_ connection: NWConnection) {
        guard connections.count < 32 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state { case .cancelled, .failed: self?.connections.removeValue(forKey: id); default: break }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self, weak connection] in connection?.cancel(); self?.connections.removeValue(forKey: id) }
        receive(connection, accumulated: Data())
    }
    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak connection] chunk, _, complete, error in
            guard let self, let connection else { return }
            var buffer = accumulated
            if let chunk { buffer.append(chunk) }
            guard buffer.count <= 16384 else { connection.cancel(); return }
            if let request = String(data: buffer, encoding: .utf8), request.contains("\r\n\r\n") {
                self.respond(connection, request: request)
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, accumulated: buffer) }
        }
    }
    private func respond(_ connection: NWConnection, request: String) {
        let lines = request.components(separatedBy: "\r\n")
        let first = lines.first?.split(separator: " ") ?? []
        guard first.count == 3, first[0] == "GET" || first[0] == "POST" else { send(connection, code: "405 Method Not Allowed", type: "text/plain", body: Data()); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
        }
        // Reject browser cross-origin reads and DNS-rebinding hostnames.
        let host = headers["host"]?.split(separator: ":").first.map(String.init) ?? ""
        guard host == "localhost" || host.split(separator: ".").count == 4 && host.allSatisfy({ $0.isNumber || $0 == "." }) else { send(connection, code: "403 Forbidden", type: "text/plain", body: Data()); return }
        if let origin = headers["origin"], origin != "http://\(headers["host"] ?? "")" { send(connection, code: "403 Forbidden", type: "text/plain", body: Data()); return }
        if first[1].hasPrefix("/api/assistant/") {
            guard headers["x-pairing-token"] == token else { send(connection, code: "401 Unauthorized", type: "text/plain", body: Data()); return }
            respondToAssistant(connection, method: first[0], path: first[1])
            return
        }
        guard first[0] == "GET" else { send(connection, code: "405 Method Not Allowed", type: "text/plain", body: Data()); return }
        switch first[1] {
        case "/", "/index.html": send(connection, code: "200 OK", type: "text/html; charset=utf-8", body: html)
        case "/api/state":
            guard headers["x-pairing-token"] == token else { send(connection, code: "401 Unauthorized", type: "application/json", body: Data("{\"error\":\"配对已失效，请重新扫码\"}".utf8)); return }
            send(connection, code: "200 OK", type: "application/json; charset=utf-8", body: snapshot)
        default: send(connection, code: "404 Not Found", type: "text/plain", body: Data())
        }
    }

    private func respondToAssistant(_ connection: NWConnection, method: Substring, path: Substring) {
        let parts = path.split(separator: "/")
        if method == "GET", parts.count == 3, let reply = assistantReplies[String(parts[2])],
           let data = try? JSONEncoder().encode(reply) {
            send(connection, code: "200 OK", type: "application/json", body: data)
            return
        }
        guard method == "POST", parts.count == 4,
              let request = AssistantRequest(action: String(parts[2]), id: String(parts[3])),
              let onAssistantRequest else { send(connection, code: "404 Not Found", type: "text/plain", body: Data()); return }
        if assistantReplies[request.id] == nil {
            if assistantOrder.count >= 32, let index = assistantOrder.firstIndex(where: { assistantReplies[$0]?.state != .waiting }) {
                assistantReplies.removeValue(forKey: assistantOrder.remove(at: index))
            }
            guard assistantOrder.count < 32 else { send(connection, code: "429 Too Many Requests", type: "text/plain", body: Data()); return }
            assistantOrder.append(request.id)
            assistantReplies[request.id] = AssistantReply(id: request.id, action: request.action, state: .waiting, text: "正在整理最近的对话…")
            let connectionToken = token
            onAssistantRequest(request) { [weak self] reply in
                guard let self else { return }
                self.queue.async {
                    guard self.token == connectionToken, self.assistantReplies[reply.id] != nil else { return }
                    self.assistantReplies[reply.id] = reply
                }
            }
        }
        send(connection, code: "202 Accepted", type: "text/plain", body: Data())
    }
    private func send(_ connection: NWConnection, code: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(code)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
    static func localAddress() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return "127.0.0.1" }
        defer { freeifaddrs(list) }
        var cursor = list
        var found: [(String, String)] = []
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name != "lo0", (entry.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                found.append((name, String(cString: buffer)))
            }
        }
        return found.first(where: { $0.0 == "en0" })?.1 ?? found.first(where: { $0.0.hasPrefix("en") })?.1 ?? "127.0.0.1"
    }
}
