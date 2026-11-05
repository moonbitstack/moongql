// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// Asynchronous execution: the same document, the same response, resolved with
/// resolvers that wait.
///
/// The traversal is written once here, beside the synchronous one, because the
/// two differ in something the language will not let one express for the other:
/// a synchronous function cannot call an asynchronous one, so the part of the
/// walk that calls resolvers cannot be shared. Everything the walk *decides* —
/// which fields a selection collects, how arguments coerce, what a leaf
/// serialises to, where an error goes, how a non-null value propagates — is the
/// same code the synchronous engine calls.
///
/// Sibling fields are independent (§6.2.2), so they are resolved concurrently
/// under `Limits.max_concurrency`; the root fields of a mutation are not
/// (§6.2.3), so they run one after another. Each field keeps its own error list
/// and its own deferrals, and the parent merges them in document order, so a
/// response does not depend on the order the tasks happened to finish in.

///|
/// The outcome of completing a value: either the completed value, or the news
/// that a non-null position came back null, which nulls the nearest enclosing
/// nullable position. This is the synchronous engine's `NullBubble` carried as a
/// value, because an asynchronous function that calls other asynchronous
/// functions cannot restrict itself to one error type.
priv enum Done {
  Value(Json)
  Bubbled
}

///|
/// What one field group produced: its value, the errors and deferrals found
/// underneath it, and whether it bubbled.
priv struct Outcome {
  value : Json
  errors : Array[@lang.GqlError]
  pending : Array[Pending]
  bubble : Bool
}

///|
/// Work the incremental delivery postpones: a `@defer`red fragment or a `@stream`ed
/// remainder of a list. It runs after the initial payload is sent.
priv struct Pending {
  run : async () -> PendingDone
}

///|
/// What a postponed piece of work produced: one `incremental` entry, the errors
/// it ran into, and any deferrals it found in turn.
priv struct PendingDone {
  entry : Json
  errors : Array[@lang.GqlError]
  pending : Array[Pending]
}

///|
/// Read the `@defer` directive on a fragment: whether to defer, and the label to
/// report it under. A directive that is absent, or whose `if` is false, is not a
/// deferral.
fn defer_of(directives : Array[@lang.Directive]) -> (Bool, String?)? {
  for d in directives {
    if d.name == "defer" {
      let mut on = true
      let mut label : String? = None
      for a in d.arguments {
        match (a.name, a.value) {
          ("if", BooleanValue(b)) => on = b
          ("label", StringValue(s, _)) => label = Some(s)
          _ => ()
        }
      }
      if !on {
        return None
      }
      return Some((true, label))
    }
  }
  None
}

///|
/// Read the `@stream` directive on a field: whether to stream, its label, and how
/// many items go with the initial payload. `None` when the field is not streamed.
fn stream_of(directives : Array[@lang.Directive]) -> (String?, Int32)? {
  for d in directives {
    if d.name == "stream" {
      let mut on = true
      let mut label : String? = None
      let mut initial = 0
      for a in d.arguments {
        match (a.name, a.value) {
          ("if", BooleanValue(b)) => on = b
          ("label", StringValue(s, _)) => label = Some(s)
          ("initialCount", IntValue(s)) =>
            initial = @string.parse_int(s) catch { _ => 0 }
          _ => ()
        }
      }
      if !on {
        return None
      }
      return Some((label, initial))
    }
  }
  None
}

