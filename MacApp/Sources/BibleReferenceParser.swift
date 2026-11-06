import Foundation

enum BibleReferenceParser {
    internal struct Book {
        let canonical: String
        let osis: String
        let aliases: [String]
    }

    internal static let books: [Book] = [
        Book(canonical: "창세기", osis: "GEN", aliases: ["창세기", "창"]),
        Book(canonical: "출애굽기", osis: "EXO", aliases: ["출애굽기", "출"]),
        Book(canonical: "레위기", osis: "LEV", aliases: ["레위기", "레"]),
        Book(canonical: "민수기", osis: "NUM", aliases: ["민수기", "민"]),
        Book(canonical: "신명기", osis: "DEU", aliases: ["신명기", "신"]),
        Book(canonical: "여호수아", osis: "JOS", aliases: ["여호수아", "수"]),
        Book(canonical: "사사기", osis: "JDG", aliases: ["사사기", "삿"]),
        Book(canonical: "룻기", osis: "RUT", aliases: ["룻기", "룻"]),
        Book(canonical: "사무엘상", osis: "1SA", aliases: ["사무엘상", "삼상"]),
        Book(canonical: "사무엘하", osis: "2SA", aliases: ["사무엘하", "삼하"]),
        Book(canonical: "열왕기상", osis: "1KI", aliases: ["열왕기상", "왕상"]),
        Book(canonical: "열왕기하", osis: "2KI", aliases: ["열왕기하", "왕하"]),
        Book(canonical: "역대상", osis: "1CH", aliases: ["역대상", "대상"]),
        Book(canonical: "역대하", osis: "2CH", aliases: ["역대하", "대하"]),
        Book(canonical: "에스라", osis: "EZR", aliases: ["에스라", "스"]),
        Book(canonical: "느헤미야", osis: "NEH", aliases: ["느헤미야", "느"]),
        Book(canonical: "에스더", osis: "EST", aliases: ["에스더", "에"]),
        Book(canonical: "욥기", osis: "JOB", aliases: ["욥기", "욥"]),
        Book(canonical: "시편", osis: "PSA", aliases: ["시편", "시"]),
        Book(canonical: "잠언", osis: "PRO", aliases: ["잠언", "잠"]),
        Book(canonical: "전도서", osis: "ECC", aliases: ["전도서", "전"]),
        Book(canonical: "아가", osis: "SNG", aliases: ["아가", "아"]),
        Book(canonical: "이사야", osis: "ISA", aliases: ["이사야", "사"]),
        Book(canonical: "예레미야", osis: "JER", aliases: ["예레미야", "렘"]),
        Book(canonical: "예레미야애가", osis: "LAM", aliases: ["예레미야애가", "애가", "애"]),
        Book(canonical: "에스겔", osis: "EZK", aliases: ["에스겔", "겔"]),
        Book(canonical: "다니엘", osis: "DAN", aliases: ["다니엘", "단"]),
        Book(canonical: "호세아", osis: "HOS", aliases: ["호세아", "호"]),
        Book(canonical: "요엘", osis: "JOL", aliases: ["요엘", "욜"]),
        Book(canonical: "아모스", osis: "AMO", aliases: ["아모스", "암"]),
        Book(canonical: "오바댜", osis: "OBA", aliases: ["오바댜", "옵"]),
        Book(canonical: "요나", osis: "JON", aliases: ["요나", "욘"]),
        Book(canonical: "미가", osis: "MIC", aliases: ["미가", "미"]),
        Book(canonical: "나훔", osis: "NAM", aliases: ["나훔", "나"]),
        Book(canonical: "하박국", osis: "HAB", aliases: ["하박국", "합"]),
        Book(canonical: "스바냐", osis: "ZEP", aliases: ["스바냐", "습"]),
        Book(canonical: "학개", osis: "HAG", aliases: ["학개", "학"]),
        Book(canonical: "스가랴", osis: "ZEC", aliases: ["스가랴", "슥"]),
        Book(canonical: "말라기", osis: "MAL", aliases: ["말라기", "말"]),
        Book(canonical: "마태복음", osis: "MAT", aliases: ["마태복음", "마태", "마"]),
        Book(canonical: "마가복음", osis: "MRK", aliases: ["마가복음", "마가", "막"]),
        Book(canonical: "누가복음", osis: "LUK", aliases: ["누가복음", "누가", "눅"]),
        Book(canonical: "요한복음", osis: "JHN", aliases: ["요한복음", "요한", "요"]),
        Book(canonical: "사도행전", osis: "ACT", aliases: ["사도행전", "행"]),
        Book(canonical: "로마서", osis: "ROM", aliases: ["로마서", "롬"]),
        Book(canonical: "고린도전서", osis: "1CO", aliases: ["고린도전서", "고전"]),
        Book(canonical: "고린도후서", osis: "2CO", aliases: ["고린도후서", "고후"]),
        Book(canonical: "갈라디아서", osis: "GAL", aliases: ["갈라디아서", "갈"]),
        Book(canonical: "에베소서", osis: "EPH", aliases: ["에베소서", "엡"]),
        Book(canonical: "빌립보서", osis: "PHP", aliases: ["빌립보서", "빌"]),
        Book(canonical: "골로새서", osis: "COL", aliases: ["골로새서", "골"]),
        Book(canonical: "데살로니가전서", osis: "1TH", aliases: ["데살로니가전서", "살전"]),
        Book(canonical: "데살로니가후서", osis: "2TH", aliases: ["데살로니가후서", "살후"]),
        Book(canonical: "디모데전서", osis: "1TI", aliases: ["디모데전서", "딤전"]),
        Book(canonical: "디모데후서", osis: "2TI", aliases: ["디모데후서", "딤후"]),
        Book(canonical: "디도서", osis: "TIT", aliases: ["디도서", "딛"]),
        Book(canonical: "빌레몬서", osis: "PHM", aliases: ["빌레몬서", "몬"]),
        Book(canonical: "히브리서", osis: "HEB", aliases: ["히브리서", "히"]),
        Book(canonical: "야고보서", osis: "JAS", aliases: ["야고보서", "약"]),
        Book(canonical: "베드로전서", osis: "1PE", aliases: ["베드로전서", "벧전"]),
        Book(canonical: "베드로후서", osis: "2PE", aliases: ["베드로후서", "벧후"]),
        Book(canonical: "요한일서", osis: "1JN", aliases: ["요한일서", "요일"]),
        Book(canonical: "요한이서", osis: "2JN", aliases: ["요한이서", "요이"]),
        Book(canonical: "요한삼서", osis: "3JN", aliases: ["요한삼서", "요삼"]),
        Book(canonical: "유다서", osis: "JUD", aliases: ["유다서", "유"]),
        Book(canonical: "요한계시록", osis: "REV", aliases: ["요한계시록", "계시록", "계"])
    ]

