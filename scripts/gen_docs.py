#!/usr/bin/env python3
"""Generate a self-contained, styled API-reference site (docs/index.html) for
gh-pages from the package sources' `///` doc comments. Reproducible: reads the
.mbt files, so the docs never drift from the code."""
import re, html, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECTIONS = [
    ("schema", "schema.mbt", "Schema & SDL",
     "Code-first GraphQL: build object types and fields, then to_sdl emits the "
     "schema SDL. GqlType covers scalars, named refs, NonNull and List wrappers."),
    ("lexer", "lexer.mbt", "Query Lexer",
     "Hand-written GraphQL lexer: turns a query string into names, punctuators, "
     "int/float/string tokens (block strings dedented per spec), ignoring "
     "whitespace, commas and comments. Pure logic, no core/lexbuf dependency."),
    ("ast", "ast.mbt", "Document AST",
     "The executable-document AST (operations, selection sets, fields, "
     "arguments, variables, fragments, directives, input values), with to_query "
     "printers that render each node back to canonical GraphQL."),
    ("parser", "parser.mbt", "Query Parser",
     "Recursive-descent parser: parse(source) builds a Document from operations "
     "(query/mutation/subscription and the { ... } shorthand), fields with "
     "aliases/arguments/directives, variable definitions, and named/inline "
     "fragments — the front half of the executor."),
    ("validate", "validate.mbt", "Validator",
     "Validate a Document against the Schema before execution: fields and "
     "arguments exist, leaf vs composite selection sets, fragment spreads and "
     "type conditions resolve, and referenced variables are defined. Errors are "
     "collected, not raised."),
    ("validate_rules", "validate_rules.mbt", "Validation Rules (spec §5)",
     "The document-level slice of the GraphQL validation table: operation-name "
     "uniqueness and lone anonymous operation, fragment-name uniqueness, "
     "no-unused-fragments, fragment-spread cycle detection, and the variable-use "
     "collector behind the all-variables-used rule."),
    ("directives", "directives.mbt", "Directives",
     "The directive extension points: AppliedDirective records a directive use on "
     "a schema element (federation's @key / @shareable / @inaccessible / "
     "@override live here); DirectiveDef declares a custom directive with valid "
     "locations, args, repeatability and an optional on_field execution hook that "
     "transforms a resolved field value."),
    ("execute", "execute.mbt", "Executor",
     "execute() runs a query end to end: parse, validate, then walk the document "
     "with a resolver map ((ResolveInfo) -> Json keyed by \"Type.field\"), "
     "supporting variables, aliases, fragments, @skip/@include, non-null error "
     "propagation and list/object results — returning { data, errors } as JSON."),
    ("introspection", "introspection.mbt", "Introspection",
     "Answer __schema / __type / __typename from the schema: the introspection "
     "type system materialised as JSON that the executor walks like any object, "
     "with ofType wrapper chains, fields, interfaces, possibleTypes and enum "
     "values."),
    ("subscribe", "subscribe.mbt", "Subscriptions",
     "execute_subscription runs a single-root-field subscription against a source "
     "stream (a pull source returning Array[Json]) and returns the ordered "
     "{ data, errors } payloads a client receives — the sync core the async "
     "WebSocket variant wraps."),
    ("dataloader", "dataloader.mbt", "DataLoader",
     "Batch-and-cache loader for the N+1 problem: keys requested in a resolution "
     "pass are queued and deduped, then one dispatch runs the batch function over "
     "the distinct keys and fills a per-loader cache. Includes prime, clear and "
     "load_many/load_now."),
    ("server", "server.mbt", "HTTP Endpoint",
     "graphql_handler / graphql_app wire a schema onto the moonasgi seam: GET "
     "serves the GraphiQL IDE, POST reads a { query, variables, operationName } "
     "body and returns { data, errors }. Plugs into mooncat and runs on every "
     "backend through moonasgi's TestClient."),
    ("federation", "federation.mbt", "Apollo Federation",
     "Federation v1 and v2 subgraph support: register @key entities and their "
     "reference resolvers, then apply installs _service { sdl }, the _Any scalar, "
     "the _Entity union and the _entities(representations) resolver. v2 opts in "
     "with @link and adds @shareable / @inaccessible / @override / @requires / "
     "@provides on fields, rendered into the subgraph SDL."),
    ("gqlws", "gqlws.mbt", "graphql-transport-ws",
     "The WebSocket subprotocol a subscription client speaks: connection_init and "
     "its ack, ping/pong, subscribe with single-use operation ids, and the next / "
     "error / complete messages a running operation produces."),
]
KIND = {"struct": "struct", "enum": "enum", "fn": "fn", "type": "type", "let": "let"}


