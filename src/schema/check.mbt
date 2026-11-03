// The type system's own checks: §3 of the specification, asked of a `Schema`
// rather than of a document. `Schema::check` answers every problem it finds, so
// a schema assembled in code — or read back from SDL — can be held to the same
// rules a document is.

///|
/// The state of one pass over a schema: the schema itself and the errors found so
/// far.
priv struct Checker {
  schema : Schema
  errors : Array[@lang.GqlError]
}

///|
/// Record one problem.
fn Checker::fail(self : Checker, message : String) -> Unit {
  self.errors.push(@lang.GqlError::msg(message))
}

///|
/// Whether a value of `ty` may be sent in: a scalar, an enum, or an input object,
/// wrapped in any number of list and non-null markers (§3.6.1.4).
fn Checker::is_input_type(self : Checker, ty : GqlType) -> Bool {
  match ty {
    NonNull(inner) | ListOf(inner) => self.is_input_type(inner)
    Scalar(name) =>
      is_builtin_scalar(name) || self.schema.scalar_by_name(name) is Some(_)
    Named(name) =>
      match self.schema.type_by_name(name) {
        Some(t) => t.kind is Input
        None =>
          self.schema.enum_by_name(name) is Some(_) ||
          self.schema.scalar_by_name(name) is Some(_) ||
          is_builtin_scalar(name)
      }
  }
}

///|
/// Whether a value of `ty` may be handed out: a scalar, an enum, an object, an
/// interface, or a union, wrapped in any number of list and non-null markers.
fn Checker::is_output_type(self : Checker, ty : GqlType) -> Bool {
  match ty {
    NonNull(inner) | ListOf(inner) => self.is_output_type(inner)
    Scalar(name) =>
      is_builtin_scalar(name) || self.schema.scalar_by_name(name) is Some(_)
    Named(name) =>
      match self.schema.type_by_name(name) {
        Some(t) => !(t.kind is Input)
        None =>
          self.schema.enum_by_name(name) is Some(_) ||
          self.schema.union_by_name(name) is Some(_) ||
          self.schema.scalar_by_name(name) is Some(_) ||
          is_builtin_scalar(name)
      }
  }
}

///|
/// Whether `sub` may stand where `sup` is declared (§3.6.3.1): equal types, or a
/// non-null / list narrowing of one, or an object that is a member of the union
/// or an implementation of the interface.
fn Checker::is_sub_type(self : Checker, sub : GqlType, sup : GqlType) -> Bool {
  if sub == sup {
    return true
  }
  match (sub, sup) {
    (NonNull(a), NonNull(b)) => self.is_sub_type(a, b)
    (_, NonNull(_)) => false
    // A non-null type may stand where a nullable one is declared, the other way
    // round is a widening.
    (NonNull(a), _) => self.is_sub_type(a, sup)
    (ListOf(a), ListOf(b)) => self.is_sub_type(a, b)
    (_, ListOf(_)) | (ListOf(_), _) => false
    (Named(a), Named(b)) =>
      if a == b {
        true
      } else {
        match self.schema.union_by_name(b) {
          Some(u) => u.members.contains(a)
          None =>
            match self.schema.type_by_name(b) {
              Some(t) if t.kind is Interface =>
                match self.schema.type_by_name(a) {
                  Some(concrete) => concrete.interfaces.contains(b)
                  None => false
                }
              _ => false
            }
        }
      }
    _ => false
  }
}

///|
/// A type reference as an error reports it.
fn rule_text(ty : GqlType) -> String {
  type_sdl(ty)
}

///|
/// The names of every type the schema declares, in declaration order, with the
/// built-in scalars and the introspection types left out — those are the ones a
/// name may collide with.
fn declared_names(schema : Schema) -> Array[String] {
  let out : Array[String] = []
  for t in schema.types {
    out.push(t.name)
  }
  for e in schema.enums {
    out.push(e.name)
  }
  for u in schema.unions {
    out.push(u.name)
  }
  for s in schema.scalars {
    out.push(s.name)
  }
  out
}

