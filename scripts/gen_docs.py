#!/usr/bin/env python3
"""Generate a self-contained, styled API-reference site (docs/index.html) for
gh-pages from the package sources' `///` doc comments. Reproducible: reads the
.mbt files, so the docs never drift from the code."""
import re, html, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECTIONS = [
    ("schema", "schema/schema.mbt", "Schema & SDL",
     "Code-first GraphQL: build object types and fields, then to_sdl emits the "
     "schema SDL. GqlType covers scalars, named refs, NonNull and List wrappers."),
    ("lexer", "lang/lexer.mbt", "Query Lexer",
     "Hand-written GraphQL lexer: turns a query string into names, punctuators, "
     "int/float/string tokens (block strings dedented per spec), ignoring "
     "whitespace, commas and comments. Pure logic, no core/lexbuf dependency."),
    ("ast", "lang/ast.mbt", "Document AST",
     "The executable-document AST (operations, selection sets, fields, "
     "arguments, variables, fragments, directives, input values), with to_query "
     "printers that render each node back to canonical GraphQL."),
    ("parser", "lang/parser.mbt", "Query Parser",
     "Recursive-descent parser: parse(source) builds a Document from operations "
     "(query/mutation/subscription and the { ... } shorthand), fields with "
     "aliases/arguments/directives, variable definitions, and named/inline "
     "fragments — the front half of the executor."),
    ("error", "lang/error.mbt", "Errors",
     "GqlError, the error shape the specification's response section defines: "
     "a message, the path into the result and the source locations. Validation "
     "and execution both report in it, which is why it sits with the language "
     "rather than with either stage."),
    ("fragments", "lang/fragments.mbt", "Fragments",
     "collect_fragments gathers a document's fragment definitions by name; "
     "validation and execution both resolve spreads against it."),
    ("builtin", "schema/builtin.mbt", "Built-in Types",
     "What the specification fixes for every schema: the five built-in scalars, "
     "the meta-fields __typename, __schema and __type, and the introspection "
     "object types those meta-fields return."),
    ("validate", "valid/validate.mbt", "Validator",
     "Validate a Document against the Schema before execution: fields and "
     "arguments exist, leaf vs composite selection sets, fragment spreads and "
     "type conditions resolve, and referenced variables are defined. Errors are "
     "collected, not raised."),
    ("validate_rules", "valid/validate_rules.mbt", "Validation Rules",
     "The document-level slice of the GraphQL validation table (spec §5): operation-name "
     "uniqueness and lone anonymous operation, fragment-name uniqueness, "
     "no-unused-fragments, fragment-spread cycle detection, and the variable-use "
     "collector behind the all-variables-used rule."),
    ("directives", "schema/directives.mbt", "Directives",
     "The directive extension points: AppliedDirective records a directive use on "
     "a schema element (federation's @key / @shareable / @inaccessible / "
     "@override live here); DirectiveDef declares a custom directive with valid "
     "locations, args, repeatability and an optional on_field execution hook that "
     "transforms a resolved field value."),
    ("execute", "exec/execute.mbt", "Executor",
     "execute() runs a query end to end: parse, validate, then walk the document "
     "with a resolver map ((ResolveInfo) -> Json keyed by \"Type.field\"), "
     "supporting variables, aliases, fragments, @skip/@include, non-null error "
     "propagation and list/object results — returning { data, errors } as JSON."),
    ("convert", "exec/convert.mbt", "Conversions",
     "ToGql and FromGql carry a MoonBit value into a result and back out of an "
     "argument or a parent value; ResolveInfo::read reads an argument as any "
     "FromGql type, and field_error turns any error a resolver raised into a "
     "field error. The #gql generator writes both traits for each annotated type."),
    ("introspection", "exec/introspection.mbt", "Introspection",
     "Answer __schema / __type / __typename from the schema: the introspection "
     "type system materialised as JSON that the executor walks like any object, "
     "with ofType wrapper chains, fields, interfaces, possibleTypes and enum "
     "values."),
    ("subscribe", "exec/subscribe.mbt", "Subscriptions",
     "execute_subscription runs a single-root-field subscription against a source "
     "stream (a pull source returning Array[Json]) and returns the ordered "
     "{ data, errors } payloads a client receives — the sync core the async "
     "WebSocket variant wraps."),
    ("dataloader", "loader/dataloader.mbt", "DataLoader",
     "Batch-and-cache loader for the N+1 problem: keys requested in a resolution "
     "pass are queued and deduped, then one dispatch runs the batch function over "
     "the distinct keys and fills a per-loader cache. Includes prime, clear and "
     "load_many/load_now."),
    ("server", "server/server.mbt", "HTTP Endpoint",
     "graphql_handler / graphql_app wire a schema onto the moonasgi seam: GET "
     "serves the GraphiQL IDE, POST reads a { query, variables, operationName } "
     "body and returns { data, errors }. Plugs into mooncat and runs on every "
     "backend through moonasgi's TestClient."),
    ("federation", "federation/federation.mbt", "Apollo Federation",
     "Federation v1 and v2 subgraph support: register @key entities and their "
     "reference resolvers, then apply installs _service { sdl }, the _Any scalar, "
     "the _Entity union and the _entities(representations) resolver. v2 opts in "
     "with @link and adds @shareable / @inaccessible / @override / @requires / "
     "@provides on fields, rendered into the subgraph SDL."),
    ("ide", "server/ide.mbt", "Built-in IDE",
     "The IDE the endpoint serves on a GET without a query: GraphiQL, Apollo "
     "Sandbox or Altair, chosen with one value. Each page is built here with its "
     "assets pinned to an exact version, and the subscription socket is derived "
     "from the page's own location unless you name one."),
    ("of_sdl", "schema/parse_sdl.mbt", "Reading SDL",
     "The other direction: build a Schema from SDL text. print-then-parse is a "
     "round trip, so a schema written as SDL and the same schema built in code "
     "print identically; a definition that stops mid-way reports the line and "
     "column where it stopped."),
    ("gqlws", "server/gqlws.mbt", "graphql-transport-ws",
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
            # `let x : T = { .. }` loses its body above, and `extend T with Eq::`
            # loses its method list; neither dangling tail reads as source.
            core = re.sub(r"\s*=\s*$", "", core).rstrip()
            core = re.sub(r"::\s*$", "", core).rstrip()
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
  --bg:#07060a; --panel:#100d17; --panel-2:#151120; --ink:#e9e3d4;
  --muted:#9b917c; --line:rgba(201,168,76,.26); --accent:#c9a84c; --accent-soft:rgba(201,168,76,.14);
  --out:#eed89b; --code-bg:#0d0b12; --bronze:#c9a84c; --query:#4a90d9;
  /* the names theme.css uses, so rules can be lifted across without renaming */
  --gold:#c9a84c; --gold-hi:#eed89b; --gold-hair:rgba(201,168,76,.26); --gold-dim:rgba(201,168,76,.34);
  --serif:"Cormorant Garamond",ui-serif,Georgia,serif;
  --display:"Cormorant Garamond",ui-serif,Georgia,serif;
  --caps:"Cinzel",ui-serif,Georgia,serif;
  --sans:"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --shadow:0 1px 0 rgba(0,0,0,.6),0 30px 80px -50px rgba(0,0,0,.9);
}
:root[data-theme=light]{
  --bg:#efe9dc; --panel:#f6f1e5; --panel-2:#eee7d6; --ink:#211c14;
  --muted:#6b6153; --line:rgba(138,106,42,.3); --accent:#8a6a2a; --accent-soft:rgba(138,106,42,.12);
  --out:#a8823a; --code-bg:#e8e0cd; --bronze:#8a6a2a; --query:#2f6ea8;
  --gold:#856527; --gold-hi:#946d2c; --gold-hair:rgba(133,101,39,.22); --gold-dim:rgba(133,101,39,.38);
  --shadow:0 1px 0 rgba(31,26,20,.06),0 24px 60px -40px rgba(31,26,20,.35);
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){html{scroll-behavior:auto}*{animation:none!important;transition:none!important}}
body{margin:0;background:var(--bg);color:var(--ink);
  font-family:var(--sans);font-size:15.5px;line-height:1.68;-webkit-font-smoothing:antialiased}
code,pre,.mono{font-family:var(--mono)}
:root{
  --serif:"Fraunces",ui-serif,Georgia,"Times New Roman",serif;
  --sans:"Inter",system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
.layout{display:grid;grid-template-columns:264px minmax(0,1fr);max-width:1120px;margin:0 auto}
.sidebar{position:sticky;top:64px;align-self:start;height:calc(100vh - 64px);overflow-y:auto;
  border-right:1px solid var(--line);padding:1.6rem 1.1rem 2rem;background:var(--panel-2)}
.brand{display:flex;align-items:center;gap:.55rem;font-family:var(--mono);font-weight:600;
  font-size:1.2rem;letter-spacing:-.01em;color:var(--ink);margin-bottom:.15rem}
.brand .dot{width:11px;height:11px;border-radius:50%;background:var(--accent);box-shadow:0 0 0 4px var(--accent-soft)}
.brand-sub{color:var(--muted);font-size:.8rem;margin:0 0 1.3rem;padding-left:.15rem}
.side-nav{display:flex;flex-direction:column;gap:.1rem;position:relative}
/* one dashed spine down the rail; the current section is the gem on it */
.side-nav::before{content:"";position:absolute;left:.5rem;top:.35rem;bottom:.35rem;width:1px;
  background:repeating-linear-gradient(180deg,var(--accent) 0 3px,transparent 3px 7px);
  opacity:.26}
.side-nav a{position:relative;color:var(--muted);font-size:.9rem;
  padding:.32rem .6rem .32rem 1.3rem;border-radius:2px;
  font-family:var(--sans);display:flex;align-items:center;gap:.4rem}
.side-nav a .at{color:var(--accent);opacity:.6}
.side-nav a:hover{color:var(--ink);text-decoration:none}
.side-nav a::after{content:"";position:absolute;left:.5rem;top:50%;width:5px;height:5px;
  background:var(--rule,var(--accent));transform:translate(-50%,-50%) rotate(45deg) scale(0);
  transition:transform .18s ease;box-shadow:0 0 6px color-mix(in oklab,var(--rule,var(--accent)) 75%,transparent)}
.side-nav a.active{color:var(--ink);font-weight:500}
.side-nav a.active::after{transform:translate(-50%,-50%) rotate(45deg) scale(1)}
.side-nav a.active .at{opacity:1}
/* at night the rail is bronze and the current section is the violet one */
:root[data-theme=dark] .side-nav a{color:color-mix(in oklab,var(--accent) 58%,var(--muted))}
:root[data-theme=dark] .side-nav a:hover{color:var(--ink)}
:root[data-theme=dark] .side-nav a.active{--rule:var(--query)}
:root[data-theme=dark] .side-nav a.active .at{color:var(--query);opacity:1}
.side-foot{margin-top:1.6rem;padding-top:1.1rem;border-top:1px solid var(--line);display:flex;flex-wrap:wrap;gap:.4rem}
.side-foot img{height:20px;display:block}
/* the toggle wears the same plate as the one on every other page */
.theme-btn{margin-top:1rem;background:none;border:1px solid var(--gold-hair);color:var(--muted);
  border-radius:2px;padding:.3rem .55rem;font-family:var(--caps);font-size:.64rem;
  letter-spacing:.14em;text-transform:uppercase;cursor:pointer;width:100%;
  transition:color .25s,border-color .25s}
.theme-btn:hover{color:var(--gold-hi);border-color:var(--gold-dim)}
main{padding:2.6rem 2.4rem 5rem;min-width:0}
.hero h1{font-family:var(--display);font-weight:500;font-size:2.9rem;letter-spacing:-.02em;margin:0}
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
.contract .k{color:var(--accent);font-weight:500}.contract .ty{color:var(--query)}.contract .op{color:var(--muted)}
section.pkg{scroll-margin-top:1.2rem;padding-top:2.4rem;margin-top:2rem;border-top:1px solid var(--line)}
section.pkg > h2{font-family:var(--display);font-weight:500;font-size:1.75rem;margin:0 0 .15rem;letter-spacing:-.01em}
section.pkg > h2 .at{color:var(--accent);margin-right:.45em}
.pdesc{color:var(--muted);margin:.15rem 0 1.2rem;max-width:72ch}
.item{background:var(--panel);border:1px solid var(--line);border-radius:13px;
  padding:1rem 1.2rem;margin:.85rem 0;box-shadow:var(--shadow);transition:border-color .15s,transform .15s}
.item:hover{border-color:color-mix(in oklab,var(--accent) 40%,var(--line))}
.kind{display:inline-block;font-size:.66rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;
  border-radius:6px;padding:.1rem .45rem;margin-bottom:.55rem;
  color:var(--accent);background:var(--accent-soft);border:1px solid color-mix(in oklab,var(--accent) 26%,transparent)}
.item .kind{color:var(--accent);background:var(--accent-soft);
  border-color:color-mix(in oklab,var(--bronze) 30%,transparent)}
.sig{font-size:.98rem;margin:0 0 .55rem;overflow-x:auto;white-space:pre;color:var(--ink);padding-bottom:.15rem}
.sig .k{color:var(--accent);font-weight:500}.sig .ty{color:var(--query)}.sig .op{color:var(--muted)}
.doc{margin:0;color:var(--ink);max-width:76ch}
.doc code{background:var(--code-bg);padding:.06rem .35rem;border-radius:5px;font-size:.9em;color:var(--accent)}
footer{margin-top:3rem;padding-top:1.3rem;border-top:1px solid var(--line);color:var(--muted);font-size:.9rem}
/* ---------- top bar, the same five links on every page ---------- */
.topbar{position:sticky;top:0;z-index:20;backdrop-filter:blur(8px);
  background:color-mix(in oklab,var(--bg) 86%,transparent);border-bottom:1px solid var(--line)}
.topbar .brand-link{display:flex;align-items:center;color:var(--accent)}
.topbar .mark{width:22px;height:22px;display:block}
.topbar .in{display:flex;align-items:center;gap:1.1rem;height:64px;max-width:1120px;margin:0 auto;
  padding:0 1.5rem}
.topbar .sub{font-family:var(--sans);font-size:.66rem;letter-spacing:.14em;color:var(--muted);
  text-transform:uppercase;border-left:1px solid var(--gold-hair);padding-left:.6rem;margin-left:.2rem}
.topbar .name{font-family:var(--caps);font-weight:500;font-size:.92rem;letter-spacing:.22em;text-transform:uppercase;color:var(--ink)}
/* the same nav as the other three pages: same rhythm, same sweeping rule */
.topbar nav{margin-left:auto;display:flex;align-items:center;gap:1.35rem}
.topbar nav a{font-family:var(--caps);font-size:.7rem;letter-spacing:.2em;text-transform:uppercase;
  color:var(--muted);position:relative;padding:.2rem 0}
.topbar nav a::after{content:"";position:absolute;left:0;right:0;bottom:-2px;height:1px;
  background:var(--gold);transform:scaleX(0);transform-origin:left;transition:transform .3s}
.topbar nav a:hover{color:var(--ink);text-decoration:none}
.topbar nav a:hover::after,.topbar nav a[aria-current]::after{transform:scaleX(1)}
.topbar nav a[aria-current]{color:var(--gold-hi)}
.theme-btn.top{width:auto;margin:0}

/* ---------- chrome shared by every page ---------- */
html, button, input, textarea, select { font-variant-ligatures: no-contextual; }
@supports selector(::-webkit-scrollbar) {
  html::-webkit-scrollbar, .sidebar::-webkit-scrollbar, .sig::-webkit-scrollbar,
  pre::-webkit-scrollbar { width: 10px; height: 10px; }
  html::-webkit-scrollbar-track, .sidebar::-webkit-scrollbar-track,
  .sig::-webkit-scrollbar-track, pre::-webkit-scrollbar-track { background: transparent; }
  html::-webkit-scrollbar-thumb, .sidebar::-webkit-scrollbar-thumb,
  .sig::-webkit-scrollbar-thumb, pre::-webkit-scrollbar-thumb {
    border-radius: 99px; border: 3px solid transparent; background-clip: content-box;
    background-color: color-mix(in srgb, var(--ink) 24%, transparent); }
  html:not(.scrolled)::-webkit-scrollbar-thumb { background-color: transparent; }
}
@supports not selector(::-webkit-scrollbar) {
  html { scrollbar-width: thin;
    scrollbar-color: color-mix(in srgb, var(--ink) 26%, transparent) transparent; }
  html:not(.scrolled) { scrollbar-color: transparent transparent; }
}
p, li, .doc { overflow-wrap: anywhere; }

@media (max-width:820px){
  /* the bar wraps exactly the way it does on the other three pages */
  .topbar .in{height:auto;flex-wrap:wrap;padding:.6rem 1.5rem;row-gap:.5rem;position:relative}
  .topbar .sub{display:none}
  .topbar .name{max-width:calc(100% - 5rem)}
  .topbar nav{margin-left:0;width:100%;justify-content:flex-start;flex-wrap:wrap;gap:.5rem .95rem}
  .theme-btn.top{position:absolute;top:.55rem;right:1.4rem;margin:0}
  .layout{grid-template-columns:1fr}
  .sidebar{position:static;height:auto;border-right:none;border-bottom:1px solid var(--line)}
  .side-nav{flex-flow:row wrap}.side-nav::before{display:none}.side-nav a{padding-left:.55rem}.side-nav a::after{display:none}
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
  // the rail marks the last section whose heading has passed the top: the same
  // rule at load, mid-scroll and at the foot of the page
  const sections=[...document.querySelectorAll("section.pkg")];
  const mark=()=>{
    if(!sections.length)return;
    let pick=sections[0].id;
    sections.forEach(s=>{if(s.getBoundingClientRect().top<=140)pick=s.id;});
    if(scrollY+innerHeight>=document.documentElement.scrollHeight-4)pick=sections[sections.length-1].id;
    links.forEach(a=>a.classList.toggle("active",a.getAttribute("href")==="#"+pick));
  };
  mark();
  addEventListener("scroll",mark,{passive:true});
  const root=document.documentElement;
  const scrolled=()=>root.classList.toggle("scrolled",scrollY>0);
  addEventListener("scroll",scrolled,{passive:true});
  scrolled();
  const tb=document.getElementById("theme");
  const paint=mode=>{root.setAttribute("data-theme",mode);
    if(tb){tb.textContent=mode==="light"?"◑ day":"◐ night";
      tb.setAttribute("aria-label","switch to "+(mode==="light"?"night":"day")+" theme");}};
  paint(root.getAttribute("data-theme")==="light"?"light":"dark");
  if(tb)tb.addEventListener("click",()=>{
    const cur=root.getAttribute("data-theme")==="light"?"dark":"light";
    paint(cur);try{localStorage.setItem("moongql-theme",cur)}catch(e){}});
});
"""

CONTRACT = """let s = Schema::new()
let q = s.object("Query")
q.field("hello", NonNull(Scalar("String")))

let sdl = s.to_sdl()   // "schema { query: Query }  type Query { hello: String! }" """


def interface_names():
    """Every public name the compiler reports, per package interface."""
    names = set()
    paths = [ROOT / "src" / "pkg.generated.mbti"] + sorted(
        p for p in (ROOT / "src").glob("*/pkg.generated.mbti")
    )
    for path in paths:
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r"pub(?:\(all\))?\s+(?:fn|struct|enum|type|let|suberror|trait)\s+(?:\[[^]]*\]\s*)?([A-Za-z_][A-Za-z0-9_]*)", line)
            if m:
                names.add(m.group(1).split("::")[-1])
    return names


