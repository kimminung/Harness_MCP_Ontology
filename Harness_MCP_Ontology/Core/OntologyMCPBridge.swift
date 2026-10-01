//
//  OntologyMCPBridge.swift
//  온톨로지를 MCP 도구로 노출 → 하네스 속 LLM이 "추측" 대신 "조회"하고,
//  LLM의 "쓰기"는 추론·검증을 통과해야만 반영된다.
//
//  도구 세 개:
//    ontology_query     — 패턴 질의 (읽기)
//    ontology_explain   — "왜 그렇게 아는가" 근거 트리 (읽기)
//    ontology_add_fact  — 사실 추가 (쓰기, 추론·검증 통과 시에만 반영)
//

import Foundation

nonisolated struct ToolError: Error, CustomStringConvertible {
    let description: String
}

/// 여러 도구 호출이 동시에 와도 지식 그래프가 꼬이지 않도록 actor로 감싼다
actor OntologyService {
    private var onto: Ontology
    private var revision = 0            // UI가 "바뀌었는지" 싸게 알 수 있게

    init(_ onto: Ontology) {
        var o = onto
        o.reason()
        self.onto = o
    }

    /// UI용 스냅샷 — Ontology는 값 타입이라 그대로 복사해 주면 끝
    func snapshot() -> (onto: Ontology, revision: Int) { (onto, revision) }

    /// patterns: [["?가게","rdf:type","ex:음식점"], ...]
    func query(_ args: JSONValue) throws -> String {
        guard case .array(let rows)? = args["patterns"] else {
            throw ToolError(description: "patterns 인자가 필요합니다")
        }
        let patterns: [Pattern] = try rows.map { row -> Pattern in
            guard case .array(let cells) = row, cells.count == 3,
                  let s = cells[0].stringValue,
                  let p = cells[1].stringValue,
                  let o = cells[2].stringValue else {
                throw ToolError(description: "각 패턴은 문자열 3개짜리 배열이어야 합니다")
            }
            return (QTerm.parse(s), QTerm.parse(p), QTerm.parse(o))
        }

        let results = onto.ask(Query(patterns))
        guard !results.isEmpty else { return "결과 없음" }
        return results
            .map { b in b.keys.sorted().map { "\($0)=\(b[$0]!)" }.joined(separator: ", ") }
            .sorted()
            .joined(separator: "\n")
    }

    /// subject / predicate / object 로 지목한 사실의 근거 트리
    func explain(_ args: JSONValue) throws -> String {
        let fact = try Self.triple(from: args)
        return onto.explain(fact)
    }

    /// subject / predicate / object 하나를 추가. 모순이면 throw → MCP 결과의 isError = true
    func addFact(_ args: JSONValue) throws -> String {
        let fact = try Self.triple(from: args)
        let problems = onto.commitIfConsistent(fact)
        guard problems.isEmpty else {
            throw ToolError(description: "거부됨(스키마와 모순): " + problems.joined(separator: "; "))
        }
        revision += 1
        return "반영됨: \(fact)"
    }

    private static func triple(from args: JSONValue) throws -> Triple {
        guard let s = args["subject"]?.stringValue,
              let p = args["predicate"]?.stringValue,
              let o = args["object"]?.stringValue else {
            throw ToolError(description: "subject, predicate, object가 모두 필요합니다")
        }
        return Triple(Term.parse(s), Term.parse(p), Term.parse(o))
    }
}

nonisolated extension Ontology {
    /// LLM에게 보여줄 어휘 목록. 도구 설명에 넣어두면 없는 클래스·관계를 지어내지 않는다.
    var vocabulary: String {
        let subclassTriples = kb.match(nil, V.subClassOf, nil)
        let classes = Set(subclassTriples.flatMap { [$0.s, $0.o] })

        var properties = Set<Term>()
        for key in [V.domain, V.range, V.inverseOf] {
            for t in kb.match(nil, key, nil) { properties.insert(t.s) }
        }
        for t in kb.match(nil, V.type, V.Transitive) { properties.insert(t.s) }
        for t in kb.match(nil, V.type, V.Symmetric)  { properties.insert(t.s) }

        let classList = classes.map(\.description).sorted().joined(separator: ", ")
        let propertyList = properties.map(\.description).sorted().joined(separator: ", ")
        return "클래스: \(classList) / 관계: \(propertyList)"
    }
}

/// 하네스의 MCP 서버에 등록할 도구들
nonisolated func ontologyTools(for onto: Ontology) -> [MCPTool] {
    ontologyTools(service: OntologyService(onto), vocabulary: onto.vocabulary)
}

nonisolated func ontologyTools(service: OntologyService, vocabulary vocab: String) -> [MCPTool] {
    let tripleSchema: JSONValue = [
        "type": "object",
        "properties": [
            "subject":   ["type": "string", "description": "주어 IRI (예: ex:마포국밥)"],
            "predicate": ["type": "string", "description": "술어 IRI (예: ex:판매함, rdf:type)"],
            "object":    ["type": "string", "description": "목적어 IRI 또는 따옴표로 감싼 리터럴"]
        ],
        "required": ["subject", "predicate", "object"]
    ]

    return [
        MCPTool(
            name: "ontology_query",
            description: """
            지식 그래프를 패턴으로 조회한다. 각 패턴은 [주어, 술어, 목적어]이고 ?로 시작하면 변수다. \
            타입은 rdf:type, 값(리터럴)은 따옴표로 감싼다. 사실을 추측하지 말고 이 도구로 확인할 것. \
            사용 가능한 어휘 — \(vocab)
            """,
            inputSchema: [
                "type": "object",
                "properties": [
                    "patterns": [
                        "type": "array",
                        "items": [
                            "type": "array",
                            "items": ["type": "string"],
                            "minItems": 3,
                            "maxItems": 3
                        ]
                    ]
                ],
                "required": ["patterns"]
            ],
            run: { args in try await service.query(args) }
        ),
        MCPTool(
            name: "ontology_explain",
            description: "지식 그래프가 어떤 사실을 '왜' 아는지 추론 근거 트리를 돌려준다. 입력된 사실이면 그렇게 표시된다.",
            inputSchema: tripleSchema,
            run: { args in try await service.explain(args) }
        ),
        MCPTool(
            name: "ontology_add_fact",
            description: "지식 그래프에 사실 하나를 추가한다. 추론 후 스키마와 모순되면 거부된다.",
            inputSchema: tripleSchema,
            run: { args in try await service.addFact(args) }
        ),
    ]
}
