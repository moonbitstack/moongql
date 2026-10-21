///|
/// The GraphQL validator (spec §5, the subset that matters before execution):
/// every selected field exists on its parent type, leaf fields carry no
/// sub-selection while composite fields require one, field arguments are declared
/// (and required arguments supplied), fragment spreads name existing fragments,
/// fragment type conditions name existing types, and every referenced variable
/// is defined with a type that exists. Errors are collected, not raised, so
/// `execute` can report them all in one `{ errors }` response.

///|
/// Validator state: the schema, the document's fragments, the fragments that lie
/// on a spread cycle, and the error list.
priv struct Validator {
  schema : @schema.Schema
  fragments : Map[String, @lang.FragmentDefinition]
  cyclic : Array[String]
  errors : Array[@lang.GqlError]
}

///|
/// Look up an output object/interface/input or synthetic introspection type.
fn Validator::lookup_type(
  self : Validator,
  name : String,
) -> @schema.ObjectType? {
  match self.schema.type_by_name(name) {
    Some(t) => Some(t)
    None => @schema.introspection_type_def(name)
  }
}

///|
/// Whether `name` is a leaf type (scalar or enum) with no selectable subfields.
fn Validator::is_leaf(self : Validator, name : String) -> Bool {
  @schema.is_builtin_scalar(name) ||
  self.schema.enum_by_name(name) is Some(_) ||
  self.schema.scalar_by_name(name) is Some(_) ||
  name == "__TypeKind" ||
  name == "__DirectiveLocation"
}

///|
/// The base named type of a query-grammar `TypeRef` (unwrapping `!` and `[]`).
fn typeref_base(t : @lang.TypeRef) -> String {
  match t {
    NamedType(n) => n
    ListType(inner) => typeref_base(inner)
    NonNullType(inner) => typeref_base(inner)
  }
}

///|
/// Whether `needle` occurs in `hay`.
fn str_in(hay : Array[String], needle : String) -> Bool {
  for s in hay {
    if s == needle {
      return true
    }
  }
  false
}

///|
/// Record a validation error about the node at `pos`, which the response reports
/// as the error's `locations` (§7.1.2).
fn Validator::err_at(
  self : Validator,
  message : String,
  pos : @lang.Pos,
) -> Unit {
  self.errors.push(@lang.GqlError::at(message, pos))
}

///|
/// Record a validation error about the document as a whole rather than any one
/// node in it — the only case §7.1.2 leaves without `locations`.
fn Validator::err(self : Validator, message : String) -> Unit {
  self.errors.push(@lang.GqlError::msg(message))
}

///|
/// The definition of `name` among an operation's variables, if it declares one.
fn var_def(
  vds : Array[@lang.VariableDefinition],
  name : String,
) -> @lang.VariableDefinition? {
  for vd in vds {
    if vd.variable == name {
      return Some(vd)
    }
  }
  None
}

///|
/// Check every `$variable` referenced by a value is defined (when `defined` is
/// `Some`; fragment bodies pass `None` since their variables come from the
/// operation that spreads them).
fn Validator::check_value_vars(
  self : Validator,
  v : @lang.Value,
  defined : Array[@lang.VariableDefinition]?,
  pos : @lang.Pos,
) -> Unit {
  match defined {
    None => return
    Some(vds) =>
      match v {
        Variable(n) =>
          if var_def(vds, n) is None {
            self.err_at("Variable '$" + n + "' is not defined", pos)
          }
        ListValue(items) =>
          for it in items {
            self.check_value_vars(it, defined, pos)
          }
        ObjectValue(fields) =>
          for kv in fields {
            self.check_value_vars(kv.1, defined, pos)
          }
        _ => ()
      }
  }
}

///|
/// The definition of the directive `name`: a built-in executable directive
/// (`@skip`/`@include`) or a user-registered one, else `None` for an undefined
/// directive.
fn Validator::directive_def(
  self : Validator,
  name : String,
) -> @schema.DirectiveDef? {
  match @schema.builtin_exec_directive(name) {
    Some(d) => Some(d)
    None => self.schema.directive_def_by_name(name)
  }
}

///|
/// Report duplicate argument names in an argument list (spec §5.4.2, Argument
/// Uniqueness), for a field or a directive named `owner`.
fn Validator::check_arg_uniqueness(
  self : Validator,
  args : Array[@lang.Argument],
  owner : String,
) -> Unit {
  let seen : Array[String] = []
  for a in args {
    if str_in(seen, a.name) {
      self.err_at(
        "Duplicate argument '" + a.name + "' on '" + owner + "'",
        a.pos,
      )
    }
    seen.push(a.name)
  }
}

