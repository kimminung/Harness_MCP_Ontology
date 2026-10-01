# 하네스 랩 — 직원 교육 커리큘럼

대상: 에이전트/LLM 제품을 만들거나 기획하는 개발자·PM. Swift 기초가 있으면 실습까지, 없으면 시연 중심으로 진행한다.
형식: 90분 × 3세션. 각 세션은 **시연(앱) → 개념 → 코드 읽기 → 실습 → 퀴즈** 순서.
준비물: Xcode 26, 이 저장소, 실행 대상 My Mac. (visionOS 시뮬레이터도 가능)

앱 안의 📖 **학습 가이드**가 이 문서의 요약본이다. 수업 중에는 가이드를 띄워 두고, 이 문서는 진행자용으로 쓴다.

---

## 세션 1 — 하네스: LLM은 함수, 나머지는 바깥 틀

### 시연 (15분)
1. `서울 날씨 어때?` → 왼쪽 칸에서 🧠 → 🔧 → 말풍선. "모델은 `get_weather`를 불러달라고 했을 뿐, 실행은 누가 했나?"
2. `7번 메모 삭제해줘` → 🔧 줄에 `거부됨`. 가운데 칸에 `tools/call`이 **없음**을 확인. "서버까지 가지도 않았다."
3. `추가: 마포국밥 판매함 국밥` → 승인 알림. 거부를 눌러 보고, 다시 보내 허용.

### 개념 (20분)
- 모델 어댑터 `LanguageModel.next(system:history:tools:) -> ModelTurn` 하나뿐.
- 에이전트 루프 4단계와 두 안전장치(`maxSteps`, `maxHistory`). `Docs/diagrams/agent-loop.svg`.
- 권한 훅은 **실행 전** 게이트. 정책 거부(즉시) vs 사용자 승인(async 대기).
- 실패도 관찰이다: `isError: true`가 모델에게 돌아가야 재시도가 가능하다.

### 코드 읽기 (20분)
`Core/Harness.swift`를 위에서 아래로. 멈춰서 볼 곳:
- `run(_:)`의 `guard turn.stop == .toolUse, !turn.toolCalls.isEmpty else { return turn.text }` — 종료 판정 한 줄.
- `execute(_:)`의 `if case .deny(let why) = await permission(call)` — 서버보다 먼저.
- `compactIfNeeded()` — 왜 user 메시지 경계에서만 자르는가.
`App/AppModel.swift`의 `permission(for:)`, `askUser`, `resolveApproval` — continuation으로 클릭을 기다리는 법.

### 실습 (25분)
1. `AgentHarness(maxSteps: 1)`로 바꾸고 질문 → "⚠️ 최대 1단계" 확인 → 원복.
2. `permission(for:)`에 `get_weather`도 승인이 필요하도록 추가.
3. (도전) `ScriptedModel.summarize`에서 `ontology_query` 결과 후 `ontology_explain`을 한 번 더 요청해 2바퀴 루프 만들기.

### 퀴즈
- 모델이 낸 `ToolCall`을 실제로 실행하는 함수는? (`AgentHarness.execute`)
- 거부된 도구 호출은 와이어 칸에 왜 안 보이나?
- `maxHistory`를 넘겼을 때 아무 데서나 자르면 어떤 문제가 생기나?

---

## 세션 2 — MCP: 봉투·운반·어휘

### 시연 (15분)
1. 앱 시작 직후 가운데 칸 맨 위: `server/discover`(id 1) → `tools/list`(id 2). 캡션을 읽는다.
2. "도구 메뉴판" 탭 → `description`과 `inputSchema`. "LLM이 보는 것이 정확히 이것이다."
3. 질문 하나 → `tools/call`(C→S)과 같은 id의 응답(S→C) 짝 찾기.

