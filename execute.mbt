///|
/// The GraphQL execution engine: it walks a validated `Document` against a
/// `Schema` using a resolver map, then serialises `{ data, errors }` to JSON.
/// This is the "can actually run" half of moongql — `execute` turns a query
/// string, variable values, a root value and a context into a real response,
/// mirroring `graphql-core`'s `execute` (which strawberry drives).
///
/// Faithful equivalences to strawberry's Python (see README design notes):
/// resolvers are explicit `(ResolveInfo) -> Json` functions keyed by
/// `"Type.field"` rather than methods discovered by reflection, and the field
/// return type drives leaf/composite completion the same way graphql-core's
/// `complete_value` does.

///|
/// The information a field resolver receives: the resolved parent object (as
/// JSON), the coerced arguments, the shared context value, and the field's name.
/// A resolver returns the field's value as JSON (an object for composite types,
/// whose sub-fields are then resolved against it) and may `raise ResolverError`
/// to surface a field error.
pub(all) struct ResolveInfo {
  parent : Json
  args : Map[String, Json]
  ctx : Json
  field_name : String
}

///|
/// Read a named argument as JSON, or `Json::null()` when it was not supplied.
pub fn ResolveInfo::arg(self : ResolveInfo, name : String) -> Json {
  match self.args.get(name) {
    Some(v) => v
    None => Json::null()
  }
}

///|
/// An error raised by a field resolver; its message is reported in the response
/// `errors` list with the field's response path.
pub(all) suberror ResolverError {
  ResolverError(String)
  ResolverErrorExt(String, Map[String, Json])
}

///|
/// A registry of field resolvers, keyed by `"TypeName.fieldName"`. Fields with
/// no registered resolver fall back to the default resolver, which reads the
/// field's name off the parent JSON object (matching graphql-core's
/// `default_field_resolver`).
pub struct Resolvers {
  map : Map[String, (ResolveInfo) -> Json raise ResolverError]
}

///|
/// Create an empty resolver registry.
pub fn Resolvers::new() -> Resolvers {
  { map: Map([]), }
}

///|
/// Register `resolver` for field `field_name` on type `type_name`.
pub fn Resolvers::field(
  self : Resolvers,
  type_name : String,
  field_name : String,
  resolver : (ResolveInfo) -> Json raise ResolverError,
) -> Unit {
  self.map[type_name + "." + field_name] = resolver
}

///|
/// A GraphQL error entry: a message, an optional response path (string field
/// keys and integer list indices), and optional source locations.
pub(all) struct GqlError {
  message : String
  path : Array[Json]
  locations : Array[Pos]
  extensions : Map[String, Json]
}

///|
/// Build an error carrying only a message, for the request-level failures that
/// cannot be pinned to a point in the document (an empty document, an unknown
/// operation name).
fn GqlError::msg(message : String) -> GqlError {
  { message, path: [], locations: [], extensions: Map([]), }
}

///|
/// Build an error carrying a message and the position of the node it is about.
/// §7.1.2 requires `locations` on every error that can name one.
fn GqlError::at(message : String, pos : Pos) -> GqlError {
  { message, path: [], locations: [pos], extensions: Map([]), }
}

///|
/// Serialise an error to the GraphQL JSON error shape, omitting an empty path
/// or locations list.
fn GqlError::to_json(self : GqlError) -> Json {
  let entries : Array[(String, Json)] = [("message", Json(self.message))]
  if self.locations.length() > 0 {
    let locs : Array[Json] = []
    for p in self.locations {
      locs.push(jobj([("line", Json(p.line)), ("column", Json(p.col))]))
    }
    entries.push(("locations", Json(locs)))
  }
  if self.path.length() > 0 {
    entries.push(("path", Json(self.path)))
  }
  // A resolver-supplied `extensions` map (← GraphQL spec §7.1.2), emitted only
  // when non-empty.
  if !self.extensions.is_empty() {
    entries.push(("extensions", Json(self.extensions)))
  }
  jobj(entries)
}

///|
/// Build a JSON object from ordered `(key, value)` entries, preserving order.
fn jobj(entries : Array[(String, Json)]) -> Json {
  let m : Map[String, Json] = Map([])
  for e in entries {
    m[e.0] = e.1
  }
  Json(m)
}

