#!/usr/bin/env python3
"""Write the code and the recorded output of docs/guide.html from src/examples/guide.

Each way of writing the same server has a package there: `annotations` (`#gql`
annotations), `functions` (calls on the schema and the resolver map) and
`classes` (a struct per type, its two conversions, a method per field). A block
between `// guide:<name>` and `// end` is a snippet, shown as written; `check`
runs every document of the guide against all three and fails if they answer
differently, so its output is what the page records.

    python3 scripts/gen_guide.py           rewrite docs/guide.html
    python3 scripts/gen_guide.py --check   fail if docs/guide.html is not what this would write
"""

import html
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "examples" / "guide"
GUIDE = ROOT / "docs" / "guide.html"

STYLES = ("annotations", "functions", "classes")

KEYWORDS = {
    "let", "fn", "pub", "priv", "struct", "enum", "impl", "trait", "match",
    "if", "else", "raise", "return", "mut", "for", "in", "guard", "self",
    "true", "false", "type", "extend", "with", "async", "and", "or", "not",
    "using", "catch", "while", "break", "continue",
}

TOKEN = re.compile(
    r"(?P<comment>//[^\n]*)"
    r'|(?P<string>"(?:\\.|[^"\\])*")'
    r"|(?P<attr>#[a-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)*)"
    r"|(?P<word>[A-Za-z_][A-Za-z0-9_]*)"
)

SNIPPETS = {}


def highlight(text):
    """The page's colours: comments and strings muted, keywords dark, types blue."""
    out = []
    at = 0
    for m in TOKEN.finditer(text):
        out.append(html.escape(text[at:m.start()], quote=False))
        run = html.escape(m.group(0), quote=False)
        if m.group("comment") or m.group("string") or m.group("attr"):
            out.append(f'<span class="c">{run}</span>')
        elif m.group("word") in KEYWORDS:
            out.append(f'<span class="k">{run}</span>')
        elif m.group("word")[:1].isupper():
            out.append(f'<span class="ty">{run}</span>')
        else:
            out.append(run)
        at = m.end()
    out.append(html.escape(text[at:], quote=False))
    return "".join(out)


def snippets(style):
    """Every `// guide:<name>` block of one package, by name, outdented."""
    if style in SNIPPETS:
        return SNIPPETS[style]
    found = {}
    for path in sorted((SRC / style).glob("*.mbt")):
        text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        for m in re.finditer(
            r"^([ \t]*)// guide:([a-z.]+)[ \t]*\n(.*?)^[ \t]*// end[ \t]*$",
            text,
            re.S | re.M,
        ):
            indent = len(m.group(1))
            lines = []
            for line in m.group(3).rstrip("\n").split("\n"):
                line = line[indent:] if line[:indent].strip() == "" else line.lstrip()
                # A `///` block reads as prose on the page, not as a doc marker.
                if line.strip() == "///|":
                    continue
                if line.startswith("/// "):
                    line = "// " + line[4:]
                lines.append(line)
            found[m.group(2)] = "\n".join(lines)
    SNIPPETS[style] = found
    return found


def code(text):
    return f'<pre class="hl"><code>{highlight(text)}</code></pre>' 


def output(text):
    return f'<pre class="out">{html.escape(text, quote=False)}</pre>'


def variant(style, body, note):
    extra = f'\n      <p class="why">{note}</p>' if note else ""
    return (
        f'    <div class="variant" data-style="{style}">\n'
        f'      <p class="way">{style}</p>\n'
        f"      {code(body)}{extra}\n"
        f"    </div>"
    )


def group(key, notes=None, extra=None):
    """One block written three ways. `extra` lists further snippet names per style."""
    notes = notes or {}
    boxes = []
    for style in STYLES:
        parts = snippets(style)
        names = [key] + (extra or {}).get(style, [])
        body = "\n\n".join(parts[name] for name in names if name in parts)
        boxes.append(variant(style, body, notes.get(style, "")))
    return '<div class="styles">\n' + "\n".join(boxes) + "\n  </div>"


