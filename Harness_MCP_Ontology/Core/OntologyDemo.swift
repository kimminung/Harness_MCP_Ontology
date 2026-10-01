//
//  OntologyDemo.swift
//  예시 지식 그래프(합정동 가게들)와, 추론·질의·검증 과정을 단계별로 보여주는 리포트
//

import Foundation

nonisolated enum OntologyDemo {

    static func build() -> Ontology {
        var o = Ontology()

        // ── 스키마(TBox): "세상에 어떤 종류의 것이 있고, 어떻게 연결될 수 있는가"
        o.add("ex:음식점", V.subClassOf, "ex:장소")
        o.add("ex:카페",   V.subClassOf, "ex:음식점")
        o.add("ex:한식당", V.subClassOf, "ex:음식점")
        o.add("ex:지역",   V.subClassOf, "ex:장소")
        o.add("ex:음식점", V.disjointWith, "ex:지역")        // 가게이면서 동네일 수는 없다

        o.add("ex:위치함", V.domain, "ex:장소")
        o.add("ex:위치함", V.range,  "ex:지역")
        o.add("ex:위치함", V.type,   V.Transitive)           // 합정동⊂마포구⊂서울 이 이어진다
        o.add("ex:포함함", V.inverseOf, "ex:위치함")         // 서울은 마포구를 포함한다
        o.add("ex:판매함", V.domain, "ex:음식점")            // 파는 주체는 음식점이어야
        o.add("ex:판매함", V.range,  "ex:메뉴")
        o.add("ex:평점",   V.domain, "ex:음식점")
        o.add("ex:근처",   V.type,   V.Symmetric)            // A가 B 근처면 B도 A 근처

        // ── 사실(ABox): 실제 데이터 (가게 이름은 예시용 가상 이름)
        o.add("ex:달콤크로플", V.type,      "ex:카페")
        o.add("ex:달콤크로플", "ex:위치함", "ex:합정동")
        o.add("ex:달콤크로플", "ex:판매함", "ex:크로플")
        o.add("ex:달콤크로플", "ex:평점",   .literal("4.6"))
        o.add("ex:달콤크로플", "ex:근처",   "ex:마포국밥")

        o.add("ex:마포국밥",   V.type,      "ex:한식당")
        o.add("ex:마포국밥",   "ex:위치함", "ex:합정동")
        o.add("ex:마포국밥",   "ex:평점",   .literal("4.2"))

        o.add("ex:합정동",     "ex:위치함", "ex:마포구")
        o.add("ex:마포구",     "ex:위치함", "ex:서울")
        return o
    }

    /// 원래 콘솔 데모(run)를 UI에 보여줄 수 있게 줄 단위 리포트로 바꾼 것
    static func report() -> [String] {
        var lines: [String] = []
        var onto = build()
        lines.append("① 입력한 트리플: \(onto.kb.count)개")

        // 질문: "서울에 있는 음식점 중 평점 4.5 이상인 곳은?"
        let q = Query([
            ("?가게", "rdf:type",  "ex:음식점"),
            ("?가게", "ex:위치함", "ex:서울"),
            ("?가게", "ex:평점",   "?점수"),
        ], filter: { b in
            (Double(b["?점수"]?.literalValue ?? "") ?? 0) >= 4.5
        })

        lines.append("② 추론 전 질의 결과: \(onto.ask(q).count)건 — '서울에 있다'·'음식점이다'가 어디에도 직접 적혀 있지 않음")

        let r = onto.reason()
        lines.append("③ 추론: \(r.rounds)라운드 동안 \(r.added)개 사실이 새로 생김 → 총 \(onto.kb.count)개")
        let byRule = Dictionary(grouping: onto.kb.proofs.values, by: \.rule).mapValues(\.count)
        lines.append("   규칙별: " + byRule.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · "))

        for b in onto.ask(q) {
            lines.append("④ 추론 후 질의 결과: \(b["?가게"]!)  평점 \(b["?점수"]!)")
        }

        lines.append("")
        lines.append("⑤ 왜 '달콤크로플은 서울에 있다'고 아는가?")
        lines.append(onto.explain(Triple("ex:달콤크로플", "ex:위치함", "ex:서울"))
            .trimmingCharacters(in: .newlines))

        lines.append("")
        lines.append("⑥ LLM이 만들어낸 사실을 반영하기 전에 검증")
        let candidates = [
            Triple("ex:마포국밥", "ex:판매함", "ex:국밥"),    // 정상적인 사실
            Triple("ex:합정동",   "ex:판매함", "ex:크로플"),  // 환각: 동네가 음식을 판다?
        ]
        for fact in candidates {
            let problems = onto.commitIfConsistent(fact)
            if problems.isEmpty {
                lines.append("   ✅ 반영: \(fact)")
            } else {
                lines.append("   ⛔️ 거부: \(fact) — \(problems.joined(separator: ", "))")
            }
        }
        return lines
    }

    /// 채팅 화면에 보여줄 예시 질문 — ScriptedModel이 확실히 알아듣는 문장들
    static let sampleQuestions: [String] = [
        "서울에 있는 음식점 중 평점 4.5 이상인 곳은?",
        "합정동에 있는 카페 알려줘",
        "달콤크로플 근처에 뭐가 있어?",
        "왜 달콤크로플이 서울에 있다고 알아?",
        "추가: 마포국밥 판매함 국밥",
        "추가: 합정동 판매함 크로플",
        "서울 날씨 어때?",
        "7번 메모 삭제해줘",
    ]
}
