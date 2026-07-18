#!/usr/bin/env python3
"""Download Devicon SVGs for termio's iOS file icon catalog.

Run from the repo root. Writes an asset catalog into ios/Sources/LangIcons.xcassets
(UIImage cannot decode SVG at runtime, so iOS ships them Xcode-compiled) and the
shared catalog into Shared/Sources/TermioShared/LangIconCatalog.swift. macOS uses
the native Hugeicons file theme instead.
"""
import json, os, sys, urllib.request, concurrent.futures, re

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
CACHE_DIR = "/tmp/termio-devicons"
CATALOG = os.path.join(REPO, "Shared/Sources/TermioShared/LangIconCatalog.swift")
XCASSETS = os.path.join(REPO, "ios/Sources/LangIcons.xcassets")
RAW = "https://raw.githubusercontent.com/devicons/devicon/master/icons/{name}/{name}-{variant}.svg"

# devicon name -> (extensions, exact-filenames). Lowercase everything.
# Config filenames are enumerated across their common script-extension variants.
def cfg(stem):
    return [f"{stem}.{e}" for e in ("js", "ts", "mjs", "cjs", "cts", "mts")]

MAP = {
    "typescript":  (["ts", "mts", "cts"], ["tsconfig.json"]),
    "javascript":  (["js", "mjs", "cjs"], ["jsconfig.json", ".babelrc"]),
    "react":       (["jsx", "tsx"], []),
    "swift":       (["swift"], ["package.swift"]),
    "python":      (["py", "pyw", "pyi", "pyx"], ["requirements.txt", "pipfile", "pyproject.toml", "setup.py"]),
    "ruby":        (["rb", "erb", "gemspec", "ru"], ["gemfile", "gemfile.lock", "rakefile", ".ruby-version"]),
    "go":          (["go"], ["go.mod", "go.sum"]),
    "rust":        (["rs"], ["cargo.toml", "cargo.lock"]),
    "c":           (["c", "h"], []),
    "cplusplus":   (["cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++"], []),
    "csharp":      (["cs", "csx"], []),
    "java":        (["java", "jar", "class"], []),
    "kotlin":      (["kt", "kts"], []),
    "objectivec":  (["m", "mm"], []),
    "php":         (["php", "phtml", "php3", "php4", "php5"], []),
    "dart":        (["dart"], []),
    "html5":       (["html", "htm", "xhtml"], []),
    "css3":        (["css"], []),
    "sass":        (["scss", "sass"], []),
    "stylus":      (["styl"], []),
    "json":        (["json", "jsonc", "json5"], []),
    "yaml":        (["yaml", "yml"], []),
    "xml":         (["xml", "xsl", "xslt", "xsd", "plist", "storyboard", "xib"], []),
    "markdown":    (["md", "markdown", "mdx", "mdown"], ["readme"]),
    "bash":        (["sh", "bash", "ksh"], [".bashrc", ".bash_profile", ".profile", ".bash_aliases"]),
    "zsh":         (["zsh"], [".zshrc", ".zshenv", ".zprofile", ".zlogin"]),
    "powershell":  (["ps1", "psm1", "psd1"], []),
    "lua":         (["lua"], []),
    "perl":        (["pl", "pm", "perl"], []),
    "r":           (["r", "rmd"], []),
    "scala":       (["scala", "sc", "sbt"], []),
    "haskell":     (["hs", "lhs"], []),
    "elixir":      (["ex", "exs"], ["mix.exs"]),
    "erlang":      (["erl", "hrl"], ["rebar.config"]),
    "clojure":     (["clj", "cljc", "edn"], []),
    "clojurescript": (["cljs"], []),
    "elm":         (["elm"], []),
    "ocaml":       (["ml", "mli"], []),
    "fsharp":      (["fs", "fsx", "fsi"], []),
    "groovy":      (["groovy"], []),
    "gradle":      (["gradle"], ["build.gradle", "settings.gradle"]),
    "julia":       (["jl"], []),
    "nim":         (["nim", "nims"], []),
    "crystal":     (["cr"], []),
    "zig":         (["zig"], []),
    "vala":        (["vala", "vapi"], []),
    "solidity":    (["sol"], []),
    "graphql":     (["graphql", "gql"], []),
    "vyper":       (["vy"], []),
    "coffeescript":(["coffee"], []),
    "purescript":  (["purs"], []),
    "haxe":        (["hx", "hxml"], []),
    "fortran":     (["f", "f90", "f95", "f03", "for"], []),
    "cobol":       (["cob", "cbl", "cpy"], []),
    "racket":      (["rkt"], []),
    "latex":       (["tex", "ltx", "sty", "cls"], []),
    "matlab":      (["mat"], []),
    "visualbasic": (["vb", "vbs", "bas"], []),
    "delphi":      (["pas", "dpr", "dfm"], []),
    "pug":         (["pug", "jade"], []),
    "handlebars":  (["hbs", "handlebars"], []),
    "wasm":        (["wasm", "wat"], []),
    "vuejs":       (["vue"], cfg("vue.config")),
    "svelte":      (["svelte"], cfg("svelte.config")),
    "astro":       (["astro"], cfg("astro.config")),
    "sqlite":      (["sqlite", "sqlite3", "db"], []),
    "prisma":      (["prisma"], ["schema.prisma"]),
    "jupyter":     (["ipynb"], []),
    "docker":      ([], ["dockerfile", "containerfile", ".dockerignore",
                         "docker-compose.yml", "docker-compose.yaml",
                         "compose.yml", "compose.yaml"]),
    "git":         ([], [".gitignore", ".gitattributes", ".gitmodules", ".gitconfig", ".gitkeep"]),
    "vim":         (["vim"], [".vimrc", ".gvimrc"]),
    "denojs":      ([], ["deno.json", "deno.jsonc", "deno.lock"]),
    "nodejs":      ([], ["package.json", ".nvmrc", ".node-version"]),
    "npm":         ([], ["package-lock.json", ".npmrc", ".npmignore", "npm-shrinkwrap.json"]),
    "yarn":        ([], ["yarn.lock", ".yarnrc", ".yarnrc.yml"]),
    "pnpm":        ([], ["pnpm-lock.yaml", "pnpm-workspace.yaml"]),
    "bun":         ([], ["bun.lockb", "bunfig.toml"]),
    "eslint":      ([], [".eslintrc", ".eslintrc.json", ".eslintrc.js", ".eslintrc.cjs",
                         ".eslintrc.yml", ".eslintignore", "eslint.config.js", "eslint.config.mjs"]),
    "babel":       ([], ["babel.config.js", "babel.config.json", ".babelrc.json"]),
    "webpack":     ([], cfg("webpack.config")),
    "vitejs":      ([], cfg("vite.config")),
    "rollup":      ([], cfg("rollup.config")),
    "postcss":     ([], cfg("postcss.config")),
    "tailwindcss": ([], cfg("tailwind.config")),
    "jest":        ([], cfg("jest.config") + ["jest.setup.js"]),
    "vitest":      ([], cfg("vitest.config")),
    "playwright":  ([], cfg("playwright.config")),
    "cypressio":   ([], cfg("cypress.config")),
    "nextjs":      ([], cfg("next.config")),
    "nuxtjs":      ([], cfg("nuxt.config")),
    "cmake":       (["cmake"], ["cmakelists.txt"]),
    "composer":    ([], ["composer.json", "composer.lock"]),
    "maven":       ([], ["pom.xml"]),
    "terraform":   (["tf", "tfvars"], []),
    "ansible":     ([], ["ansible.cfg", "playbook.yml"]),
    "vagrant":     ([], ["vagrantfile"]),
    "nginx":       ([], ["nginx.conf"]),
    "apache":      ([], [".htaccess"]),
    "netlify":     ([], ["netlify.toml"]),
    "vercel":      ([], ["vercel.json"]),
    "firebase":    ([], ["firebase.json", ".firebaserc"]),
    "heroku":      ([], ["procfile"]),
    "visualstudio":(["sln", "suo"], []),
    "dot-net":     (["csproj", "vbproj", "fsproj"], []),
}

