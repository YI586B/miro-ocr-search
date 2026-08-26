import Foundation

/// Query -> the term(s) to look for on the image (drops quotes, operators, wildcards). In
/// `.phrase` mode the whole query is kept together as one term, so only that contiguous phrase
/// gets highlighted; in `.words` mode each word is highlighted separately, wherever it appears.
public func searchTerms(_ q: String, mode: SearchMode) -> [String] {
    if mode == .phrase {
        let t = q.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\"()*^+-"))
        return t.isEmpty ? [] : [t]
    }
    let skip: Set<String> = ["AND", "OR", "NOT", "NEAR"]
    return q.components(separatedBy: CharacterSet(charactersIn: " \t\n\"()"))
        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*^+-")) }
        .filter { !$0.isEmpty && !skip.contains($0) }
}
