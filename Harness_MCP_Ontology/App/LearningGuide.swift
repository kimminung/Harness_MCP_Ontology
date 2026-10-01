//
//  LearningGuide.swift
//  앱 안에 들어 있는 교육 자료 — "이 화면에서 보이는 것이 코드의 어디에서 오는가"
//
//  교육 원칙: 개념 → 화면에서 확인 → 코드 위치 → 직접 바꿔보기(실습)
//

import Foundation

nonisolated struct GuideSection: Identifiable, Sendable {
    let id: String
    let title: String
    let systemImage: String
    let summary: String
    let points: [String]
    let files: [String]
    let tryIt: [String]
}

nonisolated enum LearningGuide {

    static let sections: [GuideSection] = [

        GuideSection(
            id: "overview",
            title: "큰 그림: 세 개의 층",
            systemImage: "square.3.layers.3d",
            summary: "LLM은 '다음 출력'을 내는 함수일 뿐이다. 도구를 실행하고, 결과를 다시 먹이고, 권한·기억을 관리하는 바깥 틀이 하네스다. 하네스는 MCP라는 공통 규약으로 도구 서버와 대화하고, 도구 서버 중 하나가 온톨로지(지식 그래프)를 감싼다.",
            points: [
                "① 하네스(Agent Harness) — 에이전트 루프, 권한 훅, 컨텍스트 압축. 왼쪽 칸이 입구와 출구.",
                "② MCP(Model Context Protocol) — JSON-RPC 2.0 봉투 + 전송(Transport) + 어휘(tools/list, tools/call). 가운데 칸이 선 위를 흐르는 메시지.",
                "③ 온톨로지(Ontology) — 트리플 저장소 + 스키마 + 추론기 + 질의 + 검증. 오른쪽 칸이 그래프의 현재 상태.",
                "모델(LLM)은 교체 가능한 부품이다. 상단 메뉴에서 스크립트 모델 ↔ 온디바이스 모델을 바꿔도 나머지 두 층은 그대로다.",
            ],
            files: ["App/AppModel.swift (조립)", "Core/Harness.swift", "Core/MCP.swift", "Core/Ontology.swift"],
            tryIt: [
                "예시 질문 하나를 보낸 뒤, 세 칸을 왼쪽→가운데→오른쪽 순서로 읽어 보세요. 한 질문이 세 층을 어떻게 통과하는지 보입니다.",
            ]
        ),

        GuideSection(
            id: "loop",
            title: "하네스의 심장: 에이전트 루프",
            systemImage: "arrow.triangle.2.circlepath",
            summary: "run(_:)은 네 단계를 maxSteps만큼 반복한다. ① 생각(모델에게 기록+도구 목록을 주고 다음 행동을 받음) → ② 종료 판정(도구 요청이 없으면 그것이 최종 답) → ③ 행동(권한 확인 후 MCP로 실행) → ④ 관찰(결과를 기록에 붙임).",
            points: [
                "채팅 칸의 🧠 줄이 ①, 🔧 줄이 ③+④, 말풍선이 ②(최종 답)이다.",
                "모델은 도구를 '실행'하지 않는다. ToolCall(id, name, arguments)라는 JSON을 낼 뿐이다. 실행은 언제나 execute(_:)의 몫.",
                "도구 실패도 isError=true인 '관찰'로 모델에게 돌아간다. 그래서 모델이 인자를 고쳐 재시도할 수 있다.",
                "maxSteps(기본 8)는 무한 루프 방지, maxHistory(기본 40)는 컨텍스트 창 한계 대비. compactIfNeeded()는 user 메시지 경계에서만 잘라 도구 요청↔결과 짝을 지킨다.",
            ],
            files: ["Core/Harness.swift — AgentHarness.run / execute / compactIfNeeded"],
            tryIt: [
                "AgentHarness 생성 시 maxSteps를 1로 바꾸고 질문을 보내 보세요. '최대 1단계에 도달' 메시지가 최종 답이 됩니다.",
                "ScriptedModel.summarize에서 ontology_query 결과가 오면 한 번 더 ontology_explain을 요청하도록 바꿔, 2단계 루프를 만들어 보세요.",
            ]
        ),

        GuideSection(
            id: "permission",
            title: "권한 훅: 모델이 원한다고 전부 실행하지 않는다",
            systemImage: "hand.raised",
            summary: "PermissionHook은 ToolCall을 받아 .allow 또는 .deny(이유)를 돌려주는 async 함수다. 하네스는 MCP 서버에 보내기 '전에' 이 훅을 부른다.",
            points: [
                "delete_ 접두사 도구는 정책으로 즉시 거부된다 → '7번 메모 삭제해줘'를 보내면 서버까지 가지도 않는다(와이어 칸에 tools/call이 없다).",
                "ontology_add_fact는 사람에게 묻는다 → 승인 다이얼로그. 훅이 async라서 CheckedContinuation으로 사용자의 클릭을 기다릴 수 있다.",
                "거부 사유도 모델에게 '관찰'로 돌아간다. 모델은 왜 안 됐는지 읽고 사용자에게 설명할 수 있다.",
            ],
            files: ["Core/Harness.swift — PermissionHook, execute", "App/AppModel.swift — permission(for:), askUser, resolveApproval"],
            tryIt: [
                "AppModel.permission(for:)에 get_weather를 거부하는 규칙을 추가해 보세요. 어떤 메시지가 어디까지 흐르는지 와이어 칸에서 비교하세요.",
            ]
        ),

        GuideSection(
            id: "mcp",
            title: "MCP: 봉투·운반·어휘",
            systemImage: "envelope.open",
            summary: "MCP 메시지는 JSON-RPC 2.0이다. 요청(id+method) → 같은 id의 응답(result 또는 error). 운반은 메모리 파이프·stdio·HTTP 무엇이든 되고, 어휘는 server/discover, tools/list, tools/call 같은 메서드 이름이다.",
            points: [
                "가운데 칸의 C→S(파랑)가 요청, S→C(초록)가 응답. 같은 id끼리 짝이다.",
                "2026-07-28 스펙은 무상태(stateless): 핸드셰이크 대신 모든 요청의 params._meta에 프로토콜 버전·클라이언트 정보를 싣는다. 서버는 매 요청마다 버전을 검사한다.",
                "tools/list 응답이 곧 LLM이 보는 '도구 설명서'다. description이 모델이 도구를 고르는 유일한 근거, inputSchema가 인자 모양이다. '도구 메뉴판' 탭에서 확인.",
                "InMemoryTransport는 실제처럼 바이트로 직렬화했다가 상대편이 다시 해석한다. 이 데모가 같은 프로세스인 것은 운반 방식의 차이일 뿐이다.",
            ],
            files: ["Core/MCP.swift — RPCMessage, MCPTransport, InMemoryTransport, MCPServer, MCPClient"],
            tryIt: [
                "MCPServer.handle에 'ping' 메서드 case를 추가하고, MCPClient에 ping()을 만들어 attach 직후 호출해 보세요.",
                "AppModel.rebuild의 날씨 도구 설명(description)을 바꾸면 '도구 메뉴판' 탭 내용이 어떻게 바뀌는지 확인하세요.",
            ]
        ),

        GuideSection(
            id: "ontology",
            title: "온톨로지: 추측 대신 조회, 쓰기는 검증 후에",
            systemImage: "point.3.connected.trianglepath.dotted",
            summary: "모든 지식은 (주어 술어 목적어) 트리플 한 줄이다. 스키마(클래스 계층, domain/range, 전이·대칭·역관계)도 트리플이다. 추론기는 규칙을 새 사실이 안 나올 때까지 반복 적용하고, 검증기는 disjointWith 모순을 찾는다.",
            points: [
                "오른쪽 칸 '추론됨' 탭의 보라색 규칙 이름은 Proof.rule이다. 트리플을 누르면 explain()이 근거를 거슬러 올라간다.",
                "'달콤크로플은 서울에 있다'는 어디에도 직접 적혀 있지 않다. 합정동⊂마포구⊂서울 + 전이 관계 규칙으로 추론된 것이다.",
                "commitIfConsistent는 복사본(가상 세계)에 먼저 넣고 추론·검증한 뒤, 모순이 없을 때만 반영한다. TripleStore가 값 타입이라 복사가 한 줄이다.",
                "'합정동이 크로플을 판다'는 거부된다: 판매함의 domain이 음식점이라 합정동이 음식점이 되는데, 음식점과 지역은 disjoint이기 때문.",
            ],
            files: ["Core/Ontology.swift — TripleStore, Reasoner.rules, Validator, Query, Ontology", "Core/OntologyDemo.swift — 예시 데이터", "Core/OntologyMCPBridge.swift — 도구 3개"],
            tryIt: [
                "OntologyDemo.build()에 새 가게를 추가하고 '합정동에 있는 카페 알려줘'로 조회해 보세요.",
                "Reasoner.rules에 'owl:FunctionalProperty' 같은 규칙을 하나 추가하고, 추론 수가 어떻게 바뀌는지 '데모 리포트'로 확인하세요.",
                "'추가: 달콤크로플 위치함 마포국밥'을 보내 range 검증이 어떻게 반응하는지 보세요 (힌트: 마포국밥이 지역이 되어 버린다).",
            ]
        ),

        GuideSection(
            id: "model",
            title: "모델 어댑터: 형식 변환이 전부",
            systemImage: "brain",
            summary: "LanguageModel 프로토콜은 next(system:history:tools:) 하나다. ScriptedModel은 규칙으로, OnDeviceLanguageModel은 Apple Foundation Models의 구조화 출력(@Generable)으로 같은 ModelTurn을 만든다.",
            points: [
                "ScriptedModel은 '진짜 LLM이 하는 일'을 흉내 낸다: 질문 속 단어를 어휘(ex:카페, ex:위치함…)로 옮기고, 도구 결과를 읽어 문장으로 정리한다.",
                "OnDeviceLanguageModel은 모델에게 text/toolName/argumentsJSON 세 칸을 채우게 한다. 모델이 도구를 직접 부르지 않으므로 하네스 구조가 그대로 드러난다.",
                "Claude API 어댑터를 만든다면: [ToolSpec] → tools 배열, [Message] → messages 배열, 응답의 tool_use 블록 → ToolCall, stop_reason == tool_use → .toolUse. 그게 전부다.",
            ],
            files: ["Core/ScriptedModel.swift", "App/OnDeviceLanguageModel.swift", "Core/Harness.swift — LanguageModel 프로토콜"],
            tryIt: [
                "ScriptedModel.decide에 '메뉴' 질문 규칙을 하나 더 추가해 보세요 (예: '국밥 파는 곳').",
                "Apple Intelligence가 켜진 기기라면 상단 메뉴에서 온디바이스 모델로 바꾸고 같은 질문을 보내, 두 모델이 같은 도구를 고르는지 비교하세요.",
            ]
        ),

        GuideSection(
            id: "codemap",
            title: "코드 지도",
            systemImage: "map",
            summary: "파일 하나가 개념 하나다. 위에서 아래로 읽으면 의존 방향과 같다.",
            points: [
                "Core/MCP.swift — JSONValue, LogEntry/LogSink, RPCMessage, Transport 3종, ToolSpec, MCPTool, MCPServer, MCPClient",
                "Core/Harness.swift — Message, ToolCall, ModelTurn, LanguageModel, Permission, AgentHarness",
                "Core/Ontology.swift — Term, Triple, V(어휘), TripleStore, Reasoner, Validator, QTerm/Query, Ontology",
                "Core/OntologyMCPBridge.swift — OntologyService(actor), ontologyTools(…) 도구 3개",
                "Core/OntologyDemo.swift — 예시 그래프 build(), 단계별 report(), 예시 질문",
                "Core/ScriptedModel.swift — 규칙 기반 데모 모델",
                "App/AppModel.swift — 조립(main.swift 역할), 승인 흐름, 로그 스트림",
                "App/OnDeviceLanguageModel.swift — Foundation Models 어댑터",
                "App/LearningGuide.swift — 이 가이드",
                "ContentView.swift — 세 칸 화면",
            ],
            files: [],
            tryIt: [
                "Core 폴더만 떼어 내면 UI 없이도 돌아간다. 명령줄 도구 프로젝트에 Core를 넣고 원래 main.swift(Docs 참고)로 실행해 보세요.",
            ]
        ),
    ]
}
