import SwiftUI

/// ⌘+ / ⌘- 로 조절하는 UI 글자 크기 배율.
enum UIScale {
    static let key = "uiScale"
    static let range: ClosedRange<Double> = 0.7...2.0
    static let step = 0.1

    static var current: Double {
        get {
            let value = UserDefaults.standard.double(forKey: key)
            return value == 0 ? 1.0 : min(max(value, range.lowerBound), range.upperBound)
        }
        set { UserDefaults.standard.set(min(max(newValue, range.lowerBound), range.upperBound), forKey: key) }
    }

    static func bigger() { current = (current + step).rounded(toPlaces: 1) }
    static func smaller() { current = (current - step).rounded(toPlaces: 1) }
    static func reset() { current = 1.0 }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}

/// Font와 같은 이름의 체이닝(.caption.weight(.semibold) 등)을 지원하는 배율 적용 폰트.
struct UIFont {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var isMono = false
    var isMonoDigit = false

    static let caption2 = UIFont(size: 10)
    static let caption = UIFont(size: 11)
    static let footnote = UIFont(size: 11)
    static let subheadline = UIFont(size: 12)
    static let body = UIFont(size: 13)
    static let headline = UIFont(size: 13, weight: .semibold)
    static let title3 = UIFont(size: 15)
    static let title2 = UIFont(size: 17)
    static let title = UIFont(size: 22)
    static let largeTitle = UIFont(size: 26)

    static func system(size: CGFloat, weight: Font.Weight = .regular) -> UIFont {
        UIFont(size: size, weight: weight)
    }

    func weight(_ weight: Font.Weight) -> UIFont { var f = self; f.weight = weight; return f }
    func monospaced() -> UIFont { var f = self; f.isMono = true; return f }
    func monospacedDigit() -> UIFont { var f = self; f.isMonoDigit = true; return f }

    func font(scale: Double) -> Font {
        let base = Font.system(size: size * scale, weight: weight, design: isMono ? .monospaced : .default)
        return isMonoDigit ? base.monospacedDigit() : base
    }
}

private struct ScaledFontModifier: ViewModifier {
    @AppStorage(UIScale.key) private var scale = 1.0
    let font: UIFont

    func body(content: Content) -> some View {
        content.font(font.font(scale: min(max(scale, UIScale.range.lowerBound), UIScale.range.upperBound)))
    }
}

extension View {
    /// 배율이 적용되는 글꼴. 기존 `.font(.caption)` 대신 사용한다.
    func uiFont(_ font: UIFont) -> some View { modifier(ScaledFontModifier(font: font)) }
}