///|
/// Interpret a JSON value as a boolean (`true`/`false`), or `None` otherwise.
fn json_bool(j : Json) -> Bool? {
  match j {
    True => Some(true)
    False => Some(false)
    _ => None
  }
}

///|
/// Turn a numeric literal's source text into a JSON number. GraphQL int/float
/// literal syntax is a subset of JSON number syntax, so the lexer-validated text
/// parses directly; malformed text (unreachable for well-formed input) is null.
fn parse_number_json(s : String) -> Json {
  @json.parse(s) catch {
    _ => Json::null()
  }
}

///|
/// Internal signal used to bubble a null from a non-null position up to the
/// nearest nullable field, per the GraphQL "errors and non-nullability" rules.
priv suberror NullBubble

///|
/// The per-request executor state: the schema, resolvers, the document's named
/// fragments, the coerced variable values, the context value, and the running
/// error list.
priv struct Exec {
  schema : Schema
  resolvers : Resolvers
  fragments : Map[String, FragmentDefinition]
  variables : Map[String, Json]
  ctx : Json
  errors : Array[GqlError]
}

///|
/// Record a field error at `path`, pointed at the field in the document that
/// produced it.
fn Exec::add_error(
  self : Exec,
  message : String,
  path : Array[Json],
  pos : Pos,
) -> Unit {
  self.errors.push({ message, path, locations: [pos], extensions: Map([]), })
}

///|
/// Record a field error at `path` carrying a resolver-supplied `extensions` map
/// (← GraphQL spec §7.1.2).
fn Exec::add_error_ext(
  self : Exec,
  message : String,
  path : Array[Json],
  pos : Pos,
  extensions : Map[String, Json],
) -> Unit {
  self.errors.push({ message, path, locations: [pos], extensions, })
}

///|
/// The five built-in scalar type names, which are leaves with no declaration.
fn is_builtin_scalar(name : String) -> Bool {
  name == "String" ||
  name == "Int" ||
  name == "Float" ||
  name == "Boolean" ||
  name == "ID"
}

///|
/// Whether `name` denotes a leaf type (a scalar or an enum) rather than a
/// composite type whose fields are selected into.
fn Exec::is_leaf_type(self : Exec, name : String) -> Bool {
  is_builtin_scalar(name) ||
  self.schema.enum_by_name(name) is Some(_) ||
  self.schema.scalar_by_name(name) is Some(_) ||
  name == "__TypeKind" ||
  name == "__DirectiveLocation"
}

///|
/// Coerce a GraphQL AST value to JSON, substituting variables from the request.
fn Exec::value_to_json(self : Exec, v : Value) -> Json {
  match v {
    Variable(n) =>
      match self.variables.get(n) {
        Some(x) => x
        None => Json::null()
      }
    IntValue(s) => parse_number_json(s)
    FloatValue(s) => parse_number_json(s)
    StringValue(s, _) => Json(s)
    BooleanValue(b) => Json(b)
    NullValue => Json::null()
    EnumValue(n) => Json(n)
    ListValue(items) => {
      let out : Array[Json] = []
      for it in items {
        out.push(self.value_to_json(it))
      }
      Json(out)
    }
    ObjectValue(fields) => {
      let m : Map[String, Json] = Map([])
      for kv in fields {
        m[kv.0] = self.value_to_json(kv.1)
      }
      Json(m)
    }
  }
}

///|
/// Fill in a field's declared argument defaults for any argument the query left
/// out. An argument the query supplied — including an explicit `null` — keeps its
/// value; only a genuinely absent argument takes its default.
fn apply_arg_defaults(args : Map[String, Json], fdef : Field) -> Unit {
  for name, default in fdef.arg_defaults {
    if args.get(name) is None {
      args[name] = default
    }
  }
}

///|
/// Coerce a field's argument list to a `name -> JSON` map.
fn Exec::coerce_args(self : Exec, field : QueryField) -> Map[String, Json] {
  let m : Map[String, Json] = Map([])
  for a in field.arguments {
    m[a.name] = self.value_to_json(a.value)
  }
  m
}