///|
/// Validate a directive list at type-system/executable `location`: every directive
/// is defined (§5.7.1), used at an allowed location (§5.7.2), and — unless declared
/// repeatable — appears at most once (§5.7.3); its arguments are unique (§5.4.2),
/// declared and complete (§5.7.4), and their variable references are defined.
fn Validator::check_directives(
  self : Validator,
  directives : Array[@lang.Directive],
  defined : Array[@lang.VariableDefinition]?,
  location : String,
) -> Unit {
  let seen : Array[String] = []
  for d in directives {
    self.check_arg_uniqueness(d.arguments, "@" + d.name)
    match self.directive_def(d.name) {
      None => {
        self.err_at("Unknown directive '@" + d.name + "'", d.pos)
        for a in d.arguments {
          self.check_value_vars(a.value, defined, a.pos)
        }
      }
      Some(def) => {
        if !str_in(def.locations, location) {
          self.err_at(
            "Directive '@" + d.name + "' may not be used on " + location,
            d.pos,
          )
        }
        if str_in(seen, d.name) && !def.is_repeatable {
          self.err_at(
            "Directive '@" +
            d.name +
            "' can only be used once at this location (it is not repeatable)",
            d.pos,
          )
        }
        self.check_directive_args(d, def, defined)
      }
    }
    seen.push(d.name)
  }
}

///|
/// Validate a directive's arguments against its definition (§5.4.1 Argument Names
/// and §5.4.2.1 Required Arguments, at a directive rather than a field): every
/// supplied argument is declared, its value fits the declared type, and every
/// non-null argument is supplied. Without this `@skip(iff: true)` and a bare
/// `@skip` both reached the executor, which then read a missing `if` as false.
fn Validator::check_directive_args(
  self : Validator,
  d : @lang.Directive,
  def : @schema.DirectiveDef,
  defined : Array[@lang.VariableDefinition]?,
) -> Unit {
  let owner = "directive '@" + d.name + "'"
  for a in d.arguments {
    self.check_value_vars(a.value, defined, a.pos)
    let mut declared = false
    for da in def.args {
      if da.0 == a.name {
        declared = true
        self.check_value_type(
          a.value,
          da.1,
          "argument '" + a.name + "' of " + owner,
          a.pos,
        )
        self.check_var_usage(a.value, da.1, false, defined, a.pos)
      }
    }
    if !declared {
      self.err_at("Unknown argument '" + a.name + "' on " + owner, a.pos)
    }
  }
  for da in def.args {
    if da.1 is NonNull(_) {
      let mut supplied = false
      for a in d.arguments {
        if a.name == da.0 {
          supplied = true
        }
      }
      if !supplied {
        self.err_at(
          "Directive '@" +
          d.name +
          "' is missing required argument '" +
          da.0 +
          "'",
          d.pos,
        )
      }
    }
  }
}

///|
/// Validate the arguments of a field against its declared argument list: every
/// supplied argument must be declared, every non-null argument must be supplied,
/// and every argument value's variables must be defined.
fn Validator::check_field_args(
  self : Validator,
  field : @lang.QueryField,
  fdef : @schema.Field,
  defined : Array[@lang.VariableDefinition]?,
) -> Unit {
  self.check_arg_uniqueness(field.arguments, field.name)
  let declared : Array[String] = []
  for a in fdef.args {
    declared.push(a.0)
  }
  for a in field.arguments {
    if !str_in(declared, a.name) {
      self.err_at(
        "Unknown argument '" + a.name + "' on field '" + field.name + "'",
        a.pos,
      )
    } else {
      for da in fdef.args {
        if da.0 == a.name {
          self.check_value_type(
            a.value,
            da.1,
            "argument '" + a.name + "' of field '" + field.name + "'",
            a.pos,
          )
          self.check_var_usage(
            a.value,
            da.1,
            fdef.arg_defaults.get(a.name) is Some(_),
            defined,
            a.pos,
          )
        }
      }
    }
    self.check_value_vars(a.value, defined, a.pos)
  }
  for da in fdef.args {
    if da.1 is NonNull(_) {
      let mut supplied = false
      for a in field.arguments {
        if a.name == da.0 {
          supplied = true
        }
      }
      if !supplied {
        self.err_at(
          "Field '" +
          field.name +
          "' is missing required argument '" +
          da.0 +
          "'",
          field.pos,
        )
      }
    }
  }
}

