///|
/// Subscription execution (GraphQL spec §6.2.3). A subscription operation has a
/// single root field backed by a *source stream* of events; each event is mapped
/// through the normal execution machinery into one `{ data, errors }` payload.
///
/// The stream is modelled as a pull source — a resolver returning an
/// `Array[Json]` of payloads — so the whole pipeline is synchronous and runs on
/// every backend. `execute_subscription` returns the ordered sequence of response
/// payloads, exactly what a client would receive over the wire in order.
///
/// The async native variant (a live stream over a WebSocket, driven by
/// moonasgi/mooncat) wraps the same core: the source resolver becomes an async
/// generator yielding events, and each event runs `execute_subscription_event`
/// below. Splitting the pull source from the transport keeps the ordering and
/// per-event execution testable without an async runtime.

///|
/// A registry of subscription *source* resolvers, keyed by `"TypeName.fieldName"`
/// on the subscription root type. A source returns the ordered stream of event
/// payloads; each payload is the resolved value of the root field for one event,
/// and its sub-selection is resolved against it like any object value.
pub struct Subscribers {
  map : Map[String, (ResolveInfo) -> Array[Json] raise ResolverError]
}

///|
/// Create an empty subscription source registry.
pub fn Subscribers::new() -> Subscribers {
  { map: Map([]), }
}

///|
/// Register a source stream for the root subscription field `field_name` on
/// `type_name`. The source is called once per operation and yields the ordered
/// events to deliver.
pub fn Subscribers::field(
  self : Subscribers,
  type_name : String,
  field_name : String,
  source : (ResolveInfo) -> Array[Json] raise ResolverError,
) -> Unit {
  self.map[type_name + "." + field_name] = source
}

///|
/// ExecuteSubscriptionEvent (spec §6.2.3.3): produce one response's `data` for a
/// single event. The event is the resolved value of the root field, so it is
/// completed directly against the field's type and its sub-selection resolves
/// against it. A non-null root field whose event is null nulls out `data`.
fn Exec::execute_subscription_event(
  self : Exec,
  root_type : @schema.ObjectType,
  key : String,
  group : Array[@lang.QueryField],
  event : Json,
) -> Json {
  let first = group[0]
  let fpath : Array[Json] = [Json(key)]
  match self.field_type_of(root_type, first.name) {
    None => {
      self.add_error(
        "Cannot query field '" +
        first.name +
        "' on type '" +
        root_type.name +
        "'",
        fpath,
        first.pos,
      )
      let m : Map[String, Json] = Map([])
      m[key] = Json::null()
      Json(m)
    }
    Some(ftype) => {
      let completed = self.complete(ftype, event, group, fpath) catch {
        NullBubble => {
          if ftype is NonNull(_) {
            return Json::null()
          }
          Json::null()
        }
      }
      let m : Map[String, Json] = Map([])
      m[key] = completed
      Json(m)
    }
  }
}

///|
/// The outcome of establishing a subscription (GraphQL spec §6.2.3
/// `CreateSourceEventStream` + `MapSourceToResponseEvent`): either the request
/// failed before any event could be produced — a parse, validation, or
/// source-resolution error the client should receive *instead of* a stream — or
/// the source yielded its ordered `{ data, errors }` response payloads. Keeping
/// the two apart lets a transport (the `graphql-transport-ws` handler) send a
/// single `error` message for the former and a run of `next` messages for the
/// latter, which the flat "one error response in the payload list" shape cannot
/// distinguish.
pub(all) enum SubscriptionResult {
  RequestError(Array[@lang.GqlError])
  EventStream(Array[Json])
}

