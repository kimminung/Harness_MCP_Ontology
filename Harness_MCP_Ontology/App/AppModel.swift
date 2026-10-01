//
//  AppModel.swift
//  조립 & 실행 — 원래 main.swift가 하던 일을 앱 수명 안에서 한다.
//
//  ① MCP 서버 준비(메모리 파이프) → 날씨·메모·온톨로지 도구 등록
//  ② 하네스 조립: 모델 + MCP 클라이언트 + 권한 정책(파괴적 작업 거부, 그래프 쓰기는 사용자 승인)
//  ③ 사용자가 채팅으로 질문 → 하네스 루프 실행 → 과정은 로그로, 결과는 채팅으로
//

import Foundation
import Observation

nonisolated struct ChatEntry: Identifiable, Sendable {
    nonisolated enum Role: Sendable { case user, assistant, trace, error }
    let id = UUID()
    let role: Role
    let text: String
}

/// 권한 훅이 사용자에게 물어볼 때 UI에 띄우는 요청
nonisolated struct ApprovalRequest: Identifiable, Sendable {
    let id = UUID()
    let call: ToolCall
}

@Observable
@MainActor
final class AppModel {

    enum ModelKind: String, CaseIterable, Identifiable {
        case scripted = "스크립트 모델 (데모)"
        case onDevice = "온디바이스 모델 (Foundation Models)"
        var id: String { rawValue }
    }

    // ── UI가 바라보는 상태
    var modelKind: ModelKind = .scripted
    var isOnDeviceAvailable = false
    var onDeviceStatus = ""
    var chat: [ChatEntry] = []
    var log: [LogEntry] = []
    var tools: [ToolSpec] = []
    var ontology = OntologyDemo.build()
    var ontologyRevision = 0
    var pendingApproval: ApprovalRequest?
    var isRunning = false
    var isReady = false
    var input = ""
    var showGuide = false

    // ── 내부 부품
    private let service: OntologyService
    private var harness: AgentHarness?
    private var serverTask: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var logContinuation: AsyncStream<LogEntry>.Continuation?
    private var flushWaiters: [CheckedContinuation<Void, Never>] = []
    private var approvalContinuation: CheckedContinuation<Permission, Never>?
    private static let flushMarker = "__flush__"

    init() {
        service = OntologyService(OntologyDemo.build())
        #if canImport(FoundationModels)
        isOnDeviceAvailable = OnDeviceLanguageModel.isAvailable
        onDeviceStatus = OnDeviceLanguageModel.availabilityDescription
        #else
        onDeviceStatus = "이 플랫폼에는 FoundationModels가 없습니다"
        #endif
        #if DEBUG
        if CommandLine.arguments.contains("-showGuide") { showGuide = true }   // 스크린샷/검증용
        #endif
        Task { await rebuild() }
    }

    // MARK: - 조립

    /// 서버·파이프·하네스를 처음부터 다시 만든다 (모델을 바꿀 때도 사용)
    func rebuild() async {
        isReady = false
        serverTask?.cancel()
        logTask?.cancel()
        flushWaiters.forEach { $0.resume() }     // 이전 통로를 기다리던 쪽이 있으면 풀어준다
        flushWaiters.removeAll()
        harness = nil

        // 로그 통로: 어느 actor에서 찍든 순서대로 메인 액터로 모은다
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream()
        let sink: LogSink = { continuation.yield($0) }
        logContinuation = continuation
        logTask = Task { [weak self] in
            for await entry in stream {
                guard let self else { return }
                if entry.text == Self.flushMarker {          // 순서 맞추기용 표식: 기다리던 쪽을 깨운다
                    let waiters = self.flushWaiters
                    self.flushWaiters.removeAll()
                    waiters.forEach { $0.resume() }
                    continue
                }
                self.log.append(entry)
                // 실행 중인 턴의 생각·도구 호출은 채팅에도 흐릿하게 보여준다
                if self.isRunning, entry.kind == .thought || entry.kind == .tool {
                    self.chat.append(ChatEntry(role: .trace, text: entry.text))
                }
            }
        }

        // ① MCP 서버 준비
        //    (보통은 별도 프로세스나 원격 서버지만, 데모는 같은 프로세스에서 메모리 파이프로 연결)
        let (clientPipe, serverPipe) = InMemoryTransport.pair(log: sink)
        let server = MCPServer(name: "demo-server", version: "1.0", transport: serverPipe, log: sink)

        await server.register(MCPTool(
            name: "get_weather",
            description: "도시 이름을 받아 현재 날씨를 알려준다.",
            inputSchema: [
                "type": "object",
                "properties": ["city": ["type": "string", "description": "도시 이름"]],
                "required": ["city"]
            ],
            run: { args in "\(args["city"]?.stringValue ?? "?") 맑음 23℃" }
        ))

        await server.register(MCPTool(
            name: "delete_note",
            description: "메모를 영구 삭제한다.",
            inputSchema: [
                "type": "object",
                "properties": ["id": ["type": "integer"]],
                "required": ["id"]
            ],
            run: { _ in "삭제 완료" }
        ))

        let vocabulary = await service.snapshot().onto.vocabulary
        for tool in ontologyTools(service: service, vocabulary: vocabulary) {
            await server.register(tool)
        }

        serverTask = Task { await server.run() }

        // ② 하네스 조립: 모델 + MCP 클라이언트 + 권한 정책
        let harness = AgentHarness(
            model: makeModel(),
            system: "너는 도구를 쓸 줄 아는 비서다. 사실은 추측하지 말고 지식 그래프 도구로 확인한다.",
            permission: { [weak self] call in
                guard let self else { return .deny("앱이 종료됨") }
                return await self.permission(for: call)
            },
            log: sink
        )
        self.harness = harness

        do {
            try await harness.attach(MCPClient(transport: clientPipe))
            tools = await harness.availableTools()
            await refreshOntology()
            isReady = true
            #if DEBUG
            if Self.autoDemo { await runAutoDemo() }
            #endif
        } catch {
            chat.append(ChatEntry(role: .error, text: "MCP 서버 연결 실패: \(error)"))
        }
    }

