// Compare this library's SDL printer and reader with graphql-js's.
//
//   node scripts/sdl_crosscheck.mjs [--keep]
//
// For every case below: this library reads the SDL and prints it back, graphql-js
// parses that print and prints it again, and this library reads *that* and prints
// once more. A passing run means:
//
//   A  graphql-js accepts every document this library prints;
//   B  graphql-js's view of the schema is unchanged by a round trip through this
//      library's reader (print(parse(x)) is the same before and after);
//   C  this library's print is byte-identical across the hop: our(js(our)) === our;
//   D  the two printers agree byte for byte once their two formatting
//      conventions are set aside — descriptions written as `"..."` rather than
//      `"""..."""`, and the `schema { query: ... }` block printed even when the
//      root types have their default names. The script applies exactly those two
//      rewrites, so a difference of any other kind still fails.
//
// graphql-js is not a dependency of the library: this script installs nothing and
// expects `graphql` to be resolvable from the current directory.

import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { parse, print, buildASTSchema, validateSchema } = require("graphql");

const CASES = {
  "objects and fields": `
type Query {
  hello: String!
  user(id: ID!): User
} 

type User {
  id: ID!
  name: String!
  tags: [String!]!
}`,

  "descriptions, deprecation and defaults": `
type Query {
  "The root of everything."
  me: User
  search(term: String! = "all", first: Int = 10, tags: [String!] = ["a", "b"]): [String!]!
  old: String @deprecated(reason: "use me")
}

type User {
  id: ID!
  legacyName: String! @deprecated(reason: "use name")
  name: String!
}`,

  "interfaces, unions and enums": `
interface Node {
  id: ID!
}

type User implements Node {
  id: ID!
  name: String!
}

type Post implements Node {
  id: ID!
  author: User!
}

union Content = User | Post

enum Role {
  ADMIN
  GUEST
  OLD @deprecated(reason: "use GUEST")
}

type Query {
  node(id: ID!): Node
  content: [Content!]!
  role: Role!
}`,

  "input objects and mutations": `
schema {
  query: Query
  mutation: Mutation
  subscription: Subscription
}

input NewUser {
  name: String!
  role: Role = GUEST
  tags: [String!]
}

enum Role {
  ADMIN
  GUEST
}

type Query {
  users: [User!]!
}

type User {
  id: ID!
  name: String!
}

type Mutation {
  addUser(input: NewUser!): User!
}

type Subscription {
  userAdded: User!
}`,

  "custom scalars and directive definitions": `
scalar DateTime @specifiedBy(url: "https://example.invalid/datetime")

"A label a router may route by."
directive @tag(name: String!, weight: Int = 1) repeatable on OBJECT | FIELD_DEFINITION

type Query @tag(name: "root") {
  now: DateTime!
  "When the next one starts."
  next(in: Int = 1): DateTime
}`,

  "input field defaults, of every shape": `
input Filter {
  role: Role = GUEST
  limit: Int = 10
  tags: [String!] = ["a", "b"]
  nested: Inner = { n: 1 }
}

input Inner {
  n: Int
}

enum Role {
  ADMIN
  GUEST
}

type Query {
  books(filter: Filter = { role: ADMIN, limit: 5 }): [String!]!
}`,

  "nested types and arguments": `
type Query {
  books(first: Int = 20, after: String, filter: Filter): BookPage!
}

input Filter {
  title: String
  statuses: [Status!] = [DRAFT]
}

enum Status {
  DRAFT
  PUBLISHED
}

type BookPage {
  edges: [Book!]!
  total: Int!
}

type Book {
  id: ID!
  title: String!
  status: Status!
}`,
};

const ROOT = new URL("..", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");

// The tool is built once and run directly: `moon run` prints what it built on the
// same stream, and a printer's output has to be nothing but SDL.
const TOOL = join(
  ROOT,
  "_build",
  "native",
  "debug",
  "build",
  "cmd",
  "sdl",
  process.platform === "win32" ? "sdl.exe" : "sdl",
);

function buildTool() {
  execFileSync("moon", ["build", "src/cmd/sdl", "--target", "native"], {
    cwd: ROOT,
    stdio: "ignore",
  });
}

function ourSdl(file) {
  try {
    return execFileSync(TOOL, [file], { encoding: "utf-8", stdio: ["ignore", "pipe", "pipe"] })
      .replace(/\r\n/g, "\n")
      .replace(/\n+$/, "\n");
  } catch (e) {
    throw new Error("the SDL reader failed: " + (e.stdout || "") + (e.stderr || ""));
  }
}

// The two conventions, applied to both printers' output so the rest is compared
// byte for byte.
function normalize(sdl) {
  let out = sdl.replace(/\r\n/g, "\n").replace(/\n+$/, "\n");
  out = out.replace(/"""([^"\n]*)"""/g, '"$1"');
  out = out.replace(/^schema \{\n  query: Query\n\}\n\n/m, "");
  return out;
}

buildTool();
const dir = mkdtempSync(join(tmpdir(), "moongql-sdl-"));
let failures = 0;
let cases = 0;

for (const [name, sdl] of Object.entries(CASES)) {
  cases++;
  const file = join(dir, `case${cases}.graphql`);
  writeFileSync(file, sdl.trim() + "\n", "utf-8");

  const ours = ourSdl(file);

  let js1;
  try {
    js1 = print(parse(ours)) + "\n";
  } catch (e) {
    failures++;
    console.log(`FAIL ${name}: graphql-js cannot parse what we print\n${e.message}`);
    continue;
  }

  const schema = buildASTSchema(parse(ours));
  const problems = validateSchema(schema);
  if (problems.length > 0) {
    failures++;
    console.log(`FAIL ${name}: graphql-js will not build the schema`);
    for (const p of problems) console.log("  " + p.message);
    continue;
  }

  // C: our print is the same after a hop through graphql-js.
  const back = join(dir, `case${cases}.js.graphql`);
  writeFileSync(back, js1, "utf-8");
  const oursAgain = ourSdl(back);
  const c = oursAgain === ours;

  // B: graphql-js sees the same schema after our reader touched its print.
  const js2 = print(parse(oursAgain)) + "\n";
  const b = js2 === js1;

  // D: the two printers agree once their two conventions are set aside.
  const d = normalize(ours) === normalize(js1);

  if (!b || !c || !d) {
    failures++;
    console.log(`FAIL ${name}`);
    if (!b) console.log("  B: graphql-js sees a different schema after our reader");
    if (!c) {
      console.log("  C: our print changed across the hop");
      console.log("  --- ours\n" + ours + "  --- ours again\n" + oursAgain);
    }
    if (!d) {
      console.log("  D: the printers differ beyond the two conventions");
      const a = normalize(ours).split("\n");
      const z = normalize(js1).split("\n");
      for (let i = 0; i < Math.max(a.length, z.length); i++) {
        if (a[i] !== z[i]) console.log(`    line ${i + 1}\n      ours: ${a[i]}\n      js:   ${z[i]}`);
      }
    }
  } else {
    console.log(`ok   ${name}`);
  }
}

rmSync(dir, { recursive: true, force: true });
console.log(`\n${cases - failures}/${cases} cases agree`);
process.exit(failures === 0 ? 0 : 1);