def esc(t):
    return html.escape(t)


def main():
    HEAD = ('<!doctype html><html lang="en" data-theme="dark"><head><meta charset="utf-8">'
            '<script>'
            '(function(){var m=null;try{var q=new URLSearchParams(location.search).get("theme");'
            'if(q==="light"||q==="dark"){m=q;localStorage.setItem("moongql-theme",q)}'
            'else m=localStorage.getItem("moongql-theme")}catch(e){}'
            'if(m!=="light"&&m!=="dark"){m=(window.matchMedia&&'
            'window.matchMedia("(prefers-color-scheme: light)").matches)?"light":"dark"}'
            'document.documentElement.setAttribute("data-theme",m)})();'
            '</script>'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>moongql — API reference</title>'
            '<meta name="description" content="Every public interface of moongql, generated from the source: schema, lexer, parser, validator, executor, dataloader and the HTTP endpoint.">'
            '<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns=\'http://www.w3.org/2000/svg\' viewBox=\'0 0 32 32\'%3E%3Crect x=\'3.5\' y=\'3.5\' width=\'25\' height=\'25\' fill=\'none\' stroke=\'%23c9a84c\' stroke-width=\'1\'/%3E%3Crect x=\'7.5\' y=\'7.5\' width=\'17\' height=\'17\' fill=\'none\' stroke=\'%23c9a84c\' stroke-width=\'.6\' opacity=\'.6\'/%3E%3Ccircle cx=\'16\' cy=\'16\' r=\'4\' fill=\'%23e9e3d4\'/%3E%3C/svg%3E">'
            '<link rel="preconnect" href="https://fonts.googleapis.com">'
            '<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>'
            '<link href="https://fonts.googleapis.com/css2?family=Cinzel:wght@400;500;600&'
            'family=Cormorant+Garamond:ital,wght@0,300;0,400;0,500;0,600;1,400&'
            'family=Inter:wght@300;400;500&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">'
            '<style>' + CSS + '</style></head><body>')

    TOP = ('<header class="topbar"><div class="in">'
           '<a href="index.html" class="brand-link"><svg class=\"mark\" viewBox=\"0 0 32 32\" aria-hidden=\"true\"><rect x=\"3.5\" y=\"3.5\" width=\"25\" height=\"25\" fill=\"none\" stroke=\"var(--bronze)\" stroke-width=\"1\"/><rect x=\"7.5\" y=\"7.5\" width=\"17\" height=\"17\" fill=\"none\" stroke=\"var(--bronze)\" stroke-width=\".6\" opacity=\".55\"/><circle cx=\"16\" cy=\"16\" r=\"3.2\" fill=\"currentColor\"/><circle cx=\"16\" cy=\"16\" r=\"6.2\" fill=\"none\" stroke=\"var(--bronze)\" stroke-width=\".5\" opacity=\".45\"/></svg></a>'
           '<a class="name" href="index.html">moongql</a>'
           '<span class="sub">GraphQL &middot; MoonBit</span>'
           '<nav><a href="index.html">Home</a><a href="guide.html">Guide</a>'
           '<a href="api.html" aria-current="page">API</a>'
           '<a href="showcase.html">Showcase</a>'
           '<a href="https://github.com/moonbitstack/moongql">GitHub</a>'
           '<button class="theme-btn top" id="theme">◐ night</button></nav>'
           '</div></header>')

    side = ['<aside class="sidebar">'
            '<p class="brand-sub">MoonBit GraphQL — API reference</p><nav class="side-nav">']
    side += ['<a href="#%s"><span class="at">§</span>%s</a>' % (sid, title)
             for sid, _, title, _ in SECTIONS]
    side += ['</nav>'
             '<div class="side-foot">'
             '<a href="https://mooncakes.io/docs/moonbitstack/moongql">mooncakes</a>'
             '<a href="https://github.com/moonbitstack/moongql">GitHub</a>'
             '</div></aside>']

    hero = ('<main><header class="hero"><h1>moongql</h1>'
            '<p class="tag">A code-first GraphQL library for MoonBit: define object types and '
            'fields in code and print the schema SDL, then read SDL back into the same schema.</p>'
            '<div class="install"><span class="prompt">$</span><code>moon add moonbitstack/moongql</code>'
            '<button class="copy" data-copy="moon add moonbitstack/moongql">copy</button></div>'
            '<div class="contract"><h2><span class="spark">&#10038;</span> A schema in four lines</h2>'
            '<pre>' + tint(CONTRACT) + '</pre></div></header>')

    body = [HEAD, TOP, '<div class="layout">'] + side + [hero]
    total = 0
    for sid, rel, title, desc in SECTIONS:
        body.append('<section class="pkg" id="%s"><h2><span class="at">§</span>%s</h2>'
                    '<p class="pdesc">%s</p>' % (sid, title, esc(desc)))
        for kind, sig, doc in parse(ROOT / "src" / rel):
            total += 1
            body.append('<div class="item" data-k="%s"><span class="kind">%s</span>'
                        '<pre class="sig">%s</pre>%s</div>'
                        % (kind, kind, tint(sig), ('<p class="doc">%s</p>' % prose(doc)) if doc else ''))
        body.append('</section>')
    body.append('<footer>Generated from source <code>///</code> doc-comments · '
                '<a href="https://mooncakes.io/docs/moonbitstack/moongql">mooncakes</a> · '
                '<a href="https://github.com/moonbitstack/moongql">GitHub</a> · Apache-2.0 &#169; Leo Cheng</footer>')
    body.append('</main></div><script>' + JS + '</script></body></html>')

    out = ROOT / "docs" / "api.html"
    out.parent.mkdir(exist_ok=True)
    out.write_text("\n".join(body), encoding="utf-8")

    # Every public name in the package interfaces has to appear on the page.
    # A section that forgets a file shows up here rather than as a reader's
    # surprise, and the docs workflow runs this script again and diffs.
    documented = set()
    for _, rel, _, _ in SECTIONS:
        for _, sig, _ in parse(ROOT / "src" / rel):
            documented.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", sig))
    missing = sorted(interface_names() - documented)
    print("wrote %s (%d public items across %d sections)" % (out, total, len(SECTIONS)))
    if missing:
        print("not documented: " + ", ".join(missing))
        raise SystemExit(1)
    print("every public interface name appears on the page")


if __name__ == "__main__":
    main()
