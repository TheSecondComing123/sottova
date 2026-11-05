import Foundation
import Testing

/// The UI draws each role with its component and each value with its token. Every place that still doesn't is
/// listed here, counted, so the list can only shrink.
struct LookRulesTests {
    private static let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Sources/Sottova").standardizedFileURL

    enum Rule {
        case radius, font, icon, underline, plainIcon, reveal
    }

    private static let roleFonts: Set<String> = ["32 medium", "22 medium", "17 medium", "15 medium", "17 semibold",
                                                 "13 regular", "12 regular", "11 semibold", "11 medium"]
    private static let icons = ["Ph.x.icon(", "Ph.dotsThree.icon("]

    /// The rules one line breaks; `near` is the lines either side, for a reveal.
    static func broken(_ line: String, near: [String] = []) -> [Rule] {
        var rules: [Rule] = []
        if line.contains(/cornerRadius: (6|8|10|12)(?![.\d])/) { rules.append(.radius) }
        if line.matches(of: /\.system\(size: (\d+)(?:, weight: \.(\w+))?\)/).contains(where: { roleFonts.contains("\($0.1) \($0.2 ?? "regular")") }) {
            rules.append(.font)
        }
        let icon = icons.contains { line.contains($0) }
        if icon { rules.append(.icon) }
        if line.contains(".underline(") { rules.append(.underline) }
        if icon && (line.contains("buttonStyle(.plain)") || line.contains("buttonStyle(PlainButtonStyle())")) { rules.append(.plainIcon) }
        // hit testing that follows an opacity is a hand-made `.revealed`; `false` only lets clicks through a decoration
        if line.contains(".allowsHitTesting("), !line.contains(".allowsHitTesting(false)"), ([line] + near).contains(where: { $0.contains(".opacity(") }) {
            rules.append(.reveal)
        }
        return rules
    }

