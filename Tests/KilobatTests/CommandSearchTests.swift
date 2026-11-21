import Testing
import KilobatCore

struct CommandSearchTests {
    @Test func ranksTitleAndAliasesBeforeDescription() {
        let channel = CommandSearch(title: "Wi-Fi channels", aliases: ["spectrum"], detail: "Check nearby networks")
        let radar = CommandSearch(title: "Radar", aliases: [], detail: "Compare Wi-Fi channels and spectrum")
        #expect((channel.rank("Wi-Fi channels") ?? 100) < (radar.rank("Wi-Fi channels") ?? 0))
        #expect((channel.rank("spectrum") ?? 100) < (radar.rank("spectrum") ?? 0))
        #expect(channel.rank("check speed") == nil)
    }

    @Test func matchesAccentsPunctuationAndEnglishAliases() {
        let search = CommandSearch(title: "Réseau Wi-Fi", aliases: ["Channels"], detail: "Nearby networks")
        #expect(search.rank("  RESEAU Wi‑Fi  ") == 0)
        #expect(search.rank("channel") != nil)
        #expect(search.rank("wifi") != nil)
    }
}