///|
/// §3.9: the root operation types are named, exist, and are object types.
fn Checker::check_roots(self : Checker) -> Unit {
  let root = self.schema.type_by_name(self.schema.query)
  match root {
    None => self.fail("Query root type must be provided.")
    Some(t) =>
      if !(t.kind is Object) {
        self.fail(
          "Query root type must be Object type, it cannot be \{t.name}.",
        )
      }
  }
  for r in [self.schema.mutation, self.schema.subscription] {
    match r {
      None => ()
      Some(name) =>
        match self.schema.type_by_name(name) {
          None => self.fail("Root type '\{name}' is not defined in the schema.")
          Some(t) =>
            if !(t.kind is Object) {
              self.fail(
                "Root type '\{name}' must be Object type, it cannot be \{kind_keyword(t.kind)} '\{name}'.",
              )
            }
        }
    }
  }
}

///|
/// §3.6.1.1, §3.6.1.2 and §3.4: every type name is unique and none begins with
/// `__`, which introspection owns.
fn Checker::check_type_names(self : Checker) -> Unit {
  let seen : Map[String, Unit] = Map([])
  for name in declared_names(self.schema) {
    if seen.get(name) is Some(_) {
      self.fail("There can be only one type named '\{name}'.")
    } else {
      seen[name] = ()
    }
    if name.has_prefix("__") {
      self.fail(
        "Name '\{name}' must not begin with '__', which is reserved by GraphQL introspection.",
      )
    }
  }
}

///|
/// §3.6.1.4 and §3.6.2: each field's type is of the right side of the schema, its
/// arguments are input types, and its own name and its arguments' names are each
/// written once.
fn Checker::check_fields(self : Checker, t : ObjectType) -> Unit {
  if t.fields.is_empty() {
    self.fail(
      if t.kind is Input {
        "Input Object type \{t.name} must define one or more fields."
      } else if t.kind is Interface {
        "Interface type \{t.name} must define one or more fields."
      } else {
        "Type \{t.name} must define one or more fields."
      },
    )
  }
  let seen : Map[String, Unit] = Map([])
  for f in t.fields {
    if seen.get(f.name) is Some(_) {
      self.fail("Field '\{t.name}.\{f.name}' can only be defined once.")
    } else {
      seen[f.name] = ()
    }
    if t.kind is Input {
      if !f.args.is_empty() {
        self.fail("Input field '\{t.name}.\{f.name}' cannot have arguments.")
      }
      if !self.is_input_type(f.typ) {
        self.fail(
          "The type of \{t.name}.\{f.name} must be Input Type but got: \{rule_text(f.typ)}.",
        )
      }
    } else if !self.is_output_type(f.typ) {
      self.fail(
        "The type of \{t.name}.\{f.name} must be Output Type but got: \{rule_text(f.typ)}.",
      )
    }
    let args : Map[String, Unit] = Map([])
    for a in f.args {
      let (name, ty) = a
      if args.get(name) is Some(_) {
        self.fail(
          "Argument '\{t.name}.\{f.name}(\{name}:)' can only be defined once.",
        )
      } else {
        args[name] = ()
      }
      if !self.is_input_type(ty) {
        self.fail(
          "The type of \{t.name}.\{f.name}(\{name}:) must be Input Type but got: \{rule_text(ty)}.",
        )
      }
    }
  }
}

