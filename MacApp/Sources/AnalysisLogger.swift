import AppKit
import Foundation
import SwiftUI

struct AnalysisLogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let videoName: String
    let videoDuration: Double
    let eventKind: ReviewEventKind
    let label: String
    let time: Double
    let endTime: Double?
    let confidence: Double
    let recognizedText: String?
    let isPrayer: Bool
    let bibleReferences: [String]
    let matchStatuses: [String]
    let accuracy: Double?
    let scriptureTexts: [String]
    let comparedSubtitleTexts: [String]
    let detectedIssues: [String]
    var isFlaggedFalsePositive: Bool
    var userNote: String

    var hasSuspectedIssue: Bool {
        !detectedIssues.isEmpty || matchStatuses.contains("오탈자 의심") || matchStatuses.contains("불일치")
    }

    var timeRangeString: String {
        if let endTime, endTime > time + 0.2 {
            return "\(formatTime(time)) ~ \(formatTime(endTime))"
        }
        return formatTime(time)
    }

    /// 오탐 리포팅 및 붙여넣기용 포맷 문자열
    var formattedReportBlock: String {
        var lines: [String] = []
        let flagPrefix = isFlaggedFalsePositive ? "[오탐 리포트]" : (hasSuspectedIssue ? "[검수 의심 로그]" : "[분석 결과 로그]")
        lines.append("\(flagPrefix) 파일: \(videoName) | 구간: \(timeRangeString) (영상 길이 \(formatTime(videoDuration, includeTenths: false)))")
        lines.append("- 분류: \(label) (\(eventKind.label), 신뢰도 \(Int(confidence * 100))%)")

        if !bibleReferences.isEmpty {
            let statusStr = matchStatuses.isEmpty ? "" : " | 판정: \(matchStatuses.joined(separator: ", "))"
            let accStr = accuracy.map { String(format: " (일치율 %.1f%%)", $0 * 100) } ?? ""
            lines.append("- 성경 구절: \(bibleReferences.joined(separator: ", "))\(statusStr)\(accStr)")
        } else if isPrayer {
            lines.append("- 구분: 기도문 자막 (맞춤법·띄어쓰기 검토)")
        }

        if let recognizedText, !recognizedText.isEmpty {
            lines.append("- OCR 인식 원문: \(recognizedText)")
        }
        for (idx, sub) in comparedSubtitleTexts.enumerated() where !sub.isEmpty {
            let prefix = comparedSubtitleTexts.count > 1 ? " [\(idx + 1)]" : ""
            lines.append("- 비교 추출 자막\(prefix): \(sub)")
        }
        for (idx, scrip) in scriptureTexts.enumerated() where !scrip.isEmpty {
            let prefix = scriptureTexts.count > 1 ? " [\(idx + 1)]" : ""
            lines.append("- 성경 원문\(prefix): \(scrip)")
        }
        if !detectedIssues.isEmpty {
            lines.append("- 검출된 의심 내역:")
            for issue in detectedIssues {
                lines.append("  • \(issue)")
            }
        }
        if !userNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("- 사용자 메모(오탐 사유): \(userNote)")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class AnalysisLogger: ObservableObject {
    static let shared = AnalysisLogger()

    @Published private(set) var entries: [AnalysisLogEntry] = []

    nonisolated static var logFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hcc.MaeMook", isDirectory: true)
            .appendingPathComponent("analysis.log")
    }

    nonisolated static var entriesFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hcc.MaeMook", isDirectory: true)
            .appendingPathComponent("analysis-entries.json")
    }

    private init() {
        loadSavedEntries()
    }

    var flaggedCount: Int {
        entries.filter(\.isFlaggedFalsePositive).count
    }

    var suspectedCount: Int {
        entries.filter(\.hasSuspectedIssue).count
    }

    /// 분석이 완료된 리포트의 전체 이벤트를 분석 결과 로그에 기록합니다.
    func recordReport(_ report: AnalysisReport, replaceExistingForVideo: Bool = true) {
        let now = report.createdAt
        let existingNotes = Dictionary(
            uniqueKeysWithValues: entries
                .filter { $0.videoName == report.videoName }
                .map { ("\($0.label)|\(String(format: "%.1f", $0.time))", ($0.isFlaggedFalsePositive, $0.userNote)) }
        )

        if replaceExistingForVideo {
            entries.removeAll { $0.videoName == report.videoName }
        }

        var newEntries: [AnalysisLogEntry] = []
        for event in report.events {
            let key = "\(event.label)|\(String(format: "%.1f", event.time))"
            let preserved = existingNotes[key]
            let entry = Self.makeEntry(
                from: event,
                videoName: report.videoName,
                videoDuration: report.duration,
                timestamp: now,
                isFlagged: preserved?.0 ?? false,
                userNote: preserved?.1 ?? ""
            )
            newEntries.append(entry)
        }

        // 최신 분석 영상의 항목이 위에 오되, 같은 영상 내에서는 시간순 유지
        entries.insert(contentsOf: newEntries, at: 0)
        if entries.count > 2000 {
            entries = Array(entries.prefix(2000))
        }
        persistEntries()
        Self.appendReportToLogFile(report: report, entries: newEntries)
    }

    /// 기존 세션에서 복원된 완료 리포트가 아직 로그에 없으면 등록합니다.
    func syncReportsIfNeeded(_ reports: [AnalysisReport]) {
        let loggedVideos = Set(entries.map(\.videoName))
        for report in reports where !loggedVideos.contains(report.videoName) {
            recordReport(report, replaceExistingForVideo: false)
        }
    }

    /// 특정 검출 후보(ReviewEvent)를 오탐 리포트 대상으로 토글하거나 클립보드에 즉시 복사합니다.
    @discardableResult
    func flagAndCopyEvent(
        _ event: ReviewEvent,
        videoName: String,
        videoDuration: Double
    ) -> AnalysisLogEntry {
        if let index = entries.firstIndex(where: { $0.id == event.id || ($0.videoName == videoName && abs($0.time - event.time) < 0.05 && $0.label == event.label) }) {
            entries[index].isFlaggedFalsePositive = true
            let updated = entries[index]
            persistEntries()
            Self.appendSingleFlagToFile(updated)
            copyText(updated.formattedReportBlock)
            return updated
        } else {
            let created = Self.makeEntry(
                from: event,
                videoName: videoName,
                videoDuration: videoDuration,
                timestamp: Date(),
                isFlagged: true,
                userNote: ""
            )
            entries.insert(created, at: 0)
            persistEntries()
            Self.appendSingleFlagToFile(created)
            copyText(created.formattedReportBlock)
            return created
        }
    }

    func isFlagged(eventID: UUID, videoName: String?, time: Double, label: String) -> Bool {
        entries.contains {
            $0.isFlaggedFalsePositive && (
                $0.id == eventID ||
                ($0.videoName == videoName && abs($0.time - time) < 0.05 && $0.label == label)
            )
        }
    }

    func toggleFlag(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFlaggedFalsePositive.toggle()
        if entries[index].isFlaggedFalsePositive {
            Self.appendSingleFlagToFile(entries[index])
        }
        persistEntries()
    }

    func updateNote(id: UUID, note: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].userNote = note
        persistEntries()
    }

    func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyEntries(_ targetEntries: [AnalysisLogEntry]) {
        let text = targetEntries.map(\.formattedReportBlock).joined(separator: "\n\n----------------------------------------\n\n")
        copyText(text.isEmpty ? "기록된 분석 결과 로그가 없습니다." : text)
    }

    func revealLogFileInFinder() {
        let url = Self.logFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            let initial = entries.map(\.formattedReportBlock).joined(separator: "\n\n")
            try? initial.write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func exportLogFile(entries targetEntries: [AnalysisLogEntry]) {
        let panel = NSSavePanel()
        panel.title = "분석 결과 로그(오탐 리포트) 내보내기"
        panel.nameFieldStringValue = "매묵_분석결과_오탐리포트.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let target = panel.url else { return }
        let content = targetEntries.map(\.formattedReportBlock).joined(separator: "\n\n========================================\n\n")
        try? content.write(to: target, atomically: true, encoding: .utf8)
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.entriesFileURL)
        try? FileManager.default.removeItem(at: Self.logFileURL)
    }

    private static func makeEntry(
        from event: ReviewEvent,
        videoName: String,
        videoDuration: Double,
        timestamp: Date,
        isFlagged: Bool,
        userNote: String
    ) -> AnalysisLogEntry {
        let refs = event.bibleReferences.map(\.displayName)
        let statuses = event.bibleComparisons.map(\.status.rawValue)
        let avgAcc: Double? = {
            let values = event.bibleComparisons.map(\.accuracy)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }()
        let scripTexts = event.bibleComparisons.map(\.scriptureText).filter { !$0.isEmpty }
        let subTexts = event.bibleComparisons.map(\.subtitleText).filter { !$0.isEmpty }

        var issues: [String] = []
        for comp in event.bibleComparisons {
            if let marker = comp.markedVerse, comp.markedVerseInRange == false {
                issues.append("[\(comp.reference.displayName)] 절 번호 \(marker) 범위 밖")
            }
            for err in comp.errors {
                issues.append("[\(comp.reference.displayName)] (\(err.kind.rawValue)) \(err.description)")
            }
            if comp.errors.isEmpty && (comp.status == .minorTypo || comp.status == .mismatch) {
                issues.append("[\(comp.reference.displayName)] \(comp.summary)")
            }
        }
        for tip in event.grammarSuggestions {
            issues.append("[기도문 맞춤법/띄어쓰기] \(tip)")
        }

        return AnalysisLogEntry(
            id: event.id,
            timestamp: timestamp,
            videoName: videoName,
            videoDuration: videoDuration,
            eventKind: event.kind,
            label: event.label,
            time: event.time,
            endTime: event.endTime,
            confidence: event.confidence,
            recognizedText: event.recognizedText,
            isPrayer: event.isPrayer,
            bibleReferences: refs,
            matchStatuses: statuses,
            accuracy: avgAcc,
            scriptureTexts: scripTexts,
            comparedSubtitleTexts: subTexts,
            detectedIssues: issues,
            isFlaggedFalsePositive: isFlagged,
            userNote: userNote
        )
    }

    private func loadSavedEntries() {
        guard let data = try? Data(contentsOf: Self.entriesFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([AnalysisLogEntry].self, from: data) {
            entries = loaded.map { Self.refreshEntry($0) }
            persistEntries()
        }
    }

    /// 이전 버전에서 기록된 로그 항목도 최신 다중 절(22, 23절 / 11, 12절)·상반절·기도문 검증 로직으로 자동 갱신합니다.
    private static func refreshEntry(_ entry: AnalysisLogEntry) -> AnalysisLogEntry {
        guard entry.eventKind == .subtitle, let text = entry.recognizedText, !text.isEmpty else {
            return entry
        }
        if entry.isPrayer {
            let tips = KoreanGrammarChecker.check(text).map { "[기도문 맞춤법/띄어쓰기] \($0)" }
            return AnalysisLogEntry(
                id: entry.id,
                timestamp: entry.timestamp,
                videoName: entry.videoName,
                videoDuration: entry.videoDuration,
                eventKind: entry.eventKind,
                label: entry.label,
                time: entry.time,
                endTime: entry.endTime,
                confidence: entry.confidence,
                recognizedText: entry.recognizedText,
                isPrayer: true,
                bibleReferences: [],
                matchStatuses: [],
                accuracy: nil,
                scriptureTexts: [],
                comparedSubtitleTexts: [],
                detectedIssues: tips,
                isFlaggedFalsePositive: entry.isFlaggedFalsePositive,
                userNote: entry.userNote
            )
        }
        if entry.label.contains("본문 안내") {
            return entry
        }
        let parsed = BibleReferenceParser.parse(text)
        guard !parsed.isEmpty else { return entry }
        let result = BibleVerseChecker.analyze(recognizedText: text, references: parsed)
        let refNames = result.references.map(\.displayName)
        let updatedEvent = ReviewEvent(
            kind: .subtitle,
            label: "말씀 자막 (\(refNames.joined(separator: ", ")))",
            time: entry.time,
            endTime: entry.endTime,
            confidence: entry.confidence,
            recognizedText: text,
            bibleReferences: result.references,
            bibleComparisons: result.comparisons,
            isPrayer: false,
            grammarSuggestions: []
        )
        return makeEntry(
            from: updatedEvent,
            videoName: entry.videoName,
            videoDuration: entry.videoDuration,
            timestamp: entry.timestamp,
            isFlagged: entry.isFlaggedFalsePositive,
            userNote: entry.userNote
        )
    }

    private func persistEntries() {
        do {
            let target = Self.entriesFileURL
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(entries).write(to: target, options: .atomic)
        } catch {
            // Ignore persistence failure
        }
    }

    nonisolated private static func appendReportToLogFile(report: AnalysisReport, entries: [AnalysisLogEntry]) {
        let formatter = ISO8601DateFormatter()
        var block = "\n================================================================================\n"
        block += "[분석 완료] \(report.videoName) | 분석 시각: \(formatter.string(from: report.createdAt)) | 길이: \(formatTime(report.duration, includeTenths: false)) | 총 후보: \(entries.count)건\n"
        if let loudness = report.loudness {
            block += String(format: "[음량 측정] 통합 %.1f LUFS / 피크 %.1f dBFS (%@)\n", loudness.integratedLUFS, loudness.samplePeakDBFS, loudness.statusLabel)
        }
        block += "================================================================================\n\n"
        block += entries.map(\.formattedReportBlock).joined(separator: "\n\n----------------------------------------\n\n")
        block += "\n\n"
        writeAppend(block)
    }

    nonisolated private static func appendSingleFlagToFile(_ entry: AnalysisLogEntry) {
        let block = "\n>>> [사용자 오탐 체크 기록] <<<\n" + entry.formattedReportBlock + "\n\n"
        writeAppend(block)
    }

    nonisolated private static func writeAppend(_ string: String) {
        let url = logFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let data = string.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url, options: .atomic)
            }
        } catch {
            // Ignore file write failure
        }
    }
}