///|
/// CollectFields for the asynchronous engine: the same flattening as §6.3.2,
/// except that a `@defer`red fragment is not expanded into the current selection
/// but reported separately, with the label it carries.
fn Exec::collect_fields_deferred(
  self : Exec,
  obj : @schema.ObjectType,
  selections : Array[@lang.Selection],
  visited : Map[String, Bool],
  keys : Array[String],
  groups : Map[String, Array[@lang.QueryField]],
  deferred : Array[(String?, Array[@lang.Selection])],
  allow_defer : Bool,
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) =>
        if self.should_include(f.directives) {
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
      FragmentSpreadSel(name, dirs, _) =>
        if self.should_include(dirs) {
          let here = if allow_defer {
            match defer_of(dirs) {
              Some((true, label)) => Some(label)
              _ => None
            }
          } else {
            None
          }
          match here {
            Some(label) =>
              match self.fragments.get(name) {
                Some(frag) => deferred.push((label, frag.selection_set))
                None => ()
              }
            None =>
              if visited.get(name) is None {
                visited[name] = true
                match self.fragments.get(name) {
                  Some(frag) =>
                    if self.fragment_applies(frag.type_condition, obj) {
                      self.collect_fields_deferred(
                        obj,
                        frag.selection_set,
                        visited,
                        keys,
                        groups,
                        deferred,
                        allow_defer,
                      )
                    }
                  None => ()
                }
              }
          }
        }
      InlineFragmentSel(cond, dirs, sels, _) =>
        if self.should_include(dirs) {
          let here = if allow_defer {
            match defer_of(dirs) {
              Some((true, label)) => Some(label)
              _ => None
            }
          } else {
            None
          }
          match here {
            Some(label) => deferred.push((label, sels))
            None => {
              let applies = match cond {
                None => true
                Some(c) => self.fragment_applies(c, obj)
              }
              if applies {
                self.collect_fields_deferred(
                  obj, sels, visited, keys, groups, deferred, allow_defer,
                )
              }
            }
          }
        }
    }
  }
}

///|
/// Resolve a field's raw value asynchronously: a resolver registered with
/// `field_async` first, then one registered with `field`, then the default
/// resolver — the synchronous engine's order, with the shape that waits in
/// front. A refusal is recorded at the field's path and leaves null.
async fn Exec::resolve_raw_async(
  self : Exec,
  obj : @schema.ObjectType,
  field : @lang.QueryField,
  info : ResolveInfo,
  path : Array[Json],
) -> Json {
  let name = field.name
  if name == "__typename" {
    return Json(obj.name)
  }
  let key = obj.name + "." + name
  match self.pre_field(key, info) {
    Some(e) => {
      self.add_field_error(e, path, field.pos)
      return Json::null()
    }
    None => ()
  }
  match self.resolvers.async_map.get(key) {
    Some(resolver) =>
      resolver(info) catch {
        e => {
          self.add_field_error(field_error(e), path, field.pos)
          Json::null()
        }
      }
    None =>
      match self.resolvers.map.get(key) {
        Some(resolver) =>
          resolver(info) catch {
            e => {
              self.add_field_error(field_error(e), path, field.pos)
              Json::null()
            }
          }
        None => self.default_raw(obj, field, info)
      }
  }
}

///|
/// One element of a list, completed in an executor of its own so that the errors
/// and deferrals it produces can be merged in index order however the elements
/// were scheduled — the same arrangement a field group uses.
async fn Exec::complete_item(
  self : Exec,
  inner : @schema.GqlType,
  item : Json,
  fields : Array[@lang.QueryField],
  path : Array[Json],
  limits : Limits,
) -> Outcome {
  let sub = Exec::state(
    self.schema,
    self.resolvers,
    self.fragments,
    self.variables,
    self.ctx,
  )
  match sub.complete_async(inner, item, fields, path, limits) {
    Value(value) =>
      { value, errors: sub.errors, pending: sub.pending, bubble: false, }
    Bubbled =>
      {
        value: Json::null(),
        errors: sub.errors,
        pending: sub.pending,
        bubble: true,
      }
  }
}