    private func makeModel() -> any LanguageModel {
        #if canImport(FoundationModels)
        if modelKind == .onDevice, isOnDeviceAvailable { return OnDeviceLanguageModel() }
        #endif
        return ScriptedModel()
    }

    func switchModel(to kind: ModelKind) {
        guard kind != modelKind else { return }
        modelKind = kind
        chat.append(ChatEntry(role: .trace, text: "모델을 '\(kind.rawValue)'(으)로 바꿨습니다. 하네스를 다시 조립합니다."))
        Task { await rebuild() }
    }

    // MARK: - ③ 실행

    func send(_ text: String? = nil) {
        let question = (text ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isRunning, let harness else { return }
        input = ""
        chat.append(ChatEntry(role: .user, text: question))
        isRunning = true

        Task {
            defer { isRunning = false }
            do {
                let answer = try await harness.run(question)
                await flushLog()                 // 과정(🧠/🔧)이 먼저, 최종 답은 그 뒤에
                chat.append(ChatEntry(role: .assistant, text: answer))
            } catch {
                chat.append(ChatEntry(role: .error, text: "실패: \(error)"))
            }
            await refreshOntology()
        }
    }

    /// 지금까지 싱크에 들어온 로그가 전부 화면 상태에 반영될 때까지 기다린다
    private func flushLog() async {
        guard let logContinuation else { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append(continuation)
            logContinuation.yield(LogEntry(.harness, Self.flushMarker))
        }
    }

    func clearChat() {
        chat.removeAll()
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - 권한 훅 — "모델이 원한다고 전부 실행하지 않는다"

    private func permission(for call: ToolCall) async -> Permission {
        if call.name.hasPrefix("delete_") {
            return .deny("파괴적 작업은 사용자 승인이 필요")      // 정책으로 즉시 거부
        }
        if call.name == "ontology_add_fact" {
            return await askUser(call)                               // 사람에게 물어본다
        }
        return .allow
    }

    private func askUser(_ call: ToolCall) async -> Permission {
        #if DEBUG
        if Self.autoDemo { return .allow }   // 자동 데모에서는 사람 대신 허용
        #endif
        if approvalContinuation != nil {
            return .deny("다른 승인 요청이 처리 중")
        }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = ApprovalRequest(call: call)
        }
    }

    func resolveApproval(_ allow: Bool) {
        pendingApproval = nil
        let continuation = approvalContinuation
        approvalContinuation = nil
        continuation?.resume(returning: allow ? .allow : .deny("사용자가 거부함"))
    }

    // MARK: - 온톨로지 스냅샷

    func refreshOntology() async {
        let snap = await service.snapshot()
        ontology = snap.onto
        ontologyRevision = snap.revision
    }

    /// 인스펙터에서 트리플을 눌렀을 때 — 하네스를 거치지 않고 바로 설명한다
    func explain(_ t: Triple) -> String {
        ontology.explain(t)
    }

    // MARK: - 검증용 자동 데모 (실행 인자 -autoDemo)

    #if DEBUG
    nonisolated static let autoDemo = CommandLine.arguments.contains("-autoDemo")

    private func runAutoDemo() async {
        guard let harness else { return }
        for question in OntologyDemo.sampleQuestions.prefix(6) {
            chat.append(ChatEntry(role: .user, text: question))
            isRunning = true
            do {
                let answer = try await harness.run(question)
                await flushLog()
                chat.append(ChatEntry(role: .assistant, text: answer))
            } catch {
                chat.append(ChatEntry(role: .error, text: "실패: \(error)"))
            }
            isRunning = false
            await refreshOntology()
        }
    }
    #endif
}
