import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [AnalysisItem] = []
    @Published var selectedID: UUID?
    @Published var player = AVPlayer()
    @Published var errorMessage: String?
    @Published var enabledKinds = Set(ReviewEventKind.allCases)
    @Published var currentTime = 0.0
    @Published var playbackRate = 1.0
    @Published var isPlaying = false
    @Published var videoDuration = 0.0
    @Published var filterOnlyBible = false

    private var queueTask: Task<Void, Never>?
    private var activeTask: Task<AnalysisReport, Error>?
    private var activeID: UUID?
    private var timeObserver: Any?
    private var keyMonitor: Any?

    var selectedItem: AnalysisItem? { items.first { $0.id == selectedID } }
    var videoURL: URL? { selectedItem?.url }
    var report: AnalysisReport? { selectedItem?.report }
    var isAnalyzing: Bool { selectedItem?.state == .running }
    var progress: Double { selectedItem?.progress ?? 0 }
    var status: String { selectedItem?.status ?? "분석할 영상을 추가해 주세요." }
    var elapsedSeconds: Double? { selectedItem?.elapsedSeconds }
    var estimatedRemainingSeconds: Double? { selectedItem?.estimatedRemainingSeconds }
    var queuedCount: Int { items.filter { $0.state == .queued }.count }
    var completedCount: Int { items.filter { $0.state == .completed }.count }

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                self?.isPlaying = (self?.player.rate ?? 0) != 0
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            // 파일 열기/저장 창, 알림창 등 패널이 열려 있을 때는 가로채지 않는다.
            if NSApp.keyWindow is NSPanel { return event }
            // 실제로 글자를 입력하는(편집 가능한) 텍스트 필드에서만 양보한다.
            // 자막 텍스트처럼 선택만 가능한 NSTextView가 포커스를 가져가도 단축키는 동작해야 한다.
            if let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isEditable { return event }
            switch event.keyCode {
            case 12: Task { @MainActor in self?.slower() }; return nil  // Q / ㅂ
            case 13: Task { @MainActor in self?.normalSpeed() }; return nil // W / ㅈ
            case 14: Task { @MainActor in self?.faster() }; return nil // E / ㄷ
            case 49: Task { @MainActor in self?.togglePlayback() }; return nil // Space
            case 123: Task { @MainActor in self?.seekRelative(-3) }; return nil // ←
            case 124: Task { @MainActor in self?.seekRelative(3) }; return nil // →
            case 125: Task { @MainActor in self?.slower() }; return nil // ↓
            case 126: Task { @MainActor in self?.faster() }; return nil // ↑
            default: return event
            }
        }
        restoreSession()
        UpdateChecker.shared.checkForUpdates(userInitiated: false)
    }

    private struct SavedItem: Codable {
        let id: UUID
        let url: URL
        let state: AnalysisItemState
        let report: AnalysisReport?
        let status: String
        let errorMessage: String?
        let errorDetails: String?
    }

    private struct SavedSession: Codable {
        let items: [SavedItem]
        let selectedID: UUID?
    }

    private var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hcc.MaeMook", isDirectory: true)
            .appendingPathComponent("session.json")
    }

    private func saveSession() {
        let session = SavedSession(items: items.map {
            SavedItem(
                id: $0.id,
                url: $0.url,
                state: $0.state,
                report: $0.report,
                status: $0.status,
                errorMessage: $0.errorMessage,
                errorDetails: $0.errorDetails
            )
        }, selectedID: selectedID)
        do {
            let target = sessionURL
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: target, options: .atomic)
        } catch {
            errorMessage = "작업 목록을 저장하지 못했습니다: \(error.localizedDescription)"
            AppLogger.shared.record(
                level: .error,
                category: "세션 저장",
                message: "작업 목록을 저장하지 못했습니다.",
                error: error
            )
        }
    }

    private func restoreSession() {
        guard let data = try? Data(contentsOf: sessionURL),
              let session = try? JSONDecoder().decode(SavedSession.self, from: data) else { return }
        items = session.items.map { saved in
            var item = AnalysisItem(id: saved.id, url: saved.url)
            item.report = saved.report
            item.state = saved.state == .running ? .queued : saved.state
            item.progress = item.state == .completed ? 1 : 0
            item.status = saved.state == .running ? "이전 분석을 다시 시작하는 중…" : saved.status
            item.errorMessage = saved.errorMessage
            item.errorDetails = saved.errorDetails
            if !FileManager.default.fileExists(atPath: saved.url.path) {
                item.state = .failed
                item.status = "원본 영상을 찾을 수 없습니다."
                item.errorMessage = item.status
                item.errorDetails = "경로: \(saved.url.path)"
                AppLogger.shared.record(
                    level: .warning,
                    category: "세션 복원",
                    message: "원본 영상을 찾을 수 없습니다.",
                    details: "파일 경로: \(saved.url.path)",
                    videoURL: saved.url
                )
            }
            return item
        }
        if let id = session.selectedID, items.contains(where: { $0.id == id }) { selectItem(id) }
        else if let first = items.first { selectItem(first.id) }
        startQueueIfNeeded()
    }

    var visibleEvents: [ReviewEvent] {
        guard let report else { return [] }
        return report.events.filter { event in
            guard enabledKinds.contains(event.kind) else { return false }
            if filterOnlyBible {
                return !event.bibleReferences.isEmpty || !event.bibleComparisons.isEmpty
            }
            return true
        }
    }

    var bibleEventsCount: Int {
        report?.events.filter { !$0.bibleReferences.isEmpty || !$0.bibleComparisons.isEmpty }.count ?? 0
    }

    var bibleTypoCount: Int {
        guard let events = report?.events else { return 0 }
        var count = 0
        for event in events {
            for comp in event.bibleComparisons {
                if comp.status == .minorTypo || comp.status == .mismatch {
                    count += 1
                }
            }
        }
        return count
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.title = "분석할 영상 선택"
        panel.prompt = "대기열에 추가"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        if panel.runModal() == .OK { addVideos(panel.urls) }
    }

    func addVideos(_ urls: [URL], enqueue: Bool = true) {
        let supported = urls.filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        if supported.count != urls.count {
            let rejected = urls.filter { !["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
            errorMessage = "MP4, MOV 또는 M4V 영상만 추가할 수 있습니다."
            AppLogger.shared.record(
                level: .warning,
                category: "파일 추가",
                message: "지원하지 않는 형식의 파일이 제외되었습니다.",
                details: rejected.map(\.path).joined(separator: "\n")
            )
        }
        var firstAdded: UUID?
        for url in supported {
            if let existing = items.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                if firstAdded == nil { firstAdded = existing.id }
                continue
            }
            var item = AnalysisItem(url: url)
            if enqueue {
                item.state = .queued
                item.status = "분석 순서를 기다리는 중…"
            } else {
                item.status = "영상이 준비되었습니다. ‘분석 시작’을 누르세요."
            }
            items.append(item)
            if firstAdded == nil { firstAdded = item.id }
        }
        if let firstAdded { selectItem(firstAdded) }
        saveSession()
        if enqueue { startQueueIfNeeded() }
    }

    func openVideo(_ url: URL) { addVideos([url], enqueue: false) }

    func selectItem(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }), selectedID != id else { return }
        player.pause()
        isPlaying = false
        selectedID = id
        player.replaceCurrentItem(with: AVPlayerItem(url: item.url))
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        playbackRate = 1
        currentTime = 0
        videoDuration = item.report?.duration ?? 0
        saveSession()
        Task {
            let duration = try? await AVURLAsset(url: item.url).load(.duration).seconds
            guard self.selectedID == id, let duration, duration.isFinite else { return }
            self.videoDuration = duration
        }
    }

    func showItemForReview(_ id: UUID) {
        selectItem(id)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.title.contains("영상 검수 도우미") })?.makeKeyAndOrderFront(nil)
    }

    func analyze() {
        guard let id = selectedID else { return }
        enqueueItem(id)
    }

    func enqueueItem(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .running else { return }
        items[index].state = .queued
        items[index].report = nil
        items[index].progress = 0
        items[index].elapsedSeconds = nil
        items[index].estimatedRemainingSeconds = nil
        items[index].errorMessage = nil
        items[index].errorDetails = nil
        items[index].status = "분석 순서를 기다리는 중…"
        saveSession()
        startQueueIfNeeded()
    }

    private func startQueueIfNeeded() {
        guard queueTask == nil else { return }
        queueTask = Task { [weak self] in
            guard let self else { return }
            while let item = self.items.first(where: { $0.state == .queued }) {
                let id = item.id
                guard let index = self.items.firstIndex(where: { $0.id == id }) else { continue }
                self.items[index].state = .running
                self.items[index].status = "분석을 준비하는 중…"
                self.activeID = id
                let worker = Task {
                    try await VideoAnalyzer.analyze(url: item.url) { update in
                        await MainActor.run {
                            guard let index = self.items.firstIndex(where: { $0.id == id }),
                                  self.items[index].state == .running else { return }
                            self.items[index].progress = update.fraction
                            self.items[index].status = update.message
                            self.items[index].elapsedSeconds = update.elapsedSeconds
                            self.items[index].estimatedRemainingSeconds = update.estimatedRemainingSeconds
                        }
                    }
                }
                self.activeTask = worker
                do {
                    let result = try await worker.value
                    if let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].state == .running {
                        self.items[index].report = result
                        self.items[index].progress = 1
                        self.items[index].state = .completed
                        self.items[index].status = "분석 완료 · 후보 \(result.events.count)개"
                    }
                } catch is CancellationError {
                    if let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].state == .running {
                        self.items[index].state = .cancelled
                        self.items[index].status = "분석이 취소되었습니다."
                    }
                } catch {
                    let details = AppLogger.describe(error: error, extraDetails: "경로: \(item.url.path)")
                    if let index = self.items.firstIndex(where: { $0.id == id }), self.items[index].state == .running {
                        self.items[index].state = .failed
                        self.items[index].errorMessage = error.localizedDescription
                        self.items[index].errorDetails = details
                        self.items[index].status = "분석 실패 · \(error.localizedDescription)"
                    }
                    AppLogger.shared.record(
                        level: .error,
                        category: "영상 분석",
                        message: "영상 분석 실패: \(error.localizedDescription)",
                        error: error,
                        details: "파일 경로: \(item.url.path)",
                        videoURL: item.url
                    )
                }
                self.saveSession()
                self.activeTask = nil
                self.activeID = nil
            }
            self.queueTask = nil
        }
    }

    func cancelAnalysis() {
        guard let id = selectedID else { return }
        cancelItem(id)
    }

    func cancelItem(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].state == .queued || items[index].state == .running else { return }
        items[index].state = .cancelled
        items[index].status = "분석이 취소되었습니다."
        if activeID == id { activeTask?.cancel() }
        saveSession()
    }

    func removeItem(_ id: UUID) {
        cancelItem(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedID == id
        items.remove(at: index)
        if wasSelected {
            selectedID = nil
            if let next = items.indices.contains(index) ? items[index].id : items.last?.id {
                selectItem(next)
            } else {
                player.pause()
                player.replaceCurrentItem(with: nil)
                currentTime = 0
                videoDuration = 0
            }
        }
        saveSession()
    }

    func seek(to seconds: Double) {
        let target = min(max(0, seconds), videoDuration > 0 ? videoDuration : seconds)
        currentTime = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying { player.playImmediately(atRate: Float(playbackRate)) }
    }

    func togglePlayback() {
        if isPlaying { player.pause(); isPlaying = false }
        else { player.playImmediately(atRate: Float(playbackRate)); isPlaying = true }
    }

    private let playbackRates: [Double] = [0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8, 10]

    func seekRelative(_ seconds: Double) { seek(to: currentTime + seconds) }

    func slower() {
        let target = playbackRates.last(where: { $0 < playbackRate - 0.001 }) ?? 0.1
        setPlaybackRate(target)
    }
    func normalSpeed() { setPlaybackRate(1.0) }
    func faster() {
        let target = playbackRates.first(where: { $0 > playbackRate + 0.001 }) ?? 10
        setPlaybackRate(target)
    }

    func setPlaybackRate(_ rate: Double) {
        playbackRate = min(10, max(0.1, rate))
        player.currentItem?.audioTimePitchAlgorithm = .spectral
        if isPlaying { player.playImmediately(atRate: Float(playbackRate)) }
    }

    func openBible(_ reference: BibleReference) {
        guard let url = reference.url else { return }
        NSWorkspace.shared.open(url)
    }

    func toggle(_ kind: ReviewEventKind) {
        if enabledKinds.contains(kind) { enabledKinds.remove(kind) }
        else { enabledKinds.insert(kind) }
    }

    func exportJSON() {
        guard let report else { return }
        let panel = NSSavePanel()
        panel.title = "분석 결과 저장"
        panel.nameFieldStringValue = "\(report.videoName)-검수결과.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: target, options: .atomic)
            // 저장 여부는 탭의 분석 상태를 바꾸지 않는다.
        } catch {
            errorMessage = error.localizedDescription
            AppLogger.shared.record(
                level: .error,
                category: "JSON 내보내기",
                message: "분석 결과 JSON 저장에 실패했습니다.",
                error: error,
                details: "대상 경로: \(target.path)",
                videoURL: videoURL
            )
        }
    }
}
