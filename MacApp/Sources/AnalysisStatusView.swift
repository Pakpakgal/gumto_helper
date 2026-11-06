import SwiftUI

struct AnalysisStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var logger: AppLogger
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("분석 상태").uiFont(.title2.weight(.semibold))
                    Text("전체 \(model.items.count)편 · 완료 \(model.completedCount)편 · 대기 \(model.queuedCount)편")
                        .uiFont(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    openWindow(id: "error-log")
                } label: {
                    Label(logger.errorCount > 0 ? "에러 로그 (\(logger.errorCount))" : "에러 로그", systemImage: "exclamationmark.bubble")
                }
                Button("영상 추가…") { model.chooseVideo() }
            }
            .padding(16)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").uiFont(.largeTitle).foregroundStyle(.secondary)
                    Text("분석할 영상이 없습니다").uiFont(.headline)
                    Text("영상을 추가하면 순서대로 분석합니다.").uiFont(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: item.state.symbol)
                                    .foregroundStyle(item.state == .completed ? .green : item.state == .failed ? .red : .secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.url.lastPathComponent).uiFont(.subheadline.weight(.medium)).lineLimit(1)
                                    Text(item.status)
                                        .uiFont(.caption)
                                        .foregroundStyle(item.state == .failed ? .red : .secondary)
                                        .lineLimit(2)
                                    if item.state == .failed, let details = item.errorDetails, !details.isEmpty {
                                        Text(details)
                                            .uiFont(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                            .textSelection(.enabled)
                                    }
                                    if item.state == .running {
                                        ProgressView(value: item.progress)
                                        HStack {
                                            Text("\(Int(item.progress * 100))%")
                                            if let elapsed = item.elapsedSeconds {
                                                Text("경과 \(formatTime(elapsed, includeTenths: false))")
                                            }
                                            if let remaining = item.estimatedRemainingSeconds {
                                                Text("예상 \(formatTime(remaining, includeTenths: false)) 남음")
                                            }
                                        }
                                        .uiFont(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                Text(item.state.label).uiFont(.caption).foregroundStyle(.secondary)
                                if item.state == .queued || item.state == .running {
                                    Button("취소") { model.cancelItem(item.id) }
                                } else if item.state == .failed {
                                    Button("에러 로그") { openWindow(id: "error-log") }
                                    Button("재시도") { model.enqueueItem(item.id) }
                                } else if item.state == .cancelled {
                                    Button("재시도") { model.enqueueItem(item.id) }
                                } else if item.state == .completed {
                                    Button("검토") { model.showItemForReview(item.id) }
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }
}