///|
/// A human-readable name for the kind of a literal input value, used in
/// §5.6.1 type-mismatch messages ("... found a string.").
fn value_desc(v : @lang.Value) -> String {
  match v {
    Variable(n) => "$" + n
    IntValue(_) => "an integer"
    FloatValue(_) => "a float"
    StringValue(_, _) => "a string"
    BooleanValue(_) => "a boolean"
    NullValue => "null"
    EnumValue(e) => "enum value " + e
    ListValue(_) => "a list"
    ObjectValue(_) => "an object"
  }
}

///|
/// Reproject a query-grammar `TypeRef` onto the schema builder's `GqlType` so a
/// variable's default value can flow through the same §5.6.1 checker as a
/// field-argument literal. `NamedType` becomes `Named` (the `Scalar` sugar only
/// exists on the builder side, and the value checker treats both identically).
fn typeref_to_gql(t : @lang.TypeRef) -> @schema.GqlType {
  match t {
    NamedType(n) => Named(n)
    ListType(inner) => ListOf(typeref_to_gql(inner))
    NonNullType(inner) => NonNull(typeref_to_gql(inner))
  }
}

///|
/// AreTypesCompatible (spec §5.8.5): whether a value of `vt` may stand where `lt`
/// is expected. A non-null location demands a non-null variable; a list location
/// demands a list variable, item by item; named types must be the same type, with
/// no scalar coercion (an `Int!` variable does not fit an `ID!` argument).
fn types_compatible(vt : @schema.GqlType, lt : @schema.GqlType) -> Bool {
  match (vt, lt) {
    (NonNull(vi), NonNull(li)) => types_compatible(vi, li)
    (_, NonNull(_)) => false
    (NonNull(vi), _) => types_compatible(vi, lt)
    (ListOf(vi), ListOf(li)) => types_compatible(vi, li)
    (ListOf(_), _) | (_, ListOf(_)) => false
    _ => vt.named_base() == lt.named_base()
  }
}

///|
/// AllVariableUsagesAreAllowed (spec §5.8.5): a variable may only appear where its
/// declared type fits the input position. A nullable variable still fits a non-null
/// position when something supplies the missing value — a non-null variable default
/// or a default on the location itself — so `$s` below is allowed only in the
/// second query:
///
/// ```graphql
/// query ($s: ID)       { user(id: $s) { name } }   # id: ID! — rejected
/// query ($s: ID = "1") { user(id: $s) { name } }   # the default fills the gap
/// ```
///
/// `v` may be a literal wrapping the variable, so list entries and input-object
/// fields are followed to the position the variable actually occupies. Nothing
/// happens for a fragment body (`defined` is `None`) or for a variable the
/// operation never declared, which §5.8.3 reports instead.
fn Validator::check_var_usage(
  self : Validator,
  v : @lang.Value,
  loc : @schema.GqlType,
  loc_default : Bool,
  defined : Array[@lang.VariableDefinition]?,
  pos : @lang.Pos,
) -> Unit {
  let vds = match defined {
    Some(x) => x
    None => return
  }
  match v {
    Variable(n) =>
      match var_def(vds, n) {
        None => ()
        Some(vd) => {
          let vt = typeref_to_gql(vd.typ)
          let ok = match loc {
            NonNull(inner) if !(vt is NonNull(_)) =>
              (
                loc_default ||
                (match vd.default_value {
                  None | Some(NullValue) => false
                  Some(_) => true
                })
              ) &&
              types_compatible(vt, inner)
            _ => types_compatible(vt, loc)
          }
          if !ok {
            self.err_at(
              "Variable '$" +
              vd.variable +
              "' of type '" +
              vd.typ.to_query() +
              "' used in position expecting type '" +
              @schema.type_sdl(loc) +
              "'.",
              pos,
            )
          }
        }
      }
    ListValue(items) => {
      let item = match loc {
        NonNull(ListOf(i)) | ListOf(i) => i
        _ => loc
      }
      for it in items {
        self.check_var_usage(it, item, false, defined, pos)
      }
    }
    ObjectValue(fields) =>
      match self.schema.type_by_name(loc.named_base()) {
        Some(td) =>
          for kv in fields {
            match td.field_by_name(kv.0) {
              Some(fd) =>
                self.check_var_usage(kv.1, fd.typ, false, defined, pos)
              None => ()
            }
          }
        None => ()
      }
    _ => ()
  }
}

