//
//  ScriptedModel.swift
//  데모용 가짜 LLM — 규칙으로 질문을 도구 호출 JSON으로 바꾼다.
//
//  진짜 LLM도 인터페이스는 똑같다: 기록을 읽고 → 텍스트 또는 "도구 써줘" JSON을 낸다.
//  실행은 언제나 하네스의 몫. (온디바이스 모델 어댑터는 OnDeviceLanguageModel.swift)
//

import Foundation

nonisolated struct ScriptedModel: LanguageModel {

    // 질문 속 한국어 단어 → 온톨로지 IRI. 진짜 LLM이라면 도구 설명의 "어휘"를 읽고 스스로 한다.
    private static let classWords: [(String, String)] = [
        ("카페", "ex:카페"), ("한식당", "ex:한식당"), ("음식점", "ex:음식점"),
        ("맛집", "ex:음식점"), ("식당", "ex:음식점"), ("가게", "ex:음식점"), ("장소", "ex:장소"),
    ]
    private static let placeWords = ["서울", "마포구", "합정동"]

    func next(system: String, history: [Message], tools: [ToolSpec]) async throws -> ModelTurn {
        func has(_ tool: String) -> Bool { tools.contains { $0.name == tool } }

        switch history.last {
        case .user(let q)?:
            return decide(question: q, has: has)

        case .toolResult(_, let content, let isError)?:
            // 어떤 도구의 결과인지, 원래 질문이 무엇이었는지 기록에서 거슬러 찾는다
            let callName = lastToolCall(in: history)?.name ?? "?"
            let question = lastUserQuestion(in: history) ?? ""
            return summarize(tool: callName, content: content, isError: isError, question: question)

        default:
            return ModelTurn(text: "무엇을 도와드릴까요? 아래 예시 질문을 눌러보세요.")
        }
    }

    // MARK: - ① 질문 → 도구 호출

    private func decide(question q: String, has: (String) -> Bool) -> ModelTurn {
        let id = "call_\(UUID().uuidString.prefix(6))"

        // 날씨
        if q.contains("날씨"), has("get_weather") {
            let city = q.components(separatedBy: " ").first ?? "서울"
            return ModelTurn(text: "날씨 도구를 호출할게요.",
                             toolCalls: [ToolCall(id: id, name: "get_weather", arguments: ["city": .string(city)])],
                             stop: .toolUse)
        }

        // 메모 삭제 (권한 훅이 막는 것을 보여주기 위한 예)
        if q.contains("삭제"), has("delete_note") {
            let number = Double(q.components(separatedBy: CharacterSet.decimalDigits.inverted)
                .first { !$0.isEmpty } ?? "7") ?? 7
            return ModelTurn(text: "메모 삭제 도구를 호출할게요.",
                             toolCalls: [ToolCall(id: id, name: "delete_note", arguments: ["id": .number(number)])],
                             stop: .toolUse)
        }

        // 사실 추가: "추가: 마포국밥 판매함 국밥"
        if q.contains("추가"), has("ontology_add_fact"), let fact = Self.parseFact(q) {
            return ModelTurn(text: "지식 그래프에 사실을 추가해볼게요: \(fact.s) \(fact.p) \(fact.o)",
                             toolCalls: [ToolCall(id: id, name: "ontology_add_fact",
                                                  arguments: ["subject": .string(fact.s),
                                                              "predicate": .string(fact.p),
                                                              "object": .string(fact.o)])],
                             stop: .toolUse)
        }

        // 근거 설명: "왜 달콤크로플이 서울에 있다고 알아?"
        if q.contains("왜") || q.contains("근거"), has("ontology_explain") {
            if let fact = Self.parseLocationClaim(q) {
                return ModelTurn(text: "왜 그렇게 아는지 추론 근거를 조회할게요.",
                                 toolCalls: [ToolCall(id: id, name: "ontology_explain",
                                                      arguments: ["subject": .string(fact.s),
                                                                  "predicate": .string(fact.p),
                                                                  "object": .string(fact.o)])],
                                 stop: .toolUse)
            }
        }

        // 지식 그래프 질의
        if has("ontology_query"), let patterns = Self.buildPatterns(q) {
            return ModelTurn(text: "추측하지 않고 지식 그래프를 조회할게요.",
                             toolCalls: [ToolCall(id: id, name: "ontology_query", arguments: ["patterns": patterns])],
                             stop: .toolUse)
        }

        return ModelTurn(text: "무엇을 도와드릴까요? (예: \"합정동에 있는 카페 알려줘\", \"서울 날씨 어때?\")")
    }

    // MARK: - ② 도구 결과 → 최종 답변

    private func summarize(tool: String, content: String, isError: Bool, question: String) -> ModelTurn {
        if isError { return ModelTurn(text: "도구가 실패했어요 (\(content))") }

        switch tool {
        case "ontology_query":
            if content == "결과 없음" { return ModelTurn(text: "조건에 맞는 항목을 찾지 못했어요.") }
            let threshold = Self.ratingThreshold(in: question)
            // 같은 개체가 여러 줄(예: 타입이 여러 개)로 나오면 하나로 묶는다
            var order: [String] = []
            var scores: [String: String] = [:]
            var menus: [String: [String]] = [:]
            var kinds: [String: Set<String>] = [:]
            for line in content.split(separator: "\n") {
                let cells = Self.parseRow(String(line))
                if let threshold, let score = cells["?점수"].flatMap(Double.init), score < threshold { continue }
                let main = cells["?가게"] ?? cells["?이웃"] ?? cells["?메뉴"] ?? cells.values.sorted().first ?? "?"
                if !order.contains(main) { order.append(main) }
                if let score = cells["?점수"] { scores[main] = score }
                if let menu = cells["?메뉴"], cells["?가게"] != nil, !(menus[main] ?? []).contains(menu) {
                    menus[main, default: []].append(menu)
                }
                if let kind = cells["?종류"] { kinds[main, default: []].insert(kind) }
            }
            if order.isEmpty { return ModelTurn(text: "조건(평점 기준)에 맞는 항목이 없어요.") }
            let rows = order.map { main -> String in
                var extras: [String] = []
                if let kind = Self.mostSpecific(kinds[main] ?? []) { extras.append(kind) }
                if let score = scores[main] { extras.append("평점 \(score)") }
                if let menu = menus[main] { extras.append("메뉴 \(menu.joined(separator: "·"))") }
                return "• \(main)" + (extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")
            }
            return ModelTurn(text: "지식 그래프에서 확인한 결과예요:\n" + rows.joined(separator: "\n"))

        case "ontology_explain":
            return ModelTurn(text: "근거는 이렇습니다 (입력된 사실에서 규칙을 거쳐 추론됨):\n" + content.trimmingCharacters(in: .newlines))

        case "ontology_add_fact":
            return ModelTurn(text: "검증을 통과해 지식 그래프에 \(content)")

        default:
            return ModelTurn(text: "확인해보니 \(content) 입니다.")
        }
    }

    // MARK: - 기록 되짚기

    private func lastToolCall(in history: [Message]) -> ToolCall? {
        for m in history.reversed() {
            if case .assistant(_, let calls) = m, let c = calls.last { return c }
        }
        return nil
    }

    private func lastUserQuestion(in history: [Message]) -> String? {
        for m in history.reversed() {
            if case .user(let q) = m { return q }
        }
        return nil
    }

    // MARK: - 작은 파서들

    /// "ex:" 접두사가 없으면 붙인다. 따옴표 리터럴은 그대로.
    private static func iri(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") || s.contains(":") || s.hasPrefix("?") { return s }
        return "ex:" + s
    }

    /// "추가: 마포국밥 판매함 국밥" / "추가 마포국밥 평점 "4.0"" → (s, p, o)
    private static func parseFact(_ q: String) -> (s: String, p: String, o: String)? {
        var body = q
        for junk in ["추가해줘", "추가해", "추가:", "추가", ":"] { body = body.replacingOccurrences(of: junk, with: " ") }
        let tokens = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 3 else { return nil }
        return (iri(tokens[0]), iri(tokens[1]), iri(tokens[2]))
    }

    /// "왜 달콤크로플이 서울에 있다고 알아?" → (ex:달콤크로플, ex:위치함, ex:서울)
    private static func parseLocationClaim(_ q: String) -> (s: String, p: String, o: String)? {
        guard let place = placeWords.first(where: { q.contains($0) }) else { return nil }
        var body = q
        for junk in ["왜", "근거", "있다고", "있어", "있는지", "알아", "알지", "?", "？"] {
            body = body.replacingOccurrences(of: junk, with: " ")
        }
        let tokens = body.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let subject = tokens.first { !$0.contains(place) }
            .map { Self.stripParticles($0) }
        guard let subject, !subject.isEmpty else { return nil }
        return (iri(subject), "ex:위치함", iri(place))
    }

    /// 질문에서 [클래스 / 위치 / 평점 / 메뉴 / 근처] 단서를 찾아 질의 패턴을 만든다
    private static func buildPatterns(_ q: String) -> JSONValue? {
        var patterns: [JSONValue] = []

        // "X 근처" — 특정 가게의 이웃
        if q.contains("근처") {
            let tokens = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let i = tokens.firstIndex(where: { $0.hasPrefix("근처") }), i > 0 {
                let subject = stripParticles(tokens[i - 1])
                patterns.append([.string(iri(subject)), "ex:근처", "?이웃"])
                patterns.append(["?이웃", "rdf:type", "?종류"])
                return .array(patterns)
            }
        }

        var subjectVar = "?가게"
        if let cls = classWords.first(where: { q.contains($0.0) }) {
            patterns.append([.string(subjectVar), "rdf:type", .string(cls.1)])
        }
        if let place = placeWords.first(where: { q.contains($0) }) {
            patterns.append([.string(subjectVar), "ex:위치함", .string(iri(place))])
        }
        if q.contains("평점") || q.contains("이상") || q.contains("점") {
            patterns.append([.string(subjectVar), "ex:평점", "?점수"])
        }
        if q.contains("메뉴") || q.contains("파는") || q.contains("판매") || q.contains("뭘 팔") {
            patterns.append([.string(subjectVar), "ex:판매함", "?메뉴"])
        }
        if patterns.isEmpty {
            // "크로플 파는 곳" 같은 메뉴 중심 질문
            if q.contains("크로플") || q.contains("국밥") {
                let menu = q.contains("크로플") ? "ex:크로플" : "ex:국밥"
                subjectVar = "?가게"
                patterns.append([.string(subjectVar), "ex:판매함", .string(menu)])
            } else {
                return nil
            }
        }
        if patterns.count == 1, case .array(let cells) = patterns[0], cells.count == 3,
           cells[1].stringValue == "ex:위치함", cells[2].stringValue?.hasPrefix("?") == false {
            // 위치만 물었으면 뭐든 그 지역에 있는 것들을 타입과 함께
            patterns.append([.string(subjectVar), "rdf:type", "?종류"])
        }
        return .array(patterns)
    }

    /// 상위 개념(장소·음식점)보다 구체적인 타입을 고른다: {장소, 음식점, 카페} → 카페
    private static func mostSpecific(_ kinds: Set<String>) -> String? {
        guard !kinds.isEmpty else { return nil }
        for general in ["장소", "음식점"] where kinds.count > 1 && kinds.contains(general) {
            var narrowed = kinds
            narrowed.remove(general)
            return mostSpecific(narrowed)
        }
        return kinds.sorted().joined(separator: "/")
    }

    /// "4.5 이상" → 4.5
    private static func ratingThreshold(in q: String) -> Double? {
        guard q.contains("이상") else { return nil }
        let scanner = Scanner(string: q)
        scanner.charactersToBeSkipped = CharacterSet.decimalDigits.union(CharacterSet(charactersIn: ".")).inverted
        return scanner.scanDouble()
    }

    /// "?가게=ex:달콤크로플, ?점수="4.6"" → ["?가게": "달콤크로플", "?점수": "4.6"]
    private static func parseRow(_ line: String) -> [String: String] {
        var out: [String: String] = [:]
        for cell in line.split(separator: ",") {
            let parts = cell.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            out[parts[0]] = Term.parse(parts[1]).shortName
        }
        return out
    }

    /// 조사 떼기: "달콤크로플이" → "달콤크로플", "마포국밥은" → "마포국밥"
    private static func stripParticles(_ word: String) -> String {
        var w = word
        for particle in ["이가", "에서는", "에서", "에는", "은", "는", "이", "가", "을", "를", "에", "의"] {
            if w.hasSuffix(particle), w.count > particle.count {
                w = String(w.dropLast(particle.count))
                break
            }
        }
        return w
    }
}