def parse(path):
    items, doc = [], []
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        s = lines[i].strip()
        if s == "///|":
            doc = []
        elif s.startswith("///"):
            doc.append(s[3:].strip())
        elif s.startswith("pub"):
            buf = s
            is_alias = re.match(r"pub\s+(type|let)\b", buf) is not None
            while (not is_alias and "{" not in buf and i + 1 < len(lines)):
                i += 1
                buf += " " + lines[i].strip()
            core = re.sub(r"\s*\{.*$", "", buf)
            core = re.sub(r"^pub(?:\(all\))?\s+", "", core).strip()
            core = re.sub(r"\s+", " ", core).rstrip(",").rstrip()
            core = re.sub(r",\s*\)", ")", core)
            first = core.split(" ")[0] if core else ""
            items.append((KIND.get(first, "item"), core, " ".join(doc).strip()))
            doc = []
        elif s == "":
            pass
        else:
            doc = []
        i += 1
    return items


def tint(sig):
    s = html.escape(sig)
    s = re.sub(r"\b(fn|struct|enum|type|let|async)\b", r'<span class="k">\1</span>', s)
    s = re.sub(r"\b([A-Z][A-Za-z0-9_]*)\b", r'<span class="ty">\1</span>', s)
    s = s.replace("-&gt;", '<span class="op">-&gt;</span>').replace("?", '<span class="op">?</span>')
    return s


def prose(t):
    t = html.escape(t)
    return re.sub(r"`([^`]+)`", r"<code>\1</code>", t)


