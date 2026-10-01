//
//  MCP.swift
//  MCP(Model Context Protocol)의 뼈대를 직접 구현한 학습용 코드
//  기준 스펙: MCP 2026-07-28 (stateless 개정판)
//
//  MCP = 세 개의 층
//    ① 봉투 : JSON-RPC 2.0 메시지 (id / method / params / result / error)
//    ② 운반 : Transport — stdio(한 줄 = JSON 하나) 또는 Streamable HTTP
//    ③ 어휘 : MCP 메서드 — server/discover, tools/list, tools/call, resources/read ...
//
//  ※ 실제 제품에는 공식 Swift SDK(modelcontextprotocol/swift-sdk) 사용을 권장.
//    이 파일은 "안이 어떻게 생겼는지" 보여주기 위해 단순화한 버전입니다.
//
//  ※ 앱 통합 메모: 이 프로젝트는 기본 액터 격리가 MainActor라서, actor 사이를 오가는
//    값 타입·프로토콜은 전부 `nonisolated`로 선언했다. 콘솔 print 대신 LogSink로 로그를 흘려보낸다.
//

import Foundation

// ─────────────────────────────────────────────────────────────
// MARK: - 0. JSONValue — MCP 메시지는 전부 "임의 모양의 JSON"
// ─────────────────────────────────────────────────────────────
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil()                                  { self = .null }
        else if let v = try? c.decode(Bool.self)          { self = .bool(v) }
        else if let v = try? c.decode(Double.self)        { self = .number(v) }
        else if let v = try? c.decode(String.self)        { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self)   { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:          try c.encodeNil()
        case .bool(let v):   try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] } else { return nil }
    }
    var stringValue: String? {
        if case .string(let s) = self { return s } else { return nil }
    }
    var numberValue: Double? {
        if case .number(let n) = self { return n } else { return nil }
    }
    /// 로그 출력용 한 줄 JSON
    var compact: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(decoding: enc.encode(self), as: UTF8.self)) ?? "?"
    }
    /// 외부(LLM)가 만든 JSON 문자열을 해석. 실패하면 nil
    static func parse(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// 리터럴로 편하게 쓰기: let schema: JSONValue = ["type": "object", "required": ["city"]]
extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral v: String)  { self = .string(v) }
    init(integerLiteral v: Int)    { self = .number(Double(v)) }
    init(floatLiteral v: Double)   { self = .number(v) }
    init(booleanLiteral v: Bool)   { self = .bool(v) }
    init(arrayLiteral e: JSONValue...) { self = .array(e) }
    init(dictionaryLiteral e: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: e))
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 0-1. 로그 싱크 — print 대신 UI로 흘려보내기 위한 작은 통로
// ─────────────────────────────────────────────────────────────
nonisolated struct LogEntry: Identifiable, Sendable {
    nonisolated enum Kind: String, Sendable {
        case wire       // 📡 선 위를 흐르는 JSON-RPC
        case harness    // 🔌 🗜 하네스 내부 상태
        case thought    // 🧠 모델의 출력(생각)
        case tool       // 🔧 도구 실행 결과
        case server     // 🛠 MCP 서버 쪽 이벤트
    }
    let id = UUID()
    let date = Date()
    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

typealias LogSink = @Sendable (LogEntry) -> Void

/// 아무 싱크도 안 주면 예전처럼 콘솔로 찍는다
nonisolated let consoleLog: LogSink = { entry in print("\(entry.kind.rawValue): \(entry.text)") }

// ─────────────────────────────────────────────────────────────
// MARK: - 1. JSON-RPC 2.0 봉투 — MCP의 "문법"
//   요청  : id O, method O  → 반드시 같은 id로 응답이 돌아옴
//   알림  : id X, method O  → 응답 없음 (보내고 끝)
//   응답  : id O, result 또는 error
// ─────────────────────────────────────────────────────────────
nonisolated struct RPCMessage: Codable, Sendable {
    var jsonrpc = "2.0"
    var id: Int?                 // 스펙상 문자열 id도 허용되지만 여기선 정수로 단순화
    var method: String?
    var params: JSONValue?
    var result: JSONValue?
    var error: RPCError?

    var isRequest:      Bool { id != nil && method != nil }
    var isNotification: Bool { id == nil && method != nil }
    var isResponse:     Bool { id != nil && method == nil }

    static func request(_ id: Int, _ method: String, _ params: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, method: method, params: params)
    }
    static func response(_ id: Int, _ result: JSONValue) -> RPCMessage {
        RPCMessage(id: id, result: result)
    }
    static func failure(_ id: Int, _ error: RPCError) -> RPCMessage {
        RPCMessage(id: id, error: error)
    }
}