struct AnalysisLogView: View {
    @ObservedObject private var analysisLogger = AnalysisLogger.shared
    @EnvironmentObject private var model: AppModel

    enum FilterMode: String, CaseIterable {
        case suspected = "오탈자·의심 판정"
        case flagged = "🚩 오탐 체크됨"
        case subtitles = "전체 자막·말씀"
        case all = "전체 이벤트(컷·디졸브 포함)"
    }

    @State private var filterMode: FilterMode = .suspected
    @State private var selectedVideo: String = "전체 영상"
    @State private var searchText = ""
    @State private var copiedFeedback: String?

    private var videoNames: [String] {
        var seen = Set<String>()
        var result = ["전체 영상"]
        for entry in analysisLogger.entries {
            if seen.insert(entry.videoName).inserted {
                result.append(entry.videoName)
            }
        }
        return result
    }

    private var filteredEntries: [AnalysisLogEntry] {
        analysisLogger.entries.filter { entry in
            if selectedVideo != "전체 영상" && entry.videoName != selectedVideo {
                return false
            }
            switch filterMode {
            case .suspected:
                if !entry.hasSuspectedIssue && !entry.isFlaggedFalsePositive { return false }
            case .flagged:
                if !entry.isFlaggedFalsePositive { return false }
            case .subtitles:
                if entry.eventKind != .subtitle { return false }
            case .all:
                break
            }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return entry.videoName.lowercased().contains(q)
                || entry.label.lowercased().contains(q)
                || (entry.recognizedText?.lowercased().contains(q) ?? false)
                || entry.detectedIssues.contains(where: { $0.lowercased().contains(q) })
                || entry.userNote.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterBar
            Divider()
            if filteredEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filteredEntries) { entry in
                            AnalysisLogRow(
                                entry: entry,
                                onToggleFlag: { analysisLogger.toggleFlag(id: entry.id) },
                                onCopy: {
                                    analysisLogger.copyText(entry.formattedReportBlock)
                                    showCopied("단건 복사됨")
                                },
                                onUpdateNote: { note in
                                    analysisLogger.updateNote(id: entry.id, note: note)
                                },
                                onSeekToVideo: {
                                    if let item = model.items.first(where: { $0.url.lastPathComponent == entry.videoName }) {
                                        model.showItemForReview(item.id)
                                        model.seek(to: max(0, entry.time - 1))
                                    }
                                }
                            )
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            let reports = model.items.compactMap(\.report)
            analysisLogger.syncReportsIfNeeded(reports)
            if analysisLogger.suspectedCount == 0 && analysisLogger.flaggedCount == 0 {
                filterMode = .subtitles
            }
        }
    }

