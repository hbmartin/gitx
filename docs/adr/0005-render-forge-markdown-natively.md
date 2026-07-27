# Render Forge Markdown natively with swift-markdown

GitX will parse Forge-authored Markdown with `swift-markdown`, sanitize it into a GitX-owned document model, and render that model through native AppKit views. The renderer will never accept an unsanitized syntax tree. This extends ADR-0001's native-rendering direction to Pull Requests, Issues, comments, and reviews while retaining GitHub-flavored Markdown structure and offline rendering; Foundation's narrower attributed-string parser and server-rendered HTML were rejected because they respectively lose important structure or enlarge the untrusted-HTML and WebKit-adjacent surface.

## Sanitization contract

Forge Markdown is untrusted input. The sanitizer may emit only:

- text, paragraphs, headings, block quotes, lists, task-list state, tables, thematic breaks, and line breaks;
- emphasis, strong emphasis, strikethrough, inline code, and fenced code blocks;
- links whose destinations pass the URL policy below; and
- images as inert alt text and a placeholder, never as automatically loaded content.

Raw HTML, custom directives, embedded media, forms, scripts, style data, and unknown nodes are discarded as structure and rendered only as inert text when preserving their source helps comprehension. They are never interpreted as AppKit view descriptions, attributed-string markup, or HTML.

Link destinations must be absolute `https` URLs, `mailto` URLs, or relative Forge references that resolve to the configured Forge origin. GitX parses both the configured Forge base and the resolved destination as URLs; it never compares origins with string prefixes or suffixes. A Forge origin is valid only when it uses `https`, has a normalized host, contains no userinfo, and has a valid effective port. Origin comparison requires the same normalized host and effective port, treating an omitted HTTPS port as 443. A non-default port is accepted only when the configured Forge origin explicitly uses that same port.

Relative Forge references are resolved against the configured Forge origin and accepted only when the result has that exact origin. Protocol-relative forms, malformed URLs, credentials in authority components, other schemes, and local-file paths render as plain text. Absolute `https` links to other origins and valid `mailto` links remain allowed, but they do not qualify as relative Forge references. Links open only after an explicit user action, through the system browser or mail application; GitX does not prefetch destinations, generate remote previews, or open them in an embedded browser.

Images never trigger network or local-file access during parsing or rendering. A future explicit image-loading feature must use a separately reviewed network boundary, allow only `https`, prevent credential forwarding to unrelated hosts, enforce response size and media-type limits, and preserve the inert placeholder on failure.