    /// Vision customWords용 성경 66권 전체 이름 및 약어 캐시.
    static let allCustomWords: [String] = {
        books.flatMap { [$0.canonical] + $0.aliases }
    }()

    /// 모든 alias를 canonical → short alias로 역매핑.
    static let aliasesToCanonical: [String: String] = {
        var map: [String: String] = [:]
        for book in books {
            for alias in book.aliases {
                map[alias] = book.canonical
            }
        }
        return map
    }()

    static func parse(_ text: String) -> [BibleReference] {
        var found: [BibleReference] = []
        for book in books {
            for alias in book.aliases.sorted(by: { $0.count > $1.count }) {
                // OCR이 책 이름 사이에 공백을 삽입하는 경우(예: "요한 복음")도 허용한다.
                let escaped = alias.map { NSRegularExpression.escapedPattern(for: String($0)) }
                    .joined(separator: "\\s*")
                let pattern = "(?:^|[^가-힣])\(escaped)\\s*(\\d{1,3})\\s*(?:(?:장|편)\\s*|[.:：]\\s*)(\\d{1,3})(?:\\s*(?:절)?\\s*[-~–—]\\s*(\\d{1,3}))?\\s*(?:절)?"
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    guard let chapterRange = Range(match.range(at: 1), in: text),
                          let verseRange = Range(match.range(at: 2), in: text),
                          let chapter = Int(text[chapterRange]),
                          let verse = Int(text[verseRange]), chapter > 0, verse > 0 else { continue }
                    var endVerse: Int?
                    if match.range(at: 3).location != NSNotFound,
                       let endRange = Range(match.range(at: 3), in: text) {
                        if let parsed = Int(text[endRange]), parsed >= verse { endVerse = parsed }
                    }
                    found.append(BibleReference(book: book.canonical, osisCode: book.osis, chapter: chapter, verse: verse, endVerse: endVerse, accuracy: nil))
                }
            }
        }
        return Array(Set(found)).sorted { $0.displayName < $1.displayName }
    }
}
