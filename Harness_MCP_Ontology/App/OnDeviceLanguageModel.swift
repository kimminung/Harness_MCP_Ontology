//
//  OnDeviceLanguageModel.swift
//  Apple Foundation Models(온디바이스)를 하네스의 LanguageModel 어댑터로 감싼 것.
//
//  핵심: 모델은 도구를 "실행"하지 않는다. 구조화 출력(@Generable)으로
//  "이 도구를 이 인자로 불러줘"라는 결정만 내고, 실행은 AgentHarness가 한다.
//  (Foundation Models 자체의 Tool 호출 기능을 쓰지 않는 이유 — 하네스 구조를 그대로 드러내기 위해)
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels

/// 모델이 한 턴에 내놓는 결정. 도구가 필요 없으면 toolName은 빈 문자열.
@Generable
nonisolated struct ModelDecision: Sendable {
    @Guide(description: "사용자에게 보여줄 한국어 문장. 도구를 부른다면 무엇을 확인할지 짧게.")
    var text: String

    @Guide(description: "호출할 도구 이름. 도구 목록에 있는 이름만 가능. 도구가 필요 없으면 빈 문자열.")
    var toolName: String

    @Guide(description: "도구 인자를 담은 JSON 객체 문자열 (예: {\"city\":\"서울\"}). 도구가 없으면 빈 문자열.")
    var argumentsJSON: String

    init(text: String, toolName: String, argumentsJSON: String) {
        self.text = text
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
    }
}

nonisolated struct OnDeviceLanguageModel: LanguageModel {

    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    static var availabilityDescription: String {
        switch SystemLanguageModel.default.availability {
        case .available:
            return "온디바이스 모델 사용 가능"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:       return "이 기기는 온디바이스 모델을 지원하지 않습니다"
            case .appleIntelligenceNotEnabled: return "설정에서 Apple Intelligence를 켜야 합니다"
            case .modelNotReady:           return "모델을 내려받는 중입니다. 잠시 후 다시 시도하세요"
            @unknown default:              return "온디바이스 모델을 쓸 수 없습니다"
            }
        }
    }

    func next(system: String, history: [Message], tools: [ToolSpec]) async throws -> ModelTurn {
        let session = LanguageModelSession(instructions: Self.instructions(system: system, tools: tools))
        let prompt = Self.render(history)
        let decision = try await session.respond(to: prompt, generating: ModelDecision.self).content

        let toolName = decision.toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !toolName.isEmpty, tools.contains(where: { $0.name == toolName }) else {
            return ModelTurn(text: decision.text)
        }
        let arguments = JSONValue.parse(decision.argumentsJSON) ?? [:]
        return ModelTurn(
            text: decision.text,
            toolCalls: [ToolCall(id: "call_\(UUID().uuidString.prefix(6))", name: toolName, arguments: arguments)],
            stop: .toolUse)
    }

    // MARK: - 형식 변환 (어댑터가 하는 일의 전부)

    private static func instructions(system: String, tools: [ToolSpec]) -> String {
        var s = "The person's locale is ko_KR. You MUST respond in Korean.\n"
        s += system + "\n\n"
        s += "너는 아래 도구 중 하나를 골라 호출을 '요청'할 수 있다. 도구는 네가 아니라 바깥 하네스가 실행하고, 결과를 다음 턴에 '도구결과'로 돌려준다.\n"
        s += "도구결과가 이미 기록에 있으면 그것을 바탕으로 최종 답을 쓰고 toolName은 빈 문자열로 둔다.\n"
        s += "IRI는 반드시 'ex:' 접두사를 붙인다 (예: ex:달콤크로플, ex:서울). 변수는 '?가게'처럼 ?로 시작한다.\n\n"
        s += "사용 가능한 도구:\n"
        for t in tools {
            s += "- \(t.name): \(t.description)\n  입력 스키마: \(t.inputSchema.compact)\n"
        }
        return s
    }

    private static func render(_ history: [Message]) -> String {
        var lines: [String] = ["대화 기록:"]
        for m in history {
            switch m {
            case .user(let q):
                lines.append("사용자: \(q)")
            case .assistant(let text, let calls):
                lines.append("어시스턴트: \(text)")
                for c in calls { lines.append("  → 도구 요청 \(c.name)(\(c.arguments.compact))") }
            case .toolResult(_, let content, let isError):
                lines.append("도구결과\(isError ? "(오류)" : ""): \(content)")
            }
        }
        lines.append("")
        lines.append("다음 행동을 결정하라.")
        return lines.joined(separator: "\n")
    }
}
#endif