nonisolated struct RPCError: Codable, Sendable, Error {
    var code: Int
    var message: String

    static let methodNotFound     = RPCError(code: -32601, message: "Method not found")
    static let invalidParams      = RPCError(code: -32602, message: "Invalid params")
    static let unsupportedVersion = RPCError(code: -32022, message: "Unsupported protocol version")
}

/// MCP 상수. 2026-07-28부터는 핸드셰이크 대신 "모든 요청"의 params._meta에 아래 정보를 싣는다.
nonisolated enum MCP {
    static let protocolVersion = "2026-07-28"
    static let versionKey      = "io.modelcontextprotocol/protocolVersion"
    static let clientInfoKey   = "io.modelcontextprotocol/clientInfo"
    static let clientCapsKey   = "io.modelcontextprotocol/clientCapabilities"
    static let serverInfoKey   = "io.modelcontextprotocol/serverInfo"
}

/// 직렬화: 메시지 ↔ 바이트
nonisolated enum Wire {
    static func encode(_ m: RPCMessage) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(m)
    }
    static func decode(_ d: Data) throws -> RPCMessage {
        try JSONDecoder().decode(RPCMessage.self, from: d)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 2. Transport — 메시지를 실어 나르는 파이프
//   MCP 자체는 파이프 종류에 무관하다. 봉투만 같으면 된다.
// ─────────────────────────────────────────────────────────────
nonisolated protocol MCPTransport: Sendable {
    var incoming: AsyncStream<RPCMessage> { get }
    func send(_ message: RPCMessage) async throws
}

/// (A) 데모용: 같은 프로세스 안에서 클라이언트↔서버를 메모리로 연결.
///     오가는 JSON을 그대로 로그로 내보내서 "선 위를 흐르는 것"을 눈으로 보여준다.
nonisolated struct InMemoryTransport: MCPTransport {
    let incoming: AsyncStream<RPCMessage>
    private let peerInbox: AsyncStream<RPCMessage>.Continuation
    private let label: String
    private let log: LogSink

    func send(_ message: RPCMessage) async throws {
        let bytes = try Wire.encode(message)                 // 실제처럼 바이트로 직렬화했다가
        log(LogEntry(.wire, "\(label) \(String(decoding: bytes, as: UTF8.self))"))
        peerInbox.yield(try Wire.decode(bytes))              // 상대편이 다시 해석
    }

    static func pair(log: @escaping LogSink = consoleLog) -> (client: InMemoryTransport, server: InMemoryTransport) {
        let (toClient, toClientInbox) = AsyncStream<RPCMessage>.makeStream()
        let (toServer, toServerInbox) = AsyncStream<RPCMessage>.makeStream()
        return (InMemoryTransport(incoming: toClient, peerInbox: toServerInbox, label: "C→S", log: log),
                InMemoryTransport(incoming: toServer, peerInbox: toClientInbox, label: "S→C", log: log))
    }
}

#if os(macOS)
/// (B) 로컬 MCP 서버의 실제 방식: stdin/stdout으로 "한 줄 = JSON 메시지 하나".
///     ⚠️ stdio 서버에서 print()로 stdout에 로그를 찍으면 프로토콜이 깨진다 → 로그는 stderr로.
nonisolated final class StdioTransport: MCPTransport, @unchecked Sendable {
    let incoming: AsyncStream<RPCMessage>
    private let output: FileHandle
    private let child: Process?          // 하네스가 서버를 자식 프로세스로 띄운 경우 보관

    init(input: FileHandle = .standardInput,
         output: FileHandle = .standardOutput,
         child: Process? = nil) {
        self.output = output
        self.child = child
        self.incoming = AsyncStream { continuation in
            Task {
                do {
                    for try await line in input.bytes.lines {
                        if let msg = try? Wire.decode(Data(line.utf8)) { continuation.yield(msg) }
                    }
                } catch {}
                continuation.finish()
            }
        }
    }

    func send(_ message: RPCMessage) async throws {
        var data = try Wire.encode(message)
        data.append(0x0A)                                     // '\n' 이 메시지 경계
        try output.write(contentsOf: data)
    }

    /// 하네스(호스트) 쪽: 서버 실행파일을 자식 프로세스로 실행하고 그 파이프에 연결.
    /// Claude Desktop 설정의 "command": "..." 가 하는 일이 바로 이것.
    /// (앱 샌드박스 안에서는 임의 실행파일을 띄울 수 없으므로 이 앱의 데모는 InMemoryTransport를 쓴다)
    static func launch(_ executable: URL, arguments: [String] = []) throws -> StdioTransport {
        let process = Process()
        let toServer = Pipe(), fromServer = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = toServer
        process.standardOutput = fromServer
        try process.run()
        return StdioTransport(input: fromServer.fileHandleForReading,
                              output: toServer.fileHandleForWriting,
                              child: process)
    }
}
#endif

/// (C) 원격 MCP 서버: Streamable HTTP. 2026-07-28부터 세션이 없어서
///     요청 하나하나가 독립된 POST → 로드밸런서 뒤 어느 서버 인스턴스가 받아도 된다.
nonisolated final class HTTPTransport: MCPTransport, @unchecked Sendable {
    let incoming: AsyncStream<RPCMessage>
    private let inbox: AsyncStream<RPCMessage>.Continuation
    private let endpoint: URL

    init(endpoint: URL) {
        self.endpoint = endpoint
        let (stream, continuation) = AsyncStream<RPCMessage>.makeStream()
        self.incoming = stream
        self.inbox = continuation
    }

    func send(_ message: RPCMessage) async throws {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue(MCP.protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        // 본문을 까보지 않고도 게이트웨이가 라우팅할 수 있게 헤더에 메서드/대상 이름을 노출
        if let method = message.method { req.setValue(method, forHTTPHeaderField: "Mcp-Method") }
        if let name = message.params?["name"]?.stringValue { req.setValue(name, forHTTPHeaderField: "Mcp-Name") }
        req.httpBody = try Wire.encode(message)

        let (data, _) = try await URLSession.shared.data(for: req)
        // (SSE 스트리밍 응답 처리는 생략 — 단일 JSON 응답만 처리)
        if message.id != nil, let reply = try? Wire.decode(data) { inbox.yield(reply) }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 3. 도구 설명서 — 서버가 주고, 하네스가 LLM에게 그대로 보여준다
// ─────────────────────────────────────────────────────────────
nonisolated struct ToolSpec: Sendable, Identifiable {
    let name: String
    let description: String      // ← LLM이 "언제 이 도구를 쓸지" 판단하는 유일한 근거
    let inputSchema: JSONValue   // ← JSON Schema. LLM은 인자를 이 모양대로 만들어 온다

    var id: String { name }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 4. MCP 서버 — "이런 도구 있어요" 광고 + 호출되면 실행
//   서버는 LLM을 모른다. JSON 요청을 받아 JSON으로 답하는 프로그램일 뿐.
// ─────────────────────────────────────────────────────────────
nonisolated struct MCPTool: Sendable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    let run: @Sendable (JSONValue) async throws -> String
}

actor MCPServer {
    private let name: String
    private let version: String
    private let transport: any MCPTransport
    private let log: LogSink
    private var tools: [MCPTool] = []        // 배열: 목록 순서를 항상 같게 (LLM 프롬프트 캐시에 유리)

    init(name: String, version: String, transport: any MCPTransport, log: @escaping LogSink = consoleLog) {
        self.name = name
        self.version = version
        self.transport = transport
        self.log = log
    }

    func register(_ tool: MCPTool) { tools.append(tool) }

    /// 메인 루프: 요청 하나 받으면 → 처리 → 같은 id로 응답
    func run() async {
        log(LogEntry(.server, "🛠 \(name) v\(version) 대기 중 — 도구 \(tools.count)개"))
        for await msg in transport.incoming where msg.isRequest {
            guard let id = msg.id, let method = msg.method else { continue }
            let reply: RPCMessage
            do {
                reply = .response(id, try await handle(method, msg.params))
            } catch let e as RPCError {
                reply = .failure(id, e)
            } catch {
                reply = .failure(id, RPCError(code: -32603, message: "\(error)"))
            }
            try? await transport.send(reply)
        }
    }

    private func handle(_ method: String, _ params: JSONValue?) async throws -> JSONValue {
        // 핸드셰이크가 없으므로 "매 요청마다" 버전을 확인한다 (= 무상태)
        guard params?["_meta"]?[MCP.versionKey]?.stringValue == MCP.protocolVersion else {
            throw RPCError.unsupportedVersion
        }

        switch method {
        case "server/discover":              // 서버 정체·능력 조회 (클라이언트는 호출 안 해도 됨)
            return [
                "resultType": "complete",
                "supportedVersions": [.string(MCP.protocolVersion)],
                "capabilities": ["tools": [:]],
                "_meta": [MCP.serverInfoKey: ["name": .string(name), "version": .string(version)]]
            ]

        case "tools/list":                   // 도구 "메뉴판"
            return [
                "resultType": "complete",
                "tools": .array(tools.map { t -> JSONValue in
                    ["name": .string(t.name),
                     "description": .string(t.description),
                     "inputSchema": t.inputSchema]
                })
            ]

        case "tools/call":                   // 실제 실행
            guard let toolName = params?["name"]?.stringValue,
                  let tool = tools.first(where: { $0.name == toolName }) else {
                throw RPCError.invalidParams
            }
            do {
                let text = try await tool.run(params?["arguments"] ?? [:])
                return Self.toolResult(text, isError: false)
            } catch {
                // 도구 실패는 "프로토콜 에러"가 아니라 "결과"로 돌려준다
                // → LLM이 에러 메시지를 읽고 인자를 고쳐 다시 시도할 수 있게
                return Self.toolResult("실행 실패: \(error)", isError: true)
            }

        // resources/list·resources/read, prompts/list·prompts/get 도 똑같은 패턴으로 case만 추가하면 된다.
        default:
            throw RPCError.methodNotFound
        }
    }

    private static func toolResult(_ text: String, isError: Bool) -> JSONValue {
        ["resultType": "complete",
         "content": [["type": "text", "text": .string(text)]],
         "isError": .bool(isError)]
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 5. MCP 클라이언트 — 하네스 안에 살면서 서버 1개와 1:1로 연결
// ─────────────────────────────────────────────────────────────
actor MCPClient {
    private let transport: any MCPTransport
    private var nextID = 1
    private var waiting: [Int: CheckedContinuation<JSONValue, Error>] = [:]   // id → 응답 기다리는 호출
    private var listening = false
    private(set) var serverName = "?"

    init(transport: any MCPTransport) { self.transport = transport }

    /// 모든 요청에 붙는 _meta — 요청 하나하나가 자기완결적 (2026-07-28의 핵심)
    private var meta: JSONValue {
        [MCP.versionKey: .string(MCP.protocolVersion),
         MCP.clientInfoKey: ["name": "SwiftHarness", "version": "0.1"],
         MCP.clientCapsKey: [:]]
    }

    // ── 공개 API ────────────────────────────────

    /// (선택) 서버 정체·능력 조회. 예전 스펙의 initialize 핸드셰이크를 대체.
    func discover() async throws {
        let r = try await request("server/discover")
        serverName = r["_meta"]?[MCP.serverInfoKey]?["name"]?.stringValue ?? "?"
    }

    /// 도구 메뉴판 받아오기
    func listTools() async throws -> [ToolSpec] {
        guard case .array(let list)? = try await request("tools/list")["tools"] else { return [] }
        return list.compactMap { t -> ToolSpec? in
            guard let name = t["name"]?.stringValue else { return nil }
            return ToolSpec(name: name,
                            description: t["description"]?.stringValue ?? "",
                            inputSchema: t["inputSchema"] ?? [:])
        }
    }

    /// 도구 실행 요청
    func callTool(_ name: String, arguments: JSONValue) async throws -> (text: String, isError: Bool) {
        let r = try await request("tools/call", ["name": .string(name), "arguments": arguments])
        // (resultType == "input_required" — 서버가 사용자 확인을 요구하는 경우 — 는 생략)
        guard case .array(let blocks)? = r["content"] else { return ("", true) }
        let text = blocks.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
        return (text, r["isError"] == .bool(true))
    }

    // ── 내부 동작 ───────────────────────────────

    /// 요청을 보내고, 같은 id의 응답이 올 때까지 기다린다
    private func request(_ method: String, _ params: [String: JSONValue] = [:]) async throws -> JSONValue {
        startListening()
        var p = params
        p["_meta"] = meta
        let id = nextID
        nextID += 1
        let message = RPCMessage.request(id, method, .object(p))

        return try await withCheckedThrowingContinuation { cont in
            waiting[id] = cont                               // ① 먼저 "기다림"을 등록하고
            Task {                                           // ② 그다음 전송 (순서가 바뀌면 빠른 응답을 놓침)
                do { try await self.transport.send(message) }
                catch { self.resolve(id, .failure(error)) }
            }
        }
    }

    /// 수신 루프: 도착한 응답을 id로 짝지어, 기다리던 호출을 깨운다 (요청-응답 다중화)
    private func startListening() {
        guard !listening else { return }
        listening = true
        Task {
            for await msg in self.transport.incoming where msg.isResponse {
                guard let id = msg.id else { continue }
                if let err = msg.error { self.resolve(id, .failure(err)) }
                else { self.resolve(id, .success(msg.result ?? .null)) }
            }
        }
    }

    private func resolve(_ id: Int, _ outcome: Result<JSONValue, Error>) {
        waiting.removeValue(forKey: id)?.resume(with: outcome)
    }
}