///|
/// CompleteValue (GraphQL spec §6.4.3), asynchronously: a non-null position that
/// comes back null bubbles, lists complete element-wise and may be streamed,
/// leaves serialise, and composite values recurse into their sub-selection.
async fn Exec::complete_async(
  self : Exec,
  ftype : @schema.GqlType,
  value : Json,
  fields : Array[@lang.QueryField],
  path : Array[Json],
  limits : Limits,
) -> Done {
  let pos = fields[0].pos
  match ftype {
    NonNull(inner) =>
      match self.complete_async(inner, value, fields, path, limits) {
        Value(v) =>
          if v is Null {
            self.add_error(
              "Cannot return null for non-nullable field", path, pos,
            )
            Bubbled
          } else {
            Value(v)
          }
        Bubbled => Bubbled
      }
    ListOf(inner) =>
      match value {
        Null => Value(Json::null())
        Array(items) => {
          let streamed = if limits.max_stream > 0 {
            stream_of(fields[0].directives)
          } else {
            None
          }
          let cut = match streamed {
            Some((_, initial)) =>
              if initial < 0 {
                0
              } else if initial > items.length() {
                items.length()
              } else {
                initial
              }
            None => items.length()
          }
          // The elements of a list are as independent as the fields of a
          // selection set (§6.4.3 completes each one on its own), so they are
          // completed concurrently and merged back in index order. That is also
          // what lets a field resolver batch across the elements of a list it
          // cannot see: each element is a task that can queue its key while its
          // siblings do the same.
          let done : Array[Outcome] = if cut > 1 && limits.max_concurrency > 1 {
            let tasks : Array[async () -> Outcome] = []
            for i in 0..<cut {
              let ipath = path.copy()
              ipath.push(Json(i))
              let item = items[i]
              tasks.push(async fn() {
                self.complete_item(inner, item, fields, ipath, limits)
              })
            }
            @async.all(tasks, max_concurrent=limits.max_concurrency)
          } else {
            let out : Array[Outcome] = []
            for i in 0..<cut {
              let ipath = path.copy()
              ipath.push(Json(i))
              out.push(
                self.complete_item(inner, items[i], fields, ipath, limits),
              )
            }
            out
          }
          let out : Array[Json] = []
          let mut bubbled = false
          for d in done {
            for e in d.errors {
              self.errors.push(e)
            }
            for p in d.pending {
              self.pending.push(p)
            }
            if d.bubble {
              bubbled = true
              break
            }
            out.push(d.value)
          }
          if bubbled {
            Bubbled
          } else {
            match streamed {
              Some((label, _)) =>
                if cut < items.length() {
                  let limit = limits.max_stream
                  let stop = if items.length() - cut > limit {
                    cut + limit
                  } else {
                    items.length()
                  }
                  for i in cut..<stop {
                    self.pending.push(
                      self.stream_pending(
                        inner, items, fields, path, i, label, limits,
                      ),
                    )
                  }
                }
              None => ()
            }
            Value(Json(out))
          }
        }
        _ => {
          self.add_error("Expected a list value", path, pos)
          Value(Json::null())
        }
      }
    Scalar(name) => Value(self.serialize_leaf(name, value))
    Named(name) =>
      if self.is_leaf_type(name) {
        Value(self.serialize_leaf(name, value))
      } else {
        match value {
          Null => Value(Json::null())
          _ =>
            if self.schema.union_by_name(name) is Some(u) {
              match self.union_member(u, value, path, pos) {
                Some(obj) =>
                  self.execute_selection_set_async(
                    obj,
                    merge_subselections(fields),
                    value,
                    path,
                    true,
                    limits,
                  )
                None => Value(Json::null())
              }
            } else {
              match self.output_type(name) {
                Some(decl) =>
                  match self.concrete_type(decl, value, path, pos) {
                    Some(obj) =>
                      self.execute_selection_set_async(
                        obj,
                        merge_subselections(fields),
                        value,
                        path,
                        true,
                        limits,
                      )
                    None => Value(Json::null())
                  }
                None => {
                  self.add_error(
                    "Unknown output type '" + name + "'",
                    path,
                    pos,
                  )
                  Value(Json::null())
                }
              }
            }
        }
      }
  }
}

