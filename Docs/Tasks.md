# 하네스 랩 — 태스크 문서

기준일 2026-10-01. 상태: ✅ 완료 · 🔄 진행 · ⬜ 대기. 수용 기준은 `Docs/TechPRD.md` 6장을 따른다.

## 마일스톤

| M | 이름 | 상태 | 내용 |
|---|---|---|---|
| M1 | Core 이식 | ✅ | 콘솔 데모 6개 파일을 앱 라이브러리로 |
| M2 | 세 칸 UI | ✅ | 채팅·와이어·온톨로지, 승인 알림 |
| M3 | 교육 투명성 | ✅ | 학습 가이드, 와이어 해설, 코드 지도 |
| M4 | 문서·공개 준비 | ✅ | PRD, 태스크, 교육 커리큘럼, README, 다이어그램, 스크린샷, Apache-2.0 |
| M5 | 품질 보강 | ⬜ | 테스트 타깃, 기기 검증, 첫 커밋 |

## M1 · Core 이식

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T-101 | `MCP.swift` 이식, `print` → `LogSink`, 모든 타입 `nonisolated` | ✅ | `typealias`에는 `nonisolated` 불가 |
| T-102 | `Harness.swift` 이식, `log` 주입, `availableTools()` 추가 | ✅ | ScriptedModel은 별도 파일로 분리 |
| T-103 | `Ontology.swift` 이식, `Binding` → `Bindings`, `Term.shortName`, `explain` 미지 사실 처리 | ✅ | SwiftUI `Binding` 충돌 해소 |
| T-104 | `OntologyMCPBridge.swift`: `OntologyService.snapshot/explain`, `ontology_explain` 도구 추가 | ✅ | `nonisolated extension Ontology` |
| T-105 | `OntologyDemo.swift`: `run()` → `report()` 줄 배열, `sampleQuestions` | ✅ | |
| T-106 | `ScriptedModel.swift`: 날씨·삭제 + 온톨로지 질의·설명·추가 규칙, 결과 그룹화 | ✅ | 8개 예시 질문 보장 |
| T-107 | Core만으로 전체 파이프라인 스니펫 검증 | ✅ | `RunCodeSnippet` |

## M2 · 세 칸 UI

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T-201 | `AppModel`: 서버·파이프·하네스 조립(`rebuild`), `send` | ✅ | 원 `main.swift` 역할 |
| T-202 | 권한 훅: `delete_*` 거부, `ontology_add_fact` 승인 알림(`CheckedContinuation`) | ✅ | |
| T-203 | 로그 `AsyncStream` 소비 + `flushLog()`로 🧠/🔧 → 말풍선 순서 보장 | ✅ | 첫 실행에서 순서 역전 발견 후 수정 |
| T-204 | `ChatPane`: 말풍선, 추적 줄, 예시 질문 칩, 입력창 | ✅ | |
| T-205 | `WirePane`: 전체/JSON-RPC/하네스 필터, 도구 메뉴판 | ✅ | |
| T-206 | `OntologyPane`: 통계, 사실/추론됨/스키마, 근거 트리, 데모 리포트 시트 | ✅ | `Section` 열거형 → `Part` |
| T-207 | 모델 선택(스크립트/온디바이스), 사용 불가 사유 표시 | ✅ | |
| T-208 | `OnDeviceLanguageModel` (FoundationModels `@Generable`) | ✅ | 응답 품질은 기기 검증 필요 (T-503) |
| T-209 | iPhone 탭 레이아웃, visionOS/iOS 빌드 | ✅ | `xcodebuild` 두 플랫폼 성공 |
| T-210 | 앱 표시 이름 "하네스 랩" | ✅ | `INFOPLIST_KEY_CFBundleDisplayName` |

## M3 · 교육 투명성

| ID | 태스크 | 상태 | 비고 |
|---|---|---|---|
| T-301 | `LearningGuide` 7개 장(큰 그림, 루프, 권한, MCP, 온톨로지, 모델 어댑터, 코드 지도) | ✅ | 각 장: 개념 → 화면 확인 → 코드 위치 → 실습 |
| T-302 | `LearningGuideView` 시트(NavigationSplitView) + 📖 버튼 | ✅ | |
| T-303 | `WireAnnotator`: 와이어·생각·도구 로그에 해설 캡션 | ✅ | id·메서드·의미 |
| T-304 | DEBUG 실행 인자 `-autoDemo`, `-showGuide` | ✅ | 검증·스크린샷용 |

## M4 · 문서·공개 준비

| ID | 태스크 | 상태 | 산출물 |
|---|---|---|---|
| T-401 | 기술 PRD | ✅ | `Docs/TechPRD.md` |
| T-402 | 태스크 문서 | ✅ | `Docs/Tasks.md` (이 문서) |
| T-403 | 교육 커리큘럼 | ✅ | `Docs/Training.md` |
| T-404 | README (한국어 + English summary, Mermaid) | ✅ | `README.md` |
| T-405 | 다이어그램 4종 | ✅ | `Docs/diagrams/architecture-layers.svg`, `agent-loop.svg`, `mcp-flow.svg`, `ontology-inference.svg` |
| T-406 | 대표 스크린샷 | ✅ | `Docs/screenshots/main-three-panes.png`, `learning-guide.png` |
| T-407 | Apache-2.0 `LICENSE`, `NOTICE`, `.gitignore` | ✅ | |
| T-408 | `git init -b main` (커밋은 GitHub Desktop에서) | ✅ | 커밋 없음 |

## M5 · 품질 보강 (대기)

| ID | 태스크 | 상태 | 수용 기준 |
|---|---|---|---|
| T-501 | Swift Testing 타깃: `Reasoner` 규칙별 추론 수, `Validator` 모순, `Query` 조인, `ScriptedModel` 8개 질문 | ⬜ | 전부 통과 |
| T-502 | `MCPClient`/`MCPServer` 왕복 테스트(버전 불일치 → `-32022`) | ⬜ | |
| T-503 | 온디바이스 모델 기기 검증(Apple Intelligence 켜진 Mac / Vision Pro) | ⬜ | 8개 질문 중 6개 이상 같은 도구 선택 |
| T-504 | visionOS 시뮬레이터 실제 실행 스크린샷 | ⬜ | |
| T-505 | 첫 커밋과 GitHub 공개 | ⬜ | GitHub Desktop |
| T-506 | 두 번째 MCP 서버 장착 데모(도구 이름 접두사) | ⬜ | 선택 |
| T-507 | compaction 요약 모드(모델에게 앞부분 요약 요청) | ⬜ | 선택 |

## 결정 기록

| 날짜 | 결정 | 이유 |
|---|---|---|
| 10-01 | Core 타입 전부 `nonisolated` (빌드 설정 변경 대신) | SwiftUI 쪽은 MainActor 기본을 유지하고, 라이브러리만 명시적으로 격리 해제 |
| 10-01 | 모델이 FoundationModels의 Tool 호출 기능을 쓰지 않고 구조화 출력으로 "결정"만 냄 | 하네스가 실행 주체임을 코드에서 그대로 보여주기 위해 |
| 10-01 | 로그 순서 보장을 `Task.yield` 대신 flush 표식으로 | 결정적이어야 수업에서 매번 같은 화면이 나온다 |
| 10-01 | `ontology_explain` 도구 추가 | 원 데모 ⑤("왜 아는가")를 모델이 도구로 꺼내 쓰게 하기 위해 |
