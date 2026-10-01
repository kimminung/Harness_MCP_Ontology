# 하네스 랩 — 기술 PRD

| 항목 | 내용 |
|---|---|
| 문서 버전 | 1.0 (2026-10-01) |
| 제품명 | 하네스 랩 (Harness Lab) — Xcode 타깃 `MyApp`, 표시 이름 "하네스 랩" |
| 상태 | 구현 완료, 교육 배포 준비 |
| 플랫폼 | macOS 27, visionOS 27, iOS 27 (단일 타깃, `TARGETED_DEVICE_FAMILY = 1,2,7`) |
| 언어/프레임워크 | Swift 6.2 (Swift 5 언어 모드, Approachable Concurrency, 기본 격리 MainActor), SwiftUI, Observation, FoundationModels(선택) |
| 외부 의존성 | 없음 |

## 1. 배경과 문제

사내 교육에서 "에이전트", "MCP", "온톨로지"는 각각 따로 설명되고, 실제 코드에서 어디까지가 LLM의 일이고 어디부터가 바깥 코드의 일인지 모호하게 남는다. 기존 자료는 콘솔 데모(명령줄 도구 + `print`)여서 세 층이 동시에 어떻게 맞물리는지 한눈에 보기 어렵고, 수강생이 스스로 바꿔보며 결과를 확인하기 번거롭다.

## 2. 목표

1. **한 화면, 세 층.** 질문 하나가 하네스 → MCP → 온톨로지를 통과하는 과정을 세 칸에서 동시에 본다.
2. **코드 투명성.** 화면의 모든 줄이 어느 파일의 어느 함수에서 나오는지 앱 안에서 안내한다(학습 가이드, 와이어 해설, 코드 지도).
3. **결정적 데모.** 네트워크·API 키 없이 같은 입력에 같은 출력을 내는 스크립트 모델로 수업을 진행할 수 있다.
4. **실습 가능.** 수강생이 규칙·도구·권한 정책을 한 줄 바꾸고 ⌘R로 결과를 즉시 확인한다.
5. **진짜 모델로 확장.** 같은 하네스에 온디바이스 Foundation Models를 끼워 "모델이 바뀌어도 구조는 그대로"임을 보인다.

## 3. 비목표

- 공식 MCP SDK 호환, 원격 MCP 서버 실제 연결(HTTPTransport는 구조 설명용으로만 포함).
- SPARQL/OWL 표준 완전 구현. 7개 규칙과 `disjointWith` 검증만 다룬다.
- 대화 저장, 멀티 세션, 사용자 계정.
- 프로덕션급 compaction(요약). 앞부분 절단만 구현한다.

## 4. 대상 사용자

| 페르소나 | 요구 |
|---|---|
| 교육 진행자 | 예시 질문 버튼으로 시나리오를 재현하고, 와이어 칸을 띄워 설명한다 |
| 신입/전환 개발자 | 학습 가이드의 "직접 바꿔보기"를 수행하며 코드 위치를 익힌다 |
| 기획/PM | 권한 훅·검증 거부 같은 안전장치가 어디서 작동하는지 화면으로 이해한다 |

## 5. 아키텍처

```
┌───────────────────────────── App (MainActor) ─────────────────────────────┐
│ ContentView ── ChatPane · WirePane(WireAnnotator) · OntologyPane · Guide  │
│ AppModel: 조립(서버·파이프·하네스) · 승인 흐름 · 로그 AsyncStream · 스냅샷 │
└──────────────┬──────────────────────────┬──────────────────────┬──────────┘
               │ LogSink                  │ run(question)        │ snapshot()
┌──────────────▼───────┐  ┌───────────────▼────────┐  ┌──────────▼──────────┐
│ MCPServer (actor)    │◀─│ AgentHarness (actor)   │  │ OntologyService     │
│ tools: weather, note,│  │ model: LanguageModel   │  │ (actor)             │
│ ontology_*           │  │ permission: hook       │  │ Ontology (struct)   │
│ transport: InMemory  │  │ route → MCPClient      │  │ reason/ask/commit   │
└──────────────────────┘  └────────────────────────┘  └─────────────────────┘
```

### 5.1 Core (UI 비의존, `Foundation`만 import)