///|
/// §3.6.3.1: an object or interface that implements an interface carries every
/// field of it, with a type that is a sub-type and arguments that match exactly,
/// and it declares the interfaces its interfaces implement.
fn Checker::check_implementation(
  self : Checker,
  t : ObjectType,
  iface_name : String,
) -> Unit {
  let iface = match self.schema.type_by_name(iface_name) {
    Some(i) =>
      if i.kind is Interface {
        i
      } else {
        self.fail(
          "Type \{t.name} must only implement Interface types, it cannot implement \{iface_name}.",
        )
        return
      }
    None => {
      self.fail(
        "Type \{t.name} must only implement Interface types, it cannot implement \{iface_name}.",
      )
      return
    }
  }
  if t.name == iface_name {
    self.fail(
      "Type \{t.name} cannot implement itself because it would create a circular reference.",
    )
    return
  }
  for i in iface.interfaces {
    if !t.interfaces.contains(i) {
      self.fail(
        "Type \{t.name} must implement \{i} because it is implemented by \{iface_name}.",
      )
    }
  }
  for field in iface.fields {
    let own = match t.field_by_name(field.name) {
      Some(f) => f
      None => {
        self.fail(
          "Interface field \{iface_name}.\{field.name} expected but \{t.name} does not provide it.",
        )
        continue
      }
    }
    if !self.is_sub_type(own.typ, field.typ) {
      self.fail(
        "Interface field \{iface_name}.\{field.name} expects type \{rule_text(field.typ)} but \{t.name}.\{own.name} is type \{rule_text(own.typ)}.",
      )
    }
    for arg in field.args {
      let (name, ty) = arg
      match own.args.iter().find_first(a => a.0 == name) {
        None =>
          self.fail(
            "Interface field argument \{iface_name}.\{field.name}(\{name}:) expected but \{t.name}.\{own.name} does not provide it.",
          )
        Some((_, own_ty)) =>
          if !(own_ty == ty) {
            self.fail(
              "Interface field argument \{iface_name}.\{field.name}(\{name}:) expects type \{rule_text(ty)} but \{t.name}.\{own.name}(\{name}:) is type \{rule_text(own_ty)}.",
            )
          }
      }
    }
    for arg in own.args {
      let (name, ty) = arg
      if ty is NonNull(_) && !field.args.iter().any(a => a.0 == name) {
        self.fail(
          "Object field \{t.name}.\{own.name} includes required argument \{name} that is missing from the Interface field \{iface_name}.\{field.name}.",
        )
      }
    }
  }
}

///|
/// §3.6.3: every declared interface is checked against the object or interface
/// that implements it.
fn Checker::check_interfaces(self : Checker) -> Unit {
  for t in self.schema.types {
    if t.kind is Input {
      continue
    }
    for iface_name in t.interfaces {
      self.check_implementation(t, iface_name)
    }
  }
}

///|
/// §3.6.4.2: no input object reaches itself through a chain of non-null fields —
/// there would be no value that satisfies it. `path` is the chain walked so far,
/// and `seen` the objects already on it.
fn Checker::check_input_cycle(
  self : Checker,
  t : ObjectType,
  path : Array[String],
  seen : Array[String],
) -> Unit {
  if seen.contains(t.name) {
    self.fail(
      "Cannot reference Input Object '\{t.name}' within itself through a series of non-null fields: '\{path.join(".")}'.",
    )
    return
  }
  let seen = seen.copy()
  seen.push(t.name)
  for f in t.fields {
    if f.typ is NonNull(inner) {
      let base = inner.named_base()
      match self.schema.type_by_name(base) {
        Some(next) if next.kind is Input => {
          let here = path.copy()
          here.push(f.name)
          self.check_input_cycle(next, here, seen)
        }
        _ => ()
      }
    }
  }
}

///|
/// §3.6.4: every input object is walked for a required-field cycle.
fn Checker::check_input_cycles(self : Checker) -> Unit {
  for t in self.schema.types {
    if t.kind is Input {
      self.check_input_cycle(t, [], [])
    }
  }
}

