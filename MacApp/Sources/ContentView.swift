import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var logger: AppLogger
    @EnvironmentObject private var updater: UpdateChecker
    @ObservedObject private var analysisLogger = AnalysisLogger.shared
    @ObservedObject private var feedback = FeedbackModel.shared
    @State private var isDropTarget = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let update = updater.availableUpdate {
                updateBanner(update)
                Divider()
            }
            if !model.items.isEmpty { tabStrip; Divider() }
            if model.videoURL == nil { emptyState }
            else { reviewWorkspace }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("이전 분석 내역을 불러올까요?", isPresented: $model.showRestorePrompt) {
            Button("불러올까요? (이전 내역 불러오기)") {
                model.confirmRestoreSession()
            }
            Button("새로 시작하기", role: .destructive) {
                model.startFreshSession()
            }
        } message: {
            Text(model.pendingSessionSummary)
        }
        .alert("오류", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("에러 로그 보기") {
                model.errorMessage = nil
                openWindow(id: "error-log")
            }
            Button("확인", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "업데이트 버전이 있습니다 (v\(updater.availableUpdate?.latestVersion ?? ""))",
            isPresented: $updater.showUpdateAlert,
            presenting: updater.availableUpdate
        ) { info in
            Button("업데이트 다운로드") {
                updater.openDownload(info)
            }
            Button("릴리스 페이지 열기") {
                updater.openReleasePage(info)
            }
            Button("이 버전 건너뛰기") {
                updater.skipVersion(info.latestVersion)
            }
            Button("나중에", role: .cancel) {}
        } message: { info in
            Text("현재 버전: v\(info.currentVersion) → 최신 버전: v\(info.latestVersion)\n\n\(info.releaseNotes)")
        }
        .alert("최신 버전입니다", isPresented: $updater.showUpToDateAlert) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("현재 최신 버전(v\(updater.currentVersion))을 사용하고 있습니다.")
        }
        .alert("업데이트 확인 실패", isPresented: Binding(
            get: { updater.checkErrorMessage != nil },
            set: { if !$0 { updater.checkErrorMessage = nil } }
        )) {
            Button("배포 경로 설정…") {
                updater.checkErrorMessage = nil
                updater.showSourceConfigSheet = true
            }
            Button("에러 로그 보기") {
                updater.checkErrorMessage = nil
                openWindow(id: "error-log")
            }
            Button("확인", role: .cancel) {}
        } message: {
            Text(updater.checkErrorMessage ?? "")
        }
        .sheet(isPresented: $updater.showSourceConfigSheet) {
            UpdateSourceSettingsSheet(checker: updater)
        }
        .sheet(isPresented: $updater.showProgressModal) {
            UpdateProgressSheet(checker: updater)
        }
        .sheet(isPresented: $feedback.showSheet) {
            FeedbackSheet(model: feedback)
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let value = String(data: data, encoding: .utf8), let url = URL(string: value) else { return }
                    Task { @MainActor in model.addVideos([url]) }
                }
            }
            return !providers.isEmpty
        }
        .onOpenURL { url in model.addVideos([url]) }
        .onAppear {
            updater.checkForUpdates(userInitiated: false)
        }
    }

    private func updateBanner(_ info: AppUpdateInfo) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
                .uiFont(.headline)
            Text("업데이트 버전이 있습니다 · v\(info.latestVersion) (현재 v\(info.currentVersion))")
                .uiFont(.caption.weight(.semibold))
            Text(info.releaseTitle)
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("자세히") {
                updater.presentModalUpdateAlert(info)
            }
            .controlSize(.small)
            Button("다운로드") {
                updater.openDownload(info)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.10))
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .foregroundStyle(.blue)
                .uiFont(.title2)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text("매묵 영상 검수 도우미").uiFont(.headline)
                    Text("v\(updater.currentVersion)")
                        .uiFont(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(model.videoURL?.lastPathComponent ?? "로컬 영상 분석")
                    .uiFont(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let update = updater.availableUpdate {
                Button {
                    updater.presentModalUpdateAlert(update)
                } label: {
                    Label("업데이트 있음 (v\(update.latestVersion))", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Button {
                    updater.checkForUpdates(userInitiated: true)
                } label: {
                    Label(updater.isChecking ? "확인 중…" : "업데이트 확인", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(updater.isChecking)
            }
            Button {
                openWindow(id: "analysis-log")
            } label: {
                Label(
                    analysisLogger.flaggedCount > 0 ? "분석 로그 (오탐 \(analysisLogger.flaggedCount))" : "분석 로그",
                    systemImage: analysisLogger.flaggedCount > 0 ? "flag.fill" : "doc.text.below.ecg"
                )
            }
            .tint(analysisLogger.flaggedCount > 0 ? .orange : nil)
            Button {
                openWindow(id: "error-log")
            } label: {
                Label(
                    logger.errorCount > 0 ? "에러 로그 (\(logger.errorCount))" : "에러 로그",
                    systemImage: logger.errorCount > 0 ? "exclamationmark.triangle.fill" : "doc.text.magnifyingglass"
                )
            }
            .tint(logger.errorCount > 0 ? .red : nil)
            Button("분석 상태", systemImage: "list.bullet.clipboard") { openWindow(id: "analysis-status") }
            Button("개선 요청", systemImage: "lightbulb") { feedback.showSheet = true }
                .tint(.yellow)
            Button("영상 추가", systemImage: "plus") { model.chooseVideo() }
            if let item = model.selectedItem {
                switch item.state {
                case .running, .queued:
                    Button("분석 취소", systemImage: "xmark.circle", role: .destructive) { model.cancelAnalysis() }
                case .ready, .cancelled, .failed, .completed:
                    Button(item.state == .completed ? "다시 분석" : "분석 시작", systemImage: "waveform.path.ecg") { model.analyze() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if model.report != nil {
                Button("JSON 내보내기", systemImage: "square.and.arrow.up") { model.exportJSON() }
            }
        }
        .padding(.horizontal, 16).frame(height: 58)
    }

    private var tabStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(model.items) { item in
                    HStack(spacing: 4) {
                        Button {
                            model.selectItem(item.id)
                        } label: {
                            Label(item.url.deletingPathExtension().lastPathComponent, systemImage: item.state.symbol)
                                .lineLimit(1)
                                .frame(maxWidth: 190)
                        }
                        .buttonStyle(.plain)
                        Button { model.removeItem(item.id) } label: {
                            Image(systemName: "xmark").uiFont(.caption2)
                        }
                        .buttonStyle(.plain)
                        .help("탭 닫기")
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(item.id == model.selectedID ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    .help("\(item.url.lastPathComponent) · \(item.state.label)")
                }
            }.padding(.horizontal, 12).padding(.vertical, 7)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "play.rectangle.on.rectangle")
                .uiFont(.system(size: 70, weight: .thin)).foregroundStyle(.secondary)
            Text("영상을 추가해 분석을 맡겨두세요").uiFont(.title2.weight(.semibold))
            Text("MP4, MOV, M4V 파일을 여러 개 선택하거나 이 창에 끌어놓으세요.\n분석은 추가한 순서대로 진행됩니다.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("영상 추가…") { model.chooseVideo() }.buttonStyle(.borderedProminent).controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay { if isDropTarget { RoundedRectangle(cornerRadius: 18).stroke(.blue, style: StrokeStyle(lineWidth: 4, dash: [10])).padding(24) } }
    }

    private var reviewWorkspace: some View {
        HSplitView {
            VStack(spacing: 0) {
                PlayerSurface(player: model.player)
                    .background(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                timeline
                statusBar
            }
            .frame(minWidth: 650)
            eventSidebar.frame(minWidth: 350, idealWidth: 420, maxWidth: 520)
        }
    }

    private var timeline: some View {
        let duration = max(model.videoDuration, model.report?.duration ?? 0)
        return VStack(spacing: 9) {
            HStack(spacing: 10) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
                Text(formatTime(model.currentTime, includeTenths: false))
                    .uiFont(.caption.monospacedDigit()).fixedSize()
                IntegratedTimeline(
                    duration: duration,
                    currentTime: model.currentTime,
                    events: model.visibleEvents,
                    color: color,
                    onSeek: model.seek
                )
                Text(formatTime(duration, includeTenths: false))
                    .uiFont(.caption.monospacedDigit()).fixedSize()
            }
            HStack(spacing: 7) {
                Text("재생 속도").uiFont(.caption).foregroundStyle(.secondary)
                speedButton("Q / ↓", label: "감속", action: model.slower)
                speedButton("W /", label: "정속, 이전 배속상태", action: model.normalSpeed)
                speedButton("E / ↑", label: "가속", action: model.faster)
                Text(String(format: "%.2f×", model.playbackRate))
                    .uiFont(.caption.monospacedDigit().weight(.semibold))
                    .fixedSize()
                Spacer()
                Text("상단 바: 자막 구간 · 하단 바: 전환 마커 및 탐색")
                    .uiFont(.caption2).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func speedButton(_ key: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(key).uiFont(.caption2.monospaced())
                Text(label).uiFont(.caption)
            }
        }.buttonStyle(.bordered).controlSize(.small)
    }

    private var statusBar: some View {
        VStack(spacing: 5) {
            if model.isAnalyzing { ProgressView(value: model.progress).progressViewStyle(.linear) }
            HStack {
                Text(model.status)
                    .foregroundStyle(model.selectedItem?.state == .failed ? .red : .secondary)
                    .lineLimit(1)
                if model.selectedItem?.state == .failed {
                    Button("에러 로그 보기") {
                        openWindow(id: "error-log")
                    }
                    .buttonStyle(.link)
                    .uiFont(.caption)
                }
                Spacer()
                if model.isAnalyzing {
                    HStack(spacing: 6) {
                        Text("\(Int(model.progress * 100))%").monospacedDigit()
                        if let elapsed = model.elapsedSeconds {
                            Text("경과 \(formatTime(elapsed, includeTenths: false))")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            if let remaining = model.estimatedRemainingSeconds {
                                Text("예상 \(formatTime(remaining, includeTenths: false)) 남음")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }.uiFont(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 14).padding(.bottom, 10)
    }

    /// 현재 재생 위치에 해당하는 후보. 행을 눌러 이동할 때 1초 앞에서 시작하므로 1초 앞서 잡는다.
    private func currentEventID(in events: [ReviewEvent]) -> UUID? {
        let now = model.currentTime + 1.0
        return events.last(where: { $0.time <= now })?.id
    }

    private var eventSidebar: some View {
        // 재생 중 0.1초마다 다시 그려지므로 필터링/현재 후보 계산은 한 번만 한다.
        let events = model.visibleEvents
        let currentID = currentEventID(in: events)
        return VStack(spacing: 0) {
            HStack {
                Text("검출 후보").uiFont(.headline)
                Spacer()
                Text("\(events.count)개").foregroundStyle(.secondary)
            }.padding(14)
            filterBar.padding(.horizontal, 12).padding(.bottom, 8)
            if let loudness = model.report?.loudness {
                loudnessCard(loudness).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if model.bibleEventsCount > 0 {
                bibleSummaryCard().padding(.horizontal, 12).padding(.bottom, 8)
            }
            Divider()
            if model.report == nil {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "scope").uiFont(.largeTitle).foregroundStyle(.secondary)
                    Text(model.isAnalyzing ? "영상을 분석하고 있습니다" : model.selectedItem?.state == .queued ? "분석 순서를 기다리고 있습니다" : "분석을 시작하면 후보가 표시됩니다")
                        .foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else if events.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .uiFont(.largeTitle).foregroundStyle(.secondary)
                    Text("후보 없음").uiFont(.headline)
                    Text("선택한 종류의 검출 후보가 없습니다.")
                        .uiFont(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(events) { event in
                        let isCurrent = event.id == currentID
                        EventRow(
                            event: event,
                            videoName: model.videoURL?.lastPathComponent ?? "영상",
                            videoDuration: max(model.videoDuration, model.report?.duration ?? 0),
                            color: color(event.kind),
                            onBible: model.openBible
                        )
                            .contentShape(Rectangle())
                            .onTapGesture { model.seek(to: max(0, event.time - 1)) }
                            .padding(.horizontal, 6)
                            .background(isCurrent ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(alignment: .leading) {
                                if isCurrent {
                                    Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 4)
                                }
                            }
                            .id(event.id)
                    }
                    .listStyle(.inset)
                    // 재생 위치가 다른 후보 구간으로 넘어가면 목록을 그 위치로 따라간다.
                    .onChange(of: currentID) { id in
                        guard let id else { return }
                        withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(ReviewEventKind.allCases) { kind in
                Button {
                    model.toggle(kind)
                } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(kind)).frame(width: 7, height: 7)
                        Text(kind.label)
                    }
                }
                .buttonStyle(.bordered)
                .tint(model.enabledKinds.contains(kind) ? color(kind) : .gray)
            }

            if model.bibleEventsCount > 0 {
                Button {
                    model.filterOnlyBible.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "book.closed.fill")
                            .uiFont(.caption2)
                        Text("말씀 (\(model.bibleEventsCount))")
                    }
                }
                .buttonStyle(.bordered)
                .tint(model.filterOnlyBible ? .blue : .secondary)
            }
        }
    }

    private func bibleSummaryCard() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("말씀 자막 검수", systemImage: "book.closed.fill")
                    .uiFont(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Spacer()
                Text("\(model.bibleEventsCount)건 검출")
                    .uiFont(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if model.bibleTypoCount > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("오탈자/차이 \(model.bibleTypoCount)건 의심")
                            .uiFont(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("검출된 구절 원문 일치")
                            .uiFont(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                Button {
                    model.filterOnlyBible.toggle()
                } label: {
                    Text(model.filterOnlyBible ? "전체 보기" : "말씀만 보기")
                        .uiFont(.caption2.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(9)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.blue.opacity(0.22), lineWidth: 1))
    }

    private func loudnessColor(_ level: LoudnessResult.Level) -> Color {
        switch level {
        case .ready: return .green
        case .loud, .peak: return .orange
        case .quiet: return .blue
        }
    }

    private func loudnessCard(_ result: LoudnessResult) -> some View {
        let tint = loudnessColor(result.level)
        let icon: String
        switch result.level {
        case .ready: icon = "checkmark.circle.fill"
        case .loud, .peak: icon = "exclamationmark.triangle.fill"
        case .quiet: icon = "speaker.slash.fill"
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("음량", systemImage: "speaker.wave.2.fill").uiFont(.subheadline.weight(.semibold))
                Spacer()
                Label(result.statusLabel, systemImage: icon)
                    .uiFont(.caption.weight(.semibold))
                    .foregroundStyle(tint)
            }
            HStack(spacing: 18) {
                Text(String(format: "통합 %.1f LUFS", result.integratedLUFS))
                    .foregroundStyle(result.integratedLUFS >= -15 && result.integratedLUFS <= -13 ? Color.green : tint)
                Text(String(format: "피크 %.1f dBFS", result.samplePeakDBFS))
                    .foregroundStyle(result.samplePeakDBFS <= -1 ? Color.green : Color.orange)
            }.uiFont(.caption.monospacedDigit().weight(.semibold))
            Text("YouTube 공개 공식값이 아닌 실무 기준: -14 ±1 LUFS, sample peak ≤ -1 dBFS")
                .uiFont(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(tint.opacity(result.level == .ready ? 0.10 : 0.16), in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(result.level == .ready ? 0.35 : 0.65), lineWidth: result.level == .ready ? 1 : 2))
    }

    private func color(_ kind: ReviewEventKind) -> Color {
        switch kind {
        case .cut: return Color(red: 0.20, green: 0.65, blue: 1.0)
        case .dissolve: return Color(red: 0.70, green: 0.39, blue: 1.0)
        case .subtitle: return Color(red: 1.0, green: 0.65, blue: 0.18)
        }
    }
}

private struct EventRow: View {
    let event: ReviewEvent
    let videoName: String
    let videoDuration: Double
    let color: Color
    let onBible: (BibleReference) -> Void
    @ObservedObject private var analysisLogger = AnalysisLogger.shared
    @State private var copiedFlag = false

    private var isFlagged: Bool {
        analysisLogger.isFlagged(eventID: event.id, videoName: videoName, time: event.time, label: event.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Group {
                    if let path = event.thumbnailPath, let image = NSImage(contentsOfFile: path) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.black.opacity(0.8)).overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 112, height: 63).clipShape(RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Capsule().fill(color).frame(width: 5, height: 20)
                        Text(event.label).uiFont(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    if let endTime = event.endTime, endTime > event.time + 0.2 {
                        Text("\(formatTime(event.time)) ~ \(formatTime(endTime))").uiFont(.caption.monospacedDigit())
                    } else {
                        Text(formatTime(event.time)).uiFont(.caption.monospacedDigit())
                    }
                    HStack(spacing: 6) {
                        Text("신뢰도 \(Int(event.confidence * 100))%")
                            .uiFont(.caption2).foregroundStyle(.secondary)
                        Button {
                            analysisLogger.flagAndCopyEvent(event, videoName: videoName, videoDuration: videoDuration)
                            copiedFlag = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                copiedFlag = false
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: copiedFlag ? "checkmark" : (isFlagged ? "flag.fill" : "flag"))
                                Text(copiedFlag ? "오탐 복사됨" : (isFlagged ? "오탐 기록됨" : "오탐 리포트"))
                            }
                            .uiFont(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background((isFlagged || copiedFlag ? Color.red : Color.secondary).opacity(0.12), in: Capsule())
                            .foregroundStyle(copiedFlag ? .green : (isFlagged ? .red : .secondary))
                        }
                        .buttonStyle(.plain)
                        .help("오탐 로그에 기록하고 리포팅용 상세 내역을 클립보드에 복사합니다")
                    }
                }
                Spacer(minLength: 0)
            }
            if let text = event.recognizedText, !text.isEmpty {
                Text(text)
                    .uiFont(.caption)
                    .lineLimit(event.isPrayer ? 4 : 2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if event.isPrayer {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Image(systemName: "hands.sparkles.fill")
                            .uiFont(.caption2)
                            .foregroundStyle(.purple)
                        Text("기도문 (성경 대조 생략 · 오타·띄어쓰기 검토)")
                            .uiFont(.caption2.weight(.medium))
                            .foregroundStyle(.purple)
                    }
                    if event.grammarSuggestions.isEmpty {
                        Label("오타·띄어쓰기 의심 없음", systemImage: "checkmark.circle.fill")
                            .uiFont(.caption2.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("🔍 검토 가능성 있음 (오타·띄어쓰기, 고어체는 제외):")
                                .uiFont(.caption2.weight(.bold))
                                .foregroundStyle(.indigo)
                            ForEach(event.grammarSuggestions, id: \.self) { tip in
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: "checkmark.circle")
                                        .uiFont(.caption2)
                                        .foregroundStyle(.indigo)
                                    Text(tip)
                                        .uiFont(.caption2)
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            } else if !event.bibleComparisons.isEmpty {
                ForEach(event.bibleComparisons) { comparison in
                    BibleComparisonCard(comparison: comparison, onBible: onBible)
                }
            } else if !event.bibleReferences.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "book.closed.fill").foregroundStyle(.blue)
                    ForEach(event.bibleReferences.prefix(3)) { reference in
                        Button(reference.displayName) { onBible(reference) }
                            .buttonStyle(.link).uiFont(.caption)
                        if let acc = reference.accuracy {
                            Text(String(format: "%.0f%%", acc * 100))
                                .uiFont(.caption2).foregroundStyle(
                                    acc >= 0.9 ? .green : acc >= 0.7 ? .orange : .red
                                )
                        }
                    }
                }
            }
        }.padding(.vertical, 4)
    }
}

private struct BibleComparisonCard: View {
    let comparison: BibleComparisonResult
    let onBible: (BibleReference) -> Void
    @State private var showDetails: Bool

    init(comparison: BibleComparisonResult, onBible: @escaping (BibleReference) -> Void) {
        self.comparison = comparison
        self.onBible = onBible
        // 오탈자나 불일치 의심 시 자동으로 상세 대조 내용을 펼침
        _showDetails = State(initialValue: comparison.status == .minorTypo || comparison.status == .mismatch)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "book.closed.fill")
                    .uiFont(.caption)
                    .foregroundStyle(.blue)
                Button(comparison.reference.displayName) {
                    onBible(comparison.reference)
                }
                .buttonStyle(.link)
                .uiFont(.caption.weight(.semibold))

                Spacer()

                statusBadge
            }

            if let marker = comparison.markedVerse {
                HStack(spacing: 4) {
                    Image(systemName: comparison.markedVerseInRange == true ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    Text(comparison.markedVerseInRange == true
                         ? "절 번호 \(marker) · 표기 범위 내 (본문 비교 제외)"
                         : "절 번호 \(marker) · 표기 범위 밖 (본문 비교 제외)")
                }
                .uiFont(.caption2.weight(.medium))
                .foregroundStyle(comparison.markedVerseInRange == true ? Color.green : Color.red)
            }

            // 요약 설명
            HStack(spacing: 4) {
                Text(comparison.summary)
                    .uiFont(.caption2)
                    .foregroundStyle(summaryColor)
                    .lineLimit(1)
                Spacer()
                Button {
                    showDetails.toggle()
                } label: {
                    HStack(spacing: 2) {
                        Text(showDetails ? "접기" : "대조 확인")
                        Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    }
                    .uiFont(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            if showDetails {
                VStack(alignment: .leading, spacing: 5) {
                    Divider().padding(.vertical, 2)

                    // 오류 상세 목록 (있는 경우)
                    if !comparison.errors.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("검출된 본문 차이/오탈자:")
                                .uiFont(.caption2.weight(.bold))
                                .foregroundStyle(.red)
                            ForEach(comparison.errors) { err in
                                HStack(alignment: .top, spacing: 4) {
                                    Image(systemName: errIcon(for: err.kind))
                                        .uiFont(.caption2)
                                        .foregroundStyle(errColor(for: err.kind))
                                    Text(err.description)
                                        .uiFont(.caption2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    }

                    // 원문 vs 자막 텍스트
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .top, spacing: 4) {
                            Text("성경 원문:")
                                .uiFont(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Text(comparison.scriptureText)
                                .uiFont(.caption2)
                                .textSelection(.enabled)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Text("자막 인식:")
                                .uiFont(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Text(comparison.subtitleText)
                                .uiFont(.caption2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(6)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(8)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(cardBorderColor, lineWidth: 1)
        )
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Circle().fill(badgeColor).frame(width: 6, height: 6)
            Text(comparison.status.rawValue)
                .uiFont(.caption2.weight(.semibold))
            if comparison.status != .referenceOnly {
                Text(String(format: "%.0f%%", comparison.accuracy * 100))
                    .uiFont(.caption2.monospacedDigit())
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(badgeColor.opacity(0.12), in: Capsule())
    }

    private var badgeColor: Color {
        switch comparison.status {
        case .exact: return .green
        case .minorTypo: return .orange
        case .mismatch: return .red
        case .referenceOnly: return .gray
        }
    }

    private var summaryColor: Color {
        switch comparison.status {
        case .exact: return .green
        case .minorTypo: return .orange
        case .mismatch: return .red
        case .referenceOnly: return .secondary
        }
    }

    private var cardBackground: Color {
        switch comparison.status {
        case .exact: return Color.green.opacity(0.05)
        case .minorTypo: return Color.orange.opacity(0.06)
        case .mismatch: return Color.red.opacity(0.06)
        case .referenceOnly: return Color.secondary.opacity(0.04)
        }
    }

    private var cardBorderColor: Color {
        switch comparison.status {
        case .exact: return Color.green.opacity(0.3)
        case .minorTypo: return Color.orange.opacity(0.4)
        case .mismatch: return Color.red.opacity(0.4)
        case .referenceOnly: return Color.secondary.opacity(0.2)
        }
    }

    private func errIcon(for kind: BibleTextError.ErrorKind) -> String {
        switch kind {
        case .typo: return "exclamationmark.triangle.fill"
        case .missing: return "minus.circle.fill"
        case .inserted: return "plus.circle.fill"
        case .verseNumber: return "number.circle.fill"
        }
    }

    private func errColor(for kind: BibleTextError.ErrorKind) -> Color {
        switch kind {
        case .typo: return .orange
        case .missing: return .red
        case .inserted: return .purple
        case .verseNumber: return .red
        }
    }
}

private struct IntegratedTimeline: View {
    let duration: Double
    let currentTime: Double
    let events: [ReviewEvent]
    let color: (ReviewEventKind) -> Color
    let onSeek: (Double) -> Void

    private var subtitleEvents: [ReviewEvent] {
        events.filter { $0.kind == .subtitle }
    }

    private var transitionEvents: [ReviewEvent] {
        events.filter { $0.kind != .subtitle }
    }

    /// 이전 버전 세션 데이터에 endTime이 비어 있을 때도 구간 바를 자연스럽게 표시합니다.
    private func effectiveEndTime(for event: ReviewEvent, at index: Int, in list: [ReviewEvent]) -> Double {
        if let end = event.endTime, end > event.time {
            return min(duration > 0 ? duration : end, end)
        }
        let fallbackEnd = event.time + 3.0
        if index + 1 < list.count {
            return min(fallbackEnd, max(event.time + 0.4, list[index + 1].time))
        }
        return duration > 0 ? min(duration, fallbackEnd) : fallbackEnd
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
            let subs = subtitleEvents
            let transitions = transitionEvents

            VStack(alignment: .leading, spacing: 4) {
                // 상단 레인: 프로그레스 바 위에 표시되는 자막 구간(Range) 바
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.10))
                        .frame(height: 8)
                    ForEach(Array(subs.enumerated()), id: \.element.id) { index, event in
                        let startRatio = duration > 0 ? min(1, max(0, event.time / duration)) : 0
                        let endSec = effectiveEndTime(for: event, at: index, in: subs)
                        let spanSec = max(0.2, endSec - event.time)
                        let spanWidth = duration > 0 ? max(6, width * (spanSec / max(duration, 0.1))) : 6
                        let xOffset = min(max(0, width * startRatio), max(0, width - spanWidth))
                        let barColor = color(.subtitle)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.white.opacity(0.45), lineWidth: 0.6)
                            )
                            .frame(width: spanWidth, height: 8)
                            .offset(x: xOffset)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 8)

                // 하단 레인: 메인 재생 프로그레스 바 + 컷/디졸브 전환 마커 + 자막 시작 틱
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.22)).frame(height: 10)
                    Capsule().fill(Color.accentColor.opacity(0.75))
                        .frame(width: width * progress, height: 10)

                    // 상단 자막 구간과 이어지는 시작 지점 미세 마커
                    ForEach(subs) { event in
                        let start = duration > 0 ? event.time / duration : 0
                        let barColor = color(.subtitle)
                        RoundedRectangle(cornerRadius: 1)
                            .fill(barColor.opacity(0.65))
                            .frame(width: 2, height: 12)
                            .offset(x: min(max(0, width * start), max(0, width - 2)))
                            .allowsHitTesting(false)
                    }

                    // 컷/디졸브 전환 마커
                    ForEach(transitions) { event in
                        let start = duration > 0 ? event.time / duration : 0
                        let eventWidth = event.endTime.map { max(4, width * (($0 - event.time) / max(duration, 0.1))) } ?? 4
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(event.kind))
                            .frame(width: eventWidth, height: 16)
                            .offset(x: min(max(0, width * start), max(0, width - eventWidth)))
                            .allowsHitTesting(false)
                    }

                    Circle().fill(.white).shadow(radius: 2)
                        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        .offset(x: min(max(0, width * progress - 8), max(0, width - 16)))
                        .allowsHitTesting(false)
                }
                .frame(height: 18)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard duration > 0, width > 0 else { return }
                onSeek(duration * min(1, max(0, value.location.x / width)))
            })
        }.frame(height: 32)
    }
}
