///|
/// Read a loader value or a sentinel, so assertions read cleanly.
fn or_missing(v : String?) -> String {
  match v {
    Some(x) => x
    None => "MISSING"
  }
}

///|
/// A resolution pass that requests many author ids — some repeated — collapses to
/// one batch call over the distinct keys. The counter and the recorded key list
/// prove both the single call and the dedupe.
test "dataloader collapses N+1 into one deduped batch" {
  let calls : Ref[Int32] = { val: 0, }
  let seen : Array[String] = []
  let loader : DataLoader[Int32, String] = DataLoader::new(
    keys => {
      calls.val = calls.val + 1
      let out : Array[String] = []
      for k in keys {
        seen.push(k.to_string())
        out.push("author#" + k.to_string())
      }
      out
    },
    k => k.to_string(),
  )
  // Five posts whose author ids are 1, 2, 1, 3, 2.
  loader.load(1)
  loader.load(2)
  loader.load(1)
  loader.load(3)
  loader.load(2)
  loader.dispatch()
  assert_eq(calls.val, 1)
  assert_eq(seen.length(), 3)
  assert_eq(seen[0] + "," + seen[1] + "," + seen[2], "1,2,3")
  assert_eq(or_missing(loader.get(1)), "author#1")
  assert_eq(or_missing(loader.get(2)), "author#2")
  assert_eq(or_missing(loader.get(3)), "author#3")
}

///|
/// Before dispatch a key is not yet loaded; a second pass over a cached key runs
/// no new batch, and `prime` seeds a value with no backend call at all.
test "dataloader caches, primes and clears" {
  let calls : Ref[Int32] = { val: 0, }
  let loader : DataLoader[Int32, String] = DataLoader::new(
    keys => {
      calls.val = calls.val + 1
      let out : Array[String] = []
      for k in keys {
        out.push("v" + k.to_string())
      }
      out
    },
    k => k.to_string(),
  )
  assert_eq(or_missing(loader.get(1)), "MISSING")
  loader.load(1)
  loader.dispatch()
  assert_eq(calls.val, 1)
  assert_eq(or_missing(loader.get(1)), "v1")

  // A cached key needs no further batch.
  loader.load(1)
  loader.dispatch()
  assert_eq(calls.val, 1)

  // prime avoids the backend entirely.
  loader.prime(7, "primed")
  assert_eq(or_missing(loader.get(7)), "primed")
  loader.load(7)
  loader.dispatch()
  assert_eq(calls.val, 1)

  // clear forces a reload on the next dispatch.
  loader.clear(1)
  loader.load(1)
  loader.dispatch()
  assert_eq(calls.val, 2)
}

///|
/// `load_now` and `load_many` cover the single-key and bulk entry points.
test "dataloader load_now and load_many" {
  let calls : Ref[Int32] = { val: 0, }
  let loader : DataLoader[Int32, String] = DataLoader::new(
    keys => {
      calls.val = calls.val + 1
      let out : Array[String] = []
      for k in keys {
        out.push("x" + k.to_string())
      }
      out
    },
    k => k.to_string(),
  )
  assert_eq(or_missing(loader.load_now(5)), "x5")
  assert_eq(calls.val, 1)
  loader.load_many([10, 11, 10])
  loader.dispatch()
  // one more batch for the two distinct new keys
  assert_eq(calls.val, 2)
  assert_eq(or_missing(loader.get(11)), "x11")
}
