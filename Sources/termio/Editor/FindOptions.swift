import Foundation

/// VS Code-style find modes: Aa (case), ab (whole word), .* (regex).
struct FindOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}
