#!/usr/bin/env python3
"""The market's plan (NET/.c11/plan.md, as pantheon-cmux renders it) as a page
for a c11 browser panel: c11's markdown viewer shows raw HTML as text, so its
<details> blocks wouldn't fold there.

    plan-html.py PLAN.md PLAN.html

It knows the markdown the plan uses: ## and ### headings, paragraphs, **bold**,
_emphasis_, ~~strike~~, `code`, and the lines pantheon-cmux writes for a fold:
<details>, <summary>...</summary> (with <s> in it), </details>. Everything else
is escaped, so text from the goal, the repositories and other agents stays
text. Its entities (&amp; &lt; &gt;) are kept as they are. The page keeps which
folds are open, and where it was scrolled, across the reloads the watchdog
asks for (in sessionStorage, which c11 keeps across a reload)."""
import os
import re
import sys

ENTITY = re.compile(r"&(?!(?:amp|lt|gt|quot|#\d+|#x[0-9a-fA-F]+);)")


def esc(s):
    # escape, except an entity the plan already escaped
    return ENTITY.sub("&amp;", s).replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


def inline(s, summary=False):
    # HTML itself replaces NULs. Normalize them before introducing internal
    # code-span tokens so input cannot impersonate a token or index its list.
    s = esc(s).replace("\0", "\ufffd")
    if summary:
        s = s.replace("&lt;s&gt;", "<s>").replace("&lt;/s&gt;", "</s>")
    codes = []

    def keep(m):
        codes.append("<code>" + m[1] + "</code>")
        return "\0%d\0" % (len(codes) - 1)
    s = re.sub(r"`([^`]+)`", keep, s)
    s = re.sub(r"\*\*(\S(?:.*?\S)?)\*\*", r"<strong>\1</strong>", s)
    s = re.sub(r"~~(\S(?:.*?\S)?)~~", r"<del>\1</del>", s)
    s = re.sub(r"(?<![\w])_(\S(?:.*?\S)?)_(?![\w])", r"<em>\1</em>", s)
    return re.sub(r"\0(\d+)\0", lambda m: codes[int(m[1])], s)



# Market goal checklists still arrive with legacy icons from the shared
# Markdown renderer. Display cmux's Goals palette without changing statuses
# or rewriting icons elsewhere in the operator's text.
LEGACY_GOAL_ICONS = {"✅": "🌳", "⏳": "🌱", "🟡": "🫘"}
GOAL_ICON = re.compile(r"(🌳|🪴|🌱|🫘|✅|⏳|🟡) ")


def lift_goals(lines):
    """The goal's checklist, out of its fold: pantheon-cmux folds everything
    after the goal's opening paragraph under Details, its steps (each led by
    its status icon) among the rules. The steps go above the fold, always
    in view, as a list; the rest stays folded, and an empty fold goes."""
    headings = 0
    for i, line in enumerate(lines):
        if line.startswith("## "):
            headings += 1
            if headings > 1:  # past the goal's section
                break
        if line == "<details>" and i + 1 < len(lines) and lines[i + 1] == "<summary>Details</summary>":
            depth, end = 1, i + 1
            while end < len(lines):
                if lines[end] == "<details>": depth += 1
                elif lines[end] == "</details>": depth -= 1
                if not depth: break
                end += 1
            if depth: return lines  # incomplete/unbalanced input stays readable
            inner = lines[i + 2:end]
            steps = [l for l in inner if GOAL_ICON.match(l)]
            if not steps:
                return lines
            rest = [l for l in inner if not GOAL_ICON.match(l)]
            fold = ["<details>", "<summary>Details</summary>"] + rest + ["</details>"] if any(l.strip() for l in rest) else []
            return lines[:i] + ["<goals>"] + steps + ["</goals>", ""] + fold + lines[end + 1:]
    return lines