    private func showCopied(_ label: String) {
        copiedFeedback = label
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if copiedFeedback == label { copiedFeedback = nil }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("분석 결과 로그 (오탐 리포트)").uiFont(.title2.weight(.semibold))
                    if let copiedFeedback {
                        Text(copiedFeedback)
                            .uiFont(.caption.weight(.bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.14), in: Capsule())
                    }
                }
                Text("오탐 리포팅용 상세 OCR 원문·성경 대조 로그 · 파일: \(AnalysisLogger.logFileURL.path)")
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                let targets = analysisLogger.entries.filter { $0.isFlaggedFalsePositive }
                let listToCopy = targets.isEmpty ? filteredEntries : targets
                analysisLogger.copyEntries(listToCopy)
                showCopied(targets.isEmpty ? "현재 목록(\(listToCopy.count)건) 복사됨" : "오탐 체크(\(targets.count)건) 복사됨")
            } label: {
                Label(
                    analysisLogger.flaggedCount > 0 ? "오탐 체크(\(analysisLogger.flaggedCount)건) 복사" : "현재 목록 복사",
                    systemImage: "doc.on.doc.fill"
                )
            }
            .buttonStyle(.borderedProminent)

            Button {
                analysisLogger.exportLogFile(entries: filteredEntries)
            } label: {
                Label("파일로 저장", systemImage: "square.and.arrow.down")
            }

            Button {
                analysisLogger.revealLogFileInFinder()
            } label: {
                Label("로그 파일 열기", systemImage: "folder")
            }

            Button(role: .destructive) {
                analysisLogger.clear()
            } label: {
                Label("비우기", systemImage: "trash")
            }
            .disabled(analysisLogger.entries.isEmpty)
        }
        .padding(16)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            ForEach(FilterMode.allCases, id: \.rawValue) { mode in
                let count = countForMode(mode)
                Button("\(mode.rawValue) (\(count))") {
                    filterMode = mode
                }
                .buttonStyle(.bordered)
                .tint(filterMode == mode ? .accentColor : .secondary)
            }

            Picker("영상", selection: $selectedVideo) {
                ForEach(videoNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 190)

            Spacer()

            TextField("자막, 구절, 오탐 사유 검색…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func countForMode(_ mode: FilterMode) -> Int {
        analysisLogger.entries.filter { entry in
            if selectedVideo != "전체 영상" && entry.videoName != selectedVideo { return false }
            switch mode {
            case .suspected: return entry.hasSuspectedIssue || entry.isFlaggedFalsePositive
            case .flagged: return entry.isFlaggedFalsePositive
            case .subtitles: return entry.eventKind == .subtitle
            case .all: return true
            }
        }.count
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .uiFont(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("표시할 분석 결과 로그가 없습니다")
                .uiFont(.headline)
            Text("영상을 분석하면 모든 자막 OCR 인식 원문과 성경 구절 대조 내역이 이곳에 자동 기록됩니다.\n검출 후보 목록에서 ‘오탐 리포트’ 버튼을 누르면 즉시 복사 및 체크됩니다.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct AnalysisLogRow: View {
    let entry: AnalysisLogEntry
    let onToggleFlag: () -> Void
    let onCopy: () -> Void
    let onUpdateNote: (String) -> Void
    let onSeekToVideo: () -> Void

    @State private var noteText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(entry.videoName)
                    .uiFont(.caption.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(.blue)

                Button(action: onSeekToVideo) {
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").uiFont(.caption2)
                        Text(entry.timeRangeString).uiFont(.caption.monospacedDigit().weight(.semibold))
                    }
                }
                .buttonStyle(.link)
                .help("해당 영상 시점으로 이동")

                Text(entry.label)
                    .uiFont(.subheadline.weight(.semibold))

                if let acc = entry.accuracy {
                    Text(String(format: "%.0f%%", acc * 100))
                        .uiFont(.caption2.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(statusColor.opacity(0.14), in: Capsule())
                        .foregroundStyle(statusColor)
                }

                Spacer()

                Button(action: onToggleFlag) {
                    Label(
                        entry.isFlaggedFalsePositive ? "오탐 체크됨" : "오탐 표시",
                        systemImage: entry.isFlaggedFalsePositive ? "flag.fill" : "flag"
                    )
                    .uiFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(entry.isFlaggedFalsePositive ? .red : .secondary)

                Button(action: onCopy) {
                    Label("리포트 복사", systemImage: "doc.on.doc")
                        .uiFont(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let raw = entry.recognizedText, !raw.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top, spacing: 6) {
                        Text("OCR 인식 원문:")
                            .uiFont(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 86, alignment: .leading)
                        Text(raw)
                            .uiFont(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    ForEach(Array(entry.comparedSubtitleTexts.enumerated()), id: \.offset) { _, sub in
                        HStack(alignment: .top, spacing: 6) {
                            Text("비교 추출 본문:")
                                .uiFont(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 86, alignment: .leading)
                            Text(sub)
                                .uiFont(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    ForEach(Array(entry.scriptureTexts.enumerated()), id: \.offset) { _, scrip in
                        HStack(alignment: .top, spacing: 6) {
                            Text("성경 비교 원문:")
                                .uiFont(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 86, alignment: .leading)
                            Text(scrip)
                                .uiFont(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }

            if !entry.detectedIssues.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("검출된 오탈자·차이 내역:")
                        .uiFont(.caption2.weight(.bold))
                        .foregroundStyle(.orange)
                    ForEach(entry.detectedIssues, id: \.self) { issue in
                        Text("• \(issue)")
                            .uiFont(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }
                .padding(7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 6) {
                Image(systemName: "square.and.pencil")
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                TextField("오탐 사유 메모 입력 (예: 상반절 자막인데 누락으로 잡힘, OCR 오인식 등)…", text: $noteText)
                    .textFieldStyle(.roundedBorder)
                    .uiFont(.caption)
                    .onSubmit {
                        onUpdateNote(noteText)
                    }
                    .onChange(of: noteText) { newValue in
                        onUpdateNote(newValue)
                    }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(entry.isFlaggedFalsePositive ? Color.red.opacity(0.6) : statusColor.opacity(0.28), lineWidth: entry.isFlaggedFalsePositive ? 1.5 : 1)
        )
        .onAppear {
            noteText = entry.userNote
        }
    }

    private var statusColor: Color {
        if entry.isFlaggedFalsePositive { return .red }
        if entry.hasSuspectedIssue { return .orange }
        return .green
    }
}