### 개념 (20분)
- JSON-RPC 2.0: 요청(id+method), 알림(id 없음), 응답(result|error). `Docs/diagrams/mcp-flow.svg`.
- 무상태(2026-07-28): 핸드셰이크 대신 `params._meta`에 버전·클라이언트 정보. 서버는 **매 요청** 검사.
- 운반 3종: InMemory(이 앱), stdio(한 줄 = JSON 하나, stdout에 로그 찍으면 깨짐), Streamable HTTP(요청마다 독립 POST).
- 도구 실패는 프로토콜 에러가 아니다: `result.isError = true`.

### 코드 읽기 (20분)
`Core/MCP.swift`:
- `RPCMessage.isRequest/isNotification/isResponse` — 세 가지를 구분하는 기준.
- `MCPServer.handle` — 버전 검사 → `switch method`. `tools/call`의 `do/catch`가 왜 `toolResult(…, isError: true)`로 끝나는지.
- `MCPClient.request` — `waiting[id] = cont` 를 **먼저** 하고 전송하는 이유(주석 참고).
- `InMemoryTransport.send` — 바이트로 직렬화했다가 다시 해석하는 이유.

### 실습 (25분)
1. `MCPServer.handle`에 `"ping"` case 추가(`["pong": true]` 반환) → `MCPClient.ping()` → `attach` 직후 호출 → 와이어 칸에서 확인.
2. `AppModel.rebuild`의 `get_weather` description을 바꾸고 "도구 메뉴판"이 바뀌는지 확인. 스크립트 모델의 선택은 왜 안 바뀌나? (규칙 기반이라서 — 진짜 LLM이라면 바뀔 수 있다)
3. (도전) `MCP.protocolVersion`을 클라이언트 쪽만 바꿔 `-32022 Unsupported protocol version`을 만들어 보기.

### 퀴즈
- `tools/list` 응답에서 LLM이 도구를 고르는 유일한 근거 필드는?
- 세션(핸드셰이크)이 없는데 서버가 버전을 어떻게 아나?
- stdio 서버에서 `print()`를 쓰면 안 되는 이유는?

---

## 세션 3 — 온톨로지: 추측 대신 조회, 쓰기는 검증 후에

### 시연 (15분)
1. 오른쪽 칸 통계(입력 24 / 추론 29). "추론됨" 탭의 보라색 규칙 이름.
2. `왜 달콤크로플이 서울에 있다고 알아?` → 근거 트리. 트리플 하나를 눌러 같은 트리 확인.
3. `추가: 합정동 판매함 크로플` → 거부 사유 읽기. 그래프가 바뀌지 않았음을 통계로 확인.
4. "데모 리포트" 시트 ①~⑥.

### 개념 (20분)
- 모든 지식은 트리플, 스키마도 트리플(`rdfs:subClassOf`, `rdfs:domain` …). `Docs/diagrams/ontology-inference.svg`.
- 전방 연쇄: 규칙을 새 사실이 안 나올 때까지 반복 = 고정점. 7규칙 표.
- 질의 = 패턴 조인. 변수는 같은 값이어야 한다.
- 검증: `disjointWith`. `commitIfConsistent`는 복사본에서 먼저 해 본다(값 타입).
- 왜 LLM 옆에 온톨로지인가: 추측(환각) 대신 조회, 쓰기는 스키마가 막아준다. 모델이 쓰는 도구는 `ontology_query / explain / add_fact` 셋.

### 코드 읽기 (20분)
`Core/Ontology.swift`:
- `TripleStore.match` — 세 인덱스 중 가장 작은 풀에서 시작.
- `Reasoner.rules` 중 "전이 관계"와 "domain 추론" 두 개를 손으로 따라가기.
- `Query.extend` — `if let old = next[v], old != value { return nil }`.
- `Ontology.commitIfConsistent` 4줄.
`Core/OntologyMCPBridge.swift` — 도구 설명에 `vocabulary`를 넣는 이유(없는 클래스를 지어내지 않게).