///|
/// §3.6.5: a union's members are object types, each named once.
fn Checker::check_unions(self : Checker) -> Unit {
  for u in self.schema.unions {
    if u.members.is_empty() {
      self.fail("Union type \{u.name} must include one or more types.")
    }
    let seen : Map[String, Unit] = Map([])
    for m in u.members {
      match self.schema.type_by_name(m) {
        Some(t) =>
          if !(t.kind is Object) {
            self.fail(
              "Union type \{u.name} can only include Object types, it cannot include \{m}.",
            )
          }
        None =>
          self.fail(
            "Union type \{u.name} can only include Object types, it cannot include \{m}.",
          )
      }
      if seen.get(m) is Some(_) {
        self.fail("Union type \{u.name} can only include type \{m} once.")
      } else {
        seen[m] = ()
      }
    }
  }
}

///|
/// §3.6.6: an enum's values are named once each, and none is `true`, `false` or
/// `null`, which are not names a document could write.
fn Checker::check_enums(self : Checker) -> Unit {
  for e in self.schema.enums {
    if e.values.is_empty() {
      self.fail("Enum type \{e.name} must define one or more values.")
    }
    let seen : Map[String, Unit] = Map([])
    for v in e.values {
      if v == "true" || v == "false" || v == "null" {
        self.fail("Enum type \{e.name} cannot include value: \{v}.")
      }
      if seen.get(v) is Some(_) {
        self.fail("Enum type \{e.name} can only include value '\{v}' once.")
      } else {
        seen[v] = ()
      }
    }
  }
}

///|
/// The places a directive may be used (§3.13).
fn is_directive_location(name : String) -> Bool {
  match name {
    "QUERY"
    | "MUTATION"
    | "SUBSCRIPTION"
    | "FIELD"
    | "FRAGMENT_DEFINITION"
    | "FRAGMENT_SPREAD"
    | "INLINE_FRAGMENT"
    | "VARIABLE_DEFINITION"
    | "SCHEMA"
    | "SCALAR"
    | "OBJECT"
    | "FIELD_DEFINITION"
    | "ARGUMENT_DEFINITION"
    | "INTERFACE"
    | "UNION"
    | "ENUM"
    | "ENUM_VALUE"
    | "INPUT_OBJECT"
    | "INPUT_FIELD_DEFINITION" => true
    _ => false
  }
}

///|
/// §3.6.8: a directive is defined once, its arguments are input types, and every
/// location it names is one of the specification's.
fn Checker::check_directives(self : Checker) -> Unit {
  let seen : Map[String, Unit] = Map([])
  for d in self.schema.directive_defs {
    if seen.get(d.name) is Some(_) {
      self.fail("Directive @\{d.name} can only be defined once.")
    } else {
      seen[d.name] = ()
    }
    if d.name.has_prefix("__") {
      self.fail(
        "Name '\{d.name}' must not begin with '__', which is reserved by GraphQL introspection.",
      )
    }
    if d.locations.is_empty() {
      self.fail("Directive @\{d.name} must include 1 or more locations.")
    }
    for loc in d.locations {
      if !is_directive_location(loc) {
        self.fail("Directive @\{d.name} may not be used on \{loc}.")
      }
    }
    for a in d.args {
      if !self.is_input_type(a.1) {
        self.fail(
          "The type of @\{d.name}(\{a.0}:) must be Input Type but got: \{rule_text(a.1)}.",
        )
      }
    }
  }
}

///|
/// Every problem the type system has with this schema, in the order the
/// specification states the rules: names, then each shape of type, then the
/// interfaces over them, then the roots that tie them together. An empty array
/// means the schema is one the specification allows.
///
/// The rules are §3's, not §5's: this asks whether the schema itself holds
/// together, where `validate` asks whether a document is right for it.
pub fn Schema::check(self : Schema) -> Array[@lang.GqlError] {
  let c : Checker = { schema: self, errors: [], }
  c.check_type_names()
  for t in self.types {
    c.check_fields(t)
  }
  c.check_enums()
  c.check_unions()
  c.check_directives()
  c.check_interfaces()
  c.check_input_cycles()
  c.check_roots()
  c.errors
}