///|
/// Run a custom scalar's `parse_value` hook over an input value, descending
/// through non-null and list wrappers so `[DateTime!]` parses element-wise. A
/// value at a built-in scalar or non-scalar position is returned unchanged.
fn Exec::coerce_input(self : Exec, value : Json, typ : GqlType) -> Json {
  match typ {
    NonNull(inner) => self.coerce_input(value, inner)
    ListOf(inner) =>
      match value {
        Array(items) => {
          let out : Array[Json] = []
          for it in items {
            out.push(self.coerce_input(it, inner))
          }
          Json(out)
        }
        _ => value
      }
    Scalar(n) | Named(n) =>
      match self.schema.scalar_by_name(n) {
        Some(sc) => if value is Null { value } else { (sc.parse_value)(value) }
        None => value
      }
  }
}

///|
/// Apply custom-scalar input coercion to each declared argument of `fdef` that
/// carries a value, so a resolver reading `info.arg(..)` sees parsed input.
fn Exec::apply_input_scalars(
  self : Exec,
  args : Map[String, Json],
  fdef : Field,
) -> Unit {
  for da in fdef.args {
    match args.get(da.0) {
      Some(v) => args[da.0] = self.coerce_input(v, da.1)
      None => ()
    }
  }
}

///|
/// Evaluate the `if:` argument of a `@skip`/`@include` directive (default false).
fn Exec::directive_if(self : Exec, d : Directive) -> Bool {
  for a in d.arguments {
    if a.name == "if" {
      return match json_bool(self.value_to_json(a.value)) {
        Some(b) => b
        None => false
      }
    }
  }
  false
}

///|
/// Apply `@skip(if:)` / `@include(if:)` to decide whether a selection is kept.
fn Exec::should_include(self : Exec, directives : Array[Directive]) -> Bool {
  let mut keep = true
  for d in directives {
    if d.name == "skip" && self.directive_if(d) {
      keep = false
    } else if d.name == "include" && not(self.directive_if(d)) {
      keep = false
    }
  }
  keep
}

///|
/// Whether a fragment's type condition `cond` applies to an object of type
/// `obj`: the condition names the object itself or an interface it implements.
fn Exec::fragment_applies(self : Exec, cond : String, obj : ObjectType) -> Bool {
  if cond == obj.name {
    return true
  }
  for iface in obj.interfaces {
    if iface == cond {
      return true
    }
  }
  if self.schema.union_by_name(cond) is Some(u) {
    for m in u.members {
      if m == obj.name {
        return true
      }
    }
  }
  false
}

///|
/// CollectFields (GraphQL spec §6.3.2): flatten a selection set into ordered
/// response keys, expanding fragment spreads and inline fragments and honouring
/// `@skip`/`@include`. Fields sharing a response key are grouped so their
/// sub-selections merge.
fn Exec::collect_fields(
  self : Exec,
  obj : ObjectType,
  selections : Array[Selection],
  visited : Map[String, Bool],
  keys : Array[String],
  groups : Map[String, Array[QueryField]],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => {
        if not(self.should_include(f.directives)) {
          continue
        }
        let key = match f.alias_ {
          Some(a) => a
          None => f.name
        }
        match groups.get(key) {
          Some(g) => g.push(f)
          None => {
            keys.push(key)
            groups[key] = [f]
          }
        }
      }
      FragmentSpreadSel(name, dirs, _) => {
        if not(self.should_include(dirs)) {
          continue
        }
        if visited.get(name) is Some(true) {
          continue
        }
        visited[name] = true
        match self.fragments.get(name) {
          Some(frag) =>
            if self.fragment_applies(frag.type_condition, obj) {
              self.collect_fields(
                obj,
                frag.selection_set,
                visited,
                keys,
                groups,
              )
            }
          None => ()
        }
      }
      InlineFragmentSel(cond, dirs, sels, _) => {
        if not(self.should_include(dirs)) {
          continue
        }
        let applies = match cond {
          None => true
          Some(c) => self.fragment_applies(c, obj)
        }
        if applies {
          self.collect_fields(obj, sels, visited, keys, groups)
        }
      }
    }
  }
}

///|
/// The declared type of `field_name` on `obj`, resolving the introspection
/// meta-fields (`__typename`, and `__schema`/`__type` on the query root).
fn Exec::field_type_of(
  self : Exec,
  obj : ObjectType,
  field_name : String,
) -> GqlType? {
  if field_name == "__typename" {
    return Some(NonNull(Scalar("String")))
  }
  if obj.name == self.schema.query {
    if field_name == "__schema" {
      return Some(NonNull(Named("__Schema")))
    }
    if field_name == "__type" {
      return Some(Named("__Type"))
    }
  }
  match obj.field_by_name(field_name) {
    Some(f) => Some(f.typ)
    None => None
  }
}

