import Foundation
import FrisketBase

/// Builds complete, self-contained HTML documents (exportDoc.js `buildExportHtml`).
/// The app loads the result into WebKit for PDF/JPEG/print, or saves it as `.html`.
public enum ExportDocument {
    public struct Result: Equatable, Sendable {
        public var html: String
        public var title: String
        public var outline: [OutlineItem]
    }

    /// Render `markdown` and wrap it. `themeCSS` is the theme's `:root { --bg: … }` block
    /// (the app reads it); `noteURL` anchors relative images and supplies the fallback title.
    public static func build(
        markdown: String,
        noteURL: URL? = nil,
        title: String? = nil,
        themeCSS: String,
        options: ExportOptions = ExportOptions(),
        renderer: MarkdownRenderer = MarkdownRenderer()
    ) -> Result {
        let options = options.validated()
        let rendered = renderer.render(markdown)
        var body = rendered.html
        if options.embedImages {
            let noteDirectory = noteURL?.deletingLastPathComponent()
            body = ImageEmbedder(noteDirectory: noteDirectory, allowedRoot: options.allowedRoot).embed(in: body)
        }
        let fallback = noteURL.map { $0.deletingPathExtension().lastPathComponent } ?? "Untitled"
        let resolvedTitle = title ?? documentTitle(markdown, fallback: fallback)
        let html = wrap(body: body, title: resolvedTitle, outline: rendered.outline, themeCSS: themeCSS, options: options)
        return Result(html: html, title: resolvedTitle, outline: rendered.outline)
    }

    /// Wrap an already rendered body.
    public static func wrap(body: String, title: String, outline: [OutlineItem], themeCSS: String, options: ExportOptions = ExportOptions()) -> String {
        let options = options.validated()
        var beforeArticle = ""
        if let presentation = options.presentation {
            if presentation.titlePage { beforeArticle += titlePageHTML(title: title, presentation: presentation) }
            if presentation.toc { beforeArticle += tocHTML(outline.filter { $0.level <= 3 }) }
        }
        let layout: String
        if let presentation = options.presentation {
            layout = layoutCSS(options: options, presentation: presentation)
        } else {
            layout = options.mode == .pdf ? pageCSS(options) : screenCSS(options)
        }
        return [
            "<!doctype html>",
            "<html lang=\"en\"" + (options.dark ? " data-dark=\"true\"" : "") + ">",
            "<head>",
            "<meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>" + escapeHTML(title) + "</title>",
            "<style>",
            themeCSS,
            PreviewStylesheet.css,
            ".md-render { font-size: " + jsNumber(options.fontSize) + "px; }",
            "html { color-scheme: " + (options.dark ? "dark" : "light") + "; }",
            "body { color: var(--fg); background: var(--bg); }",
            "math { font-size: 1.05em; }",
            layout,
            "</style>",
            "</head>",
            "<body>",
            beforeArticle,
            "<article class=\"md-render\">",
            body,
            "</article>",
            "</body>",
            "</html>",
        ].joined(separator: "\n")
    }

    /// Front-matter `title`, else the first `# ` heading, else `fallback`.
    public static func documentTitle(_ markdown: String, fallback: String) -> String {
        let parsed = parseFrontMatter(splitFrontMatter(markdown).metaText)
        return noteTitle(markdown, fallback: fallback, properties: parsed.properties)
    }

    // MARK: pieces

    /// Contents page (`buildTocHtml`); every entry given is listed.
    public static func tocHTML(_ headings: [OutlineItem]) -> String {
        if headings.isEmpty { return "" }
        let rows = headings.map { heading in
            "<li class=\"export-toc-level-\(heading.level)\"><a href=\"#" + escapeHTML(encodeURIComponent(heading.id)) + "\">"
                + escapeHTML(heading.text.jsTrimmed) + "</a></li>"
        }.joined()
        return "<nav class=\"export-toc\" aria-label=\"Table of contents\"><h1>Contents</h1><ol>" + rows + "</ol></nav>"
    }

