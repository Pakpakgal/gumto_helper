import Foundation

// MARK: - BibleVerseChecker

enum BibleVerseChecker {

    // MARK: - In-Memory Bible Cache

    /// Canonical Book Name -> Chapter -> Verse -> Verse Text
    private static let verses: [String: [Int: [Int: String]]] = {
        guard let url = findBibleURL(),
              let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        var result: [String: [Int: [Int: String]]] = [:]
        let regex = try? NSRegularExpression(pattern: #"^([가-힣]+)(\d+):(\d+)$"#)

        for (key, text) in json {
            let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let nsKey = key as NSString
            let range = NSRange(location: 0, length: nsKey.length)
            guard let match = regex?.firstMatch(in: key, range: range),
                  match.numberOfRanges == 4 else { continue }

            let bookPrefix = nsKey.substring(with: match.range(at: 1))
            let chapterStr = nsKey.substring(with: match.range(at: 2))
            let verseStr = nsKey.substring(with: match.range(at: 3))

            guard let chapter = Int(chapterStr), let verse = Int(verseStr) else { continue }
            let canonicalName = BibleReferenceParser.aliasesToCanonical[bookPrefix] ?? bookPrefix
            result[canonicalName, default: [:]][chapter, default: [:]][verse] = trimmedText
        }

        return result
    }()

    private static func findBibleURL() -> URL? {
        if let url = Bundle.main.url(forResource: "bible", withExtension: "json") { return url }
        if let url = Bundle(for: _BundleHost.self).url(forResource: "bible", withExtension: "json") { return url }

        let execURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let candidatePaths = [
            execURL.deletingLastPathComponent().appendingPathComponent("../Resources/bible.json").standardized.path,
            execURL.deletingLastPathComponent().appendingPathComponent("Resources/bible.json").standardized.path,
            execURL.deletingLastPathComponent().appendingPathComponent("bible.json").standardized.path,
            "/Users/hyunsoo/Dev/MaeMook_Gumto/dist/bible.json",
            "/Users/hyunsoo/Dev/MaeMook_Gumto/MacApp/Resources/bible.json"
        ]
        for path in candidatePaths {
            if FileManager.default.fileExists(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// 주어진 참조 범위의 원문 전체 문자열(공백·기호 제거 정규화)을 반환합니다.
    static func normalizedScripture(for references: [BibleReference]) -> String {
        var chunks: [String] = []
        for ref in references {
            let start = ref.verse
            let end = max(start, ref.endVerse ?? ref.verse)
            for v in start...end {
                if let text = verses[ref.book]?[ref.chapter]?[v] {
                    chunks.append(text)
                }
            }
        }
        return normalizeKorean(chunks.joined(separator: " "))
    }

    // MARK: - Public API

    /// OCR 텍스트에서 성경 본문 참조를 조회하고 원문과 대조하여 오류 및 정확도를 분석합니다.
    static func analyze(
        recognizedText: String?,
        references: [BibleReference]
    ) -> (references: [BibleReference], comparisons: [BibleComparisonResult]) {
        guard let rawText = recognizedText, !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (references.map { $0.withAccuracy(nil) }, [])
        }

        var updatedRefs: [BibleReference] = []
        var comparisons: [BibleComparisonResult] = []

        // (상반절), (하반절), (중반절) 등 부분 절 표기 여부 감지
        let partLabel = extractPartLabel(from: rawText)
        // OCR 인식 텍스트에서 장·절 표기를 분리한 순수 자막 본문 추출
        let strippedBody = extractSubtitleBody(from: rawText)
        // 본문 직전의 절 번호(예: "14 그러므로 …")는 비교 대상에서 빼고 범위 포함 여부만 본다.
        let (markedVerse, subtitleBody) = extractLeadingVerseNumber(from: strippedBody)

        for ref in references {
            let start = ref.verse
            let end = ref.endVerse ?? ref.verse
            var verseList: [(verse: Int, text: String)] = []
            for v in start...max(start, end) {
                if let text = verses[ref.book]?[ref.chapter]?[v] {
                    verseList.append((v, text))
                }
            }

            guard !verseList.isEmpty else {
                updatedRefs.append(ref.withAccuracy(nil))
                continue
            }

            // "14-15절" 표기라도 화면에는 한 절씩 나눠 나올 수 있으므로,
            // 범위 안의 연속된 절 조합 중 자막과 가장 잘 맞는 구간을 원문으로 사용한다.
            let markerInRange = markedVerse.map { start...max(start, end) ~= $0 }
            let (scriptureText, shownRange) = bestScriptureSpan(
                verseList,
                subtitle: subtitleBody,
                startingAt: markerInRange == true ? markedVerse : nil
            )
            var comparison = compareText(
                reference: ref,
                scriptureText: scriptureText,
                subtitleText: subtitleBody,
                partLabel: partLabel
            )
            if let shownRange, comparison.status != .referenceOnly {
                let label = shownRange.lowerBound == shownRange.upperBound
                    ? "\(shownRange.lowerBound)절"
                    : "\(shownRange.lowerBound)-\(shownRange.upperBound)절"
                comparison = BibleComparisonResult(
                    reference: comparison.reference,
                    scriptureText: comparison.scriptureText,
                    subtitleText: comparison.subtitleText,
                    accuracy: comparison.accuracy,
                    status: comparison.status,
                    errors: comparison.errors,
                    summary: "\(label) 부분 표시 · \(comparison.summary)"
                )
            }

            if let markedVerse {
                comparison = applyVerseMarker(
                    to: comparison,
                    marker: markedVerse,
                    inRange: markerInRange ?? false,
                    start: start,
                    end: max(start, end)
                )
            }

            comparisons.append(comparison)
            updatedRefs.append(ref.withAccuracy(comparison.accuracy))
        }

        return (updatedRefs, comparisons)
    }

    /// 범위 표기(예: 14-15절) 중 자막에 실제로 표시된 연속 구간을 찾는다.
    /// 전체 범위가 가장 잘 맞으면 shownRange는 nil.
    private static func bestScriptureSpan(
        _ list: [(verse: Int, text: String)],
        subtitle: String,
        startingAt markedVerse: Int? = nil
    ) -> (String, ClosedRange<Int>?) {
        let full = list.map(\.text).joined(separator: " ")
        let normSub = normalizeKorean(subtitle)
        guard list.count > 1, normSub.count >= 3 else { return (full, nil) }

        var best = (score: characterAccuracy(normalizeKorean(full), normSub), lo: 0, hi: list.count - 1)
        // 절 번호가 표기돼 있으면 그 절에서 시작하는 구간만 후보로 삼는다.
        let fixedLo = markedVerse.flatMap { mv in list.firstIndex(where: { $0.verse == mv }) }
        if let fixedLo {
            best = (-1, fixedLo, fixedLo)
        }
        for lo in list.indices where fixedLo == nil || lo == fixedLo {
            for hi in lo..<list.count where fixedLo != nil || !(lo == 0 && hi == list.count - 1) {
                let text = list[lo...hi].map(\.text).joined(separator: " ")
                let score = characterAccuracy(normalizeKorean(text), normSub)
                if score > best.score + (fixedLo == nil ? 0.02 : 0) { best = (score, lo, hi) }
            }
        }
        let text = list[best.lo...best.hi].map(\.text).joined(separator: " ")
        if best.lo == 0 && best.hi == list.count - 1 { return (text, nil) }
        return (text, list[best.lo].verse...list[best.hi].verse)
    }

    /// 본문 맨 앞의 절 번호("14 그러므로 …", "15절 …")를 분리한다.
    private static func extractLeadingVerseNumber(from body: String) -> (Int?, String) {
        let pattern = #"^\s*(\d{1,3})\s*(?:절)?(?=[\s.:)\]]|$)[.:)\]]?\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return (nil, body) }
        let ns = body as NSString
        guard let match = regex.firstMatch(in: body, range: NSRange(location: 0, length: ns.length)),
              let number = Int(ns.substring(with: match.range(at: 1))) else { return (nil, body) }
        let rest = ns.substring(from: match.range.upperBound).trimmingCharacters(in: .whitespacesAndNewlines)
        return (number, rest)
    }

    private static func applyVerseMarker(
        to comparison: BibleComparisonResult,
        marker: Int,
        inRange: Bool,
        start: Int,
        end: Int
    ) -> BibleComparisonResult {
        var errors = comparison.errors
        var status = comparison.status
        var summary = comparison.summary
        if !inRange {
            let rangeText = start == end ? "\(start)절" : "\(start)-\(end)절"
            errors.insert(BibleTextError(
                kind: .verseNumber,
                expected: rangeText,
                recognized: "\(marker)",
                description: "절 번호 ‘\(marker)’이(가) 표기 범위(\(rangeText))에 없음"
            ), at: 0)
            if status == .exact || status == .referenceOnly { status = .minorTypo }
            summary = "절 번호 \(marker) 범위 밖 · \(summary)"
        }
        return BibleComparisonResult(
            reference: comparison.reference,
            scriptureText: comparison.scriptureText,
            subtitleText: comparison.subtitleText,
            accuracy: comparison.accuracy,
            status: status,
            errors: errors,
            summary: summary,
            markedVerse: marker,
            markedVerseInRange: inRange
        )
    }

    /// 하위 호환용 기존 메서드
    static func validateReferences(
        _ recognizedText: String?,
        references: [BibleReference]
    ) -> [BibleReference] {
        return analyze(recognizedText: recognizedText, references: references).references
    }

    // MARK: - Comparison & Diff Engine

    /// 성경 원문과 자막 본문을 대조하여 비교 결과(상태, 오류 목록, 정확도 등)를 생성합니다.
    static func compareText(
        reference: BibleReference,
        scriptureText: String,
        subtitleText: String,
        partLabel: String? = nil
    ) -> BibleComparisonResult {
        let cleanScripture = scriptureText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSubtitle = subtitleText.trimmingCharacters(in: .whitespacesAndNewlines)

        let normScripture = normalizeKorean(cleanScripture)
        let normSubtitle = normalizeKorean(cleanSubtitle)

        // 자막에 장·절만 있고 본문이 거의 없는 경우 (한글 2글자 미만)
        if normSubtitle.count < 3 {
            return BibleComparisonResult(
                reference: reference,
                scriptureText: cleanScripture,
                subtitleText: cleanSubtitle,
                accuracy: 1.0,
                status: .referenceOnly,
                errors: [],
                summary: "장·절 표기 확인됨 (자막 본문 없음)"
            )
        }

        // (상반절) / (하반절) / (중반절) 부분 절 표시가 있는 경우:
        // 나머지 반절에 대한 '누락' 경고를 생략하고, 표시된 자막이 원문 내에 오타 없이 일치하는지만 검토합니다.
        if let partLabel {
            if normScripture.contains(normSubtitle) {
                return BibleComparisonResult(
                    reference: reference,
                    scriptureText: cleanScripture,
                    subtitleText: cleanSubtitle,
                    accuracy: 1.0,
                    status: .exact,
                    errors: [],
                    summary: "\(partLabel) 원문과 100% 일치 (오타 없음)"
                )
            }

            let partialAcc = Double(charLCSLength(normScripture, normSubtitle)) / Double(max(1, normSubtitle.count))
            let errors = findErrors(scripture: cleanScripture, subtitle: cleanSubtitle, ignoreMissing: true)

            let status: BibleMatchStatus
            let summary: String

            if partialAcc >= 0.70 {
                if errors.isEmpty {
                    status = .exact
                    summary = "\(partLabel) 원문과 일치 (\(Int(partialAcc * 100))% · 오타 없음)"
                } else {
                    status = .minorTypo
                    let typoCount = errors.filter { $0.kind == .typo }.count
                    let insertedCount = errors.filter { $0.kind == .inserted }.count
                    var parts: [String] = []
                    if typoCount > 0 { parts.append("오탈자 \(typoCount)건") }
                    if insertedCount > 0 { parts.append("추가 \(insertedCount)건") }
                    if let first = errors.first {
                        summary = "\(partLabel) · \(first.description) 등 \(parts.joined(separator: ", ")) 의심"
                    } else {
                        summary = "\(partLabel) · \(parts.joined(separator: ", ")) 의심"
                    }
                }
            } else {
                status = .mismatch
                summary = "\(partLabel) 원문과 불일치 (일치율 \(Int(partialAcc * 100))%)"
            }

            return BibleComparisonResult(
                reference: reference,
                scriptureText: cleanScripture,
                subtitleText: cleanSubtitle,
                accuracy: partialAcc,
                status: status,
                errors: errors,
                summary: summary
            )
        }

        // 공백/문장부호 제외 글자가 100% 일치하는 경우
        if normScripture == normSubtitle {
            return BibleComparisonResult(
                reference: reference,
                scriptureText: cleanScripture,
                subtitleText: cleanSubtitle,
                accuracy: 1.0,
                status: .exact,
                errors: [],
                summary: "성경 원문과 100% 완전 일치"
            )
        }

        // 음절 단위 및 어절 단위 유사도 계산
        let charAcc = characterAccuracy(normScripture, normSubtitle)
        let errors = findErrors(scripture: cleanScripture, subtitle: cleanSubtitle, ignoreMissing: false)

        let status: BibleMatchStatus
        let summary: String

        if charAcc >= 0.70 {
            if errors.isEmpty {
                status = .exact
                summary = "성경 원문과 대체로 일치 (\(Int(charAcc * 100))%)"
            } else {
                status = .minorTypo
                let typoCount = errors.filter { $0.kind == .typo }.count
                let missingCount = errors.filter { $0.kind == .missing }.count
                let insertedCount = errors.filter { $0.kind == .inserted }.count

                var parts: [String] = []
                if typoCount > 0 { parts.append("오탈자 \(typoCount)건") }
                if missingCount > 0 { parts.append("누락 \(missingCount)건") }
                if insertedCount > 0 { parts.append("추가 \(insertedCount)건") }

                if let first = errors.first {
                    summary = "\(first.description) 등 \(parts.joined(separator: ", ")) 의심"
                } else {
                    summary = "\(parts.joined(separator: ", ")) 의심 (\(Int(charAcc * 100))%)"
                }
            }
        } else {
            status = .mismatch
            summary = "성경 원문과 불일치 (일치율 \(Int(charAcc * 100))%)"
        }

        return BibleComparisonResult(
            reference: reference,
            scriptureText: cleanScripture,
            subtitleText: cleanSubtitle,
            accuracy: charAcc,
            status: status,
            errors: errors,
            summary: summary
        )
    }

    /// 자막에 (상반절), (하반절), (중반절) 등의 표기가 포함되어 있는지 확인합니다.
    private static func extractPartLabel(from rawText: String) -> String? {
        let patterns: [(pattern: String, label: String)] = [
            (#"(?:\[|\(|\<)?\s*상\s*반\s*절\s*(?:\]|\)|\>)?"#, "상반절"),
            (#"(?:\[|\(|\<)\s*상\s*반\s*(?:\]|\)|\>)"#, "상반절"),
            (#"(?:\[|\(|\<)?\s*하\s*반\s*절\s*(?:\]|\)|\>)?"#, "하반절"),
            (#"(?:\[|\(|\<)\s*하\s*반\s*(?:\]|\)|\>)"#, "하반절"),
            (#"(?:\[|\(|\<)?\s*중\s*반\s*절\s*(?:\]|\)|\>)?"#, "중반절")
        ]
        let ns = rawText as NSString
        let range = NSRange(location: 0, length: ns.length)
        for item in patterns {
            if let regex = try? NSRegularExpression(pattern: item.pattern),
               regex.firstMatch(in: rawText, range: range) != nil {
                return item.label
            }
        }
        return nil
    }

    /// 자막에서 장·절 표기(예: "[창 1:1]", "마태복음 3:16", "(시편 23:1)")를 제거하고 본문만 추출
    private static func extractSubtitleBody(from rawText: String) -> String {
        var text = rawText

        // [창 1:1], (요 3:16-17), 요 3:16, 창세기 1장 1절 등 패턴 매칭 제거
        let refPattern = #"(?:\[|\(|\<)?\s*(?:[가-힣]{1,6})\s*\d{1,3}\s*(?:(?:장|편)\s*|[.:：]\s*)\d{1,3}(?:\s*(?:절)?\s*[-~–—]\s*\d{1,3})?\s*(?:절)?\s*(?:\]|\)|\>)?"#
        if let regex = try? NSRegularExpression(pattern: refPattern) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }

        // (상반절), (하반절), (중반절) 및 괄호가 한쪽 깨진 상반절/하반절 표기 제거
        let partPattern = #"(?:\[|\(|\<)?\s*(?:상|하|중)\s*반\s*절?\s*(?:\]|\)|\>)?"#
        if let regex = try? NSRegularExpression(pattern: partPattern) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }

        // 대괄호나 괄호 안에 "말씀", "개역개정" 등 괄호 태그 제거
        let tagPattern = #"\[[^\]]*\]|\([^\)]*\)"#
        if let regex = try? NSRegularExpression(pattern: tagPattern) {
            let range = NSRange(location: 0, length: (text as NSString).length)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 어절 및 토큰 기반으로 오탈자, 누락, 추가 단어 검출
    private static func findErrors(scripture: String, subtitle: String, ignoreMissing: Bool = false) -> [BibleTextError] {
        let expectedWords = words(from: scripture)
        let actualWords = words(from: subtitle)

        guard !expectedWords.isEmpty && !actualWords.isEmpty else { return [] }

        // LCS(최장 공통 부분 수열)로 일치하는 어절 인덱스 쌍 탐색
        let lcsIndices = wordLCS(expectedWords, actualWords)
        var matchedExpected = Set<Int>()
        var matchedActual = Set<Int>()

        for (eIdx, aIdx) in lcsIndices {
            matchedExpected.insert(eIdx)
            matchedActual.insert(aIdx)
        }

        var errors: [BibleTextError] = []

        let unmatchedExpected = expectedWords.indices.filter { !matchedExpected.contains($0) }
        let unmatchedActual = actualWords.indices.filter { !matchedActual.contains($0) }

        var usedActual = Set<Int>()

        for eIdx in unmatchedExpected {
            let expWord = expectedWords[eIdx]
            let expNorm = normalizeKorean(expWord)

            // 가장 유사한 actual 단어 탐색 (오탈자 의심)
            var bestMatchIdx: Int?
            var bestDist = 999

            for aIdx in unmatchedActual where !usedActual.contains(aIdx) {
                let actWord = actualWords[aIdx]
                let actNorm = normalizeKorean(actWord)
                let dist = levenshtein(expNorm, actNorm)
                let maxLen = max(expNorm.count, actNorm.count)

                if dist <= 2 && dist < maxLen {
                    if dist < bestDist {
                        bestDist = dist
                        bestMatchIdx = aIdx
                    }
                }
            }

            if let aIdx = bestMatchIdx {
                usedActual.insert(aIdx)
                let actWord = actualWords[aIdx]
                errors.append(BibleTextError(
                    kind: .typo,
                    expected: expWord,
                    recognized: actWord,
                    description: "‘\(actWord)’ → 원문: ‘\(expWord)’"
                ))
            } else if !ignoreMissing {
                errors.append(BibleTextError(
                    kind: .missing,
                    expected: expWord,
                    recognized: "",
                    description: "‘\(expWord)’ 누락 의심"
                ))
            }
        }

        for aIdx in unmatchedActual where !usedActual.contains(aIdx) {
            let actWord = actualWords[aIdx]
            let actNorm = normalizeKorean(actWord)
            // 부분 절(상반절/하반절)에서 단순 띄어쓰기 차이로 어절이 합쳐지거나 나뉜 경우는 추가 오류에서 제외
            if ignoreMissing && !actNorm.isEmpty && normalizeKorean(scripture).contains(actNorm) {
                continue
            }
            if actWord.count >= 2 {
                errors.append(BibleTextError(
                    kind: .inserted,
                    expected: "",
                    recognized: actWord,
                    description: "‘\(actWord)’ 불필요 추가"
                ))
            }
        }

        return errors
    }

    private static func words(from text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func wordLCS(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        let m = a.count
        let n = b.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if normalizeKorean(a[i - 1]) == normalizeKorean(b[j - 1]) {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        var i = m, j = n
        var result: [(Int, Int)] = []
        while i > 0 && j > 0 {
            if normalizeKorean(a[i - 1]) == normalizeKorean(b[j - 1]) {
                result.append((i - 1, j - 1))
                i -= 1
                j -= 1
            } else if dp[i - 1][j] >= dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return result.reversed()
    }

    private static func characterAccuracy(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty || !b.isEmpty else { return 1.0 }
        let lcs = charLCSLength(a, b)
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        return Double(lcs) / Double(maxLen)
    }

    private static func charLCSLength(_ a: String, _ b: String) -> Int {
        let aArr = Array(a)
        let bArr = Array(b)
        let m = aArr.count
        let n = bArr.count
        guard m > 0, n > 0 else { return 0 }

        var prev = [Int](repeating: 0, count: n + 1)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            for j in 1...n {
                if aArr[i - 1] == bArr[j - 1] {
                    curr[j] = prev[j - 1] + 1
                } else {
                    curr[j] = max(prev[j], curr[j - 1])
                }
            }
            (prev, curr) = (curr, prev)
        }
        return prev[n]
    }

    private static func levenshtein(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var d = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { d[i][0] = i }
        for j in 0...n { d[0][j] = j }

        for i in 1...m {
            for j in 1...n {
                let cost = (a[i - 1] == b[j - 1]) ? 0 : 1
                d[i][j] = min(
                    d[i - 1][j] + 1,        // deletion
                    d[i][j - 1] + 1,        // insertion
                    d[i - 1][j - 1] + cost  // substitution
                )
            }
        }
        return d[m][n]
    }

    private static func normalizeKorean(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

private final class _BundleHost {}

extension BibleReference {
    func withAccuracy(_ accuracy: Double?) -> BibleReference {
        BibleReference(
            book: book,
            osisCode: osisCode,
            chapter: chapter,
            verse: verse,
            endVerse: endVerse,
            accuracy: accuracy
        )
    }
}
