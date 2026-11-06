import Foundation

@main
struct BibleReferenceParserSmoke {
    static func main() {
        let books: [(String, String)] = [
            ("창세기", "GEN"), ("출애굽기", "EXO"), ("레위기", "LEV"), ("민수기", "NUM"), ("신명기", "DEU"),
            ("여호수아", "JOS"), ("사사기", "JDG"), ("룻기", "RUT"), ("사무엘상", "1SA"), ("사무엘하", "2SA"),
            ("열왕기상", "1KI"), ("열왕기하", "2KI"), ("역대상", "1CH"), ("역대하", "2CH"), ("에스라", "EZR"),
            ("느헤미야", "NEH"), ("에스더", "EST"), ("욥기", "JOB"), ("시편", "PSA"), ("잠언", "PRO"),
            ("전도서", "ECC"), ("아가", "SNG"), ("이사야", "ISA"), ("예레미야", "JER"), ("예레미야애가", "LAM"),
            ("에스겔", "EZK"), ("다니엘", "DAN"), ("호세아", "HOS"), ("요엘", "JOL"), ("아모스", "AMO"),
            ("오바댜", "OBA"), ("요나", "JON"), ("미가", "MIC"), ("나훔", "NAM"), ("하박국", "HAB"),
            ("스바냐", "ZEP"), ("학개", "HAG"), ("스가랴", "ZEC"), ("말라기", "MAL"), ("마태복음", "MAT"),
            ("마가복음", "MRK"), ("누가복음", "LUK"), ("요한복음", "JHN"), ("사도행전", "ACT"), ("로마서", "ROM"),
            ("고린도전서", "1CO"), ("고린도후서", "2CO"), ("갈라디아서", "GAL"), ("에베소서", "EPH"), ("빌립보서", "PHP"),
            ("골로새서", "COL"), ("데살로니가전서", "1TH"), ("데살로니가후서", "2TH"), ("디모데전서", "1TI"), ("디모데후서", "2TI"),
            ("디도서", "TIT"), ("빌레몬서", "PHM"), ("히브리서", "HEB"), ("야고보서", "JAS"), ("베드로전서", "1PE"),
            ("베드로후서", "2PE"), ("요한일서", "1JN"), ("요한이서", "2JN"), ("요한삼서", "3JN"), ("유다서", "JUD"),
            ("요한계시록", "REV")
        ]
        for (name, code) in books {
            let result = BibleReferenceParser.parse("\(name) 1장 1절")
            precondition(result.contains { $0.osisCode == code && $0.chapter == 1 && $0.verse == 1 }, "failed: \(name)")
        }

        let cases: [(String, String, Int, Int, Int?)] = [
            ("(요 3:16)", "JHN", 3, 16, nil),
            ("요한복음3：16", "JHN", 3, 16, nil),
            ("요한 복음 3.16", "JHN", 3, 16, nil),
            ("요한복음 3장 16절-18절", "JHN", 3, 16, 18),
            ("시편 23편 1절", "PSA", 23, 1, nil),
            ("고전 13장 4절~7절", "1CO", 13, 4, 7),
            ("롬 8:28", "ROM", 8, 28, nil),
            ("계 21장 4절", "REV", 21, 4, nil),
            ("요일 1:9", "1JN", 1, 9, nil)
        ]
        for (input, code, chapter, verse, endVerse) in cases {
            let result = BibleReferenceParser.parse(input)
            precondition(result.contains {
                $0.osisCode == code && $0.chapter == chapter && $0.verse == verse && $0.endVerse == endVerse
            }, "failed: \(input)")
        }
        print("Bible parser: 66권 정식명 및 주요 표기 \(cases.count)개 통과")
    }
}
