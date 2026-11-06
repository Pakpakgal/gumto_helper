import AppKit
import Foundation
import SwiftUI

enum ErrorLogLevel: String, Codable, Sendable {
    case error = "오류"
    case warning = "경고"
    case info = "정보"

    var symbol: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
}

struct ErrorLogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: ErrorLogLevel
    let category: String
    let message: String
    let details: String?
    let videoName: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: ErrorLogLevel = .error,
        category: String,
        message: String,
        details: String? = nil,
        videoName: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.details = details
        self.videoName = videoName
    }

    var formattedLine: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var line = "[\(formatter.string(from: timestamp))] [\(level.rawValue)] [\(category)]"
        if let videoName, !videoName.isEmpty {
            line += " (\(videoName))"
        }
        line += " \(message)"
        if let details, !details.isEmpty {
            line += "\n  상세: \(details)"
        }
        return line
    }
}

@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var entries: [ErrorLogEntry] = []

    nonisolated static var logFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hcc.MaeMook", isDirectory: true)
            .appendingPathComponent("error.log")
    }

    nonisolated static var entriesFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.hcc.MaeMook", isDirectory: true)
            .appendingPathComponent("error-entries.json")
    }

    private init() {
        loadSavedEntries()
    }

    var errorCount: Int {
        entries.filter { $0.level == .error || $0.level == .warning }.count
    }

    func record(
        level: ErrorLogLevel = .error,
        category: String,
        message: String,
        error: Error? = nil,
        details: String? = nil,
        videoURL: URL? = nil
    ) {
        let detailText = Self.describe(error: error, extraDetails: details)
        let entry = ErrorLogEntry(
            level: level,
            category: category,
            message: message,
            details: detailText,
            videoName: videoURL?.lastPathComponent
        )
        entries.insert(entry, at: 0)
        if entries.count > 300 {
            entries = Array(entries.prefix(300))
        }
        persistEntries()
        Self.appendToFile(entry)
    }

    nonisolated static func log(
        level: ErrorLogLevel = .error,
        category: String,
        message: String,
        error: Error? = nil,
        details: String? = nil,
        videoURL: URL? = nil
    ) {
        let detailText = describe(error: error, extraDetails: details)
        let videoName = videoURL?.lastPathComponent
        Task { @MainActor in
            AppLogger.shared.record(
                level: level,
                category: category,
                message: message,
                error: nil,
                details: detailText,
                videoURL: videoName.map { URL(fileURLWithPath: $0) }
            )
        }
    }

    nonisolated static func describe(error: Error?, extraDetails: String? = nil) -> String? {
        var parts: [String] = []
        if let extraDetails, !extraDetails.isEmpty {
            parts.append(extraDetails)
        }
        if let error {
            let nsError = error as NSError
            parts.append("Description: \(error.localizedDescription)")
            parts.append("Domain: \(nsError.domain) (Code: \(nsError.code))")
            if let failureReason = nsError.localizedFailureReason, !failureReason.isEmpty {
                parts.append("Reason: \(failureReason)")
            }
            if let recovery = nsError.localizedRecoverySuggestion, !recovery.isEmpty {
                parts.append("Suggestion: \(recovery)")
            }
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("Underlying: \(underlying.domain) (\(underlying.code)) - \(underlying.localizedDescription)")
            }
            parts.append("Debug: \(String(reflecting: error))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: Self.entriesFileURL)
        try? FileManager.default.removeItem(at: Self.logFileURL)
    }

    func copyAllToPasteboard() {
        let text = entries.map(\.formattedLine).joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.isEmpty ? "기록된 에러 로그가 없습니다." : text, forType: .string)
    }

    func revealLogFileInFinder() {
        let url = Self.logFileURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func loadSavedEntries() {
        guard let data = try? Data(contentsOf: Self.entriesFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let loaded = try? decoder.decode([ErrorLogEntry].self, from: data) {
            entries = loaded
        }
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
            // Ignore persistence failure inside logger
        }
    }

    nonisolated private static func appendToFile(_ entry: ErrorLogEntry) {
        let url = logFileURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let line = entry.formattedLine + "\n\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            }
        } catch {
            // Ignore file write failure
        }
    }
}

struct ErrorLogView: View {
    @ObservedObject private var logger = AppLogger.shared
    @State private var selectedLevel: ErrorLogLevel? = nil
    @State private var searchText = ""
    @State private var copiedFeedback = false

    private var filteredEntries: [ErrorLogEntry] {
        logger.entries.filter { entry in
            if let selectedLevel, entry.level != selectedLevel { return false }
            guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
            let query = searchText.lowercased()
            return entry.message.lowercased().contains(query)
                || entry.category.lowercased().contains(query)
                || (entry.details?.lowercased().contains(query) ?? false)
                || (entry.videoName?.lowercased().contains(query) ?? false)
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
                            ErrorLogRow(entry: entry)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("에러 로그").uiFont(.title2.weight(.semibold))
                Text("총 \(logger.entries.count)건 · 파일 경로: \(AppLogger.logFileURL.path)")
                    .uiFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                logger.copyAllToPasteboard()
                copiedFeedback = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    copiedFeedback = false
                }
            } label: {
                Label(copiedFeedback ? "복사됨" : "전체 복사", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
            }
            Button {
                logger.revealLogFileInFinder()
            } label: {
                Label("로그 파일 열기", systemImage: "folder")
            }
            Button(role: .destructive) {
                logger.clear()
            } label: {
                Label("비우기", systemImage: "trash")
            }
            .disabled(logger.entries.isEmpty)
        }
        .padding(16)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            Button("전체 (\(logger.entries.count))") { selectedLevel = nil }
                .buttonStyle(.bordered)
                .tint(selectedLevel == nil ? .accentColor : .secondary)

            ForEach([ErrorLogLevel.error, .warning, .info], id: \.rawValue) { level in
                let count = logger.entries.filter { $0.level == level }.count
                Button("\(level.rawValue) (\(count))") { selectedLevel = level }
                    .buttonStyle(.bordered)
                    .tint(selectedLevel == level ? levelColor(level) : .secondary)
            }

            Spacer()

            TextField("메시지, 파일명, 에러 코드 검색…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 240)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .uiFont(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("기록된 에러 로그가 없습니다")
                .uiFont(.headline)
            Text("영상 분석, 음량 측정, 파일 입출력, 업데이트 확인 중 발생한 오류가 이곳에 상세히 기록됩니다.")
                .uiFont(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func levelColor(_ level: ErrorLogLevel) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}

private struct ErrorLogRow: View {
    let entry: ErrorLogEntry
    @State private var isExpanded = true

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: entry.level.symbol)
                    .foregroundStyle(color)
                Text(entry.category)
                    .uiFont(.caption.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color.opacity(0.14), in: Capsule())
                    .foregroundStyle(color)

                if let videoName = entry.videoName {
                    Text(videoName)
                        .uiFont(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                Text(Self.dateFormatter.string(from: entry.timestamp))
                    .uiFont(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.formattedLine, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .uiFont(.caption)
                }
                .buttonStyle(.plain)
                .help("이 로그 복사")
            }

            Text(entry.message)
                .uiFont(.subheadline.weight(.medium))
                .textSelection(.enabled)

            if let details = entry.details, !details.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    Text(details)
                        .uiFont(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.top, 4)
                } label: {
                    Text("상세 에러 원인 / 코드")
                        .uiFont(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }

    private var color: Color {
        switch entry.level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}
