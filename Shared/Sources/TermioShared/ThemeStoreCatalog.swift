/// The theme store's index: 50 well-known Ghostty scheme names, in display order
/// — 35 dark, then 15 light, by each theme's own background luminance.
///
/// Shared because both the Mac store and the iPhone's theme picker offer the same
/// set, and two hand-kept copies would drift. Names only: the Mac resolves them
/// against `GhosttyThemeCatalog` to install a file, the phone resolves them to
/// render, and neither meaning belongs in this package.
///
/// Curated, not exhaustive. No two entries read as the same theme — measured as
/// weighted mean CIE Lab distance over background, foreground, and ANSI 1–6, with
/// every pair clearing ΔE 12, which is what keeps near-duplicate families
/// (TokyoNight Night/Storm, Catppuccin Mocha/Macchiato, Rose Pine/Moon) down to
/// one row each. `ThemeLibraryTests` enforces the resolve, the brightness split,
/// and the distance rule.
public enum ThemeStoreCatalog {
    public static let names: [String] = [
        "Dracula",
        "Catppuccin Mocha",
        "TokyoNight Night",
        "Nord",
        "Gruvbox Dark",
        "Atom One Dark",
        "Monokai Pro",
        "Rose Pine",
        "Ayu Mirage",
        "Night Owl",
        "Kanagawa Wave",
        "Kanagawa Dragon",
        "Everforest Dark Hard",
        "GitHub Dark Default",
        "iTerm2 Solarized Dark",
        "Cobalt2",
        "Vesper",
        "Flexoki Dark",
        "Melange Dark",
        "Xcode Dark",
        "Aura",
        "Dark Modern",
        "Oxocarbon",
        "Gruber Darker",
        "Jellybeans",
        "Horizon",
        "Embark",
        "Srcery",
        "Terafox",
        "Modus Vivendi",
        "Vercel",
        "Poimandres",
        "Matte Black",
        "Carbonfox",
        "Sonokai",
        "Catppuccin Latte",
        "GitHub Light Default",
        "Rose Pine Dawn",
        "Gruvbox Light",
        "iTerm2 Solarized Light",
        "Atom One Light",
        "Flexoki Light",
        "Kanagawa Lotus",
        "Xcode Light",
        "Monokai Pro Light",
        "Iceberg Light",
        "Melange Light",
        "One Half Light",
        "Modus Operandi",
        "Bluloco Light",
    ]
}