///|
/// Resolve a field's raw JSON value: dispatch to its registered resolver, the
/// introspection roots, or the default resolver (read the field off the parent).
/// A `ResolverError` becomes a recorded field error and a null value.
fn Exec::resolve_raw(
  self : Exec,
  obj : ObjectType,
  field : QueryField,
  parent : Json,
  path : Array[Json],
) -> Json {
  let name = field.name
  if name == "__typename" {
    return Json(obj.name)
  }
  let args = self.coerce_args(field)
  match obj.field_by_name(name) {
    Some(fdef) => {
      apply_arg_defaults(args, fdef)
      self.apply_input_scalars(args, fdef)
    }
    None => ()
  }
  match self.resolvers.map.get(obj.name + "." + name) {
    Some(resolver) => {
      let info = { parent, args, ctx: self.ctx, field_name: name, }
      resolver(info) catch {
        ResolverError(m) => {
          self.add_error(m, path, field.pos)
          Json::null()
        }
        ResolverErrorExt(m, ext) => {
          self.add_error_ext(m, path, field.pos, ext)
          Json::null()
        }
      }
    }
    None => {
      if obj.name == self.schema.query {
        if name == "__schema" {
          return self.introspection_schema()
        }
        if name == "__type" {
          let tn = match args.get("name") {
            Some(String(s)) => s
            _ => ""
          }
          return self.introspection_type_by_name(tn)
        }
      }
      let raw = match parent {
        Object(m) =>
          match m.get(name) {
            Some(v) => v
            None => Json::null()
          }
        _ => Json::null()
      }
      if obj.name == "__Type" && (name == "fields" || name == "enumValues") {
        return filter_deprecated(
          raw,
          args.get("includeDeprecated") is Some(True),
        )
      }
      raw
    }
  }
}

///|
/// Choose the concrete object type for a value at an interface position: if the
/// value carries a `__typename`, resolve to that object type; otherwise keep the
/// declared type.
fn Exec::concrete_type(
  self : Exec,
  declared : ObjectType,
  value : Json,
) -> ObjectType {
  match value {
    Object(m) =>
      match m.get("__typename") {
        Some(String(tn)) =>
          match self.schema.type_by_name(tn) {
            Some(t) => t
            None => declared
          }
        _ => declared
      }
    _ => declared
  }
}

///|
/// Serialise a leaf value through a custom scalar's `serialize` hook, or return
/// it unchanged for a built-in scalar or enum.
fn Exec::serialize_leaf(self : Exec, name : String, value : Json) -> Json {
  match self.schema.scalar_by_name(name) {
    Some(sc) => (sc.serialize)(value)
    None => value
  }
}

///|
/// Resolve the concrete member type for a value at a union position: read its
/// `__typename`, check that name is one of the union's members, and return that
/// object type. A missing or non-member `__typename` is a field error.
fn Exec::union_member(
  self : Exec,
  u : UnionType,
  value : Json,
  path : Array[Json],
  pos : Pos,
) -> ObjectType? {
  let tn = match value {
    Object(m) =>
      match m.get("__typename") {
        Some(String(s)) => s
        _ => ""
      }
    _ => ""
  }
  if tn == "" {
    self.add_error(
      "Cannot resolve concrete type for union '" +
      u.name +
      "': value has no __typename",
      path,
      pos,
    )
    return None
  }
  let mut is_member = false
  for m in u.members {
    if m == tn {
      is_member = true
    }
  }
  if not(is_member) {
    self.add_error(
      "Type '" + tn + "' is not a member of union '" + u.name + "'",
      path,
      pos,
    )
    return None
  }
  match self.schema.type_by_name(tn) {
    Some(t) => Some(t)
    None => {
      self.add_error("Union member type '" + tn + "' is not defined", path, pos)
      None
    }
  }
}

///|
/// The merged sub-selection sets of all fields grouped under one response key.
fn merge_subselections(fields : Array[QueryField]) -> Array[Selection] {
  let out : Array[Selection] = []
  for f in fields {
    for s in f.selection_set {
      out.push(s)
    }
  }
  out
}

