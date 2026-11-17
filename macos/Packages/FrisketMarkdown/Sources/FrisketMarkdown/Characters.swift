import Foundation

// UTF-16 code units the scanner looks at.
enum U {
    static let newline: UInt16 = 10
    static let carriageReturn: UInt16 = 13
    static let space: UInt16 = 32
    static let tab: UInt16 = 9
    static let bang: UInt16 = 33       // !
    static let quote: UInt16 = 34      // "
    static let hash: UInt16 = 35       // #
    static let dollar: UInt16 = 36     // $
    static let apostrophe: UInt16 = 39 // '
    static let openParen: UInt16 = 40  // (
    static let closeParen: UInt16 = 41 // )
    static let star: UInt16 = 42       // *
    static let plus: UInt16 = 43       // +
    static let minus: UInt16 = 45      // -
    static let dot: UInt16 = 46        // .
    static let slash: UInt16 = 47      // /
    static let colon: UInt16 = 58      // :
    static let less: UInt16 = 60       // <
    static let equals: UInt16 = 61     // =
    static let greater: UInt16 = 62    // >
    static let openBracket: UInt16 = 91  // [
    static let backslash: UInt16 = 92    // \
    static let closeBracket: UInt16 = 93 // ]
    static let caret: UInt16 = 94        // ^
    static let underscore: UInt16 = 95   // _
    static let backtick: UInt16 = 96     // `
    static let pipe: UInt16 = 124        // |
    static let tilde: UInt16 = 126       // ~
    static let zero: UInt16 = 48
    static let nine: UInt16 = 57
}

enum CharClass {
    private static let whitespace = CharacterSet.whitespacesAndNewlines
    private static let punctuation = CharacterSet.punctuationCharacters.union(.symbols)
    private static let alphanumerics = CharacterSet.alphanumerics

    /// nil stands for the edge of the text, which counts as whitespace.
    static func isWhitespace(_ unit: UInt16?) -> Bool {
        guard let unit else { return true }
        if unit == U.space || unit == U.tab || unit == U.newline || unit == U.carriageReturn { return true }
        if unit < 128 { return unit == 11 || unit == 12 }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return whitespace.contains(scalar)
    }

    static func isASCIIPunctuation(_ unit: UInt16) -> Bool {
        (unit >= 33 && unit <= 47) || (unit >= 58 && unit <= 64) || (unit >= 91 && unit <= 96) || (unit >= 123 && unit <= 126)
    }

    static func isPunctuation(_ unit: UInt16?) -> Bool {
        guard let unit else { return false }
        if unit < 128 { return isASCIIPunctuation(unit) }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return punctuation.contains(scalar)
    }

    /// Letters, digits and underscore (surrogate halves count as letters).
    static func isWord(_ unit: UInt16?) -> Bool {
        guard let unit else { return false }
        if unit == U.underscore { return true }
        if unit < 128 {
            return (unit >= 48 && unit <= 57) || (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
        }
        if unit >= 0xD800 && unit <= 0xDFFF { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return alphanumerics.contains(scalar)
    }

    static func isDigit(_ unit: UInt16) -> Bool { unit >= U.zero && unit <= U.nine }
}
