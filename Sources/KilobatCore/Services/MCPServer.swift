import Foundation

/// MCP tool annotations. Clients use them to decide when to ask the user before a call.
public struct MCPToolAnnotations {
    public let readOnly: Bool
    public let destructive: Bool
    public let idempotent: Bool
    public let openWorld: Bool
    public init(readOnly: Bool, destructive: Bool = false, idempotent: Bool = true, openWorld: Bool = false) {
        self.readOnly = readOnly; self.destructive = destructive; self.idempotent = idempotent; self.openWorld = openWorld
    }
}

public enum MCPToolOutput {
    /// Encoded JSON, sent as text and, for objects, also as `structuredContent`.
    case json(Data)
    case text(String)
}

/// Lets a running tool report progress when the client asked for it.
@MainActor public struct MCPCallContext {
    let report: (String) -> Void
    public func progress(_ message: String) { report(message) }
}

public struct MCPToolError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

@MainActor public struct MCPTool {
    public let name: String
    public let title: String
    public let description: String
    public let inputSchema: [String: Any]
    public let annotations: MCPToolAnnotations
    public let handler: @MainActor ([String: Any], MCPCallContext) async throws -> MCPToolOutput
    public init(name: String, title: String, description: String, inputSchema: [String: Any] = ["type": "object", "properties": [String: Any](), "additionalProperties": false], annotations: MCPToolAnnotations, handler: @escaping @MainActor ([String: Any], MCPCallContext) async throws -> MCPToolOutput) {
        self.name = name; self.title = title; self.description = description; self.inputSchema = inputSchema; self.annotations = annotations; self.handler = handler
    }
    var listing: [String: Any] {
        ["name": name, "title": title, "description": description, "inputSchema": inputSchema,
         "annotations": ["title": title, "readOnlyHint": annotations.readOnly, "destructiveHint": annotations.destructive, "idempotentHint": annotations.idempotent, "openWorldHint": annotations.openWorld]]
    }
}

/// Model Context Protocol server over newline-delimited JSON-RPC 2.0 (the stdio transport).
/// Requests run concurrently so a long speed test never blocks `ping` or cancellation.
@MainActor public final class MCPServer {
    public static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private let info: [String: Any]
    private let instructions: String
    private let tools: [String: MCPTool]
    private let order: [String]
    private let write: (Data) -> Void
    private var running: [String: Task<Void, Never>] = [:]

    public init(name: String, title: String, version: String, instructions: String, tools: [MCPTool], write: @escaping (Data) -> Void) {
        info = ["name": name, "title": title, "version": version]
        self.instructions = instructions
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        order = tools.map(\.name)
        self.write = write
    }

    /// Handles one line from the client. Responses are written as each request finishes.
    public func receive(_ line: Data) {
        guard !line.allSatisfy({ $0 == 32 || $0 == 9 || $0 == 13 }) else { return }
        guard let message = try? JSONSerialization.jsonObject(with: line) else { return send(Self.failure(NSNull(), -32700, "Parse error")) }
        if let batch = message as? [Any] {
            guard !batch.isEmpty else { return send(Self.failure(NSNull(), -32600, "Invalid Request")) }
            let key = "batch-" + UUID().uuidString
            running[key] = Task { @MainActor in
                var replies: [[String: Any]] = []
                for item in batch { if let reply = await self.respond(to: item) { replies.append(reply) } }
                if !replies.isEmpty { self.send(replies) }
                self.running.removeValue(forKey: key)
            }
            return
        }
        // Replies to server-initiated requests are not expected; Kilobat sends none.
        if let reply = message as? [String: Any], reply["method"] == nil, reply["result"] != nil || reply["error"] != nil { return }
        guard let request = message as? [String: Any], let method = request["method"] as? String else {
            return send(Self.failure((message as? [String: Any])?["id"] ?? NSNull(), -32600, "Invalid Request"))
        }
        if method == "notifications/cancelled", let params = request["params"] as? [String: Any], let id = params["requestId"] {
            running.removeValue(forKey: Self.key(id))?.cancel(); return
        }
        guard let id = request["id"] else { return }   // Other notifications need no reply.
        let key = Self.key(id)
        running[key] = Task { @MainActor in
            let reply = await self.respond(to: request)
            // A cancelled request gets no response, as the protocol requires.
            if !Task.isCancelled, let reply { self.send(reply) }
            self.running.removeValue(forKey: key)
        }
    }

    /// Waits for every in-flight request, e.g. after stdin closes.
    public func drain() async {
        while let (key, task) = running.first { await task.value; running.removeValue(forKey: key) }
    }

    func respond(to message: Any) async -> [String: Any]? {
        guard let request = message as? [String: Any], request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else {
            return Self.failure((message as? [String: Any])?["id"] ?? NSNull(), -32600, "Invalid Request")
        }
        guard let id = request["id"] else { return nil }
        let params = request["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0]
            return Self.success(id, ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": info, "instructions": instructions])
        case "ping": return Self.success(id, [String: Any]())
        case "tools/list": return Self.success(id, ["tools": order.compactMap { tools[$0]?.listing }])
        case "tools/call":
            guard let name = params["name"] as? String, let tool = tools[name] else {
                return Self.failure(id, -32602, "Unknown tool: \(params["name"] as? String ?? "missing name")")
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else { return Self.failure(id, -32602, "Tool arguments must be an object") }
            let token = (params["_meta"] as? [String: Any])?["progressToken"]
            var step = 0
            let context = MCPCallContext { [weak self] message in
                guard let token, let self else { return }
                step += 1
                self.send(["jsonrpc": "2.0", "method": "notifications/progress", "params": ["progressToken": token, "progress": step, "message": message]])
            }
            do { return Self.success(id, Self.result(try await tool.handler(params["arguments"] as? [String: Any] ?? [:], context))) }
            // Tool failures go back to the model as results so it can correct itself.
            catch { return Self.success(id, ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]) }
        default:
            return Self.failure(id, -32601, "Method not found: \(method)")
        }
    }

    static func result(_ output: MCPToolOutput) -> [String: Any] {
        switch output {
        case .text(let text): return ["content": [["type": "text", "text": text]]]
        case .json(let data):
            var result: [String: Any] = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { result["structuredContent"] = object }
            return result
        }
    }

    private func send(_ value: Any) {
        // Compact JSON never contains a raw newline, which is the stdio message delimiter.
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        write(data)
    }
    private static func key(_ id: Any) -> String { (id as? String).map { "s:" + $0 } ?? "n:\(id)" }
    private static func success(_ id: Any, _ result: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }
    private static func failure(_ id: Any, _ code: Int, _ message: String) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]] }
}