# Devicon marks that are a single near-black silhouette (their "original" variant
# is monochrome black) and so vanish on a dark terminal background. Rendered as a
# template tinted with the adaptive label ink instead of full color. Derived by
# luminance analysis of the rasterized SVGs (lum < 0.18 over opaque pixels).
MONOCHROME = {
    "astro", "cobol", "crystal", "denojs", "gradle", "handlebars", "latex",
    "markdown", "nextjs", "purescript", "rust", "solidity", "vercel", "yaml", "zsh",
}

# A few Devicon marks are the "official" but obscure logo — JSON's is the Crockford
# spinning-die, unrecognizable as JSON. Override those with a clearer source: the
# Material Icon Theme (PKief/vscode-material-icon-theme, MIT), whose JSON mark is a
# plain orange `{ }`.
OVERRIDES = {
    "json": "https://raw.githubusercontent.com/PKief/vscode-material-icon-theme/main/icons/json.svg",
}

def pick_variant(entry):
    svgs = entry["versions"]["svg"]
    for pref in ("original", "plain", "line"):
        if pref in svgs:
            return pref
    # else first non-wordmark, else first
    for v in svgs:
        if "wordmark" not in v:
            return v
    return svgs[0]

def main():
    manifest = json.load(open("/tmp/devicon.json"))
    by_name = {x["name"]: x for x in manifest}
    os.makedirs(CACHE_DIR, exist_ok=True)

    plan = {}  # devicon name -> variant
    for name in MAP:
        if name not in by_name:
            print("!! no devicon entry:", name); continue
        plan[name] = pick_variant(by_name[name])

    def fetch(item):
        name, variant = item
        url = OVERRIDES.get(name) or RAW.format(name=name, variant=variant)
        try:
            data = urllib.request.urlopen(url, timeout=30).read()
        except Exception as e:
            return (name, None, str(e))
        out = os.path.join(CACHE_DIR, f"{name}.svg")
        open(out, "wb").write(data)
        return (name, len(data), None)

    ok, fail = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as ex:
        for name, size, err in ex.map(fetch, plan.items()):
            (ok if err is None else fail).append((name, size or err))
    print(f"downloaded {len(ok)} icons, {len(fail)} failed")
    for n, e in fail:
        print("  FAIL", n, e)

    have = {n for n, _ in ok}
    ext_map, name_map = {}, {}
    for dn, (exts, names) in MAP.items():
        if dn not in have:
            continue
        for e in exts:
            ext_map[e] = dn
        for nm in names:
            name_map[nm] = dn

    lines = []
    lines.append("// Generated by tools/gen_langicons.py — do not edit by hand.")
    lines.append("// Maps a file's extension or exact name to a bundled Devicon mark in")
    lines.append("// the iOS asset catalog (ios/Sources/LangIcons.xcassets). Devicon is MIT;")
    lines.append("// the marks themselves are each vendor's trademark, shown for")
    lines.append("// recognition the way every code editor's file-icon theme does.")
    lines.append("import Foundation")
    lines.append("")
    lines.append("public enum LangIconCatalog {")
    lines.append("    /// Exact lowercased file name -> icon resource name. Checked before")
    lines.append("    /// the extension map so `vite.config.ts` wins over a bare `ts`.")
    lines.append("    public static let byName: [String: String] = [")
    for k in sorted(name_map):
        lines.append(f'        {json.dumps(k)}: {json.dumps(name_map[k])},')
    lines.append("    ]")
    lines.append("")
    lines.append("    /// Lowercased extension -> icon resource name.")
    lines.append("    public static let byExtension: [String: String] = [")
    for k in sorted(ext_map):
        lines.append(f'        {json.dumps(k)}: {json.dumps(ext_map[k])},')
    lines.append("    ]")
    lines.append("")
    lines.append("    /// Marks whose SVG is a single near-black silhouette; rendered as an")
    lines.append("    /// adaptive template (ink that flips with the appearance) so they stay")
    lines.append("    /// visible on a dark terminal background instead of full color.")
    lines.append("    public static let monochrome: Set<String> = [")
    for n in sorted(MONOCHROME & have):
        lines.append(f'        {json.dumps(n)},')
    lines.append("    ]")
    lines.append("}")
    lines.append("")
    lines.append("public extension LangIconCatalog {")
    lines.append("    /// The bundled logo for a file, by exact name first (so `vite.config.ts`")
    lines.append("    /// beats a bare `ts`) then by extension; `nil` when none is bundled and")
    lines.append("    /// the caller should fall back to an SF Symbol via `FileTypeIcon`.")
    lines.append("    static func resource(forFileName fileName: String) -> (name: String, monochrome: Bool)? {")
    lines.append("        let lowered = fileName.lowercased()")
    lines.append("        let ext = (lowered as NSString).pathExtension")
    lines.append("        guard let name = byName[lowered] ?? byExtension[ext] else { return nil }")
    lines.append("        return (name, monochrome.contains(name))")
    lines.append("    }")
    lines.append("}")
    open(CATALOG, "w").write("\n".join(lines) + "\n")
    print("wrote", CATALOG, "—", len(name_map), "names,", len(ext_map), "extensions")

    # The iOS asset catalog: one vector imageset per mark; the monochrome
    # silhouettes ship as templates so the app tints them with label ink.
    import shutil
    shutil.rmtree(XCASSETS, ignore_errors=True)
    os.makedirs(XCASSETS)
    with open(os.path.join(XCASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    for name in sorted(have):
        d = os.path.join(XCASSETS, f"{name}.imageset")
        os.makedirs(d)
        shutil.copy(os.path.join(CACHE_DIR, f"{name}.svg"), os.path.join(d, f"{name}.svg"))
        contents = {
            "images": [{"filename": f"{name}.svg", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {"preserves-vector-representation": True},
        }
        if name in MONOCHROME:
            contents["properties"]["template-rendering-intent"] = "template"
        with open(os.path.join(d, "Contents.json"), "w") as f:
            json.dump(contents, f, indent=2)
    print("wrote", XCASSETS, "—", len(have), "imagesets")

if __name__ == "__main__":
    main()