    /// Title page (`buildTitlePageHtml`); all text is escaped.
    public static func titlePageHTML(title: String, presentation: ExportPresentation) -> String {
        "<section class=\"export-title-page\" aria-label=\"Title page\">"
            + "<div class=\"export-title-content\"><h1>" + escapeHTML(title) + "</h1>"
            + (presentation.subtitle.isEmpty ? "" : "<p class=\"export-subtitle\">" + escapeHTML(presentation.subtitle) + "</p>")
            + (presentation.author.isEmpty ? "" : "<p class=\"export-author\">" + escapeHTML(presentation.author) + "</p>")
            + "</div></section>"
    }

    /// `@page` rule and print-friendly breaks for PDF output.
    public static func pageCSS(_ options: ExportOptions) -> String {
        "@page { size: " + options.pageSize.rawValue + (options.landscape ? " landscape" : "") + "; margin: " + jsNumber(options.margin) + "in; }\n"
            + "body { margin: 0; }\n"
            + ".md-render { max-width: none; padding: 0; }\n"
            + ".md-render h1, .md-render h2, .md-render h3 { break-after: avoid; page-break-after: avoid; }\n"
            + ".md-render pre, .md-render table, .md-render blockquote, .md-render figure,"
            + " .md-render .mermaid-rendered { break-inside: avoid; page-break-inside: avoid; }\n"
            + ".md-render img { break-inside: avoid; }\n"
    }

    static func screenCSS(_ options: ExportOptions) -> String {
        "body { margin: 0; padding: 48px 24px 72px; background: var(--bg); }\n"
            + ".md-render { max-width: " + jsNumber(options.contentWidth) + "px; margin: 0 auto; }\n"
    }

    static func presetCSS(_ preset: ExportPreset, mode: ExportMode) -> String {
        switch preset {
        case .manuscript:
            return ".md-render { font-family: Georgia, \"Times New Roman\", serif; line-height: 1.8; max-width: 7in; }\n"
                + ".md-render p { text-indent: 1.25em; margin: 0 0 0.35em; }\n"
                + ".md-render h1, .md-render h2, .md-render h3 { font-family: Georgia, \"Times New Roman\", serif; }\n"
                + (mode == .pdf ? ".md-render { font-size: 12pt !important; }\n" : "")
        case .report:
            return ".md-render { max-width: 8in; line-height: 1.62; }\n"
                + ".md-render h1 { padding-bottom: .25em; border-bottom: 2px solid var(--line); }\n"
                + ".md-render h2 { padding-bottom: .15em; border-bottom: 1px solid var(--line); }\n"
                + ".md-render table { width: 100%; }\n"
        case .standard:
            return ""
        }
    }

    /// Page/screen layout plus preset, title-page and contents styling (`presentationLayoutCss`).
    public static func layoutCSS(options: ExportOptions, presentation: ExportPresentation) -> String {
        let base = options.mode == .pdf ? pageCSS(options) : screenCSS(options)
        return base + presetCSS(presentation.preset, mode: options.mode)
            + ".export-title-page { min-height: " + (options.mode == .pdf ? "9in" : "calc(100vh - 120px)")
            + "; display: flex; align-items: center; justify-content: center; text-align: center; break-after: page; page-break-after: always; }\n"
            + ".export-title-content { max-width: 7in; }\n"
            + ".export-title-page h1 { font-size: 2.6em; line-height: 1.15; border: 0; }\n"
            + ".export-subtitle { font-size: 1.3em; opacity: .78; }\n"
            + ".export-author { margin-top: 3em; }\n"
            + ".export-toc { margin: 0 auto 3em; max-width: 8in; break-after: page; page-break-after: always; }\n"
            + ".export-toc h1 { border: 0; }\n"
            + ".export-toc ol { list-style: none; padding: 0; }\n"
            + ".export-toc li { margin: .45em 0; }\n"
            + ".export-toc-level-2 { padding-left: 1.5em; } .export-toc-level-3 { padding-left: 3em; }\n"
            + ".export-toc a { color: inherit; text-decoration: none; }\n"
    }
}