    /// The lines that count, blank where skipped so line numbers hold: no comments, and no SHOT branch.
    static func counted(_ source: String) -> [String] {
        var lines: [String] = []
        // per open #if: whether the branch it's in is SHOT's, or nil for an #if on something else
        var shot: [Bool?] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#if ") {
                shot.append(trimmed == "#if SHOT" ? true : trimmed == "#if !SHOT" ? false : nil)
            } else if trimmed == "#else", let last = shot.popLast() {
                shot.append(last.map { !$0 })
            } else if trimmed == "#endif" {
                _ = shot.popLast()
            }
            let skipped = trimmed.hasPrefix("#") || trimmed.hasPrefix("//") || shot.contains(true)
            lines.append(skipped ? "" : line)
        }
        return lines
    }

    struct Exception {
        let file: String, rule: Rule, snippet: String, count: Int
        init(_ file: String, _ rule: Rule, _ snippet: String, _ count: Int = 1) {
            (self.file, self.rule, self.snippet, self.count) = (file, rule, snippet, count)
        }
    }

    static let exceptions: [Exception] = [
        // the row-edit × sits inside the hover cross, with its offset and the cross's plate: its own role
        Exception("CollectionPage.swift", .icon, "Ph.x.icon(.bold, size: 9)"),
        // still to move: hover reveals to `.revealed`
        Exception("CollectionPage.swift", .reveal, ".allowsHitTesting(", 5),
        Exception("DayPage.swift", .reveal, ".allowsHitTesting(", 2),
        // close × to IconButton
        Exception("DayPage.swift", .icon, "Ph.x.icon(", 1),
        Exception("NowPage.swift", .icon, "Ph.x.icon(", 1),
        Exception("Queue.swift", .icon, "Ph.x.icon(", 1),
        // ••• to one menu
        Exception("CollectionPage.swift", .icon, "Ph.dotsThree.icon(", 2),
        Exception("DayPage.swift", .icon, "Ph.dotsThree.icon(", 1),
        // hand underlines to links
        Exception("RowWords.swift", .underline, ".underline(", 1),
        Exception("TitleBar.swift", .underline, ".underline(hovering)", 2),
        // the trim sheet's steppers and buttons
        Exception("TrimSheet.swift", .font, ".system(size: 11, weight: .medium)", 3),
        Exception("TrimSheet.swift", .font, ".system(size: 13)", 1),
        Exception("TrimSheet.swift", .radius, "cornerRadius: 8", 4),
    ]

    @Test func everyRoleUsesItsComponentAndEveryValueItsToken() throws {
        var unlisted: [String] = []
        var seen: [Int: Int] = [:]
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).filter { $0.hasSuffix(".swift") }
        #expect(files.count > 20)
        for file in files.sorted() where !["Look.swift", "Theme.swift", "Shot.swift"].contains(file) {
            let lines = Self.counted(try String(contentsOf: Self.folder.appending(path: file), encoding: .utf8))
            for (i, line) in lines.enumerated() {
                let near = [i > 0 ? lines[i - 1] : "", i + 1 < lines.count ? lines[i + 1] : ""]
                for rule in Self.broken(line, near: near) {
                    if let index = Self.exceptions.firstIndex(where: { $0.file == file && $0.rule == rule && line.contains($0.snippet) }) {
                        seen[index, default: 0] += 1
                    } else {
                        unlisted.append("\(file):\(i + 1) \(rule): \(line.trimmingCharacters(in: .whitespaces))")
                    }
                }
            }
        }
        #expect(unlisted.isEmpty, "use the role's component or the token: \(unlisted.joined(separator: "\n"))")
        for (index, exception) in Self.exceptions.enumerated() {
            #expect(seen[index, default: 0] == exception.count, "\(exception.file) \(exception.rule) \"\(exception.snippet)\": update the count")
        }
    }

    @Test func eachRuleCatchesItsSampleAndPassesALegitimateOne() {
        #expect(Self.broken(".background(Theme.raised, in: .rect(cornerRadius: 8))") == [.radius])
        #expect(Self.broken(".font(.system(size: 15, weight: .medium))") == [.font])
        #expect(Self.broken(".font(.system(size: 13))") == [.font])
        #expect(Self.broken("Ph.x.icon(.bold, size: 11)") == [.icon])
        #expect(Self.broken("Text(t).underline(hovering)") == [.underline])
        #expect(Self.broken("Button { } label: { Ph.dotsThree.icon(size: 14) }.buttonStyle(.plain)") == [.icon, .plainIcon])
        #expect(Self.broken(".allowsHitTesting(shown)", near: [".opacity(shown ? 1 : 0)", ""]) == [.reveal])

        #expect(Self.broken("Menu { content } label: { Text(title).role(.body) }.buttonStyle(.plain)").isEmpty)
        #expect(Self.broken("Ph.caretDown.icon(.bold, size: 8).foregroundStyle(Theme.faint)").isEmpty)
        #expect(Self.broken("RoundedRectangle(cornerRadius: 3.5).fill(Theme.muted)").isEmpty)
        #expect(Self.broken("RoundedRectangle(cornerRadius: 16)").isEmpty)
        #expect(Self.broken("RoundedRectangle(cornerRadius: 6.5)").isEmpty)
        #expect(Self.broken(".font(.system(size: 13, weight: .semibold))").isEmpty)
        #expect(Self.broken(".shadow(color: .black.opacity(0.3), radius: 12, y: 6)").isEmpty)
        #expect(Self.broken(".allowsHitTesting(false)", near: [".opacity(targeted ? 1 : 0)", ""]).isEmpty)
    }

    @Test func onlyTheShotBranchAndCommentsAreSkipped() {
        let lines = Self.counted("a\n// b\n#if SHOT\nc\n#else\nd\n#endif\n#if !SHOT\ne\n#else\nf\n#endif\n#if DEBUG\ng\n#else\nh\n#endif")
        #expect(lines.filter { !$0.isEmpty } == ["a", "d", "e", "g", "h"])
        #expect(lines.count == 17)
    }
}
