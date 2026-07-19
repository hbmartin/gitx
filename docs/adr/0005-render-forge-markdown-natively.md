# Render Forge Markdown natively with swift-markdown

GitX will parse Forge-authored Markdown with `swift-markdown` and render the sanitized syntax tree through native AppKit views. This extends ADR-0001's native-rendering direction to Pull Requests, Issues, comments, and reviews while retaining GitHub-flavored Markdown structure and offline rendering; Foundation's narrower attributed-string parser and server-rendered HTML were rejected because they respectively lose important structure or enlarge the untrusted-HTML and WebKit-adjacent surface.