///|
/// Values of Correct Type (spec §5.6.1): a literal input value must be coercible
/// to its expected type. Variables are skipped here (their compatibility is a
/// separate rule); `null` is accepted at any nullable position but rejected under
/// a non-null wrapper. List positions accept either a list literal (each element
/// checked against the item type) or a single value (list input coercion).
fn Validator::check_value_type(
  self : Validator,
  v : @lang.Value,
  t : @schema.GqlType,
  ctx : String,
  pos : @lang.Pos,
) -> Unit {
  if v is Variable(_) {
    return
  }
  match t {
    NonNull(inner) =>
      if v is NullValue {
        self.err_at(
          ctx +
          " of non-null type '" +
          @schema.type_sdl(t) +
          "' must not be null.",
          pos,
        )
      } else {
        self.check_value_type(v, inner, ctx, pos)
      }
    ListOf(inner) =>
      match v {
        NullValue => ()
        ListValue(items) =>
          for it in items {
            self.check_value_type(it, inner, ctx, pos)
          }
        _ => self.check_value_type(v, inner, ctx, pos)
      }
    Scalar(name) | Named(name) =>
      if !(v is NullValue) {
        self.check_named_value(v, name, ctx, pos)
      }
  }
}

///|
/// Check a non-null literal against a named leaf/input type: the five built-in
/// scalars by JSON shape, enums by membership, input objects field-by-field.
/// Custom scalars and output types accept anything (their coercion is user code).
fn Validator::check_named_value(
  self : Validator,
  v : @lang.Value,
  name : String,
  ctx : String,
  pos : @lang.Pos,
) -> Unit {
  match name {
    "Int" =>
      if !(v is IntValue(_)) {
        self.err_at(
          ctx + " expected type 'Int', found " + value_desc(v) + ".",
          pos,
        )
      }
    "Float" =>
      match v {
        IntValue(_) | FloatValue(_) => ()
        _ =>
          self.err_at(
            ctx + " expected type 'Float', found " + value_desc(v) + ".",
            pos,
          )
      }
    "String" =>
      if !(v is StringValue(_, _)) {
        self.err_at(
          ctx + " expected type 'String', found " + value_desc(v) + ".",
          pos,
        )
      }
    "Boolean" =>
      if !(v is BooleanValue(_)) {
        self.err_at(
          ctx + " expected type 'Boolean', found " + value_desc(v) + ".",
          pos,
        )
      }
    "ID" =>
      match v {
        StringValue(_, _) | IntValue(_) => ()
        _ =>
          self.err_at(
            ctx + " expected type 'ID', found " + value_desc(v) + ".",
            pos,
          )
      }
    _ =>
      match self.schema.enum_by_name(name) {
        Some(en) =>
          match v {
            EnumValue(ev) =>
              if !str_in(en.values, ev) {
                self.err_at(
                  ctx +
                  ": value '" +
                  ev +
                  "' does not exist in enum '" +
                  name +
                  "'.",
                  pos,
                )
              }
            _ =>
              self.err_at(
                ctx +
                " expected enum '" +
                name +
                "', found " +
                value_desc(v) +
                ".",
                pos,
              )
          }
        None =>
          match self.schema.type_by_name(name) {
            Some(td) =>
              if td.kind == Input {
                self.check_input_value(v, td, ctx, pos)
              }
            None => ()
          }
      }
  }
}

///|
/// Check a literal against an input object type: it must be an object literal,
/// every provided field must be declared, each field's value must match the
/// field type, and every non-null field must be supplied.
fn Validator::check_input_value(
  self : Validator,
  v : @lang.Value,
  td : @schema.ObjectType,
  ctx : String,
  pos : @lang.Pos,
) -> Unit {
  match v {
    ObjectValue(fields) => {
      let seen : Array[String] = []
      for kv in fields {
        let (fname, fval) = kv
        if seen.contains(fname) {
          self.err_at(
            "There can be only one input field named '" +
            td.name +
            "." +
            fname +
            "'.",
            pos,
          )
        }
        seen.push(fname)
        match td.field_by_name(fname) {
          Some(fdef) =>
            self.check_value_type(
              fval,
              fdef.typ,
              "field '" + td.name + "." + fname + "'",
              pos,
            )
          None =>
            self.err_at(
              "Field '" +
              fname +
              "' is not defined by input type '" +
              td.name +
              "'.",
              pos,
            )
        }
      }
      for fdef in td.fields {
        if fdef.typ is NonNull(_) {
          let mut present = false
          for kv in fields {
            if kv.0 == fdef.name {
              present = true
            }
          }
          if !present {
            self.err_at(
              "Field '" +
              td.name +
              "." +
              fdef.name +
              "' of required type '" +
              @schema.type_sdl(fdef.typ) +
              "' was not provided.",
              pos,
            )
          }
        }
      }
    }
    _ =>
      self.err_at(
        ctx +
        " expected input object '" +
        td.name +
        "', found " +
        value_desc(v) +
        ".",
        pos,
      )
  }
}

