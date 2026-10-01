//
//  Ontology.swift
//  온톨로지(지식 그래프 + 스키마 + 추론)의 내부를 직접 구현한 학습용 코드
//
//  온톨로지 = ① 트리플 저장소 — 모든 지식을 "주어-술어-목적어" 한 줄로
//            ② 스키마(TBox)  — 클래스 계층, 관계의 domain/range/특성 (이것도 트리플!)
//            ③ 추론기        — 규칙을 새 사실이 안 나올 때까지 반복 적용
//            ④ 질의          — 변수(?x)가 들어간 패턴 매칭 (SPARQL의 축소판)
//            ⑤ 검증          — 스키마와 모순되는 사실 탐지
//
//  ※ 실무 표준은 RDF / RDFS / OWL, 질의 언어는 SPARQL. 이 파일은 그 핵심 원리만 담은 축소판.
//  ※ 앱 통합 메모: 변수 바인딩 타입 이름이 SwiftUI의 Binding과 겹쳐 `Bindings`로 바꿨다.
//

import Foundation

// ─────────────────────────────────────────────────────────────
// MARK: - 0. Term — 그래프의 점: 이름(IRI) 또는 값(리터럴)
// ─────────────────────────────────────────────────────────────
nonisolated enum Term: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    case iri(String)        // "ex:달콤크로플", "ex:카페", "rdf:type" — 무언가를 가리키는 이름
    case literal(String)    // "4.6" — 그냥 값 (다른 사실의 주어가 될 수 없음)

    init(stringLiteral s: String) { self = .iri(s) }

    /// 외부 입력용: "\"4.6\"" 처럼 따옴표로 감싸면 리터럴, 아니면 IRI
    static func parse(_ s: String) -> Term {
        if s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            return .literal(String(s.dropFirst().dropLast()))
        }
        return .iri(s)
    }

    var literalValue: String? {
        if case .literal(let v) = self { return v } else { return nil }
    }

    /// 표시용: "ex:" 접두사를 뗀 짧은 이름
    var shortName: String {
        switch self {
        case .iri(let s):
            if let colon = s.firstIndex(of: ":") { return String(s[s.index(after: colon)...]) }
            return s
        case .literal(let s): return s
        }
    }

    var description: String {
        switch self {
        case .iri(let s):     return s
        case .literal(let s): return "\"\(s)\""
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 1. Triple — 지식의 최소 단위
// ─────────────────────────────────────────────────────────────
nonisolated struct Triple: Hashable, Sendable, CustomStringConvertible {
    let s: Term   // 주어
    let p: Term   // 술어(관계)
    let o: Term   // 목적어

    init(_ s: Term, _ p: Term, _ o: Term) {
        self.s = s
        self.p = p
        self.o = o
    }

    var description: String { "(\(s) \(p) \(o))" }
}

/// 표준 어휘. 핵심 포인트: 스키마도 "약속된 이름을 쓴 트리플"일 뿐이다.
nonisolated enum V {
    static let type: Term         = "rdf:type"                // x는 C의 인스턴스다
    static let subClassOf: Term   = "rdfs:subClassOf"         // A는 B의 하위 개념이다
    static let domain: Term       = "rdfs:domain"             // 이 관계의 주어는 반드시 C다
    static let range: Term        = "rdfs:range"              // 이 관계의 목적어는 반드시 C다
    static let inverseOf: Term    = "owl:inverseOf"           // p와 q는 서로 반대 방향
    static let disjointWith: Term = "owl:disjointWith"        // A와 B는 동시에 될 수 없다
    static let Transitive: Term   = "owl:TransitiveProperty"  // x p y, y p z ⇒ x p z
    static let Symmetric: Term    = "owl:SymmetricProperty"   // x p y ⇒ y p x

    /// 스키마(TBox) 술어인지 — UI에서 사실(ABox)과 구분해 보여주기 위함
    static func isSchemaPredicate(_ p: Term) -> Bool {
        [subClassOf, domain, range, inverseOf, disjointWith].contains(p)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 2. 트리플 저장소 — 인덱스 3개로 "어느 칸이 비어 있어도" 빨리 찾는다
// ─────────────────────────────────────────────────────────────
nonisolated struct Proof: Sendable {
    let rule: String          // 어떤 규칙으로
    let premises: [Triple]    // 어떤 사실들로부터 나왔는가
}

nonisolated struct TripleStore: Sendable {
    private(set) var all: Set<Triple> = []
    private var bySubject:   [Term: Set<Triple>] = [:]
    private var byPredicate: [Term: Set<Triple>] = [:]
    private var byObject:    [Term: Set<Triple>] = [:]
    private(set) var proofs: [Triple: Proof] = [:]   // 추론된 사실의 근거 (입력된 사실엔 없음)

    var count: Int { all.count }

    /// 새 사실이면 true, 이미 알던 사실이면 false
    @discardableResult
    mutating func add(_ t: Triple, proof: Proof? = nil) -> Bool {
        guard all.insert(t).inserted else { return false }
        bySubject[t.s, default: []].insert(t)
        byPredicate[t.p, default: []].insert(t)
        byObject[t.o, default: []].insert(t)
        if let proof { proofs[t] = proof }
        return true
    }

    /// 패턴 매칭: nil = 아무거나(와일드카드). 값이 정해진 칸 중 가장 작은 인덱스에서 출발한다.
    func match(_ s: Term? = nil, _ p: Term? = nil, _ o: Term? = nil) -> [Triple] {
        let pools = [s.map { bySubject[$0] ?? [] },
                     p.map { byPredicate[$0] ?? [] },
                     o.map { byObject[$0] ?? [] }].compactMap { $0 }
        let pool = pools.min(by: { $0.count < $1.count }) ?? all
        return Array(pool.filter { t in
            (s == nil || t.s == s) && (p == nil || t.p == p) && (o == nil || t.o == o)
        })
    }

    func has(_ t: Triple) -> Bool { all.contains(t) }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 3. 추론기 — 규칙을 "새 사실이 안 나올 때까지" 반복 (전방 연쇄, forward chaining)
// ─────────────────────────────────────────────────────────────
nonisolated struct Derivation: Sendable {
    let fact: Triple
    let premises: [Triple]
}

nonisolated func derive(_ fact: Triple, from premises: Triple...) -> Derivation {
    Derivation(fact: fact, premises: premises)
}

/// 규칙 = "지식 베이스를 보고, 새로 결론 낼 수 있는 사실들을 돌려주는 함수"
nonisolated struct Rule: Sendable {
    let name: String
    let fire: @Sendable (TripleStore) -> [Derivation]
}

nonisolated enum Reasoner {
    static let rules: [Rule] = [

        // A ⊂ B, B ⊂ C  ⇒  A ⊂ C
        Rule(name: "하위클래스 전이") { kb in
            kb.match(nil, V.subClassOf, nil).flatMap { ab in
                kb.match(ab.o, V.subClassOf, nil).map { bc in
                    derive(Triple(ab.s, V.subClassOf, bc.o), from: ab, bc)
                }
            }
        },

        // x는 A, A ⊂ B  ⇒  x는 B
        Rule(name: "타입 상속") { kb in
            kb.match(nil, V.type, nil).flatMap { xa in
                kb.match(xa.o, V.subClassOf, nil).map { ab in
                    derive(Triple(xa.s, V.type, ab.o), from: xa, ab)
                }
            }
        },

        // p의 domain = C, x p y  ⇒  x는 C
        Rule(name: "domain 추론") { kb in
            kb.match(nil, V.domain, nil).flatMap { pc in
                kb.match(nil, pc.s, nil).map { xpy in
                    derive(Triple(xpy.s, V.type, pc.o), from: xpy, pc)
                }
            }
        },

        // p의 range = C, x p y  ⇒  y는 C   (값/리터럴에는 타입을 붙이지 않음)
        Rule(name: "range 추론") { kb in
            kb.match(nil, V.range, nil).flatMap { pc in
                kb.match(nil, pc.s, nil).compactMap { xpy -> Derivation? in
                    guard case .iri(_) = xpy.o else { return nil }
                    return derive(Triple(xpy.o, V.type, pc.o), from: xpy, pc)
                }
            }
        },

        // p는 전이적, x p y, y p z  ⇒  x p z
        Rule(name: "전이 관계") { kb in
            kb.match(nil, V.type, V.Transitive).flatMap { pt in
                kb.match(nil, pt.s, nil).flatMap { xy in
                    kb.match(xy.o, pt.s, nil).map { yz in
                        derive(Triple(xy.s, pt.s, yz.o), from: xy, yz, pt)
                    }
                }
            }
        },

        // p는 대칭, x p y  ⇒  y p x
        Rule(name: "대칭 관계") { kb in
            kb.match(nil, V.type, V.Symmetric).flatMap { ps in
                kb.match(nil, ps.s, nil).map { xy in
                    derive(Triple(xy.o, ps.s, xy.s), from: xy, ps)
                }
            }
        },

        // p와 q는 역관계, x p y  ⇒  y q x   (반대 방향도)
        Rule(name: "역관계") { kb in
            kb.match(nil, V.inverseOf, nil).flatMap { pq -> [Derivation] in
                let forward = kb.match(nil, pq.s, nil).map { xy in
                    derive(Triple(xy.o, pq.o, xy.s), from: xy, pq)
                }
                let backward = kb.match(nil, pq.o, nil).map { xy in
                    derive(Triple(xy.o, pq.s, xy.s), from: xy, pq)
                }
                return forward + backward
            }
        },
    ]

    /// 고정점(fixpoint)에 도달할 때까지 모든 규칙을 반복 적용
    /// (실제 엔진은 매 라운드 "새로 생긴 사실"만 다시 보는 semi-naive 평가, RETE 등으로 최적화한다)
    @discardableResult
    static func saturate(_ kb: inout TripleStore) -> (added: Int, rounds: Int) {
        var added = 0
        var rounds = 0
        while true {
            rounds += 1
            var fresh = 0
            for rule in rules {
                for d in rule.fire(kb) {
                    if kb.add(d.fact, proof: Proof(rule: rule.name, premises: d.premises)) {
                        fresh += 1
                    }
                }
            }
            added += fresh
            if fresh == 0 { return (added, rounds) }   // 더 알아낼 게 없다 = 완료
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 4. 검증기 — 스키마와 모순되는 사실 찾기
// ─────────────────────────────────────────────────────────────
nonisolated enum Validator {
    static func contradictions(in kb: TripleStore) -> [String] {
        kb.match(nil, V.disjointWith, nil).flatMap { ab -> [String] in
            kb.match(nil, V.type, ab.s)
                .filter { kb.has(Triple($0.s, V.type, ab.o)) }
                .map { "\($0.s)은(는) \(ab.s)이면서 동시에 \(ab.o)일 수 없음" }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 5. 질의 — 변수(?x)를 채워 넣는 패턴 매칭 (SPARQL의 축소판)
// ─────────────────────────────────────────────────────────────
nonisolated enum QTerm: Sendable, ExpressibleByStringLiteral {
    case variable(String)   // "?가게"
    case term(Term)         // "ex:서울"

    init(stringLiteral s: String) { self = QTerm.parse(s) }

    static func parse(_ s: String) -> QTerm {
        s.hasPrefix("?") ? .variable(s) : .term(Term.parse(s))
    }
}

typealias Pattern = (QTerm, QTerm, QTerm)
typealias Bindings = [String: Term]          // 변수 이름 → 찾아낸 값

nonisolated struct Query {
    let patterns: [Pattern]
    let filter: (Bindings) -> Bool

    init(_ patterns: [Pattern], filter: @escaping (Bindings) -> Bool = { _ in true }) {
        self.patterns = patterns
        self.filter = filter
    }

    /// 패턴을 하나씩 적용하며 후보 해답을 넓히고 좁힌다 (= 조인)
    func run(on kb: TripleStore) -> [Bindings] {
        let solutions = patterns.reduce([Bindings()]) { partial, pattern in
            partial.flatMap { extend($0, with: pattern, in: kb) }
        }
        return solutions.filter(filter)
    }

    private func extend(_ b: Bindings, with pat: Pattern, in kb: TripleStore) -> [Bindings] {
        // 이미 값이 정해진 변수는 고정값으로, 아직 모르는 변수는 와일드카드로
        func bound(_ q: QTerm) -> Term? {
            switch q {
            case .term(let t):     return t
            case .variable(let v): return b[v]
            }
        }
        return kb.match(bound(pat.0), bound(pat.1), bound(pat.2)).compactMap { t -> Bindings? in
            var next = b
            for (q, value) in [(pat.0, t.s), (pat.1, t.p), (pat.2, t.o)] {
                guard case .variable(let v) = q else { continue }
                if let old = next[v], old != value { return nil }   // 같은 변수는 같은 값이어야 한다
                next[v] = value
            }
            return next
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 6. 온톨로지 — 위 부품을 묶은 겉면
// ─────────────────────────────────────────────────────────────
nonisolated struct Ontology: Sendable {
    private(set) var kb = TripleStore()

    mutating func add(_ s: Term, _ p: Term, _ o: Term) {
        kb.add(Triple(s, p, o))
    }

    @discardableResult
    mutating func reason() -> (added: Int, rounds: Int) {
        Reasoner.saturate(&kb)
    }

    func ask(_ query: Query) -> [Bindings] {
        query.run(on: kb)
    }

    /// 새 사실을 "가상 세계"에서 먼저 추론·검증해보고, 모순이 없을 때만 반영한다.
    /// TripleStore가 struct(값 타입)라서 `var trial = kb` 한 줄이 곧 가상 세계 복사다.
    /// 반환값: 모순 목록 (비어 있으면 반영 성공)
    mutating func commitIfConsistent(_ t: Triple) -> [String] {
        var trial = kb
        trial.add(t)
        Reasoner.saturate(&trial)
        let problems = Validator.contradictions(in: trial)
        if problems.isEmpty { kb = trial }
        return problems
    }

    /// "왜 그렇게 아는가?" — 추론 근거를 거슬러 올라가며 트리 형태로 출력
    func explain(_ t: Triple, _ indent: String = "") -> String {
        guard kb.has(t) else {
            return "\(indent)• \(t)  ← 알려지지 않은 사실\n"
        }
        guard let proof = kb.proofs[t] else {
            return "\(indent)• \(t)  ← 입력된 사실\n"
        }
        var out = "\(indent)• \(t)  ← [\(proof.rule)]\n"
        for premise in proof.premises {
            out += explain(premise, indent + "    ")
        }
        return out
    }
}
