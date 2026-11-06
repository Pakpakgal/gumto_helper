import Foundation

enum ReviewEventKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case cut
    case dissolve
    case subtitle

    var id: String { rawValue }
    var label: String {
        switch self {
        case .cut: return "컷"
        case .dissolve: return "디졸브"
        case .subtitle: return "자막"
        }
    }
}

struct ReviewEvent: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let kind: ReviewEventKind
    var label: String
    let time: Double
    let endTime: Double?
    let confidence: Double
    var thumbnailPath: String?
    var recognizedText: String?
    var bibleReferences: [BibleReference]
    var bibleComparisons: [BibleComparisonResult]
    var isPrayer: Bool
    var grammarSuggestions: [String]

    init(
        kind: ReviewEventKind,
        label: String,
        time: Double,
        endTime: Double? = nil,
        confidence: Double,
        thumbnailPath: String? = nil,
        recognizedText: String? = nil,
        bibleReferences: [BibleReference] = [],
        bibleComparisons: [BibleComparisonResult] = [],
        isPrayer: Bool = false,
        grammarSuggestions: [String] = []
    ) {
        self.id = UUID()
        self.kind = kind
        self.label = label
        self.time = time
        self.endTime = endTime
        self.confidence = confidence
        self.thumbnailPath = thumbnailPath
        self.recognizedText = recognizedText
        self.bibleReferences = bibleReferences
        self.bibleComparisons = bibleComparisons
        self.isPrayer = isPrayer
        self.grammarSuggestions = grammarSuggestions
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, label, time, endTime, confidence, thumbnailPath, recognizedText, bibleReferences, bibleComparisons, isPrayer, grammarSuggestions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.kind = try container.decode(ReviewEventKind.self, forKey: .kind)
        self.label = try container.decode(String.self, forKey: .label)
        self.time = try container.decode(Double.self, forKey: .time)
        self.endTime = try container.decodeIfPresent(Double.self, forKey: .endTime)
        self.confidence = try container.decode(Double.self, forKey: .confidence)
        self.thumbnailPath = try container.decodeIfPresent(String.self, forKey: .thumbnailPath)
        self.recognizedText = try container.decodeIfPresent(String.self, forKey: .recognizedText)
        self.bibleReferences = try container.decodeIfPresent([BibleReference].self, forKey: .bibleReferences) ?? []
        self.bibleComparisons = try container.decodeIfPresent([BibleComparisonResult].self, forKey: .bibleComparisons) ?? []
        self.isPrayer = try container.decodeIfPresent(Bool.self, forKey: .isPrayer) ?? false
        self.grammarSuggestions = try container.decodeIfPresent([String].self, forKey: .grammarSuggestions) ?? []
    }
}

struct BibleReference: Codable, Hashable, Identifiable, Sendable {
    let book: String
    let osisCode: String
    let chapter: Int
    let verse: Int
    let endVerse: Int?
    let accuracy: Double?

    var id: String { "\(osisCode).\(chapter).\(verse).\(endVerse ?? verse)" }
    var displayName: String {
        endVerse.map { "\(book) \(chapter):\(verse)-\($0)" } ?? "\(book) \(chapter):\(verse)"
    }
    var url: URL? {
        URL(string: "https://bible.bskorea.or.kr/bible/NKRV/\(osisCode).\(chapter).\(verse)")
    }
}

enum BibleMatchStatus: String, Codable, Sendable {
    case exact = "완전 일치"
    case minorTypo = "오탈자 의심"
    case mismatch = "불일치"
    case referenceOnly = "장·절 표기만 있음"
}

struct BibleTextError: Codable, Hashable, Identifiable, Sendable {
    enum ErrorKind: String, Codable, Sendable {
        case typo = "오탈자"
        case missing = "누락"
        case inserted = "추가"
        case verseNumber = "절 번호"
    }

    var id: String { "\(kind.rawValue):\(expected)->\(recognized)" }
    let kind: ErrorKind
    let expected: String
    let recognized: String
    let description: String
}

struct BibleComparisonResult: Codable, Hashable, Identifiable, Sendable {
    var id: String { reference.id }
    let reference: BibleReference
    let scriptureText: String
    let subtitleText: String
    let accuracy: Double
    let status: BibleMatchStatus
    let errors: [BibleTextError]
    let summary: String
    /// 본문 시작 직전에 표기된 절 번호 (본문 비교에서는 제외한다).
    var markedVerse: Int? = nil
    /// 표기된 절 번호가 참조 범위에 포함되는지 여부.
    var markedVerseInRange: Bool? = nil
}

struct LoudnessResult: Codable, Sendable {
    enum Level { case ready, loud, quiet, peak }

    let integratedLUFS: Double
    let samplePeakDBFS: Double

    var level: Level {
        if isYouTubeReady { return .ready }
        if integratedLUFS > -13 { return .loud }
        if integratedLUFS < -15 { return .quiet }
        return .peak
    }
    var isYouTubeReady: Bool {
        integratedLUFS >= -15 && integratedLUFS <= -13 && samplePeakDBFS <= -1
    }
    var statusLabel: String {
        switch level {
        case .ready: return "YouTube 실무 기준 적합"
        case .loud: return "음량이 높아 정규화될 수 있음"
        case .quiet: return "권장 음량보다 낮음"
        case .peak: return "피크가 높음"
        }
    }
}

struct AnalysisReport: Codable, Sendable {
    let videoName: String
    let duration: Double
    let width: Int
    let height: Int
    let createdAt: Date
    let events: [ReviewEvent]
    let loudness: LoudnessResult?
}


enum AnalysisItemState: String, Codable {
    case ready, queued, running, completed, failed, cancelled

    var label: String {
        switch self {
        case .ready: return "준비"
        case .queued: return "대기 중"
        case .running: return "분석 중"
        case .completed: return "완료"
        case .failed: return "실패"
        case .cancelled: return "취소됨"
        }
    }

    var symbol: String {
        switch self {
        case .ready: return "film"
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }
}

struct AnalysisItem: Identifiable {
    let id: UUID
    let url: URL
    var state: AnalysisItemState = .ready
    var report: AnalysisReport?
    var progress = 0.0
    var status = "분석 대기 중"
    var elapsedSeconds: Double?
    var estimatedRemainingSeconds: Double?
    var errorMessage: String?
    var errorDetails: String?

    init(id: UUID = UUID(), url: URL) {
        self.id = id
        self.url = url
    }
}

struct AnalysisProgress: Sendable {
    let fraction: Double
    let message: String
    let estimatedRemainingSeconds: Double?
    let elapsedSeconds: Double?
}

enum AnalyzerError: LocalizedError {
    case noVideoTrack
    case cannotRead(reason: String? = nil)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noVideoTrack:
            return "영상 트랙을 찾지 못했습니다."
        case .cannotRead(let reason):
            if let reason, !reason.isEmpty {
                return "영상 프레임을 읽지 못했습니다 (\(reason))."
            }
            return "영상 프레임을 읽지 못했습니다."
        case .cancelled:
            return "분석이 취소되었습니다."
        }
    }
}

func formatTime(_ seconds: Double, includeTenths: Bool = true) -> String {
    let value = max(0, seconds)
    let hours = Int(value) / 3600
    let minutes = (Int(value) % 3600) / 60
    let secs = Int(value) % 60
    let tenth = Int((value - floor(value)) * 10)
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, secs)
    }
    return includeTenths
        ? String(format: "%d:%02d.%d", minutes, secs, tenth)
        : String(format: "%d:%02d", minutes, secs)
}
