import Foundation

@main
struct BibleComparisonSmoke {
    static func main() {
        print("=== BibleComparisonSmoke Test Started ===")

        // 1. 완전 일치 테스트
        let exactText = "[창 1:1] 태초에 하나님이 천지를 창조하시니라"
        let refs1 = BibleReferenceParser.parse(exactText)
        assert(!refs1.isEmpty, "창 1:1 레퍼런스를 파싱해야 함")
        let result1 = BibleVerseChecker.analyze(recognizedText: exactText, references: refs1)
        guard let comp1 = result1.comparisons.first else {
            fatalError("비교 결과가 비어있음")
        }
        print("1. 완전 일치 테스트:")
        print("   상태: \(comp1.status.rawValue), 정확도: \(comp1.accuracy), 요약: \(comp1.summary)")
        assert(comp1.status == .exact, "완전 일치 상태여야 함")
        assert(comp1.errors.isEmpty, "오류가 없어야 함")

        // 2. 오탈자(단어 교체) 테스트
        let typoText = "요 3:16 하나님이 세상을 이처럼 사랑하사 독생사를 주섯으니 이는 그를 믿는 자마다 멸망하지 않고 영생을 얻게 하려 하심이라"
        let refs2 = BibleReferenceParser.parse(typoText)
        let result2 = BibleVerseChecker.analyze(recognizedText: typoText, references: refs2)
        guard let comp2 = result2.comparisons.first else {
            fatalError("요 3:16 비교 결과가 비어있음")
        }
        print("2. 오탈자 테스트:")
        print("   상태: \(comp2.status.rawValue), 정확도: \(comp2.accuracy), 오류 개수: \(comp2.errors.count)")
        for err in comp2.errors {
            print("   - [\(err.kind.rawValue)] \(err.description)")
        }
        assert(comp2.status == .minorTypo, "오탈자 의심 상태여야 함")
        assert(comp2.errors.contains { $0.kind == .typo }, "오탈자 항목이 검출되어야 함")

        // 3. 단어 누락 테스트
        let missingText = "창 1:1 태초에 하나님이 창조하시니라"
        let refs3 = BibleReferenceParser.parse(missingText)
        let result3 = BibleVerseChecker.analyze(recognizedText: missingText, references: refs3)
        guard let comp3 = result3.comparisons.first else {
            fatalError("창 1:1 누락 비교 결과가 비어있음")
        }
        print("3. 누락 테스트:")
        print("   상태: \(comp3.status.rawValue), 오류: \(comp3.errors.map(\.description))")
        assert(comp3.errors.contains { $0.kind == .missing && $0.expected == "천지를" }, "‘천지를’ 누락이 감지되어야 함")

        // 4. 단어 추가 테스트
        let insertedText = "창 1:1 태초에 하나님이 천지를 아름답게 창조하시니라"
        let refs4 = BibleReferenceParser.parse(insertedText)
        let result4 = BibleVerseChecker.analyze(recognizedText: insertedText, references: refs4)
        guard let comp4 = result4.comparisons.first else {
            fatalError("창 1:1 추가 비교 결과가 비어있음")
        }
        print("4. 단어 추가 테스트:")
        print("   상태: \(comp4.status.rawValue), 오류: \(comp4.errors.map(\.description))")
        assert(comp4.errors.contains { $0.kind == .inserted && $0.recognized == "아름답게" }, "‘아름답게’ 추가가 감지되어야 함")

        // 5. 장·절만 있는 경우
        let refOnlyText = "[로마서 8:28]"
        let refs5 = BibleReferenceParser.parse(refOnlyText)
        let result5 = BibleVerseChecker.analyze(recognizedText: refOnlyText, references: refs5)
        guard let comp5 = result5.comparisons.first else {
            fatalError("롬 8:28 결과 없음")
        }
        print("5. 장·절만 표기 테스트:")
        print("   상태: \(comp5.status.rawValue), 요약: \(comp5.summary)")
        assert(comp5.status == .referenceOnly, "장·절 표기만 있음 상태여야 함")

        // 6. 범위 표기(14-15절)인데 화면에는 한 절씩 나오는 경우
        for body in ["그러므로 우리에게 큰 대제사장이 계시니 승천하신 이 곧 하나님의 아들 예수시라 우리가 믿는 도리를 굳게 잡을지어다",
                     "우리에게 있는 대제사장은 우리의 연약함을 동정하지 못하실 이가 아니요 모든 일에 우리와 똑같이 시험을 받으신 이로되 죄는 없으시니라"] {
            let text = body
            let refs = BibleReferenceParser.parse("히브리서 4장 14-15절 " + text)
            let res = BibleVerseChecker.analyze(recognizedText: "히브리서 4장 14-15절 " + text, references: refs)
            guard let c = res.comparisons.first else { fatalError("범위 결과 없음") }
            print("6. 범위 분할 표시: \(c.status.rawValue) / \(c.summary)")
            assert(c.status == .exact || c.status == .minorTypo, "한 절만 표시돼도 오류가 아니어야 함")
            assert(!c.errors.contains { $0.kind == .missing }, "다음 절이 누락으로 잡히면 안 됨")
        }

        // 7. 본문 직전 절 번호: 범위 안이면 본문 비교에서 제외, 범위 밖이면 표시
        let v14 = "그러므로 우리에게 큰 대제사장이 계시니 승천하신 이 곧 하나님의 아들 예수시라 우리가 믿는 도리를 굳게 잡을지어다"
        let v15 = "우리에게 있는 대제사장은 우리의 연약함을 동정하지 못하실 이가 아니요 모든 일에 우리와 똑같이 시험을 받으신 이로되 죄는 없으시니라"
        do {
            let t = "히브리서 4장 14-15절 15 " + v15
            let r = BibleReferenceParser.parse(t)
            let c = BibleVerseChecker.analyze(recognizedText: t, references: r).comparisons[0]
            print("7a. \(c.status.rawValue) marker=\(String(describing: c.markedVerse)) inRange=\(String(describing: c.markedVerseInRange)) \(c.summary)")
            assert(c.status == .exact && c.markedVerse == 15 && c.markedVerseInRange == true, "범위 내 절 번호는 오류가 아님")
            let t2 = "히브리서 4장 14-15절 16 " + v14
            let r2 = BibleReferenceParser.parse(t2)
            let c2 = BibleVerseChecker.analyze(recognizedText: t2, references: r2).comparisons[0]
            print("7b. \(c2.status.rawValue) marker=\(String(describing: c2.markedVerse)) inRange=\(String(describing: c2.markedVerseInRange)) \(c2.summary)")
            assert(c2.markedVerseInRange == false && c2.errors.contains { $0.kind == .verseNumber }, "범위 밖 절 번호는 표시되어야 함")
        }

        print("=== 모든 성경 대조 및 오류 분석 스모크 테스트 통과 ===")
    }
}