///|
/// Validate a selection set against the object type named `type_name`. `pos` is
/// where that type was named — the operation, field or fragment the set hangs
/// off — and is what an error about the set as a whole points at.
fn Validator::check_selection_set(
  self : Validator,
  type_name : String,
  selections : Array[@lang.Selection],
  defined : Array[@lang.VariableDefinition]?,
  pos : @lang.Pos,
) -> Unit {
  match self.schema.union_by_name(type_name) {
    Some(u) => {
      self.check_union_selection_set(type_name, u, selections, defined)
      return
    }
    None => ()
  }
  self.check_can_merge(type_name, selections)
  let obj = match self.lookup_type(type_name) {
    Some(o) => o
    None => {
      self.err_at("Cannot select on unknown type '" + type_name + "'", pos)
      return
    }
  }
  for sel in selections {
    match sel {
      FieldSel(f) => {
        self.check_directives(f.directives, defined, "FIELD")
        if f.name == "__typename" {
          if f.selection_set.length() > 0 {
            self.err_at(
              "Field '__typename' must not have a selection set",
              f.pos,
            )
          }
          continue
        }
        if type_name == self.schema.query &&
          (f.name == "__schema" || f.name == "__type") {
          let meta = if f.name == "__schema" { "__Schema" } else { "__Type" }
          for a in f.arguments {
            self.check_value_vars(a.value, defined, a.pos)
          }
          if f.selection_set.length() == 0 {
            self.err_at(
              "Field '" + f.name + "' must have a selection of subfields",
              f.pos,
            )
          } else {
            self.check_selection_set(meta, f.selection_set, defined, f.pos)
          }
          continue
        }
        match obj.field_by_name(f.name) {
          None =>
            self.err_at(
              "Cannot query field '" + f.name + "' on type '" + type_name + "'",
              f.pos,
            )
          Some(fdef) => {
            self.check_field_args(f, fdef, defined)
            let base = fdef.typ.named_base()
            if self.is_leaf(base) {
              if f.selection_set.length() > 0 {
                self.err_at(
                  "Field '" +
                  f.name +
                  "' of leaf type '" +
                  base +
                  "' must not have a selection set",
                  f.pos,
                )
              }
            } else if self.schema.union_by_name(base) is Some(u) {
              if f.selection_set.length() == 0 {
                self.err_at(
                  "Field '" +
                  f.name +
                  "' of union type '" +
                  base +
                  "' must have a selection of subfields",
                  f.pos,
                )
              } else {
                self.check_union_selection_set(
                  base,
                  u,
                  f.selection_set,
                  defined,
                )
              }
            } else if self.lookup_type(base) is Some(_) {
              if f.selection_set.length() == 0 {
                self.err_at(
                  "Field '" +
                  f.name +
                  "' of type '" +
                  base +
                  "' must have a selection of subfields",
                  f.pos,
                )
              } else {
                self.check_selection_set(base, f.selection_set, defined, f.pos)
              }
            } else {
              self.err_at(
                "Field '" + f.name + "' has unknown type '" + base + "'",
                f.pos,
              )
            }
          }
        }
      }
      FragmentSpreadSel(name, dirs, spos) => {
        self.check_directives(dirs, defined, "FRAGMENT_SPREAD")
        match self.fragments.get(name) {
          Some(frag) =>
            if !self.types_overlap(type_name, frag.type_condition) {
              self.err_at(
                "Fragment '" +
                name +
                "' cannot be spread here as objects of type '" +
                type_name +
                "' can never be of type '" +
                frag.type_condition +
                "'",
                spos,
              )
            }
          None => self.err_at("Unknown fragment '" + name + "'", spos)
        }
      }
      InlineFragmentSel(cond, dirs, sels, fpos) => {
        self.check_directives(dirs, defined, "INLINE_FRAGMENT")
        let cond_type = match cond {
          Some(c) => c
          None => type_name
        }
        if self.type_exists(cond_type) {
          if !self.types_overlap(type_name, cond_type) {
            self.err_at(
              "Fragment cannot be spread here as objects of type '" +
              type_name +
              "' can never be of type '" +
              cond_type +
              "'",
              fpos,
            )
          }
          self.check_selection_set(cond_type, sels, defined, fpos)
        } else {
          self.err_at(
            "Inline fragment on unknown type '" + cond_type + "'",
            fpos,
          )
        }
      }
    }
  }
}