CSS = r"""
:root{
  --bg:#fbfbfd; --panel:#ffffff; --panel-2:#f6f7fb; --ink:#14181f;
  --muted:#5b6675; --line:#e8ebf1; --accent:#6d5efc; --accent-soft:#efecff; --out:#0ca678;
  --code-bg:#f4f5f9; --shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10);
}
@media (prefers-color-scheme:dark){:root{
  --bg:#0b0e14; --panel:#131722; --panel-2:#0f131c; --ink:#e9edf6; --muted:#96a1b5;
  --line:#212736; --accent:#9d8bff; --accent-soft:#1c1b3a; --out:#2dd4a7;
  --code-bg:#161b26; --shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5);
}}
:root[data-theme=light]{--bg:#fbfbfd;--panel:#fff;--panel-2:#f6f7fb;--ink:#14181f;--muted:#5b6675;--line:#e8ebf1;--accent:#6d5efc;--accent-soft:#efecff;--out:#0ca678;--code-bg:#f4f5f9;--shadow:0 1px 2px rgba(20,24,31,.04),0 8px 24px -12px rgba(20,24,31,.10)}
:root[data-theme=dark]{--bg:#0b0e14;--panel:#131722;--panel-2:#0f131c;--ink:#e9edf6;--muted:#96a1b5;--line:#212736;--accent:#9d8bff;--accent-soft:#1c1b3a;--out:#2dd4a7;--code-bg:#161b26;--shadow:0 1px 2px rgba(0,0,0,.3),0 12px 30px -14px rgba(0,0,0,.5)}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:"IBM Plex Sans",system-ui,-apple-system,Segoe UI,Roboto,sans-serif;
  font-size:15.5px;line-height:1.6;-webkit-font-smoothing:antialiased}
code,pre,.mono{font-family:"IBM Plex Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:grid;grid-template-columns:264px minmax(0,1fr);max-width:1180px;margin:0 auto}
.sidebar{position:sticky;top:0;align-self:start;height:100vh;overflow-y:auto;
  border-right:1px solid var(--line);padding:1.6rem 1.1rem 2rem;background:var(--panel-2)}
.brand{display:flex;align-items:center;gap:.55rem;font-family:"IBM Plex Mono";font-weight:600;
  font-size:1.35rem;letter-spacing:-.01em;color:var(--ink);margin-bottom:.15rem}
.brand .dot{width:11px;height:11px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
.brand-sub{color:var(--muted);font-size:.8rem;margin:0 0 1.3rem;padding-left:.15rem}
.side-nav{display:flex;flex-direction:column;gap:.1rem}
.side-nav a{color:var(--muted);font-size:.9rem;padding:.32rem .6rem;border-radius:8px;
  font-family:"IBM Plex Mono";display:flex;align-items:center;gap:.4rem;border-left:2px solid transparent}
.side-nav a .at{color:var(--accent);opacity:.6}
.side-nav a:hover{background:var(--accent-soft);color:var(--ink);text-decoration:none}
.side-nav a.active{color:var(--ink);background:var(--accent-soft);border-left-color:var(--accent);font-weight:500}
.side-nav a.active .at{opacity:1}
.side-foot{margin-top:1.6rem;padding-top:1.1rem;border-top:1px solid var(--line);display:flex;flex-wrap:wrap;gap:.4rem}
.side-foot img{height:20px;display:block}
.theme-btn{margin-top:1rem;background:none;border:1px solid var(--line);color:var(--muted);
  border-radius:8px;padding:.35rem .6rem;font:inherit;font-size:.82rem;cursor:pointer;width:100%}
.theme-btn:hover{border-color:var(--accent);color:var(--ink)}
main{padding:2.6rem 2.4rem 5rem;min-width:0}
.hero h1{font-family:"IBM Plex Mono";font-weight:600;font-size:2.9rem;letter-spacing:-.02em;margin:0}
.hero .tag{color:var(--muted);font-size:1.12rem;max-width:62ch;margin:.5rem 0 1.1rem;text-wrap:balance}
.badges{display:flex;flex-wrap:wrap;gap:.45rem;margin:0 0 1.4rem}
.badges img{height:21px;display:block}
.install{display:flex;align-items:center;gap:.6rem;background:var(--panel);border:1px solid var(--line);
  border-radius:12px;padding:.65rem 1rem;box-shadow:var(--shadow);max-width:420px}
.install .prompt{color:var(--out);user-select:none;font-weight:600}
.install code{flex:1;font-size:.95rem}
.copy{background:none;border:1px solid var(--line);border-radius:7px;color:var(--muted);
  cursor:pointer;font:inherit;font-size:.72rem;padding:.2rem .5rem}
.copy:hover{border-color:var(--accent);color:var(--accent)}
.copy.ok{color:var(--out);border-color:var(--out)}
.contract{margin:2.1rem 0 .5rem;background:
   radial-gradient(120% 130% at 100% 0%, var(--accent-soft) 0%, transparent 55%), var(--panel);
  border:1px solid var(--line);border-radius:16px;padding:1.2rem 1.4rem;box-shadow:var(--shadow)}
.contract h2{margin:0 0 .6rem;font-size:1.06rem;display:flex;align-items:center;gap:.5rem}
.contract h2 .spark{color:var(--accent)}
.contract pre{margin:0;overflow-x:auto;font-size:.92rem;line-height:1.7}
.contract .k{color:#8b5cf6;font-weight:500}.contract .ty{color:var(--accent)}.contract .op{color:var(--muted)}
section.pkg{scroll-margin-top:1.2rem;padding-top:2.4rem;margin-top:2rem;border-top:1px solid var(--line)}
section.pkg > h2{font-family:"IBM Plex Mono";font-size:1.55rem;margin:0 0 .15rem;letter-spacing:-.01em}
section.pkg > h2 .at{color:var(--accent)}
.pdesc{color:var(--muted);margin:.15rem 0 1.2rem;max-width:72ch}
.item{background:var(--panel);border:1px solid var(--line);border-radius:13px;
  padding:1rem 1.2rem;margin:.85rem 0;box-shadow:var(--shadow);transition:border-color .15s,transform .15s}
.item:hover{border-color:color-mix(in oklab,var(--accent) 40%,var(--line))}
.kind{display:inline-block;font-size:.66rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  border-radius:6px;padding:.1rem .45rem;margin-bottom:.55rem;
  color:var(--accent);background:var(--accent-soft);border:1px solid color-mix(in oklab,var(--accent) 26%,transparent)}
.item[data-k=struct] .kind{--c:#8b5cf6}.item[data-k=fn] .kind{--c:#0ca678}.item[data-k=let] .kind{--c:#2563eb}
.item[data-k=enum] .kind{--c:#d6336c}.item[data-k=type] .kind{--c:#0891b2}
.item .kind{color:var(--c,var(--accent));background:color-mix(in oklab,var(--c,var(--accent)) 13%,transparent);
  border-color:color-mix(in oklab,var(--c,var(--accent)) 30%,transparent)}
.sig{font-size:.98rem;margin:0 0 .55rem;overflow-x:auto;white-space:pre;color:var(--ink);padding-bottom:.15rem}
.sig .k{color:#8b5cf6;font-weight:500}.sig .ty{color:var(--accent)}.sig .op{color:var(--muted)}
@media (prefers-color-scheme:dark){.sig .k,.contract .k{color:#b794ff}}
.doc{margin:0;color:var(--ink);max-width:76ch}
.doc code{background:var(--code-bg);padding:.06rem .35rem;border-radius:5px;font-size:.9em;color:var(--accent)}
footer{margin-top:3rem;padding-top:1.3rem;border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
@media (max-width:820px){
  .layout{grid-template-columns:1fr}
  .sidebar{position:static;height:auto;border-right:none;border-bottom:1px solid var(--line)}
  .side-nav{flex-flow:row wrap}.side-nav a{border-left:none}.side-nav a.active{border-left:none}
  main{padding:1.8rem 1.2rem 4rem}.hero h1{font-size:2.2rem}
}
"""

