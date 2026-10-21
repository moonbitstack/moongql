///|
/// Document-level validation rules (GraphQL spec §5), the ones that range over the
/// whole document rather than a single selection: operation-name uniqueness and
/// the lone-anonymous-operation rule (§5.2), fragment-name uniqueness (§5.5.1.1),
/// the no-unused-fragments rule (§5.5.1.4), and cycle detection on fragment
/// spreads (§5.5.2.2), plus the variable-usage collector the per-operation checks
/// (§5.8.4) rely on. These complement the per-selection rules in `validate.mbt`.

///|
/// §5.2.1.1 (Operation Name Uniqueness) and §5.2.2.1 (Lone Anonymous Operation):
/// no two operations may share a name, and an anonymous operation must be the only
/// operation in the document.
fn Validator::check_operation_names(
  self : Validator,
  doc : @lang.Document,
) -> Unit {
  let names : Array[String] = []
  let anon : Array[@lang.Pos] = []
  let mut total = 0
  for def in doc.definitions {
    match def {
      @lang.OperationDef(op) => {
        total = total + 1
        match op.name {
          Some(n) => {
            if str_in(names, n) {
              self.err_at(
                "There can be only one operation named '" + n + "'",
                op.pos,
              )
            }
            names.push(n)
          }
          None => anon.push(op.pos)
        }
      }
      @lang.FragmentDef(_) => ()
    }
  }
  if anon.length() > 0 && total > 1 {
    self.err_at(
      "This anonymous operation must be the only defined operation in the document",
      anon[0],
    )
  }
}

///|
/// §5.5.1.1 (Fragment Name Uniqueness): no two fragment definitions may share a
/// name.
fn Validator::check_fragment_uniqueness(
  self : Validator,
  doc : @lang.Document,
) -> Unit {
  let names : Array[String] = []
  for def in doc.definitions {
    match def {
      @lang.FragmentDef(fr) => {
        if str_in(names, fr.name) {
          self.err_at(
            "There can be only one fragment named '" + fr.name + "'",
            fr.pos,
          )
        }
        names.push(fr.name)
      }
      @lang.OperationDef(_) => ()
    }
  }
}

///|
/// Collect the fragment names spread anywhere within `selections`, following the
/// spreads transitively through the fragments they reference (used to compute the
/// set of fragments reachable from an operation).
fn Validator::collect_spreads(
  self : Validator,
  selections : Array[@lang.Selection],
  out : Array[String],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => self.collect_spreads(f.selection_set, out)
      FragmentSpreadSel(name, _, _) =>
        if !str_in(out, name) {
          out.push(name)
          match self.fragments.get(name) {
            Some(fr) => self.collect_spreads(fr.selection_set, out)
            None => ()
          }
        }
      InlineFragmentSel(_, _, sels, _) => self.collect_spreads(sels, out)
    }
  }
}

///|
/// §5.5.1.4 (Fragments Must Be Used): every defined fragment must be spread,
/// transitively, from at least one operation.
fn Validator::check_fragments_used(
  self : Validator,
  doc : @lang.Document,
) -> Unit {
  let reachable : Array[String] = []
  for def in doc.definitions {
    match def {
      @lang.OperationDef(op) =>
        self.collect_spreads(op.selection_set, reachable)
      @lang.FragmentDef(_) => ()
    }
  }
  for def in doc.definitions {
    match def {
      @lang.FragmentDef(fr) =>
        if !str_in(reachable, fr.name) {
          self.err_at("Fragment '" + fr.name + "' is never used", fr.pos)
        }
      @lang.OperationDef(_) => ()
    }
  }
}

///|
/// The fragment names spread directly within `selections` (descending through
/// inline fragments and fields but not following a spread into its fragment body).
fn Validator::direct_spreads(
  self : Validator,
  selections : Array[@lang.Selection],
  out : Array[String],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => self.direct_spreads(f.selection_set, out)
      FragmentSpreadSel(name, _, _) => if !str_in(out, name) { out.push(name) }
      InlineFragmentSel(_, _, sels, _) => self.direct_spreads(sels, out)
    }
  }
}

///|
/// Whether the fragment `current` can, by following spreads, reach `start`.
/// `visited` guards against revisiting a fragment so the walk terminates even on a
/// cyclic graph.
fn Validator::fragment_reaches(
  self : Validator,
  start : String,
  current : String,
  visited : Array[String],
) -> Bool {
  match self.fragments.get(current) {
    None => false
    Some(fr) => {
      let spreads : Array[String] = []
      self.direct_spreads(fr.selection_set, spreads)
      for s in spreads {
        if s == start {
          return true
        }
        if !str_in(visited, s) {
          visited.push(s)
          if self.fragment_reaches(start, s, visited) {
            return true
          }
        }
      }
      false
    }
  }
}