///|
/// Validate a selection set at a union position: only `__typename` and fragments
/// on member types (or the union itself) may select into a union. A direct field
/// selection other than `__typename` is an error.
fn Validator::check_union_selection_set(
  self : Validator,
  union_name : String,
  u : @schema.UnionType,
  selections : Array[@lang.Selection],
  defined : Array[@lang.VariableDefinition]?,
) -> Unit {
  self.check_can_merge(union_name, selections)
  for sel in selections {
    match sel {
      FieldSel(f) => {
        self.check_directives(f.directives, defined, "FIELD")
        if f.name == "__typename" {
          if f.selection_set.length() > 0 {
            self.err_at(
              "Field '__typename' must not have a selection set",
              f.pos,
            )
          }
        } else {
          self.err_at(
            "Cannot query field '" +
            f.name +
            "' directly on union type '" +
            union_name +
            "'; select it inside an inline fragment on a member type",
            f.pos,
          )
        }
      }
      FragmentSpreadSel(name, dirs, spos) => {
        self.check_directives(dirs, defined, "FRAGMENT_SPREAD")
        if !self.fragments.contains(name) {
          self.err_at("Unknown fragment '" + name + "'", spos)
        }
      }
      InlineFragmentSel(cond, dirs, sels, fpos) => {
        self.check_directives(dirs, defined, "INLINE_FRAGMENT")
        let cond_type = match cond {
          Some(c) => c
          None => union_name
        }
        if cond_type == union_name {
          self.check_union_selection_set(union_name, u, sels, defined)
        } else if str_in(u.members, cond_type) {
          self.check_selection_set(cond_type, sels, defined, fpos)
        } else {
          self.err_at(
            "Inline fragment type '" +
            cond_type +
            "' is not a member of union '" +
            union_name +
            "'",
            fpos,
          )
        }
      }
    }
  }
}

///|
/// The concrete object types a value of `name` could be at runtime (← the spec's
/// possible types): a union's members, an interface's implementers, or the type
/// itself for an object or leaf.
fn Validator::possible_types(self : Validator, name : String) -> Array[String] {
  match self.schema.union_by_name(name) {
    Some(u) => u.members
    None => {
      let impls : Array[String] = []
      for t in self.schema.types {
        if t.kind is Object {
          for i in t.interfaces {
            if i == name {
              impls.push(t.name)
              break
            }
          }
        }
      }
      if impls.is_empty() {
        [name]
      } else {
        impls
      }
    }
  }
}

///|
/// Whether a fragment on `frag_type` can ever apply within a selection on
/// `parent` (← the spec's `DoTypesOverlap`, §5.5.2.3): their possible concrete
/// types must intersect.
fn Validator::types_overlap(
  self : Validator,
  parent : String,
  frag_type : String,
) -> Bool {
  if parent == frag_type {
    return true
  }
  let pb = self.possible_types(frag_type)
  for x in self.possible_types(parent) {
    if pb.contains(x) {
      return true
    }
  }
  false
}

///|
/// Whether a name denotes a selectable type: a composite/introspection type or a
/// union. Used to accept union type conditions on fragments.
fn Validator::type_exists(self : Validator, name : String) -> Bool {
  // An input object is a type, but not a *composite* one: nothing selects fields
  // from it, so a fragment cannot condition on it (§5.5.1.3).
  match self.lookup_type(name) {
    Some(t) => !(t.kind is Input)
    None => self.schema.union_by_name(name) is Some(_)
  }
}