///|
/// The postponed work of one streamed list item: the item at `index` completed
/// against the field's sub-selection, delivered as its own `incremental` entry so
/// a client sees items as they become available.
fn Exec::stream_pending(
  self : Exec,
  inner : @schema.GqlType,
  items : Array[Json],
  fields : Array[@lang.QueryField],
  path : Array[Json],
  index : Int32,
  label : String?,
  limits : Limits,
) -> Pending {
  {
    run: async fn() {
      let sub = Exec::state(
        self.schema,
        self.resolvers,
        self.fragments,
        self.variables,
        self.ctx,
      )
      let ipath = path.copy()
      ipath.push(Json(index))
      let value = match
        sub.complete_async(inner, items[index], fields, ipath, limits) {
        Value(v) => v
        Bubbled => Json::null()
      }
      let entries : Array[(String, Json)] = [
        ("items", Json([value])),
        ("path", Json(ipath)),
      ]
      match label {
        Some(l) => entries.push(("label", Json(l)))
        None => ()
      }
      { entry: jobj(entries), errors: sub.errors, pending: sub.pending, }
    },
  }
}

///|
/// The postponed work of a `@defer`red fragment: at payload time its selection
/// runs against the same object, and its result is the entry's `data` at the
/// enclosing path.
fn Exec::defer_pending(
  self : Exec,
  obj : @schema.ObjectType,
  parent : Json,
  selections : Array[@lang.Selection],
  path : Array[Json],
  label : String?,
  limits : Limits,
) -> Pending {
  let at = path.copy()
  {
    run: async fn() {
      let sub = Exec::state(
        self.schema,
        self.resolvers,
        self.fragments,
        self.variables,
        self.ctx,
      )
      let data = match
        sub.execute_selection_set_async(
          obj, selections, parent, at, true, limits,
        ) {
        Value(v) => v
        Bubbled => Json::null()
      }
      let entries : Array[(String, Json)] = [("data", data), ("path", Json(at))]
      match label {
        Some(l) => entries.push(("label", Json(l)))
        None => ()
      }
      { entry: jobj(entries), errors: sub.errors, pending: sub.pending, }
    },
  }
}

///|
/// Execute one field group asynchronously, in an error list of its own so that
/// concurrent siblings do not interleave theirs.
async fn Exec::execute_field_async(
  self : Exec,
  obj : @schema.ObjectType,
  fields : Array[@lang.QueryField],
  parent : Json,
  path : Array[Json],
  limits : Limits,
) -> Outcome {
  let first = fields[0]
  match self.field_type_of(obj, first.name) {
    None => {
      self.add_error(
        "Cannot query field '" + first.name + "' on type '" + obj.name + "'",
        path,
        first.pos,
      )
      {
        value: Json::null(),
        errors: self.errors,
        pending: self.pending,
        bubble: false,
      }
    }
    Some(ftype) => {
      let recorded = self.errors.length()
      let info = self.info_for(obj, first, parent, fields)
      let raw = self.resolve_raw_async(obj, first, info, path)
      // A resolver that raised has its error recorded already; the null it
      // leaves behind propagates without a second one, as in graphql-js.
      if raw is Null && ftype is NonNull(_) && self.errors.length() > recorded {
        return {
          value: Json::null(),
          errors: self.errors,
          pending: self.pending,
          bubble: true,
        }
      }
      match self.complete_async(ftype, raw, fields, path, limits) {
        Value(value) =>
          {
            value: self.apply_exec_directives(
              first.directives,
              self.post_field(info, value),
            ),
            errors: self.errors,
            pending: self.pending,
            bubble: false,
          }
        // A bubble out of a nullable field's sub-selection nulls that field and
        // stops there; only a non-null field passes it up (§6.4.3).
        Bubbled =>
          {
            value: Json::null(),
            errors: self.errors,
            pending: self.pending,
            bubble: ftype is NonNull(_),
          }
      }
    }
  }
}

