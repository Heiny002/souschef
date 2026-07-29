import Foundation
import SwiftSoup

/// Extracts readable text from HTML while PRESERVING line structure. SwiftSoup's `text()`
/// collapses every block element and `<br>` into a single space, which destroys the line
/// breaks the recipe parser depends on. Old blogs, newsletters, and forum posts format
/// recipes as plain paragraphs with no recipe-plugin markup, so the class-based heuristic
/// finds nothing — this feeds structure-preserving text to `PastedTextExtractor` instead.
enum DOMTextExtractor {

    /// Tags whose close should become a line break (block-level + list items + `<br>`).
    private static let blockTags: Set<String> = [
        "p", "div", "li", "ul", "ol", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
        "section", "article", "blockquote", "pre", "figcaption", "dd", "dt", "table",
    ]

    /// Boilerplate that is never recipe content — removed before extracting.
    private static let boilerplateSelector =
        "script, style, nav, footer, header, aside, form, noscript, "
        + ".ad, .advertisement, .comments, .comment, .nav, .menu, .sidebar, .share, .social"

    /// Structure-preserving plain text of the main content, or "" when nothing usable.
    static func extractText(html: String) -> String {
        guard let doc = try? SwiftSoup.parse(html) else { return "" }
        _ = try? doc.select(boilerplateSelector).remove()
        // Prefer the densest recipe-ish container; fall back to the body, then the document.
        let scoped = (try? doc.select("article, main, .recipe, [itemtype*=Recipe]").first()) ?? nil
        let root: Element = scoped ?? doc.body() ?? doc
        var out = ""
        walk(root, into: &out)
        return normalize(out)
    }

    private static func walk(_ node: Node, into out: inout String) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                out += text.getWholeText()
            } else if let el = child as? Element {
                let tag = el.tagName().lowercased()
                if tag == "br" { out += "\n"; continue }
                walk(el, into: &out)
                if blockTags.contains(tag) { out += "\n" }
            }
        }
    }

    /// Collapse intra-line whitespace, trim each line, and cap blank runs at one — so the
    /// parser sees clean paragraph boundaries, not the DOM's ragged whitespace.
    private static func normalize(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line in
            line.replacingOccurrences(of: #"[ \t\u{00a0}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        var result: [String] = []
        var blanks = 0
        for line in lines {
            if line.isEmpty {
                blanks += 1
                if blanks == 1 { result.append("") }
            } else {
                blanks = 0
                result.append(line)
            }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
