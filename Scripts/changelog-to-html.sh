#!/usr/bin/env bash
#
# Render one CHANGELOG.md section as the HTML Sparkle embeds in the update
# dialog.  Called by Scripts/make_appcast.sh as:
#
#     Scripts/changelog-to-html.sh <version> > JackApp-<version>.html
#
# make_appcast.sh runs under `set -e`, and a non-zero exit here would abort
# appcast generation entirely — which means a release with no auto-update
# entry.  Missing or unparseable notes are not worth that, so every path in
# this script prints valid HTML and exits 0.
#
# Recognised in a section: `### Heading`, `- ` bullets (continuation lines
# indented under them), and plain paragraphs.  Inline `**bold**`, `` `code` ``
# and <links> are carried across; everything else is escaped.

set -uo pipefail

VERSION="${1:-}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHANGELOG="${CHANGELOG_FILE:-$ROOT/CHANGELOG.md}"

emit() {
  printf '%s\n' \
    '<!doctype html>' \
    '<html lang="en">' \
    '<meta charset="utf-8">' \
    "<title>Jack ${VERSION:-update}</title>" \
    '<style>' \
    '  body { font: 13px/1.55 -apple-system, BlinkMacSystemFont, sans-serif;' \
    '         margin: 0; padding: 4px 2px; color: #1d1d1f; }' \
    '  h3 { font-size: 12px; text-transform: uppercase; letter-spacing: .04em;' \
    '       color: #6e6e73; margin: 14px 0 6px; }' \
    '  h3:first-child { margin-top: 0; }' \
    '  ul { margin: 0 0 10px; padding-left: 20px; }' \
    '  li { margin-bottom: 5px; }' \
    '  code { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 12px;' \
    '         background: rgba(0,0,0,.06); border-radius: 3px; padding: 1px 4px; }' \
    '  @media (prefers-color-scheme: dark) {' \
    '    body { color: #f5f5f7; }' \
    '    h3 { color: #a1a1a6; }' \
    '    code { background: rgba(255,255,255,.12); }' \
    '  }' \
    '</style>' \
    '<body>'
  cat
  printf '%s\n' '</body>' '</html>'
}

fallback() {
  emit <<HTML
<p>Jack ${VERSION:-update}. See <a href="https://github.com/Thiagoxp95/jack/releases">the releases page</a> for details.</p>
HTML
  exit 0
}

[[ -n "$VERSION" && -f "$CHANGELOG" ]] || fallback

BODY=$(
  awk -v want="$VERSION" '
    function esc(s) {
      gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s)
      return s
    }
    # Re-apply the small subset of Markdown worth keeping, after escaping.
    function md(s) {
      s = esc(s)
      while (match(s, /\*\*[^*]+\*\*/)) {
        s = substr(s, 1, RSTART - 1) "<strong>" substr(s, RSTART + 2, RLENGTH - 4) \
            "</strong>" substr(s, RSTART + RLENGTH)
      }
      while (match(s, /`[^`]+`/)) {
        s = substr(s, 1, RSTART - 1) "<code>" substr(s, RSTART + 1, RLENGTH - 2) \
            "</code>" substr(s, RSTART + RLENGTH)
      }
      # <https://…> autolinks, written as &lt;https://…&gt; by now.
      while (match(s, /&lt;https?:\/\/[^ &]+&gt;/)) {
        url = substr(s, RSTART + 4, RLENGTH - 8)
        s = substr(s, 1, RSTART - 1) "<a href=\"" url "\">" url "</a>" substr(s, RSTART + RLENGTH)
      }
      return s
    }
    function closelist() { if (inlist) { print "</ul>"; inlist = 0 } }
    function flushpara() {
      if (para != "") { print "<p>" md(para) "</p>"; para = "" }
    }
    function flushitem() {
      if (item != "") { print "<li>" md(item) "</li>"; item = "" }
    }

    /^##[^#]/ {
      # "## 1.4.1 — 2026-08-11" → compare the version token only.
      line = $0; sub(/^##[ \t]*/, "", line)
      split(line, tok, /[ \t]/)
      ver = tok[1]; sub(/^[vV]/, "", ver)
      if (ver == want) { on = 1; next }
      if (on) { flushitem(); closelist(); flushpara(); exit }
      next
    }
    !on { next }

    /^###[ \t]/ {
      flushitem(); closelist(); flushpara()
      h = $0; sub(/^###[ \t]*/, "", h)
      print "<h3>" md(h) "</h3>"
      next
    }
    /^[ \t]*[-*][ \t]+/ {
      flushitem(); flushpara()
      if (!inlist) { print "<ul>"; inlist = 1 }
      item = $0; sub(/^[ \t]*[-*][ \t]+/, "", item)
      next
    }
    /^[ \t]*$/ { flushitem(); closelist(); flushpara(); next }
    {
      # A continuation of whichever block is open.
      cont = $0; sub(/^[ \t]+/, "", cont)
      if (item != "") { item = item " " cont }
      else { para = (para == "" ? cont : para " " cont) }
    }

    END { flushitem(); closelist(); flushpara() }
  ' "$CHANGELOG"
)

[[ -n "${BODY//[[:space:]]/}" ]] || fallback

emit <<<"$BODY"
exit 0