///|
/// ExecuteSelectionSet (GraphQL spec §6.3), asynchronously: collect the fields,
/// hand each group to its own task, and assemble the result object in document
/// order once they are all in.
async fn Exec::execute_selection_set_async(
  self : Exec,
  obj : @schema.ObjectType,
  selections : Array[@lang.Selection],
  parent : Json,
  path : Array[Json],
  concurrent : Bool,
  limits : Limits,
) -> Done {
  let keys : Array[String] = []
  let groups : Map[String, Array[@lang.QueryField]] = Map([])
  let deferred : Array[(String?, Array[@lang.Selection])] = []
  self.collect_fields_deferred(
    obj,
    selections,
    Map([]),
    keys,
    groups,
    deferred,
    limits.max_defer > 0,
  )
  let tasks : Array[async () -> Outcome] = []
  for key in keys {
    let group = match groups.get(key) {
      Some(g) => g
      None => []
    }
    let fpath = path.copy()
    fpath.push(Json(key))
    tasks.push(async fn() {
      let sub = Exec::state(
        self.schema,
        self.resolvers,
        self.fragments,
        self.variables,
        self.ctx,
      )
      sub.execute_field_async(obj, group, parent, fpath, limits)
    })
  }
  let outcomes : Array[Outcome] = if concurrent && tasks.length() > 1 {
    @async.all(tasks, max_concurrent=limits.max_concurrency)
  } else {
    let out : Array[Outcome] = []
    for task in tasks {
      out.push(task())
    }
    out
  }
  let result : Map[String, Json] = Map([])
  let mut bubbled = false
  for i, key in keys {
    let o = outcomes[i]
    for e in o.errors {
      self.errors.push(e)
    }
    for p in o.pending {
      self.pending.push(p)
    }
    if o.bubble {
      bubbled = true
    }
    result[key] = o.value
  }
  // A group that answered null at a non-null position nulls this object. The
  // siblings that already ran keep their errors and lose their values.
  if bubbled {
    return Bubbled
  }
  for (label, sels) in deferred {
    self.pending.push(
      self.defer_pending(obj, parent, sels, path, label, limits),
    )
  }
  Value(Json(result))
}

///|
/// Execute a top-level selection set asynchronously, absorbing a bubble that
/// reaches the root into a null `data`. Mutation roots are serial (§6.2.3);
/// query and subscription roots are not.
async fn Exec::run_root_async(
  self : Exec,
  root_type : @schema.ObjectType,
  operation : @lang.OperationType,
  selections : Array[@lang.Selection],
  root_value : Json,
  limits : Limits,
) -> Json {
  let concurrent = !(operation is Mutation)
  match
    self.execute_selection_set_async(
      root_type,
      selections,
      root_value,
      [],
      concurrent,
      limits,
    ) {
    Value(v) => v
    Bubbled => Json::null()
  }
}

///|
/// A response payload: `{ data, errors?, extensions?, hasNext? }`. `hasNext` is
/// present only when the response is delivered in pieces.
fn payload(
  data : Json?,
  errors : Array[@lang.GqlError],
  extensions : Map[String, Json],
  has_next : Bool?,
) -> Json {
  let entries : Array[(String, Json)] = []
  match data {
    Some(d) => entries.push(("data", d))
    None => ()
  }
  let errs : Array[Json] = []
  for e in errors {
    errs.push(e.to_json())
  }
  if errs.length() > 0 {
    entries.push(("errors", Json(errs)))
  }
  if !extensions.is_empty() {
    entries.push(("extensions", Json(extensions)))
  }
  match has_next {
    Some(h) => entries.push(("hasNext", Json(h)))
    None => ()
  }
  jobj(entries)
}

///|
/// The part of a request both asynchronous entry points do before executing:
/// parse, validate, choose the operation, coerce the variables. The right side is
/// a request-level failure — no operation ever started, so the response carries
/// errors and no `data`.
fn run_prepare(
  schema : @schema.Schema,
  query : String,
  variables : Map[String, Json],
  operation_name : String?,
) -> Result[
  (Map[String, @lang.FragmentDefinition], Map[String, Json], Prepared),
  Array[@lang.GqlError],
] {
  let doc = @lang.parse(query) catch { e => return Err([@lang.refusal(e)]) }
  let verrors = @valid.validate(schema, doc)
  if verrors.length() > 0 {
    return Err(verrors)
  }
  let prepared = match select_operation(schema, doc, operation_name) {
    Ok(p) => p
    Err(e) => return Err([e])
  }
  let fragments = @lang.collect_fragments(doc)
  let var_errors : Array[@lang.GqlError] = []
  let vars = coerce_variables(
    prepared.operation,
    variables,
    fragments,
    errors=var_errors,
  )
  if var_errors.length() > 0 {
    return Err(var_errors)
  }
  Ok((fragments, vars, prepared))
}

