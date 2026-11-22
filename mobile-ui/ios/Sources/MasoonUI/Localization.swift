import Foundation

extension Locale {
    func studyText(_ arabic: String, _ english: String) -> String {
        MasoonNumerals.isArabic(self) ? arabic : english
    }
}