///|
/// CompleteValue (GraphQL spec §6.4.3): coerce a resolved value to the shape its
/// field type demands. Non-null violations raise `NullBubble`, list items are
/// completed element-wise, leaf types serialise as-is, and composite types
/// recurse into their sub-selection. Introspection types (`__Schema`, `__Type`,
/// ...) complete against pre-materialised JSON via the default resolver.
fn Exec::complete(
  self : Exec,
  ftype : GqlType,
  value : Json,
  fields : Array[QueryField],
  path : Array[Json],
) -> Json raise NullBubble {
  // Every field in a group answers under one response key, so the first one is
  // the point in the document this value belongs to.
  let pos = fields[0].pos
  match ftype {
    NonNull(inner) => {
      let r = self.complete(inner, value, fields, path)
      if r is Null {
        self.add_error("Cannot return null for non-nullable field", path, pos)
        raise NullBubble
      }
      r
    }
    ListOf(inner) =>
      match value {
        Null => Json::null()
        Array(items) => {
          let out : Array[Json] = []
          for i, item in items {
            let ipath = path.copy()
            ipath.push(Json(i))
            out.push(self.complete(inner, item, fields, ipath))
          }
          Json(out)
        }
        _ => {
          self.add_error("Expected a list value", path, pos)
          Json::null()
        }
      }
    Scalar(name) => self.serialize_leaf(name, value)
    Named(name) =>
      if self.is_leaf_type(name) {
        self.serialize_leaf(name, value)
      } else {
        match value {
          Null => Json::null()
          _ =>
            if self.schema.union_by_name(name) is Some(u) {
              match self.union_member(u, value, path, pos) {
                Some(obj) =>
                  self.execute_selection_set(
                    obj,
                    merge_subselections(fields),
                    value,
                    path,
                  )
                None => Json::null()
              }
            } else {
              match self.output_type(name) {
                Some(decl) => {
                  let obj = self.concrete_type(decl, value)
                  self.execute_selection_set(
                    obj,
                    merge_subselections(fields),
                    value,
                    path,
                  )
                }
                None => {
                  self.add_error(
                    "Unknown output type '" + name + "'",
                    path,
                    pos,
                  )
                  Json::null()
                }
              }
            }
        }
      }
  }
}

///|
/// Look up an output object type by name, spanning the user schema and the
/// synthetic introspection types (`__Schema`, `__Type`, ...).
fn Exec::output_type(self : Exec, name : String) -> ObjectType? {
  match self.schema.type_by_name(name) {
    Some(t) => Some(t)
    None => introspection_type_def(name)
  }
}

///|
/// Execute one field group: resolve it, then complete it against its type,
/// absorbing a `NullBubble` into a null field value when the field is nullable
/// or re-raising it to null the parent when the field is non-null.
fn Exec::execute_field(
  self : Exec,
  obj : ObjectType,
  fields : Array[QueryField],
  parent : Json,
  path : Array[Json],
) -> Json raise NullBubble {
  let first = fields[0]
  match self.field_type_of(obj, first.name) {
    None => {
      self.add_error(
        "Cannot query field '" + first.name + "' on type '" + obj.name + "'",
        path,
        first.pos,
      )
      Json::null()
    }
    Some(ftype) => {
      let raw = self.resolve_raw(obj, first, parent, path)
      let value = self.complete(ftype, raw, fields, path) catch {
        NullBubble =>
          if ftype is NonNull(_) {
            raise NullBubble
          } else {
            Json::null()
          }
      }
      self.apply_exec_directives(first.directives, value)
    }
  }
}

///|
/// Apply any user-registered executable directives on `directives` to a field's
/// completed `value`, in order: each directive whose definition carries an
/// `on_field` hook transforms the value, threading the coerced directive
/// arguments. `@skip` / `@include` are not seen here — they were already resolved
/// during field collection — so only value-altering custom directives take effect.
fn Exec::apply_exec_directives(
  self : Exec,
  directives : Array[Directive],
  value : Json,
) -> Json {
  let mut out = value
  for d in directives {
    match self.schema.directive_def_by_name(d.name) {
      Some(def) =>
        match def.on_field {
          Some(hook) => {
            let args : Map[String, Json] = Map([])
            for a in d.arguments {
              args[a.name] = self.value_to_json(a.value)
            }
            out = hook(out, args)
          }
          None => ()
        }
      None => ()
    }
  }
  out
}