JS = r"""
document.addEventListener("DOMContentLoaded",()=>{
  document.querySelectorAll("[data-copy]").forEach(btn=>btn.addEventListener("click",()=>{
    navigator.clipboard.writeText(btn.getAttribute("data-copy")).then(()=>{
      const t=btn.textContent;btn.textContent="copied";btn.classList.add("ok");
      setTimeout(()=>{btn.textContent=t;btn.classList.remove("ok");},1100);});}));
  const links=[...document.querySelectorAll(".side-nav a")];
  const map=Object.fromEntries(links.map(a=>[a.getAttribute("href").slice(1),a]));
  const spy=new IntersectionObserver(es=>{es.forEach(e=>{if(e.isIntersecting){
    links.forEach(a=>a.classList.remove("active"));const a=map[e.target.id];if(a)a.classList.add("active");}});},
    {rootMargin:"-10% 0px -80% 0px"});
  document.querySelectorAll("section.pkg").forEach(s=>spy.observe(s));
  const tb=document.getElementById("theme");if(tb)tb.addEventListener("click",()=>{
    const cur=document.documentElement.getAttribute("data-theme")
      ||(matchMedia("(prefers-color-scheme:dark)").matches?"dark":"light");
    document.documentElement.setAttribute("data-theme",cur==="dark"?"light":"dark");});
});
"""

CONTRACT = """let s = Schema::new()
let q = s.object("Query")
q.field("hello", NonNull(Scalar("String")))

let sdl = s.to_sdl()   // "schema { query: Query }  type Query { hello: String! }" """


