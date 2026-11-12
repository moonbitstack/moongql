// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The schema reference: what the endpoint knows, written down. A `GET` on the
/// endpoint serves it when the `Ide` is `reference`.
///
/// It is rendered from the schema the application holds, not from JSON the page
/// fetches: the types, their fields, the arguments each field takes, the
/// descriptions and the deprecations are already in memory, so the page is one
/// string with nothing to load. That is the difference between this and the four
/// IDEs beside it — they run operations, this one is read.
///
/// The page is the same material as the SDL, arranged for a reader: the root
/// types first, then every other type grouped by kind, each type a section with
/// an anchor a link can point at.

///|
/// Escape the five characters that would otherwise end a text run or an
/// attribute early.
fn html_escape(text : String) -> String {
  let out = StringBuilder()
  for ch in text {
    match ch {
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '&' => out.write_string("&amp;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
/// A link to a type's section, or the name as text when the schema does not
/// declare the type (a built-in scalar, mostly).
fn type_link(schema : @schema.Schema, name : String) -> String {
  let known = schema.type_by_name(name) is Some(_) ||
    schema.enum_by_name(name) is Some(_) ||
    schema.union_by_name(name) is Some(_) ||
    schema.scalar_by_name(name) is Some(_)
  if known {
    "<a class=\"t\" href=\"#" +
    html_escape(name) +
    "\">" +
    html_escape(name) +
    "</a>"
  } else {
    "<span class=\"t\">" + html_escape(name) + "</span>"
  }
}

///|
/// A type as the SDL would write it — `[User!]!` — with every named part a link
/// and the brackets carried as punctuation, so a reader can click into the type
/// a field returns.
fn type_ref_html(schema : @schema.Schema, t : @schema.GqlType) -> String {
  match t {
    Scalar(name) => type_link(schema, name)
    Named(name) => type_link(schema, name)
    NonNull(inner) =>
      type_ref_html(schema, inner) + "<span class=\"p\">!</span>"
    ListOf(inner) =>
      "<span class=\"p\">[</span>" +
      type_ref_html(schema, inner) +
      "<span class=\"p\">]</span>"
  }
}

///|
/// The fields of an object, interface or input type: one row each, with the
/// arguments a field takes spelled out under its name.
fn fields_html(
  schema : @schema.Schema,
  fields : Array[@schema.Field],
) -> String {
  if fields.is_empty() {
    return "<p class=\"empty\">No fields.</p>"
  }
  let out = StringBuilder()
  out.write_string("<div class=\"fields\">")
  for f in fields {
    out.write_string("<div class=\"field\">")
    out.write_string("<div class=\"sig\"><span class=\"fname\">")
    out.write_string(html_escape(f.name))
    out.write_string("</span>")
    if !f.args.is_empty() {
      out.write_string("<span class=\"args\">(")
      let mut first = true
      for a in f.args {
        if !first {
          out.write_string("<span class=\"p\">, </span>")
        }
        first = false
        out.write_string("<span class=\"aname\">")
        out.write_string(html_escape(a.0))
        out.write_string("</span><span class=\"p\">: </span>")
        out.write_string(type_ref_html(schema, a.1))
        match f.arg_defaults.get(a.0) {
          Some(d) => {
            out.write_string("<span class=\"p\"> = </span><span class=\"def\">")
            out.write_string(html_escape(@moonjson.dumps(d)))
            out.write_string("</span>")
          }
          None => ()
        }
      }
      out.write_string(")</span>")
    }
    out.write_string("<span class=\"p\">: </span>")
    out.write_string(type_ref_html(schema, f.typ))
    out.write_string("</div>")
    match f.description {
      Some(d) =>
        out.write_string("<div class=\"desc\">" + html_escape(d) + "</div>")
      None => ()
    }
    match f.deprecation_reason {
      Some(reason) =>
        out.write_string(
          "<div class=\"dep\">Deprecated: " + html_escape(reason) + "</div>",
        )
      None => ()
    }
    out.write_string("</div>")
  }
  out.write_string("</div>")
  out.to_string()
}

///|
/// One directive's section: where a document may write it, the arguments it takes
/// with their defaults, and what it is for. The anchor carries the `@`, so a
/// link into the page names the directive the way a document would.
fn directive_section(
  schema : @schema.Schema,
  d : @schema.DirectiveDef,
) -> String {
  let body = StringBuilder()
  body.write_string("<p class=\"impl\">Locations: ")
  let mut first = true
  for loc in d.locations {
    if !first {
      body.write_string("<span class=\"p\"> \u{b7} </span>")
    }
    first = false
    body.write_string("<code>" + html_escape(loc) + "</code>")
  }
  if d.is_repeatable {
    body.write_string(
      "<span class=\"p\"> \u{b7} </span><code>repeatable</code>",
    )
  }
  body.write_string("</p>")
  if d.args.is_empty() {
    body.write_string("<p class=\"empty\">No arguments.</p>")
  } else {
    body.write_string("<div class=\"fields\">")
    for a in d.args {
      body.write_string(
        "<div class=\"field\"><div class=\"sig\"><span class=\"aname\">",
      )
      body.write_string(html_escape(a.0))
      body.write_string("</span><span class=\"p\">: </span>")
      body.write_string(type_ref_html(schema, a.1))
      match d.arg_defaults.get(a.0) {
        Some(v) => {
          body.write_string("<span class=\"p\"> = </span><span class=\"def\">")
          body.write_string(html_escape(@moonjson.dumps(v)))
          body.write_string("</span>")
        }
        None => ()
      }
      body.write_string("</div></div>")
    }
    body.write_string("</div>")
  }
  type_section(
    schema,
    "@" + d.name,
    "DIRECTIVE",
    d.description,
    [],
    body.to_string(),
    anchor="directive-" + d.name,
  )
}

///|
/// One type's section: the heading with its kind, the description, the
/// interfaces it implements, and the body each kind of type has.
fn type_section(
  schema : @schema.Schema,
  name : String,
  kind : String,
  description : String?,
  implements : Array[String],
  body : String,
  anchor? : String,
) -> String {
  let out = StringBuilder()
  let id = match anchor {
    Some(a) => a
    None => name
  }
  out.write_string("<section class=\"type\" id=\"" + html_escape(id) + "\">")
  out.write_string("<h2><span class=\"name\">" + html_escape(name) + "</span>")
  out.write_string("<span class=\"kind\">" + html_escape(kind) + "</span></h2>")
  match description {
    Some(d) => out.write_string("<p class=\"lede\">" + html_escape(d) + "</p>")
    None => ()
  }
  if !implements.is_empty() {
    out.write_string("<p class=\"impl\">Implements ")
    let mut first = true
    for i in implements {
      if !first {
        out.write_string("<span class=\"p\">, </span>")
      }
      first = false
      out.write_string(type_link(schema, i))
    }
    out.write_string("</p>")
  }
  out.write_string(body)
  out.write_string("</section>")
  out.to_string()
}

///|
/// The stylesheet. One set of variables, a serif for prose, a mono for
/// signatures, and every scrollable region — the page, the rail, a field row that
/// runs long — carrying the site's own bar rather than the browser's.
fn reference_style() -> String {
  let css =
    #|<style>
    #|  :root{
    #|    --bg:#07060a; --panel:#100d17; --panel-2:#151120;
    #|    --ink:#e9e3d4; --muted:#9b917c; --faint:#6d6555;
    #|    --gold:#c9a84c; --gold-hi:#eed89b; --hair:rgba(201,168,76,.22);
    #|    --serif:"Cormorant Garamond",ui-serif,Georgia,serif;
    #|    --caps:"Cinzel",ui-serif,Georgia,serif;
    #|    --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
    #|    --sans:Inter,system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
    #|  }
    #|  *{box-sizing:border-box}
    #|  html,body{margin:0;background:var(--bg);color:var(--ink)}
    #|  body{font-family:var(--sans);font-size:15px;line-height:1.6;-webkit-font-smoothing:antialiased}
    #|  a{color:var(--gold-hi);text-decoration:none}
    #|  a:hover{color:#fff;text-decoration:underline;text-underline-offset:3px}
    #|  header.top{position:sticky;top:0;z-index:5;display:flex;align-items:center;gap:18px;
    #|    padding:14px 26px;background:color-mix(in srgb,var(--bg) 88%,transparent);
    #|    border-bottom:1px solid var(--hair);backdrop-filter:blur(8px)}
    #|  header.top .mark{font-family:var(--caps);letter-spacing:.18em;text-transform:uppercase;
    #|    font-size:12px;color:var(--gold)}
    #|  header.top .mark b{display:block;font-weight:500;font-size:16px;letter-spacing:.06em;
    #|    text-transform:none;color:var(--ink);font-family:var(--serif)}
    #|  header.top .endpoint{font-family:var(--mono);font-size:12px;color:var(--muted);
    #|    overflow-wrap:anywhere}
    #|  header.top form{margin-left:auto}
    #|  header.top input{width:250px;max-width:42vw;padding:7px 11px;border-radius:2px;
    #|    border:1px solid var(--hair);background:var(--panel);color:var(--ink);
    #|    font-family:var(--mono);font-size:12px;outline:none}
    #|  header.top input:focus{border-color:var(--gold);box-shadow:0 0 0 2px rgba(201,168,76,.15)}
    #|  .shell{display:grid;grid-template-columns:minmax(0,236px) minmax(0,1fr);gap:0}
    #|  nav.rail{position:sticky;top:57px;align-self:start;height:calc(100dvh - 57px);
    #|    overflow-y:auto;padding:22px 14px 60px 26px;border-right:1px solid var(--hair)}
    #|  nav.rail .group{margin:0 0 20px}
    #|  nav.rail .group h3{margin:0 0 6px;font-family:var(--caps);font-size:11px;
    #|    letter-spacing:.16em;text-transform:uppercase;color:var(--faint);font-weight:400}
    #|  nav.rail a{display:block;padding:2px 0;font-family:var(--mono);font-size:12.5px;
    #|    color:var(--muted);border-left:1px solid transparent;padding-left:9px}
    #|  nav.rail a:hover{color:var(--ink);border-left-color:var(--gold);text-decoration:none}
    #|  main.doc{padding:40px 46px 120px;max-width:1080px}
    #|  .lede-block h1{font-family:var(--serif);font-weight:400;font-size:40px;margin:0 0 6px;
    #|    letter-spacing:.01em}
    #|  .lede-block p{color:var(--muted);max-width:62ch;margin:0 0 10px}
    #|  .counts{display:flex;flex-wrap:wrap;gap:22px;margin:22px 0 40px;
    #|    padding:16px 0;border-top:1px solid var(--hair);border-bottom:1px solid var(--hair)}
    #|  .counts div{font-family:var(--caps);font-size:11px;letter-spacing:.14em;
    #|    text-transform:uppercase;color:var(--faint)}
    #|  .counts b{display:block;font-family:var(--serif);font-size:26px;letter-spacing:0;
    #|    text-transform:none;color:var(--gold-hi);font-weight:400}
    #|  section.type{padding-top:26px;margin-bottom:34px;border-top:1px solid var(--hair)}
    #|  section.type h2{display:flex;align-items:baseline;gap:12px;margin:0 0 4px;font-weight:400}
    #|  section.type h2 .name{font-family:var(--serif);font-size:28px;color:var(--ink)}
    #|  section.type h2 .kind{font-family:var(--caps);font-size:10.5px;letter-spacing:.16em;
    #|    text-transform:uppercase;color:var(--gold);border:1px solid var(--hair);
    #|    padding:2px 8px}
    #|  section.type .lede{color:var(--muted);max-width:66ch;margin:0 0 14px}
    #|  section.type .impl{color:var(--muted);font-size:13px;margin:0 0 12px}
    #|  .fields{border-top:1px solid rgba(201,168,76,.1)}
    #|  .field{padding:11px 0;border-bottom:1px solid rgba(201,168,76,.1)}
    #|  .sig{font-family:var(--mono);font-size:13px;overflow-x:auto;white-space:nowrap;
    #|    padding-bottom:2px}
    #|  .sig .fname{color:var(--ink)}
    #|  .sig .aname{color:var(--gold-hi)}
    #|  .sig .t{color:#8fb7d9}
    #|  .sig .p{color:var(--faint)}
    #|  .sig .def{color:var(--muted)}
    #|  .field .desc{color:var(--muted);font-size:13.5px;margin-top:3px;max-width:70ch;
    #|    overflow-wrap:anywhere}
    #|  .field .dep{color:#e8837a;font-size:13px;margin-top:3px}
    #|  .values{display:flex;flex-wrap:wrap;gap:8px;margin:0 0 6px}
    #|  .values code{font-family:var(--mono);font-size:12.5px;color:var(--gold-hi);
    #|    border:1px solid var(--hair);padding:3px 8px}
    #|  .empty{color:var(--faint);font-size:13px;margin:6px 0 0}
    #|  footer.foot{margin-top:60px;padding-top:18px;border-top:1px solid var(--hair);
    #|    color:var(--faint);font-size:12px;font-family:var(--mono)}
    #|  .hidden{display:none}
    #|  @media (width <= 860px){
    #|    .shell{grid-template-columns:minmax(0,1fr)}
    #|    nav.rail{position:static;height:auto;max-height:38dvh;border-right:0;
    #|      border-bottom:1px solid var(--hair);padding:16px 18px}
    #|    main.doc{padding:24px 18px 80px}
    #|    header.top{flex-wrap:wrap;gap:10px;padding:12px 18px}
    #|    header.top form{margin-left:0;width:100%}
    #|    header.top input{width:100%;max-width:none}
    #|    .lede-block h1{font-size:30px}
    #|  }
    #|  @media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
    #|  @supports selector(::-webkit-scrollbar){
    #|    html::-webkit-scrollbar{width:10px;height:10px}
    #|    html::-webkit-scrollbar-track{background:transparent}
    #|    html::-webkit-scrollbar-thumb{border-radius:99px;border:3px solid transparent;
    #|      background-clip:content-box;background-color:color-mix(in srgb,var(--gold) 34%,transparent)}
    #|    html.at-top::-webkit-scrollbar-thumb{background:transparent}
    #|    nav.rail::-webkit-scrollbar,.sig::-webkit-scrollbar{width:8px;height:8px}
    #|    nav.rail::-webkit-scrollbar-track,.sig::-webkit-scrollbar-track{background:transparent}
    #|    nav.rail::-webkit-scrollbar-thumb,.sig::-webkit-scrollbar-thumb{border-radius:99px;
    #|      border:2px solid transparent;background-clip:content-box;
    #|      background-color:color-mix(in srgb,var(--gold) 14%,transparent)}
    #|    nav.rail:hover::-webkit-scrollbar-thumb,.sig:hover::-webkit-scrollbar-thumb{
    #|      background-color:color-mix(in srgb,var(--gold) 40%,transparent)}
    #|  }
    #|  @supports not selector(::-webkit-scrollbar){
    #|    html{scrollbar-width:thin;scrollbar-color:color-mix(in srgb,var(--gold) 36%,transparent) transparent}
    #|    html.at-top{scrollbar-color:transparent transparent}
    #|    nav.rail{scrollbar-width:thin;scrollbar-color:color-mix(in srgb,var(--gold) 18%,transparent) transparent}
    #|  }
    #|  html,button,input{font-variant-ligatures:no-contextual}
    #|</style>
  css
}

///|
/// The script: the search that narrows the rail and the page together, and the
/// scrollbar that is only visible once the page has moved.
fn reference_script() -> String {
  let script =
    #|<script>
    #|  (() => {
    #|    const root = document.documentElement;
    #|    const mark = () => root.classList.toggle('at-top', scrollY === 0);
    #|    addEventListener('scroll', mark, { passive: true });
    #|    mark();
    #|    const box = document.getElementById('q');
    #|    const links = [...document.querySelectorAll('nav.rail a')];
    #|    const sections = [...document.querySelectorAll('section.type')];
    #|    const groups = [...document.querySelectorAll('nav.rail .group')];
    #|    box?.addEventListener('input', () => {
    #|      const q = box.value.trim().toLowerCase();
    #|      for (const s of sections) {
    #|        s.classList.toggle('hidden', q !== '' && !s.id.toLowerCase().includes(q));
    #|      }
    #|      for (const a of links) {
    #|        a.classList.toggle('hidden', q !== '' && !a.dataset.name.includes(q));
    #|      }
    #|      for (const g of groups) {
    #|        g.classList.toggle('hidden', !g.querySelector('a:not(.hidden)'));
    #|      }
    #|    });
    #|    box?.addEventListener('keydown', (e) => { if (e.key === 'Escape') { box.value = ''; box.dispatchEvent(new Event('input')); } });
    #|  })();
    #|</script>
  script
}

///|
/// The documentation page for `schema`, served at `endpoint`.
pub fn reference_html(
  schema : @schema.Schema,
  endpoint~ : String = "/graphql",
) -> String {
  let objects : Array[@schema.ObjectType] = []
  let interfaces : Array[@schema.ObjectType] = []
  let inputs : Array[@schema.ObjectType] = []
  let mut field_count = 0
  for t in schema.types {
    field_count = field_count + t.fields.length()
    match t.kind {
      @schema.Object => objects.push(t)
      @schema.Interface => interfaces.push(t)
      @schema.Input => inputs.push(t)
    }
  }
  let directives = schema.all_directives()
  let out = StringBuilder()
  out.write_string("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
  out.write_string("<meta charset=\"utf-8\" />\n")
  out.write_string(
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n",
  )
  out.write_string("<title>Schema reference</title>\n")
  out.write_string(
    "<link rel=\"icon\" href=\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect x='3.5' y='3.5' width='25' height='25' fill='none' stroke='%23c9a84c' stroke-width='1'/%3E%3Crect x='7.5' y='7.5' width='17' height='17' fill='none' stroke='%23c9a84c' stroke-width='.6' opacity='.6'/%3E%3Ccircle cx='16' cy='16' r='4' fill='%23e9e3d4'/%3E%3C/svg%3E\" />\n",
  )
  out.write_string(
    "<link rel=\"preconnect\" href=\"https://fonts.googleapis.com\" />\n<link rel=\"preconnect\" href=\"https://fonts.gstatic.com\" crossorigin />\n",
  )
  out.write_string(
    "<link href=\"https://fonts.googleapis.com/css2?family=Cinzel:wght@400;500&family=Cormorant+Garamond:wght@400;500&family=Inter:wght@300;400;500&family=JetBrains+Mono:wght@400;500&display=swap\" rel=\"stylesheet\" />\n",
  )
  out.write_string(reference_style())
  out.write_string("</head>\n<body>\n")
  out.write_string("<header class=\"top\">\n")
  out.write_string("<div class=\"mark\">MoonQL<b>Schema reference</b></div>\n")
  out.write_string(
    "<div class=\"endpoint\">" + html_escape(endpoint) + "</div>\n",
  )
  out.write_string(
    "<form onsubmit=\"return false\"><input id=\"q\" type=\"search\" placeholder=\"Filter types\" aria-label=\"Filter types\" autocomplete=\"off\" /></form>\n",
  )
  out.write_string("</header>\n<div class=\"shell\">\n")

  // The rail: the root types first, because they are what a caller starts from,
  // then everything else by kind.
  out.write_string("<nav class=\"rail scroll\">\n")
  let groups : Array[(String, Array[String])] = []
  let roots : Array[String] = root_names(schema)
  if !roots.is_empty() {
    groups.push(("Root", roots))
  }
  let names : Array[String] = []
  for t in objects {
    names.push(t.name)
  }
  if !names.is_empty() {
    groups.push(("Objects", dict_order(names)))
  }
  let ifaces : Array[String] = []
  for t in interfaces {
    ifaces.push(t.name)
  }
  if !ifaces.is_empty() {
    groups.push(("Interfaces", dict_order(ifaces)))
  }
  let unions : Array[String] = []
  for u in schema.unions {
    unions.push(u.name)
  }
  if !unions.is_empty() {
    groups.push(("Unions", dict_order(unions)))
  }
  let enums : Array[String] = []
  for e in schema.enums {
    enums.push(e.name)
  }
  if !enums.is_empty() {
    groups.push(("Enums", dict_order(enums)))
  }
  let scalars : Array[String] = []
  for s in schema.scalars {
    scalars.push(s.name)
  }
  if !scalars.is_empty() {
    groups.push(("Scalars", dict_order(scalars)))
  }
  let in_names : Array[String] = []
  for t in inputs {
    in_names.push(t.name)
  }
  if !in_names.is_empty() {
    groups.push(("Input objects", dict_order(in_names)))
  }
  if !directives.is_empty() {
    groups.push(("Directives", []))
  }
  for group in groups {
    out.write_string(
      "<div class=\"group\"><h3>" + html_escape(group.0) + "</h3>",
    )
    if group.0 == "Directives" {
      for d in directives {
        out.write_string(
          "<a href=\"#directive-" +
          html_escape(d.name) +
          "\" data-name=\"@" +
          html_escape(d.name.to_lower()) +
          "\">@" +
          html_escape(d.name) +
          "</a>",
        )
      }
      out.write_string("</div>")
      continue
    }
    for name in group.1 {
      out.write_string(
        "<a href=\"#" +
        html_escape(name) +
        "\" data-name=\"" +
        html_escape(name.to_lower()) +
        "\">" +
        html_escape(name) +
        "</a>",
      )
    }
    out.write_string("</div>")
  }
  out.write_string("</nav>\n<main class=\"doc\">\n")

  out.write_string("<div class=\"lede-block\">")
  out.write_string("<h1>Everything this endpoint answers</h1>")
  out.write_string(
    "<p>A rendering of the schema the server holds, in the order a caller works through it. Fields link to the type they return, their arguments carry their defaults, and deprecated ones say so; the directives a document may write come last. The same material is available as SDL from the schema itself.</p>",
  )
  out.write_string("</div>")
  out.write_string("<div class=\"counts\">")
  out.write_string(
    "<div>Types<b>" +
    (objects.length() +
    interfaces.length() +
    inputs.length() +
    schema.enums.length() +
    schema.unions.length() +
    schema.scalars.length()).to_string() +
    "</b></div>",
  )
  out.write_string("<div>Fields<b>" + field_count.to_string() + "</b></div>")
  out.write_string(
    "<div>Enums<b>" + schema.enums.length().to_string() + "</b></div>",
  )
  out.write_string(
    "<div>Unions<b>" + schema.unions.length().to_string() + "</b></div>",
  )
  out.write_string(
    "<div>Directives<b>" + directives.length().to_string() + "</b></div>",
  )
  out.write_string("</div>\n")

  // The root types, each with its fields.
  for name in roots {
    match schema.type_by_name(name) {
      Some(t) =>
        out.write_string(
          type_section(
            schema,
            t.name,
            "ROOT",
            t.description,
            t.interfaces,
            fields_html(schema, t.fields),
          ),
        )
      None => ()
    }
  }
  for t in sorted_objects(objects) {
    if roots.contains(t.name) {
      continue
    }
    out.write_string(
      type_section(
        schema,
        t.name,
        "OBJECT",
        t.description,
        t.interfaces,
        fields_html(schema, t.fields),
      ),
    )
  }
  for t in sorted_objects(interfaces) {
    out.write_string(
      type_section(
        schema,
        t.name,
        "INTERFACE",
        t.description,
        t.interfaces,
        fields_html(schema, t.fields),
      ),
    )
  }
  for u in schema.unions {
    let body = StringBuilder()
    body.write_string("<div class=\"values\">")
    for m in u.members {
      body.write_string("<code>" + type_link(schema, m) + "</code>")
    }
    body.write_string("</div>")
    out.write_string(
      type_section(schema, u.name, "UNION", u.description, [], body.to_string()),
    )
  }
  for e in schema.enums {
    let body = StringBuilder()
    body.write_string("<div class=\"values\">")
    for v in e.values {
      body.write_string("<code>" + html_escape(v) + "</code>")
    }
    body.write_string("</div>")
    for v in e.values {
      match e.value_descriptions.get(v) {
        Some(d) =>
          body.write_string(
            "<div class=\"field\"><div class=\"sig\"><span class=\"aname\">" +
            html_escape(v) +
            "</span></div><div class=\"desc\">" +
            html_escape(d) +
            "</div></div>",
          )
        None => ()
      }
    }
    out.write_string(
      type_section(schema, e.name, "ENUM", e.description, [], body.to_string()),
    )
  }
  for t in sorted_objects(inputs) {
    out.write_string(
      type_section(
        schema,
        t.name,
        "INPUT OBJECT",
        t.description,
        [],
        fields_html(schema, t.fields),
      ),
    )
  }
  for s in schema.scalars {
    let body = match s.spec_url {
      Some(u) =>
        "<p class=\"impl\">Specification: <a href=\"" +
        html_escape(u) +
        "\">" +
        html_escape(u) +
        "</a></p>"
      None => ""
    }
    out.write_string(
      type_section(schema, s.name, "SCALAR", s.description, [], body),
    )
  }
  for d in directives {
    out.write_string(directive_section(schema, d))
  }
  out.write_string(
    "<footer class=\"foot\">query " +
    html_escape(schema.query) +
    root_note(schema) +
    "</footer>",
  )
  out.write_string("</main>\n</div>\n")
  out.write_string(reference_script())
  out.write_string("</body>\n</html>\n")
  out.to_string()
}

///|
/// Names in dictionary order, the way the rail is meant to read.
fn dict_order(names : Array[String]) -> Array[String] {
  let out = names.copy()
  out.sort_by(fn(a, b) { a.compare(b) })
  out
}

///|
/// The names of the three root types that exist, in the order a document
/// addresses them.
fn root_names(schema : @schema.Schema) -> Array[String] {
  let out : Array[String] = [schema.query]
  match schema.mutation {
    Some(m) => out.push(m)
    None => ()
  }
  match schema.subscription {
    Some(s) => out.push(s)
    None => ()
  }
  out
}

///|
/// The mutation and subscription roots the schema also declares, spelled out
/// under the query root's name.
fn root_note(schema : @schema.Schema) -> String {
  let out = StringBuilder()
  match schema.mutation {
    Some(m) => out.write_string(" · mutation " + html_escape(m))
    None => ()
  }
  match schema.subscription {
    Some(s) => out.write_string(" · subscription " + html_escape(s))
    None => ()
  }
  out.to_string()
}

///|
/// Object types in dictionary order, the order the sections are written in.
fn sorted_objects(
  types : Array[@schema.ObjectType],
) -> Array[@schema.ObjectType] {
  let out = types.copy()
  out.sort_by(fn(a, b) { a.name.compare(b.name) })
  out
}

///|
/// The page a reference request is answered with when the application did not
/// hand over a schema: the same chrome, and one sentence saying so instead of a
/// documentation page with nothing in it.
fn missing_schema_page(endpoint : String) -> String {
  let out = StringBuilder()
  out.write_string("<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n")
  out.write_string("<meta charset=\"utf-8\" />\n")
  out.write_string(
    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n",
  )
  out.write_string("<title>Schema reference</title>\n")
  out.write_string(reference_style())
  out.write_string(
    "</head>\n<body>\n<header class=\"top\"><div class=\"mark\">MoonQL",
  )
  out.write_string("<b>Schema reference</b></div><div class=\"endpoint\">")
  out.write_string(html_escape(endpoint))
  out.write_string(
    "</div></header>\n<main class=\"doc\"><div class=\"lede-block\">",
  )
  out.write_string("<h1>No schema to show</h1>")
  out.write_string(
    "<p>This page is rendered from the schema the application holds, and none was passed to it. Serving it through the application's own endpoint (<code>graphql_app</code> or <code>graphql_app_async</code>) supplies one.</p>",
  )
  out.write_string("</div></main>\n</body>\n</html>\n")
  out.to_string()
}
