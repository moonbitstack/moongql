///|
/// Read a loader slot or a sentinel, so the printout stays legible.
fn or_missing(v : String?) -> String {
  match v {
    Some(x) => x
    None => "MISSING"
  }
}

///|
/// `DataLoader` collapses N+1 fetches into one batched, deduplicated call. Loading
/// author ids `1,2,1,3,2` triggers a single batch over the three distinct keys; the
/// results are cached, `prime` seeds a value with no backend call, `clear` forces a
/// reload, and `load_now` / `load_many` cover the single and bulk entry points.
///
///     moon run src/examples/18-dataloader
#coverage.skip
fn main {
  let calls : Ref[Int32] = { val: 0, }
  let seen : Array[String] = []
  let loader : @moongql.DataLoader[Int32, String] = @moongql.DataLoader::new(
    keys => {
      calls.val += 1
      let out : Array[String] = []
      for k in keys {
        seen.push(k.to_string())
        out.push("author#" + k.to_string())
      }
      out
    },
    k => k.to_string(),
  )
  loader.load(1)
  loader.load(2)
  loader.load(1)
  loader.load(3)
  loader.load(2)
  loader.dispatch()
  println("batch calls: \{calls.val}")
  println("batched keys: " + seen.join(", "))
  println("get(2): " + or_missing(loader.get(2)))
  loader.prime(7, "primed")
  println("get(7): " + or_missing(loader.get(7)))
  loader.clear(1)
  loader.load(1)
  loader.dispatch()
  println("batch calls after clear: \{calls.val}")
  println("load_now(5): " + or_missing(loader.load_now(5)))
  loader.load_many([10, 11])
  loader.dispatch()
  println("get(11): " + or_missing(loader.get(11)))
}