| 파일 | 책임 | 핵심 타입 |
|---|---|---|
| `MCP.swift` | JSON 값, JSON-RPC 봉투, 전송, 서버, 클라이언트, 로그 싱크 | `JSONValue`, `RPCMessage`, `RPCError`, `MCPTransport`, `InMemoryTransport`, `StdioTransport`(macOS), `HTTPTransport`, `ToolSpec`, `MCPTool`, `MCPServer`, `MCPClient`, `LogEntry`, `LogSink` |
| `Harness.swift` | 대화 기록, 모델 추상화, 권한, 에이전트 루프 | `Message`, `ToolCall`, `ModelTurn`, `LanguageModel`, `Permission`, `PermissionHook`, `AgentHarness` |
| `Ontology.swift` | 트리플 저장소, 어휘, 추론, 검증, 질의 | `Term`, `Triple`, `V`, `TripleStore`, `Proof`, `Rule`, `Reasoner`, `Validator`, `QTerm`, `Query`, `Bindings`, `Ontology` |
| `OntologyMCPBridge.swift` | 온톨로지를 MCP 도구로 노출 | `OntologyService`, `ontologyTools(service:vocabulary:)`, `Ontology.vocabulary` |
| `OntologyDemo.swift` | 예시 데이터, 단계별 리포트, 예시 질문 | `OntologyDemo.build/report/sampleQuestions` |
| `ScriptedModel.swift` | 규칙 기반 데모 모델 | `ScriptedModel` |

### 5.2 App

| 파일 | 책임 |
|---|---|
| `AppModel.swift` | `@Observable @MainActor`. 서버·파이프·하네스 조립(`rebuild`), 질문 실행(`send`), 권한 훅 구현(`permission(for:)`, `askUser`, `resolveApproval`), 로그 스트림 소비와 순서 보장(`flushLog`), 온톨로지 스냅샷, DEBUG 자동 데모 |
| `OnDeviceLanguageModel.swift` | FoundationModels 어댑터. `@Generable ModelDecision{text, toolName, argumentsJSON}`로 결정만 받고 실행은 하네스가 함 |
| `LearningGuide.swift`, `LearningGuideView.swift` | 7개 장(개념/화면 확인/코드 위치/실습) |
| `ContentView.swift` | 세 칸 레이아웃(iPhone은 탭), 승인 알림, `WireAnnotator`(JSON 한 줄 → 한 문장 해설) |

## 6. 기능 요구사항

| ID | 요구사항 | 수용 기준 |
|---|---|---|
| F-01 | 질문 입력과 예시 질문 버튼 | 8개 예시 질문이 모두 최종 답을 낸다 |
| F-02 | 에이전트 루프 가시화 | 사용자 말풍선 → 🧠 → 🔧 → 최종 말풍선 순서가 항상 보장된다 |
| F-03 | 와이어 로그 | 모든 C→S/S→C 메시지가 JSON 원문 + 해설 캡션(id, 메서드, 의미)으로 표시된다 |
| F-04 | 도구 메뉴판 | `tools/list` 결과(name, description, inputSchema)를 그대로 보여준다 |
| F-05 | 권한 훅: 정책 거부 | `delete_*`는 서버 전송 전에 거부되고, 와이어에 `tools/call`이 남지 않는다 |
| F-06 | 권한 훅: 사용자 승인 | `ontology_add_fact`는 알림을 띄우고, 허용/거부가 결과에 반영된다 |
| F-07 | 온톨로지 인스펙터 | 전체/입력/추론 수, 사실·추론됨·스키마 탭, 트리플 선택 시 근거 트리 |
| F-08 | 쓰기 검증 | 스키마 모순 사실은 `isError: true`로 거부되고 그래프가 바뀌지 않는다 |
| F-09 | 데모 리포트 | 원 콘솔 데모 ①~⑥을 시트로 보여준다 |
| F-10 | 모델 교체 | 스크립트 ↔ 온디바이스 전환 시 하네스가 재조립되고, 사용 불가 시 사유를 표시한다 |
| F-11 | 학습 가이드 | 7개 장, 각 장에 코드 위치와 실습 과제 포함 |
| F-12 | 멀티플랫폼 | macOS·visionOS·iOS 빌드 성공; iPhone은 탭 레이아웃 |

## 7. 비기능 요구사항

| 항목 | 기준 |
|---|---|
| 결정성 | 스크립트 모델은 같은 질문에 같은 도구 호출과 같은 답을 낸다 |
| 응답 시간 | 스크립트 모델 기준 한 질문 완료 < 100 ms (메모리 파이프) |
| 동시성 안전 | 서버·클라이언트·하네스·온톨로지는 actor; Core 값 타입은 `Sendable` + `nonisolated` |
| 빌드 품질 | 경고 0, 외부 패키지 0 |
| 접근성 | 모든 로그/답변 텍스트 선택 가능, 동적 글꼴 사용 |
| 프라이버시 | 네트워크 사용 없음(앱 샌드박스 네트워크 꺼짐). 온디바이스 모델만 사용 |

## 8. 데이터 모델

### 8.1 하네스 기록
```
Message = .user(String)
        | .assistant(text, toolCalls: [ToolCall])
        | .toolResult(callID, content, isError)
ToolCall = { id, name, arguments: JSONValue }
ModelTurn = { text, toolCalls, stop: .endTurn | .toolUse }
```

