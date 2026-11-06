import AppKit
import Foundation

/// 기도문 자막의 오타·띄어쓰기 "검토 가능성"만 표시한다. 문장 다듬기는 하지 않는다.
/// 기도문은 고어체(‘-옵소서’, ‘-나이다’ 등)가 많아 확정적 오류가 아니라 검토 후보로만 다룬다.
enum KoreanGrammarChecker {
    struct Rule {
        let pattern: String
        let suggestion: String
        let reason: String
    }

    /// 오타·띄어쓰기 규칙 (표현을 바꾸라는 권유는 넣지 않는다).
    private static let rules: [Rule] = [
        Rule(pattern: #"안되(?=[\s.!?]|$)"#, suggestion: "안 돼", reason: "단독·어말에서는 ‘안 돼’"),
        Rule(pattern: #"어떻해"#, suggestion: "어떡해", reason: "표기"),
        Rule(pattern: #"바램(?![가-힣])"#, suggestion: "바람", reason: "표기"),
        Rule(pattern: #"([가-힣]*)됬([가-힣]*)"#, suggestion: "$1됐$2", reason: "표기"),
        Rule(pattern: #"뵈요"#, suggestion: "봬요", reason: "표기"),
        Rule(pattern: #"([가-힣]+)ㄹ께(요)?"#, suggestion: "$1ㄹ게$2", reason: "표기"),
        Rule(pattern: #"(있|없)슴(니다)"#, suggestion: "$1습$2", reason: "표기"),
        Rule(pattern: #"어의없"#, suggestion: "어이없", reason: "표기"),
        Rule(pattern: #"예수님의이름으로"#, suggestion: "예수님의 이름으로", reason: "띄어쓰기"),
        Rule(pattern: #"하나님아버지"#, suggestion: "하나님 아버지", reason: "띄어쓰기"),
        Rule(pattern: #"기도합니다(?=[가-힣])(?!아멘)"#, suggestion: "기도합니다. ", reason: "띄어쓰기"),
        Rule(pattern: #"하옵나이다(?=[가-힣])(?!아멘)"#, suggestion: "하옵나이다. ", reason: "띄어쓰기"),
        Rule(pattern: #"(기도합니다|하옵나이다)아멘"#, suggestion: "$1. 아멘", reason: "띄어쓰기")
    ]

    /// 사전에 없어도 오타로 보지 않는 기도문·성경 용어 및 어간.
    private static let allowedWords: Set<String> = [
        "주옵소서", "하옵나이다", "하옵소서", "옵소서", "긍휼", "긍휼히", "간구", "간구하옵나니", "간구합니다",
        "은혜", "은총", "아멘", "성령", "성령님", "예수", "그리스도", "여호와", "하나님", "주님", "아버지",
        "인도하옵소서", "베푸소서", "지키소서", "축복", "축복하옵소서", "찬양", "영광", "구원", "십자가", "말씀",
        "겸손케", "온전케", "거룩케", "회복케", "강건케", "충만케", "승리케", "축복함으로", "감사함으로", "순종함으로",
        "주님만을", "하나님만을", "예수님만을", "주님만", "하나님만"
    ]

    /// 성경 인물·지명·기도 상용 어근 및 활용 어미 패턴 (NSSpellChecker 오탐 방지).
    private static let archaicEnding = try! NSRegularExpression(
        pattern: #"(옵소서|옵나이다|나이다|사오니|사옵니다|사옵나이다|옵나니|시옵고|시옵소서|소서|오니|하옵|이옵|시옵|하사|케$|함으로$|하므로$|만을$|만이$|께서$|께$)"#
    )

    private static let biblicalPrefixes: [String] = [
        "아브라함", "이삭", "야곱", "리브가", "요셉", "모세", "아론", "여호수아", "갈렙", "다윗", "솔로몬",
        "사무엘", "엘리야", "엘리사", "이사야", "예레미야", "에스겔", "다니엘", "베드로", "바울", "요한",
        "이스라엘", "예루살렘", "갈릴리", "사마리아", "그리스도", "하나님", "예수님", "성령님", "주님", "여호와"
    ]

    /// PRAY 자막은 검사에서 제외한다.
    private static let prayLabel = try! NSRegularExpression(pattern: #"\bPRAY(?:ER)?\b"#, options: .caseInsensitive)

    static func check(_ rawText: String) -> [String] {
        let text = stripPrayLabel(rawText)
        var suggestions: [String] = []

        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let original = ns.substring(with: match.range)
                let fixed = regex.replacementString(for: match, in: text, offset: 0, template: rule.suggestion)
                suggestions.append("‘\(original)’ → ‘\(fixed)’ · \(rule.reason)")
            }
        }
        suggestions.append(contentsOf: spellingSuggestions(in: text, alreadyFlagged: suggestions))

        var seen = Set<String>()
        return suggestions.filter { seen.insert($0).inserted }
    }

    static func stripPrayLabel(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return prayLabel.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - macOS 한국어 맞춤법 검사기

    private static func spellingSuggestions(in text: String, alreadyFlagged: [String]) -> [String] {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
            .filter { isCheckable($0) }
        guard !words.isEmpty else { return [] }

        let run: () -> [String] = {
            let checker = NSSpellChecker.shared
            guard checker.availableLanguages.contains("ko") else { return [] }
            var results: [String] = []
            for word in words where !alreadyFlagged.contains(where: { $0.contains("‘\(word)’") }) {
                let range = checker.checkSpelling(
                    of: word, startingAt: 0, language: "ko", wrap: false,
                    inSpellDocumentWithTag: 0, wordCount: nil
                )
                guard range.location != NSNotFound else { continue }
                let guess = checker.guesses(
                    forWordRange: NSRange(location: 0, length: (word as NSString).length),
                    in: word, language: "ko", inSpellDocumentWithTag: 0
                )?.first
                // macOS 기본 한국어 사전은 활용형 어휘가 적어 대안 제시(guess)조차 없는 경우는 사전 미등재 정상 어휘일 확률이 높으므로 제외
                if let guess, guess != word {
                    results.append("‘\(word)’ → ‘\(guess)’ · 오타 가능성")
                }
            }
            return results
        }
        // NSSpellChecker는 메인 스레드에서 쓰는 것이 안전하다.
        return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
    }

    private static func isCheckable(_ word: String) -> Bool {
        guard word.count >= 2, !allowedWords.contains(word) else { return false }
        if biblicalPrefixes.contains(where: { word.hasPrefix($0) }) { return false }
        // 한글로만 이루어진 단어만 검사한다 (숫자·영문 제외).
        guard word.allSatisfy({ $0.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) } }) else { return false }
        let range = NSRange(word.startIndex..., in: word)
        return archaicEnding.firstMatch(in: word, range: range) == nil
    }

    /// 화면 가운데 PRAY 라벨이 보이면 그 시점만 기도문 진입 조건으로 인정한다.
    static func hasPrayLabel(_ text: String) -> Bool {
        prayLabel.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 기도문 텍스트 판별 (점수제). 실제 기도문은 긴 문단 + 고어체 어미(-옵소서/-나이다) +
    /// 기도 키워드를 함께 갖춘다. "기도로 시작합니다"·"기도회"·"중보기도" 같은 짧은 안내문은
    /// 어미가 없어 걸리지 않는다. 키워드 부분일치 하나로 판정하던 예전 방식은 영상 전체를
    /// '기도문 자막'으로 오염시키는 버그의 원인이었다.
    static func looksLikePrayer(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        let hasArchaicEnding = archaicEnding.firstMatch(in: trimmed, range: range) != nil
        let strongKeywords = [
            "함께 기도", "다함께 기도", "다 함께 기도", "기도문", "기도하시겠습니다",
            "기도드립니다", "기도합니다", "기도합시다", "아멘",
            "예수님의 이름으로", "예수님 이름으로", "살아계신 하나님",
            "은혜로우신 하나님", "사랑의 하나님",
        ]
        let keywordHits = strongKeywords.filter { trimmed.contains($0) }.count
        // 고어체 어미 + 키워드 1개 이상, 또는 OCR이 어미를 놓쳤을 때를 대비해 키워드 2개 이상.
        return (hasArchaicEnding && keywordHits >= 1) || keywordHits >= 2
    }
}
