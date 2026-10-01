//
//  LearningGuideView.swift
//  학습 가이드 시트 — 왼쪽 목차, 오른쪽 개념·화면에서 확인·코드 위치·실습
//

import SwiftUI

struct LearningGuideView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: GuideSection.ID? = LearningGuide.sections.first?.id

    var body: some View {
        NavigationSplitView {
            List(LearningGuide.sections, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section.id)
            }
            .navigationTitle("학습 가이드")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let section = LearningGuide.sections.first(where: { $0.id == selection }) {
                GuideDetail(section: section)
            } else {
                ContentUnavailableView("목차에서 항목을 선택하세요", systemImage: "book")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("닫기") { dismiss() }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
    }
}

private struct GuideDetail: View {
    let section: GuideSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(section.title, systemImage: section.systemImage)
                    .font(.title2.bold())

                Text(section.summary)
                    .font(.body)
                    .textSelection(.enabled)

                block("화면에서 확인하기", systemImage: "eye") {
                    ForEach(section.points, id: \.self) { point in
                        bullet(point)
                    }
                }

                if !section.files.isEmpty {
                    block("코드 위치", systemImage: "doc.text") {
                        ForEach(section.files, id: \.self) { file in
                            Text(file)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }

                if !section.tryIt.isEmpty {
                    block("직접 바꿔보기", systemImage: "wrench.and.screwdriver") {
                        ForEach(Array(section.tryIt.enumerated()), id: \.offset) { index, task in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                Text(task).font(.callout).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .navigationTitle(section.title)
    }

    private func block<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.callout).textSelection(.enabled)
        }
    }
}

#Preview {
    LearningGuideView()
}