### 실습 (25분)
1. `OntologyDemo.build()`에 가게 하나 추가(예: `ex:연남커피` 카페, 연남동 위치, 평점 4.8; 연남동은 마포구) → `서울에 있는 음식점 중 평점 4.5 이상인 곳은?` 결과 확인.
2. `추가: 달콤크로플 위치함 마포국밥` 을 보내고 왜 거부되는지 설명하기(range 추론 → 마포국밥이 지역 → 음식점과 disjoint).
3. (도전) `Reasoner.rules`에 `owl:FunctionalProperty` 규칙 추가 후 "데모 리포트" 수치 변화 보기.

### 퀴즈
- "달콤크로플은 서울에 있다"가 입력에 없는데 질의가 맞는 이유는?
- `commitIfConsistent`가 원본을 건드리지 않고 검증할 수 있는 이유는?
- 모델이 `ontology_add_fact`로 환각을 쓰려 할 때 막는 두 겹의 장치는? (사용자 승인 + 스키마 검증)

---

## 평가 체크리스트 (수료 기준)

- [ ] 세 칸 각각이 어느 층에 대응하는지 설명할 수 있다.
- [ ] 에이전트 루프 4단계를 로그(🧠/🔧/말풍선)와 연결할 수 있다.
- [ ] 권한 훅의 정책 거부와 사용자 승인의 차이를 코드 위치로 말할 수 있다.
- [ ] JSON-RPC 요청과 응답을 id로 짝지을 수 있고, `isError`와 `error`의 차이를 안다.
- [ ] 추론된 사실의 근거 트리를 읽고, 스키마 모순 거부 사유를 설명할 수 있다.
- [ ] 실습 과제 중 각 세션 1개 이상을 완료했다.

---

## 부록 A — Core만 명령줄에서 돌리기

`MyApp/Core/*.swift`를 macOS Command Line Tool 프로젝트에 넣고 아래를 `main.swift`로 쓰면 UI 없이 같은 흐름을 콘솔에서 볼 수 있다. (`consoleLog`가 기본 싱크라 `print`로 찍힌다.)

```swift
import Foundation

let (clientPipe, serverPipe) = InMemoryTransport.pair()
let server = MCPServer(name: "demo-server", version: "1.0", transport: serverPipe)

await server.register(MCPTool(
    name: "get_weather",
    description: "도시 이름을 받아 현재 날씨를 알려준다.",
    inputSchema: ["type": "object", "properties": ["city": ["type": "string"]], "required": ["city"]],
    run: { args in "\(args["city"]?.stringValue ?? "?") 맑음 23℃" }))

let service = OntologyService(OntologyDemo.build())
let vocabulary = await service.snapshot().onto.vocabulary
for tool in ontologyTools(service: service, vocabulary: vocabulary) { await server.register(tool) }
Task { await server.run() }

let harness = AgentHarness(
    model: ScriptedModel(),
    system: "너는 도구를 쓸 줄 아는 비서다.",
    permission: { call in call.name.hasPrefix("delete_") ? .deny("파괴적 작업은 사용자 승인이 필요") : .allow })
try await harness.attach(MCPClient(transport: clientPipe))

for question in OntologyDemo.sampleQuestions {
    print("\n👤 \(question)")
    print("✅ \(try await harness.run(question))")
}
```

## 부록 B — Claude API 어댑터를 만든다면

`LanguageModel`을 구현하는 타입 하나면 된다. 하는 일은 형식 변환뿐이다.

| 하네스 | Claude Messages API |
|---|---|
| `[ToolSpec]` | `tools: [{ name, description, input_schema }]` |
| `.user(text)` | `{"role":"user","content":text}` |
| `.assistant(text, toolCalls)` | `{"role":"assistant","content":[{"type":"text"…},{"type":"tool_use","id","name","input"}]}` |
| `.toolResult(callID, content, isError)` | user 메시지 안의 `{"type":"tool_result","tool_use_id","content","is_error"}` |
| 응답 `tool_use` 블록 | `ToolCall(id, name, arguments)` |
| `stop_reason == "tool_use"` | `.toolUse` |

앱 샌드박스의 네트워크(아웃바운드)를 켜야 하고, API 키는 소스에 넣지 않는다.
