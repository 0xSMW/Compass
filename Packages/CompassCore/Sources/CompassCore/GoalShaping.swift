import Foundation

/// On-device goal shaping for onboarding (A3–A5). Runs before the privacy step (A7), so nothing about
/// the goal leaves the phone until the user has seen the cloud switch. Deterministic and pure.
public enum GoalShaper {
    /// Clean up spoken or typed goal text: trims, collapses spaces, capitalises the first letter and
    /// ends with a full stop ("earn my first million, stay strong" → "Earn my first million, stay strong.").
    public static func normalize(_ text: String) -> String {
        let collapsed = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let first = collapsed.first else { return "" }
        var result = first.uppercased() + collapsed.dropFirst()
        if let last = result.last, !".!?".contains(last) {
            while let l = result.last, ",;:".contains(l) { result.removeLast() }
            result += "."
        }
        return result
    }

    /// Words that make a short goal too vague to act on ("Be happier.").
    static let vagueWords: Set<String> = [
        "happy", "happier", "better", "healthier", "healthy", "richer", "rich", "successful", "fulfilled",
        "calmer", "calm", "balanced", "productive", "free", "freer", "fitter", "wiser", "kinder", "stronger",
        "good", "great", "more", "less", "improve", "grow", "change",
    ]

    /// Lowercased words without punctuation.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }
    }

    /// A4b: one question to make a vague goal concrete, or nil when the goal is concrete enough.
    /// Never a block: the user can always keep it as is.
    ///
    /// Vague = at most four words and one of them is a vague comparative ("Be happier.", "Get better").
    public static func clarifyingQuestion(for goalText: String) -> String? {
        let w = words(goalText)
        guard !w.isEmpty, w.count <= 4 else { return nil }
        guard let vague = w.last(where: { vagueWords.contains($0) }) else { return nil }
        let focus: String
        switch vague {
        case "more", "less", "improve", "grow", "change", "good", "great":
            return "What would that look like a year from now?"
        default:
            focus = vague
        }
        return "What would \(focus) look like a year from now?"
    }

    /// A5: split a goal into parts at commas, semicolons and "and", with a proposed symbol each.
    /// "Earn my first million, stay strong, keep close friends." → three parts (wealth, strength, friends).
    /// At most four parts; a goal with no split is one part.
    public static func proposeParts(for goalText: String, makeID: () -> UUID = UUID.init) -> [GoalPart] {
        let text = normalize(goalText)
        guard !text.isEmpty else { return [] }
        var body = text
        while let l = body.last, ".!?".contains(l) { body.removeLast() }

        var clauses: [String] = []
        for chunk in body.split(whereSeparator: { ",;".contains($0) }) {
            var piece = String(chunk).trimmingCharacters(in: .whitespaces)
            for prefix in ["and ", "& "] where piece.lowercased().hasPrefix(prefix) {
                piece = String(piece.dropFirst(prefix.count))
            }
            // "Run a marathon and call Mum weekly" splits too, when both sides are long enough.
            let sides = piece.components(separatedBy: " and ")
            if sides.count == 2, sides.allSatisfy({ words($0).count >= 2 }) {
                clauses.append(contentsOf: sides)
            } else {
                clauses.append(piece)
            }
        }
        clauses = clauses.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if clauses.count > 4 {
            clauses = Array(clauses.prefix(3)) + [clauses.dropFirst(3).joined(separator: ", ")]
        }

        var used: Set<PartSymbol> = []
        return clauses.map { clause in
            let title = clause.prefix(1).uppercased() + clause.dropFirst()
            let symbol = symbol(for: clause, avoiding: used)
            used.insert(symbol)
            return GoalPart(id: makeID(), title: title, symbol: symbol)
        }
    }

    /// The whole goal as a single part ("Keep it as one part").
    public static func singlePart(for goalText: String, makeID: () -> UUID = UUID.init) -> [GoalPart] {
        var title = normalize(goalText)
        while let l = title.last, ".!?".contains(l) { title.removeLast() }
        guard !title.isEmpty else { return [] }
        return [GoalPart(id: makeID(), title: title, symbol: symbol(for: title, avoiding: []))]
    }

    static let keywords: [(PartSymbol, [String])] = [
        (.wealth, ["earn", "money", "million", "rich", "richer", "save", "savings", "business", "studio", "company",
                   "career", "job", "work", "profit", "profitable", "income", "pay", "debt", "invest", "sell", "ship", "build", "launch"]),
        (.strength, ["strong", "stronger", "run", "marathon", "fit", "fitter", "health", "healthy", "healthier", "gym",
                     "sleep", "eat", "walk", "swim", "lift", "weight", "body", "yoga", "train", "cycle", "ride"]),
        (.friends, ["friends", "friend", "family", "kids", "children", "partner", "love", "people", "mum", "mom", "dad",
                    "parents", "community", "together", "call", "visit", "close", "wife", "husband"]),
        (.moon, ["calm", "calmer", "rest", "meditate", "quiet", "peace", "read", "write", "journal", "happier", "happy"]),
        (.sun, ["learn", "study", "morning", "create", "draw", "paint", "music", "play", "language", "travel"]),
    ]

    static func symbol(for clause: String, avoiding used: Set<PartSymbol>) -> PartSymbol {
        let w = Set(words(clause))
        var best: (PartSymbol, Int)?
        for (symbol, keys) in keywords {
            let hits = keys.filter { w.contains($0) }.count
            guard hits > 0 else { continue }
            if best == nil || hits > best!.1 { best = (symbol, hits) }
        }
        if let best { return best.0 }
        let fallback: [PartSymbol] = [.flag, .sun, .moon, .wealth, .strength, .friends]
        return fallback.first { !used.contains($0) } ?? .flag
    }

    /// "one", "two", … for "Your goal has three parts."
    public static func numberWord(_ n: Int) -> String {
        let words = ["no", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < words.count ? words[n] : String(n)
    }

    /// "Your goal has three parts." / "Your goal has one part."
    public static func partsTitle(count: Int) -> String {
        "Your goal has \(numberWord(count)) \(count == 1 ? "part" : "parts")."
    }
}

// MARK: - Rhythm editing (A6)

extension TimeOfDay {
    /// Move by `minutes`, wrapping around midnight. A6 steps by 15 minutes.
    public func adding(minutes: Int) -> TimeOfDay {
        let total = ((minutesSinceMidnight + minutes) % 1440 + 1440) % 1440
        return TimeOfDay(hour: total / 60, minute: total % 60)
    }
}

extension Rhythm {
    /// A6 steps: morning stays between 04:00 and 11:45, evening between 17:00 and 23:45.
    public static let morningRange = TimeOfDay(hour: 4)...TimeOfDay(hour: 11, minute: 45)
    public static let eveningRange = TimeOfDay(hour: 17)...TimeOfDay(hour: 23, minute: 45)
    public static let step = 15

    public func movingMorning(by steps: Int) -> Rhythm {
        var r = self
        r.morning = Self.clamp(morning.minutesSinceMidnight + steps * Self.step, to: Self.morningRange)
        return r
    }

    public func movingEvening(by steps: Int) -> Rhythm {
        var r = self
        r.evening = Self.clamp(evening.minutesSinceMidnight + steps * Self.step, to: Self.eveningRange)
        return r
    }

    static func clamp(_ minutes: Int, to range: ClosedRange<TimeOfDay>) -> TimeOfDay {
        let m = min(max(minutes, range.lowerBound.minutesSinceMidnight), range.upperBound.minutesSinceMidnight)
        return TimeOfDay(hour: m / 60, minute: m % 60)
    }
}
