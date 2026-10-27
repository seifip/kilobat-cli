import Foundation
import Testing
@testable import KilobatCore

@MainActor struct MCPServerTests {
    final class Output {
        var lines: [[String: Any]] = []
        var batches: [[[String: Any]]] = []
        func reply(_ id: Int) -> [String: Any]? { lines.first { $0["id"] as? Int == id } }
    }

    func server(_ output: Output, tools: [MCPTool]? = nil) -> MCPServer {
        let defaults = [
            MCPTool(name: "status", title: "Status", description: "Snapshot", annotations: MCPToolAnnotations(readOnly: true)) { _, _ in .json(Data(#"{"connected":true}"#.utf8)) },
            MCPTool(name: "scan", title: "Scan", description: "Networks", annotations: MCPToolAnnotations(readOnly: true)) { _, _ in .json(Data(#"[{"ssid":"Cafe"}]"#.utf8)) },
            MCPTool(name: "set_profile", title: "Set profile", description: "Change", annotations: MCPToolAnnotations(readOnly: false, destructive: true)) { arguments, _ in
                guard arguments["profile"] as? String == "travel" else { throw MCPToolError("Choose travel.") }
                return .text("ok")
            },
        ]
        return MCPServer(name: "kilobat", title: "Kilobat", version: "1.0", instructions: "Ask first.", tools: tools ?? defaults) { data in
            let message = try? JSONSerialization.jsonObject(with: data)
            if let batch = message as? [[String: Any]] { output.batches.append(batch) } else if let line = message as? [String: Any] { output.lines.append(line) }
            #expect(!data.contains(10))
        }
    }

    func send(_ server: MCPServer, _ json: String) async {
        server.receive(Data(json.utf8))
        await server.drain()
    }

    @Test func testInitializeNegotiatesVersionAndAdvertisesTools() async {
        let output = Output(), server = server(output)
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)
        await send(server, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        let result = output.reply(1)?["result"] as? [String: Any]
        #expect(result?["protocolVersion"] as? String == "2025-06-18")
        #expect((result?["capabilities"] as? [String: Any])?["tools"] != nil)
        #expect((result?["serverInfo"] as? [String: Any])?["name"] as? String == "kilobat")
        #expect(result?["instructions"] as? String == "Ask first.")
        #expect((output.reply(2)?["result"] as? [String: Any])?["protocolVersion"] as? String == MCPServer.protocolVersions[0])
        #expect(output.lines.count == 2)
    }

    @Test func testToolsListCarriesAnnotationsInOrder() async {
        let output = Output(), server = server(output)
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        let tools = (output.reply(1)?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        #expect(tools.map { $0["name"] as? String } == ["status", "scan", "set_profile"])
        let change = tools[2]["annotations"] as? [String: Any]
        #expect(change?["readOnlyHint"] as? Bool == false)
        #expect(change?["destructiveHint"] as? Bool == true)
        #expect((tools[0]["annotations"] as? [String: Any])?["readOnlyHint"] as? Bool == true)
        #expect((tools[0]["inputSchema"] as? [String: Any])?["type"] as? String == "object")
    }

    @Test func testToolCallsReturnTextStructuredContentAndErrors() async {
        let output = Output(), server = server(output)
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"status","arguments":{}}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"scan"}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"set_profile","arguments":{"profile":"party"}}}"#)
        await send(server, #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"missing"}}"#)
        let status = output.reply(1)?["result"] as? [String: Any]
        #expect((status?["structuredContent"] as? [String: Any])?["connected"] as? Bool == true)
        #expect(((status?["content"] as? [[String: Any]])?.first)?["text"] as? String == #"{"connected":true}"#)
        let scan = output.reply(2)?["result"] as? [String: Any]
        #expect(scan?["structuredContent"] == nil)   // structuredContent must be an object.
        let failed = output.reply(3)?["result"] as? [String: Any]
        #expect(failed?["isError"] as? Bool == true)
        #expect(((failed?["content"] as? [[String: Any]])?.first)?["text"] as? String == "Choose travel.")
        #expect((output.reply(4)?["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func testProtocolErrorsPingAndBatches() async {
        let output = Output(), server = server(output)
        await send(server, "not json")
        await send(server, #"{"jsonrpc":"2.0","id":1,"method":"resources/list"}"#)
        await send(server, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        await send(server, #"[{"jsonrpc":"2.0","id":3,"method":"ping"},{"jsonrpc":"2.0","method":"notifications/initialized"}]"#)
        await send(server, "   ")
        #expect((output.lines[0]["error"] as? [String: Any])?["code"] as? Int == -32700)
        #expect((output.reply(1)?["error"] as? [String: Any])?["code"] as? Int == -32601)
        #expect(output.reply(2)?["result"] is [String: Any])
        #expect(output.lines.count == 3)
        #expect(output.batches.map { $0.map { $0["id"] as? Int } } == [[3]])
    }

    @Test func testSlowToolDoesNotBlockPingAndCancellationSuppressesReply() async {
        let output = Output()
        let slow = MCPTool(name: "speedtest", title: "Speed", description: "Slow", annotations: MCPToolAnnotations(readOnly: true)) { _, context in
            context.progress("Measuring…")
            try await Task.sleep(for: .seconds(30))
            return .text("done")
        }
        let server = server(output, tools: [slow])
        server.receive(Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"speedtest","_meta":{"progressToken":"p1"}}}"#.utf8))
        server.receive(Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8))
        for _ in 0..<50 where output.reply(2) == nil { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(output.reply(2) != nil)
        let progress = output.lines.first { $0["method"] as? String == "notifications/progress" }?["params"] as? [String: Any]
        #expect(progress?["progressToken"] as? String == "p1")
        server.receive(Data(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#.utf8))
        await server.drain()
        #expect(output.reply(1) == nil)
    }

    @Test func testUsageSummaryTotalsDaysAndTopApps() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
        let usage = [
            UsageEntry(date: now.addingTimeInterval(-3600), received: 100, sent: 10, apps: ["Safari": 80, "Music": 30, "idle": 0]),
            UsageEntry(date: now.addingTimeInterval(-86_400), received: 50, sent: 5, apps: ["Music": 55]),
            UsageEntry(date: now.addingTimeInterval(-10 * 86_400), received: 999, sent: 999, apps: ["Old": 1998]),
        ]
        let summary = UsageSummary(usage, days: 7, now: now, calendar: calendar)
        #expect(summary.samples == 2)
        #expect(summary.downloadBytes == 150 && summary.uploadBytes == 15)
        #expect(summary.daily.map(\.day) == ["2027-01-14", "2027-01-15"])
        #expect(summary.topApps == [UsageSummary.App(name: "Music", bytes: 85), UsageSummary.App(name: "Safari", bytes: 80)])
        #expect(UsageSummary(usage, days: 1, now: now, calendar: calendar).samples == 1)
    }
}