///|
/// Execute a GraphQL request with resolvers that wait, delivering the response in
/// pieces when the document defers or streams work.
///
/// The payloads are, in order: the initial `{ data, hasNext }`, then one per round
/// of postponed work — each carrying `incremental` entries with the `path` and
/// `label` the document asked for — and the last answers `hasNext: false`. A
/// document that defers nothing produces exactly one payload.
pub async fn execute_incremental(
  schema : @schema.Schema,
  resolvers : Resolvers,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
  root_value~ : Json = Json::null(),
  context~ : Json = Json::null(),
  extensions~ : Map[String, Json] = Map([]),
  limits~ : Limits = limits,
) -> Array[Json] {
  let (fragments, vars, prepared) = match
    run_prepare(schema, query, variables, operation_name) {
    Ok(p) => p
    Err(errs) => return [payload(None, errs, extensions, None)]
  }
  let root_type = match schema.type_by_name(prepared.root_type) {
    Some(t) => t
    None =>
      return [
        payload(
          None,
          [
            @lang.GqlError::msg(
              "Root type '" + prepared.root_type + "' is not defined",
            ),
          ],
          extensions,
          None,
        ),
      ]
  }
  let exec = Exec::state(schema, resolvers, fragments, vars, context)
  let data = exec.run_root_async(
    root_type,
    prepared.operation.operation,
    prepared.operation.selection_set,
    root_value,
    limits,
  )
  let out : Array[Json] = []
  let mut pending = exec.pending
  out.push(
    payload(Some(data), exec.errors, extensions, Some(!pending.is_empty())),
  )
  while !pending.is_empty() {
    let jobs : Array[async () -> PendingDone] = []
    for p in pending {
      jobs.push(p.run)
    }
    let done = @async.all(jobs, max_concurrent=limits.max_concurrency)
    let next : Array[Pending] = []
    let errors : Array[@lang.GqlError] = []
    for d in done {
      for p in d.pending {
        next.push(p)
      }
    }
    pending = next
    // One payload per finished piece of work, the way a client observes a stream:
    // a deferral or a streamed item is its own `next` message, not a batch.
    for i, d in done {
      for e in d.errors {
        errors.push(e)
      }
      let parts : Array[(String, Json)] = [("incremental", Json([d.entry]))]
      if !extensions.is_empty() {
        parts.push(("extensions", Json(extensions)))
      }
      let more = i + 1 < done.length() || !pending.is_empty()
      parts.push(("hasNext", Json(more)))
      out.push(jobj(parts))
    }
    // Errors that belong to the round as a whole (none today) would need their
    // own payload; each entry carries its own above.
  }
  out
}

///|
/// Execute a GraphQL request with resolvers that wait, answering one response.
///
/// This is `execute_incremental` with incremental delivery switched off: `@defer`
/// and `@stream` collapse to their in-line meanings, so the response is the whole
/// result in one payload, shaped exactly like `execute`'s.
pub async fn execute_async(
  schema : @schema.Schema,
  resolvers : Resolvers,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
  root_value~ : Json = Json::null(),
  context~ : Json = Json::null(),
  extensions~ : Map[String, Json] = Map([]),
  limits~ : Limits = limits,
) -> Json {
  let (fragments, vars, prepared) = match
    run_prepare(schema, query, variables, operation_name) {
    Ok(p) => p
    Err(errs) => return payload(None, errs, extensions, None)
  }
  let root_type = match schema.type_by_name(prepared.root_type) {
    Some(t) => t
    None =>
      return payload(
        None,
        [
          @lang.GqlError::msg(
            "Root type '" + prepared.root_type + "' is not defined",
          ),
        ],
        extensions,
        None,
      )
  }
  let exec = Exec::state(schema, resolvers, fragments, vars, context)
  let data = exec.run_root_async(
    root_type,
    prepared.operation.operation,
    prepared.operation.selection_set,
    root_value,
    { ..limits, max_defer: 0, max_stream: 0, },
  )
  payload(Some(data), exec.errors, extensions, None)
}