///|
/// Validate a single operation: its root type must be configured, its variable
/// definitions must name existing input types, and its selection set must be
/// valid.
fn Validator::check_operation(
  self : Validator,
  op : @lang.OperationDefinition,
) -> Unit {
  let root = match op.operation {
    Query => Some(self.schema.query)
    Mutation => self.schema.mutation
    Subscription => self.schema.subscription
  }
  let root_type = match root {
    Some(r) => r
    None => {
      self.err_at("Schema has no root type for this operation", op.pos)
      return
    }
  }
  let op_location = match op.operation {
    Query => "QUERY"
    Mutation => "MUTATION"
    Subscription => "SUBSCRIPTION"
  }
  self.check_directives(op.directives, None, op_location)
  let defined : Array[@lang.VariableDefinition] = []
  for vd in op.variable_definitions {
    // §5.8.1 Variable Uniqueness: a variable name is defined at most once.
    if var_def(defined, vd.variable) is Some(_) {
      self.err_at("Duplicate variable '$" + vd.variable + "'", vd.pos)
    }
    defined.push(vd)
    self.check_directives(vd.directives, Some(defined), "VARIABLE_DEFINITION")
    let base = typeref_base(vd.typ)
    // §5.8.2 Variables Are Input Types: a variable's type must be a scalar, enum,
    // or input object — never an output object, interface, or union.
    let is_input_type = @schema.is_builtin_scalar(base) ||
      self.schema.enum_by_name(base) is Some(_) ||
      self.schema.scalar_by_name(base) is Some(_) ||
      (self.schema.type_by_name(base) is Some(t) && t.kind is Input)
    if !is_input_type {
      let exists = self.schema.type_by_name(base) is Some(_) ||
        self.schema.union_by_name(base) is Some(_)
      if exists {
        self.err_at(
          "Variable '$" +
          vd.variable +
          "' cannot be non-input type '" +
          base +
          "'",
          vd.pos,
        )
      } else {
        self.err_at(
          "Variable '$" + vd.variable + "' has unknown type '" + base + "'",
          vd.pos,
        )
      }
    }
    // §5.6.1 also governs a variable's default value, a constant literal.
    match vd.default_value {
      Some(dv) =>
        self.check_value_type(
          dv,
          typeref_to_gql(vd.typ),
          "variable '$" + vd.variable + "'",
          vd.pos,
        )
      None => ()
    }
  }
  if op.operation is Subscription {
    self.check_single_root_field(op)
  }
  self.check_selection_set(root_type, op.selection_set, Some(defined), op.pos)
  self.check_spread_var_usages(root_type, op.selection_set, defined, false, [])
  // §5.8.4 All Variables Used: every defined variable is referenced somewhere in
  // the operation (directly or through a spread fragment).
  let used : Array[(String, @lang.Pos)] = []
  self.collect_used_variables(op.selection_set, Map([]), used)
  for vd in op.variable_definitions {
    if used.search_by(u => u.0 == vd.variable) is None {
      self.err_at("Variable '$" + vd.variable + "' is never used", vd.pos)
    }
  }
  // §5.8.3 All Variable Uses Defined, over the same transitive set. Checking only
  // the operation's own selections misses the common case — a variable referenced
  // inside a fragment the operation spreads — which then executed as null.
  for u in used {
    if var_def(defined, u.0) is None {
      self.err_at(
        "Variable '$" +
        u.0 +
        "' is not defined by operation '" +
        (match op.name {
          Some(n) => n
          None => "(anonymous)"
        }) +
        "'",
        u.1,
      )
    }
  }
}

///|
/// §5.8.5 for the argument positions inside the fragments an operation spreads. A
/// fragment is validated on its own, where nothing knows which operation's
/// variables it will be handed, so its positions are checked here instead — once
/// per operation that can reach it. `inside` starts false because the operation's
/// own arguments were already checked as the selection set was validated; it turns
/// true on entering a fragment body.
fn Validator::check_spread_var_usages(
  self : Validator,
  type_name : String,
  selections : Array[@lang.Selection],
  vars : Array[@lang.VariableDefinition],
  inside : Bool,
  seen : Array[String],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => {
        if inside {
          self.check_directive_var_usages(f.directives, vars)
        }
        let fdef = match self.lookup_type(type_name) {
          Some(t) => t.field_by_name(f.name)
          None => None
        }
        match fdef {
          None => ()
          Some(fd) => {
            if inside {
              for a in f.arguments {
                for da in fd.args {
                  if da.0 == a.name {
                    self.check_var_usage(
                      a.value,
                      da.1,
                      fd.arg_defaults.get(a.name) is Some(_),
                      Some(vars),
                      a.pos,
                    )
                  }
                }
              }
            }
            self.check_spread_var_usages(
              fd.typ.named_base(),
              f.selection_set,
              vars,
              inside,
              seen,
            )
          }
        }
      }
      InlineFragmentSel(cond, dirs, sels, _) => {
        if inside {
          self.check_directive_var_usages(dirs, vars)
        }
        let inner = match cond {
          Some(c) => c
          None => type_name
        }
        self.check_spread_var_usages(inner, sels, vars, inside, seen)
      }
      FragmentSpreadSel(name, dirs, _) => {
        if inside {
          self.check_directive_var_usages(dirs, vars)
        }
        if !str_in(seen, name) && !str_in(self.cyclic, name) {
          seen.push(name)
          match self.fragments.get(name) {
            Some(fr) =>
              self.check_spread_var_usages(
                fr.type_condition,
                fr.selection_set,
                vars,
                true,
                seen,
              )
            None => ()
          }
        }
      }
    }
  }
}

