import Foundation
import Testing
@testable import SottovaCore

struct ThemeFileTests {
    private static let builtIn = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Support/Themes").standardizedFileURL

    private func file(_ fields: [String: Any] = [:]) throws -> Data {
        var theme: [String: Any] = ["name": "Test", "side": "dark", "bg": "#000000", "raised": "#111111", "hover": "#222222", "border": "#333333",
                                    "decor": "#444444", "text": "#ffffff", "muted": "#cccccc", "faint": "#bbbbbb", "primary": "#ffcc00",
                                    "onPrimary": "#000000", "accents": []]
        fields.forEach { theme[$0] = $1 }
        return try JSONSerialization.data(withJSONObject: theme)
    }

    private func loading(_ files: [String: Data]) throws -> (themes: [ThemeFile], rejected: [ThemeFile.Rejected]) {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for (name, data) in files { try data.write(to: folder.appending(path: name)) }
        return ThemeFile.load(from: [folder])
    }

    @Test func everyBuiltInPassesTheGate() {
        let (themes, rejected) = ThemeFile.load(from: [Self.builtIn])
        #expect(rejected == [])
        #expect(themes.count == 19)
        #expect(themes.filter { $0.side == .light }.count == 6)
    }

    @Test func theMockedValuesAreTheOnesLoaded() {
        let themes = ThemeFile.load(from: [Self.builtIn]).themes
        let gruvbox = ThemeFile.slot(.dark, named: "Gruvbox", palette: nil, in: themes)
        #expect((gruvbox.sidebarColor, gruvbox.muted, gruvbox.faint, gruvbox.primary) == ("#32302f", "#bdae93", "#a89984", "#fabd2f"))
        #expect(gruvbox.popoverColor == "#3c3836")
        let mocha = ThemeFile.slot(.dark, named: "Catppuccin Mocha", palette: nil, in: themes)
        #expect((mocha.bg, mocha.sidebarColor, mocha.primary) == ("#1e1e2e", "#181825", "#fab387"))
    }

    @Test func aFaintFileIsSkippedWithAReason() throws {
        let (themes, rejected) = try loading(["bad.json": file(["muted": "#222222"])])
        #expect(!themes.contains { $0.name == "Test" })
        #expect(rejected == [ThemeFile.Rejected(file: "bad.json", why: "muted is too faint on the background")])
    }

    @Test(arguments: [("text", "#555555"), ("faint", "#333333"), ("primary", "#333333"), ("onPrimary", "#ffcc00")])
    func eachGateHolds(field: String, color: String) throws {
        #expect(try loading(["bad.json": file([field: color])]).rejected.count == 1)
    }

    @Test func aBrokenFileOrColorIsSkippedNotFatal() throws {
        let (themes, rejected) = try loading(["junk.json": Data("nope".utf8), "color.json": file(["hover": "red"]), "good.json": file()])
        #expect(rejected.map(\.file) == ["color.json", "junk.json"])
        #expect(themes.contains { $0.name == "Test" })
    }

    @Test func aSignIsntAColor() {
        #expect(ThemeFile.rgb("#+12345") == nil)
        #expect(ThemeFile.rgb("#ABCDEF") == 0xABCDEF)
    }

    @Test func noFolderStillLeavesMonochrome() {
        let themes = ThemeFile.load(from: [URL(filePath: "/nonexistent")]).themes
        #expect(themes.map(\.name) == ["Monochrome", "Monochrome"])
        #expect(ThemeFile.monochrome(.dark).problem == nil)
        #expect(ThemeFile.monochrome(.light).problem == nil)
    }

    @Test func aUserFileReplacesTheBuiltInOfThatNameAndSide() throws {
        let themes = try loading(["mine.json": file(["name": "Monochrome", "bg": "#010101"])]).themes
        #expect(themes.filter { $0.name == "Monochrome" && $0.side == .dark }.map(\.bg) == ["#010101"])
        #expect(themes.contains { $0.name == "Monochrome" && $0.side == .light })
    }

    @Test func slotsFallBackThroughTheOldPaletteKey() {
        let themes = ThemeFile.load(from: [Self.builtIn]).themes
        #expect(ThemeFile.slot(.dark, named: nil, palette: "catppuccin", in: themes).name == "Catppuccin Mocha")
        #expect(ThemeFile.slot(.light, named: nil, palette: "catppuccin", in: themes).name == "Catppuccin Latte")
        #expect(ThemeFile.slot(.dark, named: nil, palette: "monochrome", in: themes).name == "Monochrome")
        #expect(ThemeFile.slot(.dark, named: nil, palette: nil, in: themes).name == "Gruvbox")
        #expect(ThemeFile.slot(.light, named: "Rose Pine Dawn", palette: "gruvbox", in: themes).name == "Rose Pine Dawn")
        // a light theme named for the dark slot, or one since deleted
        #expect(ThemeFile.slot(.dark, named: "Rose Pine Dawn", palette: "gruvbox", in: themes).name == "Gruvbox")
    }

    @Test func coverGroundsAreNeverEmpty() throws {
        #expect(try loading(["a.json": file(["covers": [String]()])]).themes.first { $0.name == "Test" }?.coverGrounds == ["#111111"])
        #expect(try loading(["a.json": file()]).themes.first { $0.name == "Test" }?.coverGrounds == ["#111111"])
        #expect(ThemeFile.load(from: [Self.builtIn]).themes.allSatisfy { !$0.coverGrounds.isEmpty })
        #expect(ThemeFile.monochrome(.dark).coverGrounds.count == 3)
    }

    @Test func seedsFillWhatAFileLeavesOut() throws {
        let theme = try #require(try loading(["a.json": file()]).themes.first { $0.name == "Test" })
        #expect(theme.sidebarColor == "#111111")
        #expect(theme.iconColor == "#bbbbbb")
        #expect(theme.disabledColor == "#444444")
        #expect(theme.popoverColor == "#222222")
        let light = try #require(try loading(["a.json": file(["side": "light", "bg": "#ffffff", "raised": "#eeeeee", "text": "#000000", "muted": "#333333", "faint": "#444444", "primary": "#000000", "onPrimary": "#ffffff"])]).themes.first { $0.name == "Test" })
        #expect(light.popoverColor == "#ffffff")
    }
}
