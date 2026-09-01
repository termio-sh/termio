import type { DocsLanguage } from "@/lib/i18n";

// The docs shell's own words — everything outside the MDX body. Small on purpose:
// the pages carry the content, this carries the furniture. Chinese wording follows
// the app's own Simplified Chinese UI, so a reader sees one vocabulary across the
// app and the docs (see content/docs/.i18n/glossary.zh-CN.json).
export type DocsChrome = {
  searchTrigger: string;
  searchPlaceholder: string;
  noResults: string;
  menu: string;
  onThisPage: string;
  noHeadings: string;
  previous: string;
  next: string;
  copyForLLM: string;
  copied: string;
  copyAriaLabel: string;
  markdown: string;
  markdownAriaLabel: string;
  askAI: string;
  askAIAriaLabel: string;
  askClaude: string;
  askChatGPT: string;
  /** The prompt handed to the assistant. `{url}` becomes the page's `.md` URL.
      A template rather than a function: this record crosses into client
      components, and a function can't. */
  askPrompt: string;
  editPage: string;
  language: string;
  skipToContent: string;
  docsLabel: string;
  download: string;
  theme: string;
  themeSystem: string;
  themeLight: string;
  themeDark: string;
  unbound: string;
};

const en: DocsChrome = {
  searchTrigger: "Search docs",
  searchPlaceholder: "Search the docs…",
  noResults: "No results.",
  menu: "Documentation menu",
  onThisPage: "On this page",
  noHeadings: "No headings",
  previous: "Previous",
  next: "Next",
  copyForLLM: "Copy for LLM",
  copied: "Copied",
  copyAriaLabel: "Copy this page as Markdown",
  markdown: "Markdown",
  markdownAriaLabel: "Open this page as raw Markdown",
  askAI: "Ask AI",
  askAIAriaLabel: "Ask an assistant about this page",
  askClaude: "Ask Claude",
  askChatGPT: "Ask ChatGPT",
  askPrompt:
    "Read {url} — it is a page of the Termio documentation. Answer my questions about it, and say when something isn't covered there.",
  editPage: "Edit this page on GitHub",
  language: "Language",
  skipToContent: "Skip to content",
  docsLabel: "Docs",
  download: "Download",
  theme: "Appearance",
  themeSystem: "System appearance",
  themeLight: "Light",
  themeDark: "Dark",
  unbound: "Unbound",
};

const zhCN: DocsChrome = {
  searchTrigger: "搜索文档",
  searchPlaceholder: "搜索文档…",
  noResults: "没有匹配的结果。",
  menu: "文档目录",
  onThisPage: "本页内容",
  noHeadings: "本页没有小标题",
  previous: "上一页",
  next: "下一页",
  copyForLLM: "拷贝给 LLM",
  copied: "已拷贝",
  copyAriaLabel: "以 Markdown 拷贝本页",
  markdown: "Markdown",
  markdownAriaLabel: "以 Markdown 原文打开本页",
  askAI: "问 AI",
  askAIAriaLabel: "就本页提问",
  askClaude: "问 Claude",
  askChatGPT: "问 ChatGPT",
  askPrompt:
    "请阅读 {url}，这是 Termio 文档的一页。请据此回答我的问题；文档里没写到的地方，直接说明。",
  editPage: "在 GitHub 上编辑本页",
  language: "语言",
  skipToContent: "跳到正文",
  docsLabel: "文档",
  download: "下载",
  theme: "外观",
  themeSystem: "跟随系统",
  themeLight: "浅色",
  themeDark: "深色",
  unbound: "未绑定",
};

const CHROME: Record<DocsLanguage, DocsChrome> = { en, "zh-CN": zhCN };

export function docsChrome(lang: DocsLanguage): DocsChrome {
  return CHROME[lang] ?? en;
}

// The words fumadocs writes itself — the search field, the table of contents
// heading, the pager, the edit link. Without this map the library falls back to
// its English defaults, which is why a Chinese page carried an English "On this
// page" above a Chinese outline. Its keys are the English string plus the context
// it appears in; that is the library's own key format, not a convention of ours,
// so they are quoted verbatim from `fumadocs-ui/dist/.translations`.
export function docsLibraryChrome(lang: DocsLanguage): Record<string, string> {
  const chrome = docsChrome(lang);
  return {
    "On this page(table of contents)": chrome.onThisPage,
    "Table of Contents(inline table of contents)": chrome.onThisPage,
    "No Headings(table of contents)": chrome.noHeadings,
    "Search(search trigger)": chrome.searchTrigger,
    "Search(search dialog)": chrome.searchPlaceholder,
    "No results found(search dialog)": chrome.noResults,
    "Previous Page(pagination)": chrome.previous,
    "Next Page(pagination)": chrome.next,
    "Edit on GitHub(edit page)": chrome.editPage,
    "Toggle Menu(mobile menu)(aria-label)": chrome.menu,
    "Choose a language(language switcher)": chrome.language,
    "Choose a language(language switcher)(aria-label)": chrome.language,
  };
}