///|
/// ExecuteSelectionSet (GraphQL spec §6.3): collect fields on `obj`, execute
/// each group in order, and assemble the result object. A non-null field that
/// nulls out raises `NullBubble`, propagating to null this whole object.
fn Exec::execute_selection_set(
  self : Exec,
  obj : ObjectType,
  selections : Array[Selection],
  parent : Json,
  path : Array[Json],
) -> Json raise NullBubble {
  let keys : Array[String] = []
  let groups : Map[String, Array[QueryField]] = Map([])
  self.collect_fields(obj, selections, Map([]), keys, groups)
  let result : Map[String, Json] = Map([])
  for key in keys {
    let group = match groups.get(key) {
      Some(g) => g
      None => continue
    }
    let fpath = path.copy()
    fpath.push(Json(key))
    result[key] = self.execute_field(obj, group, parent, fpath)
  }
  Json(result)
}

///|
/// The parsed and validated inputs of one execution: the chosen operation and
/// the coerced variable values, or a request-level error list.
priv struct Prepared {
  operation : OperationDefinition
  root_type : String
}

///|
/// Select the operation to run and its root type. With no name, a single
/// operation is chosen; a name selects a matching operation. Returns the
/// operation plus its root type name, or a request error.
fn select_operation(
  schema : Schema,
  doc : Document,
  operation_name : String?,
) -> Result[Prepared, GqlError] {
  let ops : Array[OperationDefinition] = []
  for def in doc.definitions {
    match def {
      OperationDef(op) => ops.push(op)
      FragmentDef(_) => ()
    }
  }
  if ops.length() == 0 {
    return Err(GqlError::msg("Document contains no operations"))
  }
  let chosen = match operation_name {
    None =>
      if ops.length() == 1 {
        ops[0]
      } else {
        return Err(
          GqlError::msg(
            "Must provide operation name if query contains multiple operations",
          ),
        )
      }
    Some(name) => {
      let mut found : OperationDefinition? = None
      for op in ops {
        if op.name is Some(n) && n == name {
          found = Some(op)
        }
      }
      match found {
        Some(op) => op
        None =>
          return Err(GqlError::msg("Unknown operation named '" + name + "'"))
      }
    }
  }
  let root_type = match chosen.operation {
    Query => schema.query
    Mutation =>
      match schema.mutation {
        Some(m) => m
        None =>
          return Err(
            GqlError::at("Schema is not configured for mutations", chosen.pos),
          )
      }
    Subscription =>
      match schema.subscription {
        Some(s) => s
        None =>
          return Err(
            GqlError::at(
              "Schema is not configured for subscriptions",
              chosen.pos,
            ),
          )
      }
  }
  Ok({ operation: chosen, root_type, })
}

///|
/// Build the document's fragment table by name.
fn collect_fragments(doc : Document) -> Map[String, FragmentDefinition] {
  let m : Map[String, FragmentDefinition] = Map([])
  for def in doc.definitions {
    match def {
      FragmentDef(frag) => m[frag.name] = frag
      OperationDef(_) => ()
    }
  }
  m
}

///|
/// Coerce an operation's variable values: use the request-supplied value when
/// present, else the variable's default, else null.
///
/// `errors` collects the request errors §6.1.2 requires — a non-null variable with
/// no value, or `null` given for one. A caller that finds it non-empty must answer
/// with errors and no `data`, because execution never started. Without this a
/// missing `$id: ID!` reached the resolver as null and the request looked like it
/// had run.
fn coerce_variables(
  op : OperationDefinition,
  supplied : Map[String, Json],
  fragments : Map[String, FragmentDefinition],
  errors~ : Array[GqlError] = [],
) -> Map[String, Json] {
  let coerced : Map[String, Json] = Map([])
  // A throwaway executor is used only for default-value literal coercion, which
  // never dereferences a variable (defaults are constant).
  let tmp = {
    schema: Schema::new(),
    resolvers: Resolvers::new(),
    fragments,
    variables: Map([]),
    ctx: Json::null(),
    errors: [],
  }
  for vd in op.variable_definitions {
    let required = vd.typ is NonNullType(_)
    match supplied.get(vd.variable) {
      Some(v) => {
        if required && v is Null {
          errors.push(
            GqlError::at(
              "Variable '$" +
              vd.variable +
              "' of non-null type must not be null.",
              vd.pos,
            ),
          )
        }
        coerced[vd.variable] = v
      }
      None =>
        match vd.default_value {
          Some(dv) => coerced[vd.variable] = tmp.value_to_json(dv)
          None =>
            if required {
              errors.push(
                GqlError::at(
                  "Variable '$" +
                  vd.variable +
                  "' of required type was not provided.",
                  vd.pos,
                ),
              )
            }
        }
    }
  }
  coerced
}