///|
/// §5.8.5 for the arguments of a directive list, against the declared argument
/// types of each directive.
fn Validator::check_directive_var_usages(
  self : Validator,
  directives : Array[@lang.Directive],
  vars : Array[@lang.VariableDefinition],
) -> Unit {
  for d in directives {
    match self.directive_def(d.name) {
      None => ()
      Some(def) =>
        for a in d.arguments {
          for da in def.args {
            if da.0 == a.name {
              self.check_var_usage(a.value, da.1, false, Some(vars), a.pos)
            }
          }
        }
    }
  }
}

///|
/// SingleRootField (spec §5.2.3.1): a subscription must select exactly one root
/// field after fragment expansion, and it must not be an introspection field.
fn Validator::check_single_root_field(
  self : Validator,
  op : @lang.OperationDefinition,
) -> Unit {
  let fields : Array[@lang.QueryField] = []
  self.collect_root_fields(op.selection_set, Map([]), fields)
  let keys : Array[String] = []
  for f in fields {
    let key = match f.alias_ {
      Some(a) => a
      None => f.name
    }
    if !str_in(keys, key) {
      keys.push(key)
    }
  }
  if keys.length() != 1 {
    self.err_at(
      "Subscription operation must select exactly one root field",
      op.pos,
    )
  } else if @schema.is_meta_field(fields[0].name) {
    self.err_at(
      "Subscription root field '" +
      fields[0].name +
      "' must not be an introspection field",
      fields[0].pos,
    )
  }
}

///|
/// Gather the root-level fields of a selection set, expanding fragment spreads
/// and inline fragments (used to count a subscription's root fields).
fn Validator::collect_root_fields(
  self : Validator,
  selections : Array[@lang.Selection],
  visited : Map[String, Bool],
  out : Array[@lang.QueryField],
) -> Unit {
  for sel in selections {
    match sel {
      FieldSel(f) => out.push(f)
      FragmentSpreadSel(name, _, _) =>
        if !(visited.get(name) is Some(true)) {
          visited[name] = true
          match self.fragments.get(name) {
            Some(frag) =>
              self.collect_root_fields(frag.selection_set, visited, out)
            None => ()
          }
        }
      InlineFragmentSel(_, _, sels, _) =>
        self.collect_root_fields(sels, visited, out)
    }
  }
}

///|
/// Validate a fragment definition: its type condition must exist, and its body
/// must be valid against that type. Variable references inside are checked at the
/// operations that spread it.
fn Validator::check_fragment(
  self : Validator,
  frag : @lang.FragmentDefinition,
) -> Unit {
  self.check_directives(frag.directives, None, "FRAGMENT_DEFINITION")
  if self.type_exists(frag.type_condition) {
    self.check_selection_set(
      frag.type_condition,
      frag.selection_set,
      None,
      frag.pos,
    )
  } else {
    self.err_at(
      "Fragment '" +
      frag.name +
      "' has unknown type condition '" +
      frag.type_condition +
      "'",
      frag.pos,
    )
  }
}

///|
/// Validate a whole document against `schema`, returning all errors found (an
/// empty array means the document is valid and ready to execute).
pub fn validate(
  schema : @schema.Schema,
  doc : @lang.Document,
) -> Array[@lang.GqlError] {
  let v = {
    schema,
    fragments: @lang.collect_fragments(doc),
    cyclic: [],
    errors: [],
  }
  v.check_operation_names(doc)
  v.check_fragment_uniqueness(doc)
  v.check_fragment_cycles(doc)
  let mut has_op = false
  for def in doc.definitions {
    match def {
      @lang.OperationDef(op) => {
        has_op = true
        v.check_operation(op)
      }
      @lang.FragmentDef(frag) => v.check_fragment(frag)
    }
  }
  if !has_op {
    v.err("Document contains no operations")
  }
  v.check_fragments_used(doc)
  v.errors
}