def esc(t):
    return html.escape(t)


def main():
    HEAD = ('<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>moongql — MoonBit GraphQL API</title>'
            '<link rel="preconnect" href="https://fonts.googleapis.com">'
            '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
            '<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;500;600&'
            'family=IBM+Plex+Sans:wght@400;500;600&display=swap" rel="stylesheet">'
            '<style>' + CSS + '</style></head><body>')

    side = ['<aside class="sidebar"><div class="brand"><span class="dot"></span>moongql</div>'
            '<p class="brand-sub">MoonBit GraphQL — API reference</p><nav class="side-nav">']
    side += ['<a href="#%s"><span class="at">§</span>%s</a>' % (sid, title)
             for sid, _, title, _ in SECTIONS]
    side += ['</nav>'
             '<button class="theme-btn" id="theme">◐ toggle theme</button>'
             '<div class="side-foot">'
             '<a href="https://github.com/moonbitstack/moongql/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moongql/ci.yml?branch=master&label=CI&logo=github"></a>'
             '<a href="https://mooncakes.io/docs/moonbitstack/moongql"><img alt="mooncakes" src="https://img.shields.io/badge/mooncakes-Lfan--ke%2Fmoongql-1f6feb"></a>'
             '</div></aside>']

    hero = ('<main><header class="hero"><h1>moongql</h1>'
            '<p class="tag">A code-first GraphQL library for MoonBit &#8212; define object types and '
            'fields in code and emit the schema SDL, the way strawberry does for Python. '
            'Pure logic, no runtime dependencies.</p>'
            '<div class="badges">'
            '<a href="https://github.com/moonbitstack/moongql/actions"><img alt="CI" src="https://img.shields.io/github/actions/workflow/status/moonbitstack/moongql/ci.yml?branch=master&label=CI&logo=github"></a>'
            '<img alt="tests" src="https://img.shields.io/badge/tests-2%20passing%20%C3%974%20backends-0ca678">'
            '<a href="https://github.com/moonbitstack/moongql"><img alt="GitHub" src="https://img.shields.io/badge/GitHub-source-24292f?logo=github"></a>'
            '<img alt="license" src="https://img.shields.io/badge/license-Apache--2.0-6d5efc"></div>'
            '<div class="install"><span class="prompt">$</span><code>moon add moonbitstack/moongql</code>'
            '<button class="copy" data-copy="moon add moonbitstack/moongql">copy</button></div>'
            '<div class="contract"><h2><span class="spark">&#10038;</span> The contract at a glance</h2>'
            '<pre>' + tint(CONTRACT) + '</pre></div></header>')

    body = [HEAD, '<div class="layout">'] + side + [hero]
    total = 0
    for sid, rel, title, desc in SECTIONS:
        body.append('<section class="pkg" id="%s"><h2><span class="at">§</span>%s</h2>'
                    '<p class="pdesc">%s</p>' % (sid, title, esc(desc)))
        for kind, sig, doc in parse(ROOT / rel):
            total += 1
            body.append('<div class="item" data-k="%s"><span class="kind">%s</span>'
                        '<pre class="sig">%s</pre>%s</div>'
                        % (kind, kind, tint(sig), ('<p class="doc">%s</p>' % prose(doc)) if doc else ''))
        body.append('</section>')
    body.append('<footer>Generated from source <code>///</code> doc-comments · '
                '<a href="https://mooncakes.io/docs/moonbitstack/moongql">mooncakes</a> · '
                '<a href="https://github.com/moonbitstack/moongql">GitHub</a> · Apache-2.0 &#169; Leo Cheng</footer>')
    body.append('</main></div><script>' + JS + '</script></body></html>')

    out = ROOT / "docs" / "index.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(body), encoding="utf-8")
    print("wrote %s (%d public items across %d sections)" % (out, total, len(SECTIONS)))


if __name__ == "__main__":
    main()
