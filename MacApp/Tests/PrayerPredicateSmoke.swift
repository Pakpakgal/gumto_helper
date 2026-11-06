import Foundation

/// 기도문 판별(looksLikePrayer) 회귀 스모크. 빌드와 무관하게 별도 실행:
///   xcrun swiftc -O -o prayer-smoke PrayerPredicateSmoke.swift ../Sources/KoreanGrammarChecker.swift && ./prayer-smoke
@main
struct PrayerPredicateSmoke {
    static func main() {
        let cases: [(String, Bool, String)] = [
            ("기도로 시작합니다", false, "짧은 안내문"),
            ("중보기도 시간입니다", false, "공지"),
            ("오늘 오후 3시에 대예배당에서 중보기도 모임이 있습니다. 많은 참여 바랍니다.", false, "기도회 공지(길어도 어미·키워드 없음)"),
            ("사랑의 하나님, 이 시간에 함께 기도하게 하시니 감사합니다. 우리 가정을 지켜주시고 예수님의 이름으로 기도합니다. 아멘.", true, "실제 기도문"),
            ("주 우리 하나님, 우리의 연약함을 아시는 주님, 긍휼히 여겨 주옵소서. 성령으로 우리를 붙여 주시옵소서. 예수님의 이름으로 기도드립니다. 아멘.", true, "고어체 기도문"),
            ("그러므로 너희는 이렇게 기도하라 하늘에 계신 우리 아버지여 이름이 거룩히 여김을 받으시옵소서", false, "주기도문 인용=성경 본문, 말씀 자막으로 가야 함"),
            ("다함께 기도하겠습니다. 우리 교회와 가정을 위해 기도합니다. 예수님의 이름으로 기도합니다. 아멘.", true, "함께 기도 문구"),
            ("할렐루야 찬양합니다 Worship singing time 오늘도 신나게 찬양하는 하루 되세요", false, "찬양 안내(키워드 0)"),
        ]
        var failed = 0
        for (text, expected, note) in cases {
            let got = KoreanGrammarChecker.looksLikePrayer(text)
            if got != expected { failed += 1 }
            print("\(got == expected ? "PASS" : "FAIL") · 기대 \(expected) 실제 \(got) · \(note)")
        }
        let prayCases: [(String, Bool, String)] = [
            ("PRAY", true, "가운데 라벨"),
            ("Prayer", true, "혼합 대소문자"),
            ("pray with us", true, "소문자"),
            ("오늘도 PRAY 합시다 함께 기도합니다", true, "한글 텍스트 속 라벨"),
            ("SPRAY BOTTLE", false, "단어 경계로 차단"),
            ("PRAYERS", false, "복수형은 라벨로 보지 않음"),
        ]
        for (text, expected, note) in prayCases {
            let got = KoreanGrammarChecker.hasPrayLabel(text)
            if got != expected { failed += 1 }
            print("\(got == expected ? "PASS" : "FAIL") · PRAY 기대 \(expected) 실제 \(got) · \(note)")
        }
        print(failed == 0 ? "ALL PASS" : "FAILED: \(failed)")
        exit(failed == 0 ? 0 : 1)
    }
}
