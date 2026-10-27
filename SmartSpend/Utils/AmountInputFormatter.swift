import Foundation

enum AmountInputFormatter {
    /// Largest number of integer digits accepted while typing (just under a trillion), so the
    /// value stays exactly representable as a `Double` and can't overflow the UI.
    static let maxIntegerDigits = 12

    /// Formats text as the user types. Pass `previous` (the field's value before this edit) so a
    /// typed or pasted locale-specific amount is understood: a "," typed on a comma-decimal
    /// keyboard (ru, uz, de, ...) becomes the decimal point instead of being dropped, and a
    /// pasted "1.234,56" / "12,50" / "1 500 000" is read as the number it shows.
    static func formatEditingText(_ text: String, previous: String, maxFractionDigits: Int = 2) -> String {
        // Our own regrouping ("2500" → "2,500") comes back as an edit; its "," is grouping, not a decimal key.
        if text == formatEditingText(previous, maxFractionDigits: maxFractionDigits) { return text }
        return formatEditingText(interpretingInsertion(in: text, previous: previous), maxFractionDigits: maxFractionDigits)
    }

    static func formatEditingText(_ text: String, maxFractionDigits: Int = 2) -> String {
        let normalized = normalizedNumericText(text, maxFractionDigits: maxFractionDigits, maxIntegerDigits: maxIntegerDigits)
        guard !normalized.isEmpty else { return "" }

        let parts = normalized.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let rawIntegerPart = parts.first.map(String.init) ?? ""
        let integerPart = rawIntegerPart.isEmpty ? "0" : rawIntegerPart
        let groupedInteger = groupedDigits(integerPart)

        if normalized.contains(".") {
            let fractionPart = parts.count > 1 ? String(parts[1]) : ""
            return "\(groupedInteger).\(fractionPart)"
        }

        return groupedInteger
    }

    static func formatValue(_ value: Double, maxFractionDigits: Int = 2) -> String {
        guard value.isFinite else { return "" }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maxFractionDigits

        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    static func parse(_ text: String) -> Double? {
        let normalized = normalizedNumericText(text, maxFractionDigits: Int.max, maxIntegerDigits: Int.max)
        guard !normalized.isEmpty, normalized != "." else { return nil }
        return Double(normalized)
    }

    private static func normalizedNumericText(_ text: String, maxFractionDigits: Int, maxIntegerDigits: Int) -> String {
        var result = ""
        var hasDecimalSeparator = false
        var fractionDigits = 0
        var integerDigits = 0

        for character in text {
            if let digit = asciiDigit(character) {
                if hasDecimalSeparator {
                    guard fractionDigits < maxFractionDigits else { continue }
                    fractionDigits += 1
                } else {
                    // Leading zeros are trimmed below, so they don't count toward the limit.
                    if integerDigits == 0 && digit == "0" { result.append(digit); continue }
                    guard integerDigits < maxIntegerDigits else { continue }
                    integerDigits += 1
                }
                result.append(digit)
            } else if character == "." && !hasDecimalSeparator {
                hasDecimalSeparator = true
                result.append(character)
            }
        }

        guard !result.isEmpty else { return "" }

        if let decimalIndex = result.firstIndex(of: ".") {
            let integerPart = String(result[..<decimalIndex])
            let fractionPart = String(result[result.index(after: decimalIndex)...])
            return "\(trimLeadingZeros(integerPart)).\(fractionPart)"
        }

        return trimLeadingZeros(result)
    }

    /// Only real decimal digits, mapped to ASCII. `Character.isNumber` also accepts "½" or "Ⅻ",
    /// which made `Double(_:)` fail and the whole amount parse as nil.
    private static func asciiDigit(_ character: Character) -> Character? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.properties.numericType == .decimal,
              let value = character.wholeNumberValue, (0...9).contains(value) else { return nil }
        return Character(String(value))
    }

    /// Rewrites the part of `text` that was inserted relative to `previous` into canonical form
    /// ("." decimal, no grouping). The untouched remainder is already canonical.
    static func interpretingInsertion(in text: String, previous: String) -> String {
        let old = Array(previous), new = Array(text)
        guard new.count > old.count else { return text } // deletion or replacement by shorter text

        var prefix = 0
        while prefix < old.count && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        guard old.count == prefix + suffix else { return text } // not a pure insertion

        let inserted = String(new[prefix..<(new.count - suffix)])
        let replacement: String
        if inserted == "," || inserted == "\u{066B}" { // typed decimal key on a comma-decimal keyboard
            replacement = previous.contains(".") ? "" : "."
        } else if inserted.count > 1 {
            replacement = canonicalPastedNumber(inserted)
        } else {
            return text
        }
        return String(new[..<prefix]) + replacement + String(new[(new.count - suffix)...])
    }

    /// Reads a pasted amount written with either "." or "," as the decimal separator.
    /// The last separator is the decimal point when the other kind only forms valid
    /// thousands groups ("1.234,56", "1,234.56"); a lone "," is grouping only when it is
    /// followed by exactly three digits ("1,500"), otherwise decimal ("12,50").
    static func canonicalPastedNumber(_ text: String) -> String {
        let kept: [Character] = text.compactMap { character in
            if let digit = asciiDigit(character) { return digit }
            if character == "." || character == "," { return character }
            if character == "\u{066B}" { return "," } // Arabic decimal separator
            return nil
        }
        let separators = kept.indices.filter { kept[$0] == "." || kept[$0] == "," }
        guard let lastIndex = separators.last else { return String(kept) }

        let last = kept[lastIndex]
        let other: Character = last == "." ? "," : "."
        let lastCount = kept.filter { $0 == last }.count
        let hasOther = kept.contains(other)

        func isGrouping(_ part: ArraySlice<Character>, separator: Character) -> Bool {
            let groups = part.split(separator: separator, omittingEmptySubsequences: false)
            guard groups.count > 1, let first = groups.first, (1...3).contains(first.count) else { return false }
            return groups.dropFirst().allSatisfy { $0.count == 3 }
        }

        var decimalIndex: Int?
        if hasOther {
            if lastCount == 1 && isGrouping(kept[..<lastIndex], separator: other) {
                decimalIndex = lastIndex
            } else {
                decimalIndex = kept.firstIndex(of: ".")
            }
        } else if isGrouping(kept[...], separator: last) {
            decimalIndex = nil // "1,500" or "1.234.567"
        } else {
            decimalIndex = last == "." ? kept.firstIndex(of: ".") : lastIndex
        }

        var result = ""
        for (index, character) in kept.enumerated() {
            if index == decimalIndex { result.append(".") }
            else if character != "." && character != "," { result.append(character) }
        }
        return result
    }

    private static func trimLeadingZeros(_ text: String) -> String {
        let trimmed = text.drop { $0 == "0" }
        return trimmed.isEmpty ? "0" : String(trimmed)
    }

    private static func groupedDigits(_ digits: String) -> String {
        var grouped = ""

        for (offset, character) in digits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 {
                grouped.append(",")
            }
            grouped.append(character)
        }

        return String(grouped.reversed())
    }
}
