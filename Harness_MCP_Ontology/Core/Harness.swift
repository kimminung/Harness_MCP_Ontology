//
//  Harness.swift
//  에이전트 하네스(Agent Harness)의 뼈대
//
//  LLM 자체는 "대화 기록 + 도구 목록 → 다음 출력(텍스트 또는 도구 요청 JSON)"을 내는 함수일 뿐.
//  도구를 실제로 실행하고, 결과를 다시 먹이고, 반복·중단·권한·기억을 관리하는 바깥 틀 = 하네스.
//  (Claude Code 같은 코딩 에이전트가 대표적인 하네스)
//
//  ※ 데모용 가짜 LLM(ScriptedModel)은 ScriptedModel.swift로 분리했다.
//

import Foundation

// ─────────────────────────────────────────────────────────────
// MARK: - 1. 대화 기록 — 하네스가 관리하는 핵심 "상태"
// ─────────────────────────────────────────────────────────────
nonisolated enum Message: Sendable {
    case user(String)
    case assistant(text: String, toolCalls: [ToolCall])
    case toolResult(callID: String, content: String, isError: Bool)

    var isUser: Bool {
        if case .user = self { return true } else { return false }
    }
}

nonisolated struct ToolCall: Sendable {
    let id: String              // 결과가 어느 요청에 대한 것인지 짝짓는 용도
    let name: String
    let arguments: JSONValue    // LLM이 inputSchema를 보고 만들어낸 JSON
}

// ─────────────────────────────────────────────────────────────
// MARK: - 2. 모델 어댑터 — 하네스는 LLM 종류를 모른다 (프로토콜로 추상화)
// ─────────────────────────────────────────────────────────────
nonisolated enum StopReason: Sendable { case endTurn, toolUse }

nonisolated struct ModelTurn: Sendable {
    var text: String
    var toolCalls: [ToolCall] = []
    var stop: StopReason = .endTurn
}

nonisolated protocol LanguageModel: Sendable {
    func next(system: String, history: [Message], tools: [ToolSpec]) async throws -> ModelTurn
}

// 실제 어댑터(예: Claude Messages API)가 하는 일은 "형식 변환"뿐이다:
//   [ToolSpec]  → 요청 JSON의 "tools": [{ name, description, input_schema }]
//   [Message]   → "messages": [...]   (toolResult는 user 메시지 안의 tool_result 블록으로)
//   응답의 tool_use 블록 { id, name, input }  → ToolCall
//   stop_reason == "tool_use"                → .toolUse
// 즉 LLM은 도구를 "실행"하지 않는다. "이 도구를 이 인자로 불러줘"라는 JSON을 출력할 뿐.
// (이 앱의 OnDeviceLanguageModel은 Apple Foundation Models로 같은 일을 한다)

// ─────────────────────────────────────────────────────────────
// MARK: - 3. 권한 훅 — "모델이 원한다고 전부 실행하지 않는다"
// ─────────────────────────────────────────────────────────────
nonisolated enum Permission: Sendable { case allow, deny(String) }
typealias PermissionHook = @Sendable (ToolCall) async -> Permission

// ─────────────────────────────────────────────────────────────
// MARK: - 4. 하네스 본체
// ─────────────────────────────────────────────────────────────
actor AgentHarness {
    private let model: any LanguageModel
    private let system: String
    private let maxSteps: Int                       // 무한 루프 방지
    private let maxHistory: Int                     // 컨텍스트 창 한계 대비
    private let permission: PermissionHook
    private let log: LogSink

    private var history: [Message] = []
    private var tools: [ToolSpec] = []
    private var route: [String: MCPClient] = [:]    // 도구 이름 → 담당 MCP 서버
    // (여러 서버의 도구 이름이 겹칠 수 있어서 실제 하네스는 "mcp__서버명__도구명"처럼 접두사를 붙이기도 한다)

    init(model: any LanguageModel,
         system: String,
         maxSteps: Int = 8,
         maxHistory: Int = 40,
         permission: @escaping PermissionHook = { _ in .allow },
         log: @escaping LogSink = consoleLog) {
        self.model = model
        self.system = system
        self.maxSteps = maxSteps
        self.maxHistory = maxHistory
        self.permission = permission
        self.log = log
    }

    /// UI 표시용: 현재 장착된 도구 메뉴판
    func availableTools() -> [ToolSpec] { tools }

    /// UI 표시용: 현재 대화 기록 길이
    func historyCount() -> Int { history.count }

    /// MCP 서버 장착: 메뉴판(tools/list)을 받아 라우팅 표에 등록
    func attach(_ client: MCPClient) async throws {
        try await client.discover()
        let list = try await client.listTools()
        for t in list {
            tools.append(t)
            route[t.name] = client
        }
        let name = await client.serverName
        log(LogEntry(.harness, "🔌 \(name) 연결 — 도구: \(list.map(\.name).joined(separator: ", "))"))
    }

    /// ★ 하네스의 심장: 에이전트 루프
    func run(_ input: String) async throws -> String {
        history.append(.user(input))

        for step in 1...maxSteps {
            compactIfNeeded()

            // ① 생각 — 모델에게 "지금까지의 기록 + 쓸 수 있는 도구"를 주고 다음 행동을 받는다
            let turn = try await model.next(system: system, history: history, tools: tools)
            history.append(.assistant(text: turn.text, toolCalls: turn.toolCalls))
            log(LogEntry(.thought, "🧠 [\(step)] \(turn.text)"))

            // ② 종료 판정 — 도구 요청이 없으면 이것이 최종 답
            guard turn.stop == .toolUse, !turn.toolCalls.isEmpty else { return turn.text }

            // ③ 행동 — 요청된 도구를 (권한 확인 후) MCP로 실행하고
            // ④ 관찰 — 결과를 기록에 붙인다 → 다음 바퀴에서 모델이 읽는다
            for call in turn.toolCalls {
                history.append(await execute(call))
            }
        }
        return "⚠️ 최대 \(maxSteps)단계에 도달해 중단했습니다."
    }

    private func execute(_ call: ToolCall) async -> Message {
        func result(_ text: String, error: Bool) -> Message {
            log(LogEntry(.tool, "🔧 \(call.name)(\(call.arguments.compact)) → \(text)"))
            return .toolResult(callID: call.id, content: text, isError: error)
        }

        if case .deny(let why) = await permission(call) {
            return result("거부됨: \(why)", error: true)        // MCP 서버까지 가지도 않는다
        }
        guard let client = route[call.name] else {
            return result("존재하지 않는 도구입니다", error: true)
        }
        do {
            let r = try await client.callTool(call.name, arguments: call.arguments)
            return result(r.text, error: r.isError)
        } catch {
            return result("전송 오류: \(error)", error: true)  // 실패도 모델에게 "관찰"로 돌려준다
        }
    }

    /// 컨텍스트 관리: 기록이 너무 길어지면 앞부분을 잘라낸다.
    /// (제품급 하네스는 잘라낸 부분을 모델에게 요약시켜 앞에 붙이는 "compaction"을 한다)
    private func compactIfNeeded() {
        guard history.count > maxHistory else { return }
        let from = history.count - maxHistory / 2
        // 도구 요청 ↔ 도구 결과의 짝이 깨지지 않도록 user 메시지 경계에서만 자른다
        guard let cut = history[from...].firstIndex(where: \.isUser) else { return }
        history.removeSubrange(..<cut)
        log(LogEntry(.harness, "🗜 컨텍스트 압축: 앞쪽 \(cut)개 메시지 제거"))
    }
}
