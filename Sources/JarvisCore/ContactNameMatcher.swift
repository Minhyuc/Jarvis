import Foundation

public struct ContactNameMatcher: Sendable {
    public init() {}

    public func normalized(_ value: String) -> String {
        value
            .lowercased()
            .filter { !$0.isWhitespace && !$0.isPunctuation && !$0.isSymbol }
    }

    public func similarity(query: String, candidate: String) -> Double {
        let lhs = Array(normalized(query))
        let rhs = Array(normalized(candidate))
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }

        let shorter = lhs.count <= rhs.count ? String(lhs) : String(rhs)
        let longer = lhs.count > rhs.count ? String(lhs) : String(rhs)
        if shorter.count >= 2, longer.contains(shorter) {
            return 0.92
        }

        let distance = editDistance(lhs, rhs)
        let maximumLength = max(lhs.count, rhs.count)
        let characterScore = 1 - Double(distance) / Double(maximumLength)
        let pronunciationScore = hangulPronunciationSimilarity(lhs, rhs)
        let baseScore = max(characterScore, pronunciationScore)
        if maximumLength >= 3, distance == 1 {
            return max(baseScore, 0.78)
        }
        return max(0, baseScore)
    }

    public func isAcceptable(score: Double, query: String) -> Bool {
        let length = normalized(query).count
        if length <= 2 { return score >= 0.9 }
        if length >= 5 { return score >= 0.68 }
        return score >= 0.72
    }

    /// 음성 인식은 비슷하게 들리는 한글 모음을 다른 글자로 전사하는 경우가 많다.
    /// 완성형 글자를 초성·중성·종성으로 풀어 비교하면 `향/황`, `수/소` 같은
    /// 작은 발음 차이를 허용하면서 전혀 다른 짧은 이름의 오인 연결은 막을 수 있다.
    private func hangulPronunciationSimilarity(
        _ lhs: [Character],
        _ rhs: [Character]
    ) -> Double {
        let lhsJamo = lhs.flatMap(decomposedHangul)
        let rhsJamo = rhs.flatMap(decomposedHangul)
        guard !lhsJamo.isEmpty, !rhsJamo.isEmpty else { return 0 }

        let distance = phoneticEditDistance(lhsJamo, rhsJamo)
        return max(
            0,
            1 - Double(distance) / Double(max(lhsJamo.count, rhsJamo.count))
        )
    }

    private func phoneticEditDistance(_ lhs: [Character], _ rhs: [Character]) -> Double {
        var previous = (0...rhs.count).map(Double.init)

        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = [Double(lhsIndex + 1)]
            current.reserveCapacity(rhs.count + 1)

            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex]
                    + phoneticSubstitutionCost(lhsCharacter, rhsCharacter)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }

        return previous[rhs.count]
    }

    private func phoneticSubstitutionCost(_ lhs: Character, _ rhs: Character) -> Double {
        guard lhs != rhs else { return 0 }
        guard let lhsScalar = lhs.unicodeScalars.first?.value,
              let rhsScalar = rhs.unicodeScalars.first?.value else {
            return 1
        }

        // 음성 인식에서 가장 흔한 같은 계열 자모 치환만 절반의 차이로 본다.
        let lhsGroup = jamoGroup(lhsScalar)
        let rhsGroup = jamoGroup(rhsScalar)
        return lhsGroup != nil && lhsGroup == rhsGroup ? 0.5 : 1
    }

    private func jamoGroup(_ scalar: UInt32) -> Int? {
        switch scalar {
        case 0x1100...0x115F: return 0 // 초성
        case 0x1160...0x11A7: return 1 // 중성
        case 0x11A8...0x11FF: return 2 // 종성
        default: return nil
        }
    }

    private func decomposedHangul(_ character: Character) -> [Character] {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              (0xAC00...0xD7A3).contains(scalar.value) else {
            return [character]
        }

        let syllable = Int(scalar.value - 0xAC00)
        let choseong = syllable / 588
        let jungseong = (syllable % 588) / 28
        let jongseong = syllable % 28
        let choseongScalar = UnicodeScalar(0x1100 + choseong)!
        let jungseongScalar = UnicodeScalar(0x1161 + jungseong)!
        var result = [Character(String(choseongScalar)), Character(String(jungseongScalar))]
        if jongseong > 0 {
            result.append(Character(String(UnicodeScalar(0x11A7 + jongseong)!)))
        }
        return result
    }

    private func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        var previous = Array(0...rhs.count)

        for (lhsIndex, lhsCharacter) in lhs.enumerated() {
            var current = [lhsIndex + 1]
            current.reserveCapacity(rhs.count + 1)

            for (rhsIndex, rhsCharacter) in rhs.enumerated() {
                let insertion = current[rhsIndex] + 1
                let deletion = previous[rhsIndex + 1] + 1
                let substitution = previous[rhsIndex] + (lhsCharacter == rhsCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }

        return previous[rhs.count]
    }
}