///|
/// §5.5.2.2 (Fragment Spreads Must Not Form Cycles): a fragment must not be able
/// to spread itself, directly or transitively. The names it flags are kept so that
/// later rules which expand spreads can leave them alone and still terminate.
fn Validator::check_fragment_cycles(
  self : Validator,
  doc : @lang.Document,
) -> Unit {
  for def in doc.definitions {
    match def {
      @lang.FragmentDef(fr) =>
        if self.fragment_reaches(fr.name, fr.name, []) {
          self.err_at(
            "Fragment '" + fr.name + "' spreads itself (cycle)",
            fr.pos,
          )
          self.cyclic.push(fr.name)
        }
      @lang.OperationDef(_) => ()
    }
  }
}

///|
/// One field selected under a response key, with the type it was selected on and
/// the fragment it arrived through (`""` for a field written into the set itself).
/// The origin is what keeps a fragment's internal conflicts from being reported
/// twice — once where it is spread, again when the definition is checked.
priv struct Keyed {
  parent : String
  origin : String
  field : @lang.QueryField
}

///|
/// The response key a field answers under: its alias, else its name.
fn response_key(f : @lang.QueryField) -> String {
  match f.alias_ {
    Some(a) => a
    None => f.name
  }
}

///|
/// Flatten a selection set to the fields it contributes, descending through inline
/// fragments and spreads and recording the type each field was selected on. A
/// fragment on a spread cycle is left alone: §5.5.2.2 has already reported it, and
/// expanding it here would not terminate.
fn Validator::keyed_fields(
  self : Validator,
  type_name : String,
  selections : Array[@lang.Selection],
  origin : String,
  seen : Array[String],
  out : Array[Keyed],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => out.push({ parent: type_name, origin, field: f, })
      InlineFragmentSel(cond, _, sels, _) => {
        let inner = match cond {
          Some(c) => c
          None => type_name
        }
        self.keyed_fields(inner, sels, origin, seen, out)
      }
      FragmentSpreadSel(name, _, _) =>
        if !str_in(seen, name) && !str_in(self.cyclic, name) {
          seen.push(name)
          match self.fragments.get(name) {
            Some(fr) =>
              self.keyed_fields(
                fr.type_condition,
                fr.selection_set,
                if origin == "" {
                  name
                } else {
                  origin
                },
                seen,
                out,
              )
            None => ()
          }
        }
    }
  }
}

///|
/// Whether `name` is an object type, so two fields selected on different such
/// types can never appear in the same response object (← the spec's mutually
/// exclusive fields). An interface or a union says nothing about the runtime type.
fn Validator::is_object(self : Validator, name : String) -> Bool {
  match self.lookup_type(name) {
    Some(t) => t.kind is Object
    None => false
  }
}

///|
/// The declared type of `name` on `parent`, or `None` when neither the schema nor
/// introspection knows it — a field already reported as unselectable, or a meta
/// field the schema does not carry.
fn Validator::field_type(
  self : Validator,
  parent : String,
  name : String,
) -> @schema.GqlType? {
  if name == "__typename" {
    return Some(NonNull(@schema.Scalar("String")))
  }
  match self.lookup_type(parent) {
    Some(t) =>
      match t.field_by_name(name) {
        Some(f) => Some(f.typ)
        None => None
      }
    None => None
  }
}

///|
/// SameResponseShape (spec §5.3.2): whether two field types could never serialise
/// into one value. Wrappers must line up exactly; leaf types must be the same type;
/// two composite types are left to their sub-selections to reconcile.
fn Validator::types_conflict(
  self : Validator,
  a : @schema.GqlType,
  b : @schema.GqlType,
) -> Bool {
  match (a, b) {
    (ListOf(x), ListOf(y)) => self.types_conflict(x, y)
    (ListOf(_), _) | (_, ListOf(_)) => true
    (NonNull(x), NonNull(y)) => self.types_conflict(x, y)
    (NonNull(_), _) | (_, NonNull(_)) => true
    _ => {
      let (x, y) = (a.named_base(), b.named_base())
      (self.is_leaf(x) || self.is_leaf(y)) && x != y
    }
  }
}

///|
/// Whether two argument lists request the same thing. Order does not matter;
/// values are compared as they print, so a default filling in for an omitted
/// argument does not count as equal — the spec compares what was written.
fn args_equal(a : Array[@lang.Argument], b : Array[@lang.Argument]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for x in a {
    let mut same = false
    for y in b {
      if y.name == x.name {
        same = x.value.to_query() == y.value.to_query()
        break
      }
    }
    if !same {
      return false
    }
  }
  true
}