def recorded():
    """Run the guide's check program: one `document -> answer` line per document."""
    run = subprocess.run(
        ["moon", "run", "src/examples/guide/check", "--target", "native"],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if run.returncode != 0:
        sys.exit("the guide's check program failed:\n" + run.stdout + run.stderr)
    if "DIFFERS" in run.stdout:
        sys.exit(
            "the three ways of writing the guide answer differently:\n" + run.stdout
        )
    if "the three ways agree" not in run.stdout:
        sys.exit("the guide's check program did not finish:\n" + run.stdout)
    got = {}
    for line in run.stdout.splitlines():
        if " -> " in line:
            key, value = line.split(" -> ", 1)
            got[key] = value
    return got


def sections(got):
    every = {style: ["root.register"] for style in STYLES}
    field_extra = {style: ["field.register"] for style in STYLES}
    author = got['{ author(id: "1") { name books { title } } }']
    books = got['{ books { title } }']
    added = got['mutation { addBook(input: { title: "Dune", authorId: "2" }) { id title } }']
    refused = got['mutation { addBook(input: { title: "", authorId: "2" }) { id } }']
    events = got["subscription { bookAdded { title } }"]
    entity = got["_entities"]

    return {
        "1. TYPE": f"""<section id="type">
    <h2><span class="n">01</span>One type, three ways</h2>
    <p>A schema is types with fields. Write them as <code>#gql</code> annotations on the structs you
    already have, as calls on the schema, or as types with an <code>impl</code> saying how they
    cross the wire. The switch at the top of the page picks which way every block here is written;
    all three build the same schema and answer the same documents.</p>

{group("type", notes={
        "annotations": "The generator reads the annotations and writes the calls the other two ways write by hand.",
        "functions": "Each call names a type and gives it a field; a field's type says how its value is read.",
        "classes": "The two impls are exactly what the generator writes for an annotated struct; writing them yourself is how a type joins the executor.",
    })}

  </section>""",
        "2. FIELD": f"""<section id="field">
    <h2><span class="n">02</span>A field that resolves</h2>
    <p>A field whose value is not already on the parent is resolved by a function: a method on the
    type, or a closure registered under <code>"Type.field"</code>. The field's declared type tells
    the executor whether what comes back is a leaf, a list or an object.</p>

{group("field", extra=field_extra)}

    <p>Only the fields the document selects are resolved, and a resolver's value is read under the
    names the schema uses — which is why <code>author_id</code> is written out as
    <code>authorId</code> once, in the conversion.</p>
  </section>""",
        "3. ROOT": f"""<section id="root">
    <h2><span class="n">03</span>Root fields and arguments</h2>
    <p><code>Query</code> is a type like any other, and its fields are the entry points. An argument
    is declared with its type, and a resolver reads it by name.</p>

{group("root", extra=every)}

    <p class="tag">recorded · the same answer from all three</p>
{output(author)}
{output(books)}

    <p>A nullable argument may be left out, and a nullable field may answer <code>null</code>; a
    non-null field that answers <code>null</code> is a field error, and it takes the nearest
    nullable parent with it.</p>
  </section>""",
        "4. INPUT": f"""<section id="input">
    <h2><span class="n">04</span>An input object, a mutation, an error</h2>
    <p>A mutation takes its payload as an input object: a type whose fields are the caller's to
    send. A resolver that declares <code>raise</code> may fail, and its error becomes a field error
    carrying the path and the place in the document.</p>

{group("input", notes={
        "annotations": "`#gql.input` and `#gql.mutation`; the input struct's reading side is generated with it.",
        "functions": "The input is a type with fields, and the payload is one argument declared with it.",
        "classes": "The input is a struct with the reading half only — nothing sends one back out.",
    })}

{group("mutation", extra={style: ["mutation.register"] for style in STYLES})}

    <p class="tag">recorded · one book added, one refused</p>
{output(added)}
{output(refused)}

  </section>""",
        "5. SUBSCRIPTION": f"""<section id="subscription">
    <h2><span class="n">05</span>Subscriptions</h2>
    <p>A subscription field answers with the stream of its events; the executor resolves the
    selection set against each one. Over the wire the same thing is carried by
    <code>graphql-transport-ws</code>: <code>connection_init</code>, <code>subscribe</code>, then
    <code>next</code> for each payload and <code>complete</code> at the end.</p>

{group("subscription", extra={style: ["subscription.register"] for style in STYLES})}

    <p class="tag">recorded · one payload per event</p>
{output(events)}

    <p>Four events, because the mutation above added a fourth book before this ran. A real source
    would be an event bus; the shape a subgraph fills in is the same.</p>
  </section>""",
        "6. FEDERATION": f"""<section id="federation">
    <h2><span class="n">06</span>Subgraphs that compose</h2>
    <p>An entity is a type with a <code>@key</code> and a way to turn a representation — a
    <code>{{__typename, key}}</code> pair — back into the object. The subgraph then answers
    <code>_service {{ sdl }}</code> and <code>_entities(representations:)</code>, and a gateway can
    join it to its siblings.</p>

{group("federation")}

    <p class="tag">recorded · a representation resolved</p>
{output(entity)}

    <p>What comes back is the object, and the fields named by <code>@requires</code> that the
    gateway sent along stay on it for this subgraph's resolvers to read.</p>
  </section>""",
    }


MARK = re.compile(r"<!-- ============ ([0-9]+\. [A-Z]+) ============ -->\n")


def render(page, parts):
    """Replace the body of every marked section that has generated content."""
    marks = list(MARK.finditer(page))
    out = []
    at = 0
    for i, mark in enumerate(marks):
        if i + 1 < len(marks):
            end = marks[i + 1].start()
        else:
            # The last generated section stops where the hand-written ones resume.
            following = re.search(r"\n *<section", page[mark.end():])
            end = mark.end() + following.start() if following else page.index("</article>")
        out.append(page[at:mark.end()])
        if mark.group(1) in parts:
            out.append(parts[mark.group(1)] + "\n\n  ")
        else:
            out.append(page[mark.end():end])
        at = end
    out.append(page[at:])
    return "".join(out)


def main():
    page = GUIDE.read_text(encoding="utf-8")
    new = render(page, sections(recorded()))
    if "--check" in sys.argv:
        if new != page:
            sys.exit(
                "docs/guide.html is out of date with src/examples/guide; "
                "run scripts/gen_guide.py"
            )
        print("docs/guide.html is up to date")
        return
    GUIDE.write_text(new, encoding="utf-8", newline="\n")
    print("wrote docs/guide.html")


if __name__ == "__main__":
    main()