///|
/// Establish a subscription and materialise its event payloads. Parses and
/// validates `query`, requires a single-root-field subscription operation,
/// invokes the registered source, and maps every event through
/// `execute_subscription_event`. Any failure before the first event —
/// parse/validation error, a non-subscription operation, more than one root
/// field, an introspection root, a missing source, or a source `ResolverError` —
/// is a `RequestError`; success is an `EventStream` of ordered response payloads.
pub fn create_source_event_stream(
  schema : @schema.Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
  root_value~ : Json = Json::null(),
  context~ : Json = Json::null(),
) -> SubscriptionResult {
  let doc = @lang.parse(query) catch {
    GqlSyntaxError(m, line, col) =>
      return RequestError([@lang.GqlError::at(m, { line, col, })])
  }
  let verrors = @valid.validate(schema, doc)
  if verrors.length() > 0 {
    return RequestError(verrors)
  }
  let prepared = match select_operation(schema, doc, operation_name) {
    Ok(p) => p
    Err(e) => return RequestError([e])
  }
  if !(prepared.operation.operation is Subscription) {
    return RequestError([
      @lang.GqlError::at(
        "execute_subscription requires a subscription operation",
        prepared.operation.pos,
      ),
    ])
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
    return RequestError(var_errors)
  }
  let root_type = match schema.type_by_name(prepared.root_type) {
    Some(t) => t
    None =>
      return RequestError([
        @lang.GqlError::msg(
          "Root type '" + prepared.root_type + "' is not defined",
        ),
      ])
  }
  let exec = Exec::state(schema, resolvers, fragments, vars, context)
  let keys : Array[String] = []
  let groups : Map[String, Array[@lang.QueryField]] = Map([])
  exec.collect_fields(
    root_type,
    prepared.operation.selection_set,
    Map([]),
    keys,
    groups,
  )
  if keys.length() != 1 {
    return RequestError([
      @lang.GqlError::at(
        "Subscription operation must select exactly one root field",
        prepared.operation.pos,
      ),
    ])
  }
  let key = keys[0]
  let group = match groups.get(key) {
    Some(g) => g
    None =>
      return RequestError([@lang.GqlError::msg("internal: missing group")])
  }
  let root_field = group[0]
  if @schema.is_meta_field(root_field.name) {
    return RequestError([
      @lang.GqlError::at(
        "Introspection field '" +
        root_field.name +
        "' cannot be a subscription root",
        root_field.pos,
      ),
    ])
  }
  let source = match
    subscribers.map.get(root_type.name + "." + root_field.name) {
    Some(f) => f
    None =>
      return RequestError([
        @lang.GqlError::at(
          "No subscription source registered for '" +
          root_type.name +
          "." +
          root_field.name +
          "'",
          root_field.pos,
        ),
      ])
  }
  let args = exec.coerce_args(root_field)
  match root_type.field_by_name(root_field.name) {
    Some(fdef) => exec.apply_input_scalars(args, fdef)
    None => ()
  }
  let info = {
    parent: root_value,
    args,
    ctx: context,
    field_name: root_field.name,
  }
  let events = source(info) catch {
    ResolverError(m) =>
      return RequestError([@lang.GqlError::at(m, root_field.pos)])
    ResolverErrorExt(m, ext) =>
      return RequestError([
        { message: m, path: [], locations: [root_field.pos], extensions: ext, },
      ])
  }
  let out : Array[Json] = []
  for ev in events {
    let ex = Exec::state(schema, resolvers, fragments, vars, context)
    let data = ex.execute_subscription_event(root_type, key, group, ev)
    out.push(build_response(Some(data), ex.errors))
  }
  EventStream(out)
}

///|
/// Run a subscription operation and collect its ordered response payloads.
///
/// A thin wrapper over `create_source_event_stream`: a `RequestError` collapses
/// to a single `{ errors }` response (the flat shape callers without a streaming
/// transport expect), and an `EventStream` is returned as-is. `variables`,
/// `operation_name`, `root_value` and `context` mirror `execute`.
pub fn execute_subscription(
  schema : @schema.Schema,
  resolvers : Resolvers,
  subscribers : Subscribers,
  query : String,
  variables~ : Map[String, Json] = Map([]),
  operation_name? : String,
  root_value~ : Json = Json::null(),
  context~ : Json = Json::null(),
) -> Array[Json] {
  match
    create_source_event_stream(
      schema,
      resolvers,
      subscribers,
      query,
      variables~,
      operation_name?,
      root_value~,
      context~,
    ) {
    RequestError(errs) => [build_response(None, errs)]
    EventStream(payloads) => payloads
  }
}
