//
//  ContentView.swift
//  세 칸 화면: [채팅 = 하네스 입구] [와이어 = MCP 위를 흐르는 JSON-RPC] [온톨로지 = 지식 그래프 내부]
//

import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        Group {
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                compactLayout
            } else {
                wideLayout
            }
            #else
            wideLayout
            #endif
        }
        .environment(model)
        .sheet(isPresented: Binding(get: { model.showGuide }, set: { model.showGuide = $0 })) {
            LearningGuideView()
        }
        .alert("도구 실행 승인", isPresented: approvalPresented, presenting: model.pendingApproval) { request in
            Button("허용") { model.resolveApproval(true) }
            Button("거부", role: .cancel) { model.resolveApproval(false) }
        } message: { request in
            Text("모델이 \(request.call.name) 도구를 다음 인자로 실행하려 합니다:\n\(request.call.arguments.compact)\n\n지식 그래프에 쓰는 작업이라 사용자 승인이 필요합니다.")
        }
    }

    private var approvalPresented: Binding<Bool> {
        Binding(
            get: { model.pendingApproval != nil },
            set: { if !$0, model.pendingApproval != nil { model.resolveApproval(false) } }
        )
    }

    private var wideLayout: some View {
        HStack(spacing: 0) {
            ChatPane()
                .frame(minWidth: 360)
            Divider()
            WirePane()
                .frame(minWidth: 340)
            Divider()
            OntologyPane()
                .frame(minWidth: 320)
        }
        .frame(minWidth: 1040, minHeight: 600)
    }

    private var compactLayout: some View {
        TabView {
            Tab("채팅", systemImage: "bubble.left.and.bubble.right") { ChatPane() }
            Tab("와이어", systemImage: "waveform.path.ecg") { WirePane() }
            Tab("온톨로지", systemImage: "point.3.connected.trianglepath.dotted") { OntologyPane() }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 채팅 칸 — 하네스의 입구와 출구
// ─────────────────────────────────────────────────────────────
struct ChatPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            PaneHeader(title: "하네스 (Agent Harness)", systemImage: "cpu") {
                Picker("모델", selection: Binding(
                    get: { model.modelKind },
                    set: { model.switchModel(to: $0) }
                )) {
                    ForEach(AppModel.ModelKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                            .disabled(kind == .onDevice && !model.isOnDeviceAvailable)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
                Button("학습 가이드", systemImage: "book") { model.showGuide = true }
                    .labelStyle(.iconOnly)
                    .help("개념 → 화면에서 확인 → 코드 위치 → 실습")
                Button("비우기", systemImage: "trash") { model.clearChat() }
                    .labelStyle(.iconOnly)
            }

            if !model.isOnDeviceAvailable {
                Text(model.onDeviceStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if model.chat.isEmpty {
                            EmptyHint()
                        }
                        ForEach(model.chat) { entry in
                            ChatBubble(entry: entry).id(entry.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: model.chat.count) {
                    if let last = model.chat.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(OntologyDemo.sampleQuestions, id: \.self) { q in
                        Button(q) { model.send(q) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(model.isRunning || !model.isReady)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            HStack {
                TextField("질문을 입력하세요", text: $model.input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.send() }
                    .disabled(model.isRunning || !model.isReady)
                if model.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Button("보내기", systemImage: "paperplane.fill") { model.send() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || !model.isReady)
                }
            }
            .padding()
        }
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("LLM은 \"도구를 불러줘\"라는 JSON만 낸다. 실행·권한·기록은 하네스가 맡는다.")
                .font(.headline)
            Text("아래 예시 질문을 누르면 ① 모델이 도구 호출을 결정하고 → ② 하네스가 권한을 확인한 뒤 → ③ MCP 클라이언트가 JSON-RPC로 서버에 보내고 → ④ 결과를 다시 모델에게 먹여 최종 답을 받는 과정을 볼 수 있습니다.")
            Text("'삭제' 요청은 정책이 막고, '추가' 요청은 사용자 승인을 묻습니다. 가운데 칸에서 선 위를 흐르는 JSON을, 오른쪽 칸에서 지식 그래프의 변화를 확인하세요.")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding()
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ChatBubble: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(entry.text)
                    .padding(10)
                    .background(.tint, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
        case .assistant:
            HStack {
                Text(entry.text)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                Spacer(minLength: 40)
            }
        case .trace:
            Text(entry.text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 6)
        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 와이어 칸 — MCP 위를 흐르는 JSON-RPC 봉투
// ─────────────────────────────────────────────────────────────
struct WirePane: View {
    @Environment(AppModel.self) private var model
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable {
        case all = "전체", wire = "JSON-RPC", harness = "하네스", tools = "도구 메뉴판"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "MCP 와이어", systemImage: "waveform.path.ecg") {
                Picker("필터", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("비우기", systemImage: "trash") { model.clearLog() }
                    .labelStyle(.iconOnly)
            }

            if filter == .tools {
                ToolMenuList(tools: model.tools)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(filteredLog) { entry in
                                LogRow(entry: entry).id(entry.id)
                            }
                        }
                        .padding()
                    }
                    .onChange(of: model.log.count) {
                        if let last = filteredLog.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var filteredLog: [LogEntry] {
        switch filter {
        case .all:     return model.log
        case .wire:    return model.log.filter { $0.kind == .wire }
        case .harness: return model.log.filter { $0.kind != .wire }
        case .tools:   return []
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(entry.date, format: .dateTime.hour().minute().second())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let caption = WireAnnotator.caption(for: entry) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(entry.text)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(background, in: RoundedRectangle(cornerRadius: 8))
    }

    private var color: Color {
        switch entry.kind {
        case .wire:    return entry.text.hasPrefix("C→S") ? .blue : .green
        case .thought: return .purple
        case .tool:    return .orange
        case .harness: return .primary
        case .server:  return .secondary
        }
    }

    private var background: some ShapeStyle {
        entry.kind == .wire ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear)
    }
}

/// 서버가 광고하는 도구 설명서 — LLM이 보는 것과 똑같은 내용
private struct ToolMenuList: View {
    let tools: [ToolSpec]

    var body: some View {
        List(tools) { tool in
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.name).font(.headline.monospaced())
                Text(tool.description).font(.callout)
                Text(tool.inputSchema.compact)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(.vertical, 4)
        }
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 온톨로지 칸 — 지식 그래프의 내부
// ─────────────────────────────────────────────────────────────
struct OntologyPane: View {
    @Environment(AppModel.self) private var model
    @State private var part: Part = .facts
    @State private var selected: Triple?
    @State private var showReport = false

    enum Part: String, CaseIterable, Identifiable {
        case facts = "사실", inferred = "추론됨", schema = "스키마"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "온톨로지", systemImage: "point.3.connected.trianglepath.dotted") {
                Button("데모 리포트", systemImage: "doc.text.magnifyingglass") { showReport = true }
                    .labelStyle(.iconOnly)
            }

            HStack(spacing: 12) {
                stat("전체", model.ontology.kb.count)
                stat("입력", model.ontology.kb.count - model.ontology.kb.proofs.count)
                stat("추론", model.ontology.kb.proofs.count)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 6)

            Picker("구역", selection: $part) {
                ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)

            List(rows, id: \.self, selection: $selected) { t in
                TripleRow(triple: t, rule: model.ontology.kb.proofs[t]?.rule)
                    .tag(t)
            }
            .listStyle(.plain)

            if let selected {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("왜 아는가?").font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        Text(model.explain(selected).trimmingCharacters(in: .newlines))
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 160)
                }
                .padding()
            }
        }
        .sheet(isPresented: $showReport) {
            DemoReportSheet()
        }
    }

    private var rows: [Triple] {
        let kb = model.ontology.kb
        let all = kb.all.sorted { a, b in
            a.s.description == b.s.description
                ? (a.p.description == b.p.description ? a.o.description < b.o.description : a.p.description < b.p.description)
                : a.s.description < b.s.description
        }
        switch part {
        case .schema:   return all.filter { V.isSchemaPredicate($0.p) || $0.o == V.Transitive || $0.o == V.Symmetric }
        case .inferred: return all.filter { kb.proofs[$0] != nil }
        case .facts:    return all.filter { kb.proofs[$0] == nil && !V.isSchemaPredicate($0.p) && $0.o != V.Transitive && $0.o != V.Symmetric }
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.title3.monospacedDigit().bold())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private struct TripleRow: View {
    let triple: Triple
    let rule: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(triple.s.shortName).bold()
                Text(triple.p.shortName).foregroundStyle(.secondary)
                Text(triple.o.shortName)
            }
            .font(.callout)
            .lineLimit(1)
            if let rule {
                Text("← \(rule)")
                    .font(.caption2)
                    .foregroundStyle(.purple)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct DemoReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let lines = OntologyDemo.report()

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(lines.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("온톨로지 데모 리포트")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("닫기") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 와이어 해설 — JSON 한 줄을 사람이 읽는 한 문장으로
//   (교육용: 로그 자체는 그대로 두고, 그 위에 "지금 이 메시지가 무엇인지"를 덧붙인다)
// ─────────────────────────────────────────────────────────────
enum WireAnnotator {
    static func caption(for entry: LogEntry) -> String? {
        switch entry.kind {
        case .wire:    return wireCaption(entry.text)
        case .thought: return "① 생각 — 모델이 다음 행동을 결정"
        case .tool:    return entry.text.contains("→ 거부됨") ? "③ 행동 차단 — 권한 훅이 서버 전송 전에 거부" : "③ 행동 → ④ 관찰 — 결과를 기록에 붙여 모델에게 되돌림"
        case .harness: return entry.text.hasPrefix("🔌") ? "서버 장착 — tools/list 결과를 라우팅 표에 등록" : nil
        case .server:  return "MCP 서버 메인 루프 시작"
        }
    }

    private static func wireCaption(_ text: String) -> String? {
        let id = firstMatch(#""id":(\d+)"#, in: text).map { "id \($0) · " } ?? ""
        if text.hasPrefix("C→S") {
            switch firstMatch(#""method":"([^"]+)""#, in: text) {
            case "server/discover": return id + "요청 server/discover — 핸드셰이크 대신 매 요청 _meta에 버전을 싣는다"
            case "tools/list":      return id + "요청 tools/list — LLM에게 보여줄 도구 설명서를 받아온다"
            case "tools/call":      return id + "요청 tools/call — 모델이 만든 인자를 그대로 서버로"
            case let other?:        return id + "요청 \(other)"
            case nil:               return id + "요청"
            }
        }
        if text.contains("\"error\":") { return id + "응답(오류) — JSON-RPC error 객체 (프로토콜 수준 실패)" }
        if text.contains("\"isError\":true") { return id + "응답 — 도구 실패를 '결과'로 돌려줌 (모델이 읽고 재시도 가능)" }
        if text.contains("\"tools\":[") { return id + "응답 — 도구 메뉴판 (description + inputSchema)" }
        if text.contains("supportedVersions") { return id + "응답 — 서버 정체·능력" }
        return id + "응답 — 도구 실행 결과(content 블록)"
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

// ─────────────────────────────────────────────────────────────
// MARK: - 공통
// ─────────────────────────────────────────────────────────────
private struct PaneHeader<Accessory: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            accessory
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

#Preview {
    ContentView()
}