///|
/// Why two fields sharing a response key cannot merge, or `None` if they can.
/// `exclusive` says the two can never land in the same response object, which
/// leaves only the shape of the result to agree on — that is how a union or
/// interface may answer one key with a different field per member type.
fn Validator::merge_conflict(
  self : Validator,
  a : Keyed,
  b : Keyed,
  exclusive : Bool,
) -> String? {
  if !exclusive {
    if a.field.name != b.field.name {
      return Some(
        "'" + a.field.name + "' and '" + b.field.name + "' are different fields",
      )
    }
    if !args_equal(a.field.arguments, b.field.arguments) {
      return Some("they have differing arguments")
    }
  }
  let ta = self.field_type(a.parent, a.field.name)
  let tb = self.field_type(b.parent, b.field.name)
  if ta is Some(x) && tb is Some(y) && self.types_conflict(x, y) {
    return Some(
      "they return conflicting types '" +
      @schema.type_sdl(x) +
      "' and '" +
      @schema.type_sdl(y) +
      "'",
    )
  }
  if a.field.selection_set.is_empty() || b.field.selection_set.is_empty() {
    return None
  }
  let (la, lb) : (Array[Keyed], Array[Keyed]) = ([], [])
  self.keyed_fields(sub_parent(ta, a), a.field.selection_set, "", [], la)
  self.keyed_fields(sub_parent(tb, b), b.field.selection_set, "", [], lb)
  for x in la {
    for y in lb {
      let key = response_key(x.field)
      if key != response_key(y.field) {
        continue
      }
      let sub = exclusive || self.exclusive(x.parent, y.parent)
      match self.merge_conflict(x, y, sub) {
        Some(why) =>
          return Some("subfields '" + key + "' conflict because " + why)
        None => ()
      }
    }
  }
  None
}

///|
/// The type a field's sub-selection is taken on, falling back to the field's own
/// parent when the schema does not declare the field (already reported elsewhere).
fn sub_parent(t : @schema.GqlType?, k : Keyed) -> String {
  match t {
    Some(x) => x.named_base()
    None => k.parent
  }
}

///|
/// Whether two fields selected on `a` and `b` are mutually exclusive.
fn Validator::exclusive(self : Validator, a : String, b : String) -> Bool {
  a != b && self.is_object(a) && self.is_object(b)
}

///|
/// FieldsInSetCanMerge (spec §5.3.2): fields that share a response key must be able
/// to produce one value — the same field, the same arguments, and sub-selections
/// that merge in turn. Without it `{ a: name a: email }` executed as `a: <name>`
/// with `email`'s selections folded in, because the executor concatenates the
/// sub-selections of same-key fields without ever comparing them.
fn Validator::check_can_merge(
  self : Validator,
  type_name : String,
  selections : Array[@lang.Selection],
) -> Unit {
  let fields : Array[Keyed] = []
  self.keyed_fields(type_name, selections, "", [], fields)
  for i in 0..<fields.length() {
    for j in (i + 1)..<fields.length() {
      let (a, b) = (fields[i], fields[j])
      let key = response_key(a.field)
      if key != response_key(b.field) ||
        (a.origin == b.origin && a.origin != "") {
        continue
      }
      match self.merge_conflict(a, b, self.exclusive(a.parent, b.parent)) {
        Some(why) =>
          self.err_at(
            "Fields '" +
            key +
            "' conflict because " +
            why +
            ". Use different aliases on the fields to fetch both if this was intentional.",
            a.field.pos,
          )
        None => ()
      }
    }
  }
}

///|
/// Collect the variable names referenced inside a value, descending into list and
/// object values. Each name is kept with `pos`, the argument it was written in, so
/// an undefined variable can be reported where a reader will find it.
fn collect_value_variables(
  v : @lang.Value,
  pos : @lang.Pos,
  out : Array[(String, @lang.Pos)],
) -> Unit {
  match v {
    Variable(n) =>
      if out.search_by(u => u.0 == n) is None {
        out.push((n, pos))
      }
    ListValue(items) =>
      for it in items {
        collect_value_variables(it, pos, out)
      }
    ObjectValue(fields) =>
      for kv in fields {
        collect_value_variables(kv.1, pos, out)
      }
    _ => ()
  }
}

///|
/// Collect the variable names an operation actually uses: from field and directive
/// arguments across the selection set, following fragment spreads once each. Backs
/// the §5.8.4 "all variables used" check.
fn Validator::collect_used_variables(
  self : Validator,
  selections : Array[@lang.Selection],
  visited : Map[String, Bool],
  out : Array[(String, @lang.Pos)],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => {
        for a in f.arguments {
          collect_value_variables(a.value, a.pos, out)
        }
        for d in f.directives {
          for a in d.arguments {
            collect_value_variables(a.value, a.pos, out)
          }
        }
        self.collect_used_variables(f.selection_set, visited, out)
      }
      FragmentSpreadSel(name, dirs, _) => {
        for d in dirs {
          for a in d.arguments {
            collect_value_variables(a.value, a.pos, out)
          }
        }
        if !(visited.get(name) is Some(true)) {
          visited[name] = true
          match self.fragments.get(name) {
            Some(fr) =>
              self.collect_used_variables(fr.selection_set, visited, out)
            None => ()
          }
        }
      }
      InlineFragmentSel(_, dirs, sels, _) => {
        for d in dirs {
          for a in d.arguments {
            collect_value_variables(a.value, a.pos, out)
          }
        }
        self.collect_used_variables(sels, visited, out)
      }
    }
  }
}