### 8.2 MCP 봉투
```
RPCMessage = { jsonrpc:"2.0", id?, method?, params?, result?, error? }
params._meta = { "io.modelcontextprotocol/protocolVersion": "2026-07-28", clientInfo, clientCapabilities }
tools/call result = { resultType:"complete", content:[{type:"text", text}], isError }
```

### 8.3 온톨로지
```
Term = .iri(String) | .literal(String)
Triple = (s, p, o)
TripleStore = { all: Set<Triple>, bySubject/byPredicate/byObject, proofs: [Triple: Proof] }
Proof = { rule, premises }
```
예시 그래프: 입력 24 트리플 → 추론 후 53 (29 추론). 사실 1건 추가 후 입력 25 / 전체 54.

## 9. 주요 흐름

### 9.1 질문 한 바퀴 (스크립트 모델)
1. `AppModel.send` → `chat.append(.user)` → `harness.run(q)`
2. 하네스 ① `model.next` → `ModelTurn(toolCalls: [ontology_query])`, 로그 🧠
3. ③ `permission(call)` → `.allow` → `MCPClient.callTool` → `tools/call` 요청(와이어 C→S) → 서버 `OntologyService.query` → 응답(S→C)
4. ④ `history.append(.toolResult)`, 로그 🔧
5. 다음 바퀴 ① `model.next` → `.endTurn` → 최종 텍스트
6. `AppModel.flushLog()`로 로그 스트림을 비운 뒤 `chat.append(.assistant)` → 순서 보장
7. `refreshOntology()` 스냅샷 갱신

### 9.2 승인 흐름
`permission(for:)` → `askUser` → `withCheckedContinuation` 저장 + `pendingApproval` 설정 → SwiftUI alert → 버튼 → `resolveApproval(Bool)` → continuation 재개 → 하네스 계속.

### 9.3 모델 교체
`switchModel` → `rebuild()`: 이전 서버 Task·로그 Task 취소, 대기 중 flush 해제 → 새 파이프·서버·하네스 → `attach` → `tools` 갱신.

## 10. 빌드 설정과 제약

| 설정 | 값 | 이유 |
|---|---|---|
| `SWIFT_DEFAULT_ACTOR_ISOLATION` | MainActor | 템플릿 기본. Core는 전부 `nonisolated` |
| `SWIFT_APPROACHABLE_CONCURRENCY` | YES | `nonisolated(nonsending)` 기본 → actor 메서드 호출 단순화 |
| `ENABLE_APP_SANDBOX` | YES, 네트워크 OFF | `StdioTransport.launch`·`HTTPTransport`는 데모에서 미사용 |
| `INFOPLIST_KEY_CFBundleDisplayName` | 하네스 랩 | 창 제목 |

알려진 제약: `nonisolated`는 `typealias`에 붙일 수 없다. 온톨로지의 `Binding` 별칭은 SwiftUI와 충돌해 `Bindings`로 이름을 바꿨다. Device Interaction 도구는 macOS를 지원하지 않아 검증은 `-autoDemo` 인자 + `screencapture`로 했다.

## 11. 리스크

| 리스크 | 대응 |
|---|---|
| 온디바이스 모델이 잘못된 JSON 인자를 만든다 | `JSONValue.parse` 실패 시 빈 객체로 호출 → 서버가 `isError`로 돌려주고 모델이 재시도 |
| 온디바이스 모델 미지원 기기 | 메뉴 비활성화 + 사유 문구, 스크립트 모델로 수업 진행 |
| 수강생이 Core를 수정해 UI가 깨짐 | Core는 UI를 모르므로 영향 범위가 로그 문자열에 한정 |
| 스크립트 모델의 한국어 파싱 한계 | 예시 질문 8개를 보장하고, 가이드에 규칙 추가 실습을 둠 |

## 12. 검증 계획과 결과

| 항목 | 방법 | 결과(2026-10-01) |
|---|---|---|
| 8개 예시 질문 | `RunCodeSnippet`으로 Core만 실행 | 전부 기대 답 |
| UI 순서 보장 | `-autoDemo` 실행 후 스크린샷 | 🧠→🔧→말풍선 순서 확인 |
| 승인 흐름 | 수동(허용/거부) | 허용 시 반영, 거부 시 `거부됨: 사용자가 거부함` |
| 멀티플랫폼 | `xcodebuild` visionOS/iOS Simulator | BUILD SUCCEEDED |
| 경고 | Xcode 빌드 로그 | 0건 |

## 13. 향후 과제

Swift Testing 타깃(Core 단위 테스트), compaction 요약 모드, 두 번째 MCP 서버 장착으로 도구 이름 접두사 데모, Claude API 어댑터 예제(네트워크 켜는 설정 포함), 수강생 진행 체크리스트 저장.