def body(md):
    out, para = [], []
    lines = lift_goals(md.split("\n"))
    in_goals = False

    def flush():
        if para:
            out.append("<p>" + "\n".join(inline(p) for p in para) + "</p>")
            para.clear()
    for line in lines:
        if line == "<goals>":
            flush(); out.append('<ul class="goals">'); in_goals = True; continue
        if line == "</goals>":
            out.append("</ul>"); in_goals = False; continue
        if in_goals:
            line = GOAL_ICON.sub(lambda m: LEGACY_GOAL_ICONS.get(m[1], m[1]) + " ", line, count=1)
            out.append("<li>" + inline(line) + "</li>"); continue
        summary = re.fullmatch(r"<summary>(.*)</summary>", line)
        heading = re.match(r"(#{2,3}) (.*)", line)
        if line in ("<details>", "</details>"):
            flush(); out.append(line)
        elif summary:
            flush(); out.append("<summary>" + inline(summary[1], True) + "</summary>")
        elif heading:
            flush(); n = len(heading[1]); out.append("<h%d>%s</h%d>" % (n, inline(heading[2]), n))
        elif not line.strip():
            flush()
        else:
            para.append(line)
    flush()
    return "\n".join(out)


PAGE = """<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline' 'unsafe-eval'">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>%(title)s</title>
<style>
:root { --bg: #ffffff; --fg: #1f2328; --muted: #59636e; --line: #d1d9e0; --hover: #f6f8fa; --code: #eff1f3; }
@media (prefers-color-scheme: dark) {
  :root { --bg: #16181d; --fg: #e6e8eb; --muted: #9198a1; --line: #30363d; --hover: #1f232a; --code: #262b33; }
}
html { background: var(--bg); color: var(--fg); }
body { font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; margin: 0; padding: 12px 16px 32px; }
h2 { font-size: 1.25em; margin: 1.2em 0 .5em; padding-bottom: .25em; border-bottom: 1px solid var(--line); }
h2:first-child { margin-top: 0; }
h3 { font-size: 1em; margin: 1em 0 .4em; color: var(--muted); }
p { margin: .5em 0; white-space: pre-line; }
em { color: var(--muted); }
code { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; background: var(--code); padding: .1em .3em; border-radius: 4px; }
ul.goals { list-style: none; padding: 0; margin: .4em 0 .6em; }
ul.goals li { margin: .25em 0; }
details { border-left: 2px solid var(--line); margin: .3em 0; padding: 0 0 0 .6em; }
details[open] { padding-bottom: .2em; }
summary { cursor: pointer; padding: .15em .3em; margin-left: -.3em; border-radius: 4px; overflow-wrap: anywhere; }
summary:hover { background: var(--hover); }
details > :not(summary) { margin-left: .2em; overflow-wrap: anywhere; }
</style></head>
<body>
%(body)s
<script>
(function () {
  // Which folds are open, and the scroll, kept across the watchdog's reloads
  // in sessionStorage (c11 keeps it across a reload; window.name it doesn't).
  // A fold is known by its summary's text, and which of that text it is, so
  // new folds above it don't move it.
  var store = "pantheon-plan";
  var keys = function () {
    var seen = {};
    return Array.prototype.map.call(document.querySelectorAll("details"), function (d) {
      var s = d.querySelector("summary"), t = s ? s.textContent : "";
      seen[t] = (seen[t] || 0) + 1;
      return { d: d, k: t + "#" + seen[t] };
    });
  };
  var save = function () {
    try {
      sessionStorage.setItem(store, JSON.stringify({ y: window.scrollY,
        open: keys().filter(function (x) { return x.d.open; }).map(function (x) { return x.k; }) }));
    } catch (e) {}
  };
  try {
    var st = JSON.parse(sessionStorage.getItem(store) || "null");
    if (st) {
      var open = {}; st.open.forEach(function (k) { open[k] = 1; });
      keys().forEach(function (x) { if (open[x.k]) x.d.open = true; });
      window.scrollTo(0, st.y || 0);
    }
  } catch (e) {}
  document.addEventListener("toggle", save, true);
  var timer = null;
  window.addEventListener("scroll", function () { clearTimeout(timer); timer = setTimeout(save, 200); });
  window.addEventListener("pagehide", save);
})();
</script>
</body></html>
"""


def main():
    src, dst = sys.argv[1], sys.argv[2]
    md = open(src, encoding="utf-8", errors="replace").read()
    title = next((re.sub(r"[*_~`]", "", l[3:]) for l in md.split("\n") if l.startswith("## ")), "Market")
    page = PAGE % {"title": esc(title), "body": body(md)}
    tmp = dst + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(page)
    os.replace(tmp, dst)


if __name__ == "__main__":
    main()
