import type { DocsLanguage } from "@/lib/i18n";

// The docs shell's own words — everything outside the MDX body. Small on purpose:
// the pages carry the content, this carries the furniture. Chinese wording follows
// the app's own Simplified Chinese UI, so a reader sees one vocabulary across the
// app and the docs (see content/docs/.i18n/glossary.zh-CN.json).
export type DocsChrome = {
  searchTrigger: string;
  searchPlaceholder: string;
  searching: string;
  searchUnavailable: string;
  /** `{query}` is replaced with what the reader typed. A template, not a
   * function: this object crosses into a client component, and functions can't. */
  noResults: string;
  menu: string;
  onThisPage: string;
  previous: string;
  next: string;
  copyForLLM: string;
  copied: string;
  copyAriaLabel: string;
  markdown: string;
  markdownAriaLabel: string;
  editPage: string;
  skipToContent: string;
  language: string;
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
  searching: "Searching…",
  searchUnavailable: "Search isn’t available right now — try again in a moment.",
  noResults: "No results for “{query}”.",
  menu: "Documentation menu",
  onThisPage: "On this page",
  previous: "Previous",
  next: "Next",
  copyForLLM: "Copy for LLM",
  copied: "Copied",
  copyAriaLabel: "Copy this page as Markdown",
  markdown: "Markdown",
  markdownAriaLabel: "Open this page as raw Markdown",
  editPage: "Edit this page on GitHub",
  skipToContent: "Skip to content",
  language: "Language",
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
  searching: "搜索中…",
  searchUnavailable: "搜索暂时不可用，请稍后再试。",
  noResults: "没有与“{query}”匹配的结果。",
  menu: "文档目录",
  onThisPage: "本页内容",
  previous: "上一页",
  next: "下一页",
  copyForLLM: "拷贝给 LLM",
  copied: "已拷贝",
  copyAriaLabel: "以 Markdown 拷贝本页",
  markdown: "Markdown",
  markdownAriaLabel: "以 Markdown 原文打开本页",
  editPage: "在 GitHub 上编辑本页",
  skipToContent: "跳到正文",
  language: "语言",
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