///|
/// Assemble the final `{ errors?, data?, extensions? }` response object. `data`
/// is omitted for request-level failures (no execution began) and included
/// (possibly null) once execution starts; `errors` is omitted when empty, and so
/// is the server's `extensions` map (§7.1, the entry reserved for whatever a
/// server wants to say alongside the result — timings, a trace id, a cache hint).
fn build_response(
  data : Json?,
  errors : Array[GqlError],
  extensions~ : Map[String, Json] = Map([]),
) -> Json {
  let entries : Array[(String, Json)] = []
  match data {
    Some(d) => entries.push(("data", d))
    None => ()
  }
  if errors.length() > 0 {
    let arr : Array[Json] = []
    for e in errors {
      arr.push(e.to_json())
    }
    entries.push(("errors", Json(arr)))
  }
  if !extensions.is_empty() {
    entries.push(("extensions", Json(extensions)))
  }
  jobj(entries)
}

///|
/// Build a fresh per-request executor state with an empty error list.
fn Exec::state(
  schema : Schema,
  resolvers : Resolvers,
  fragments : Map[String, FragmentDefinition],
  variables : Map[String, Json],
  ctx : Json,
) -> Exec {
  { schema, resolvers, fragments, variables, ctx, errors: [], }
}

///|
/// Execute a top-level selection set against `root_type`, absorbing a `NullBubble`
/// that reaches the root into a null `data`.
fn Exec::run_root(
  self : Exec,
  root_type : ObjectType,
  selections : Array[Selection],
  root_value : Json,
) -> Json {
  self.execute_selection_set(root_type, selections, root_value, []) catch {
    NullBubble => Json::null()
  }
}

///|
/// Execute a GraphQL request end to end: parse `query`, validate it against
/// `schema`, select the operation, coerce variables, then walk the selection
/// set with `resolvers` — returning the `{ data, errors }` response as JSON.
///
/// `variables` supplies operation variable values, `operation_name` picks an
/// operation when the document has several, `root_value` seeds the root object,
/// `context` is threaded to every resolver, and `extensions` is the server's own
/// `extensions` entry on the response (§7.1), emitted when non-empty. The
/// function never raises: parse and validation failures yield an `errors`-only
/// response, and field errors are collected alongside partial `data`.
pub fn execute(
  schema : Schema,
  resolvers : Resolvers,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
  root_value~ : Json = Json::null(),
  context~ : Json = Json::null(),
  extensions~ : Map[String, Json] = Map([]),
) -> Json {
  let doc = parse(query) catch {
    GqlSyntaxError(m, line, col) =>
      return build_response(
        None,
        [GqlError::at(m, { line, col, })],
        extensions~,
      )
  }
  let verrors = validate(schema, doc)
  if verrors.length() > 0 {
    return build_response(None, verrors, extensions~)
  }
  let prepared = match select_operation(schema, doc, operation_name) {
    Ok(p) => p
    Err(e) => return build_response(None, [e], extensions~)
  }
  let fragments = collect_fragments(doc)
  let var_errors : Array[GqlError] = []
  let vars = coerce_variables(
    prepared.operation,
    variables,
    fragments,
    errors=var_errors,
  )
  if var_errors.length() > 0 {
    return build_response(None, var_errors, extensions~)
  }
  let exec = Exec::state(schema, resolvers, fragments, vars, context)
  let root_type = match schema.type_by_name(prepared.root_type) {
    Some(t) => t
    None =>
      return build_response(
        None,
        [GqlError::msg("Root type '" + prepared.root_type + "' is not defined")],
        extensions~,
      )
  }
  let data = exec.run_root(
    root_type,
    prepared.operation.selection_set,
    root_value,
  )
  build_response(Some(data), exec.errors, extensions~)
}
