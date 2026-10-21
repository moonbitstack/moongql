///|
/// A DataLoader: the batch-and-cache pattern strawberry exposes for collapsing the
/// N+1 problem. Keys requested during one resolution pass are queued and deduped;
/// a single `dispatch` runs the batch-load function once over the distinct keys
/// and fills a per-loader cache, so many `load`s for the same or overlapping keys
/// cost one backend call.
///
/// This is the synchronous core. Where Facebook's DataLoader coalesces `load`s
/// within an event-loop tick and returns a promise each, here the queue is
/// drained explicitly by `dispatch` (an async native variant schedules that drain
/// on the microtask queue). Keys are identified by a caller-supplied `key`
/// function so any key type works without a `Hash` bound.

///|
/// A batching, caching loader over key type `K` and value type `V`. `batch_load`
/// receives the distinct, un-cached keys and must return their values positionally
/// (result `i` is the value for key `i`). `key` derives a stable cache/identity
/// string for a key.
pub struct DataLoader[K, V] {
  batch_load : (Array[K]) -> Array[V]
  key : (K) -> String
  cache : Map[String, V]
  queue : Array[K]
  queued : Map[String, Bool]
}

///|
/// Create a loader from its batch-load function and a key-identity function.
pub fn[K, V] DataLoader::new(
  batch_load : (Array[K]) -> Array[V],
  key : (K) -> String,
) -> DataLoader[K, V] {
  { batch_load, key, cache: Map([]), queue: [], queued: Map([]), }
}

///|
/// Queue `k` for the next `dispatch`. A key already cached or already queued in
/// this pass is dropped, so the batch that `dispatch` runs sees each distinct key
/// exactly once — this dedupe is what collapses N+1 into one call.
pub fn[K, V] DataLoader::load(self : DataLoader[K, V], k : K) -> Unit {
  let ks = (self.key)(k)
  if self.cache.contains(ks) {
    return
  }
  if self.queued.get(ks) is Some(true) {
    return
  }
  self.queued[ks] = true
  self.queue.push(k)
}

///|
/// Queue several keys for the next `dispatch`.
pub fn[K, V] DataLoader::load_many(
  self : DataLoader[K, V],
  ks : Array[K],
) -> Unit {
  for k in ks {
    self.load(k)
  }
}

///|
/// Run the pending batch: call `batch_load` once with the queued distinct keys,
/// store each returned value in the cache under its key, and clear the queue. A
/// no-op when nothing is queued, so it is safe to call after every pass.
pub fn[K, V] DataLoader::dispatch(self : DataLoader[K, V]) -> Unit {
  if self.queue.length() == 0 {
    return
  }
  let batch = self.queue.copy()
  self.queue.clear()
  self.queued.clear()
  let values = (self.batch_load)(batch)
  let n = if values.length() < batch.length() {
    values.length()
  } else {
    batch.length()
  }
  for i in 0..<n {
    self.cache[(self.key)(batch[i])] = values[i]
  }
}

///|
/// The cached value for `k`, or `None` if it has not been loaded and dispatched.
pub fn[K, V] DataLoader::get(self : DataLoader[K, V], k : K) -> V? {
  self.cache.get((self.key)(k))
}

///|
/// Load one key and dispatch immediately, returning its value. Convenience for a
/// single lookup; batching still applies to anything already queued.
pub fn[K, V] DataLoader::load_now(self : DataLoader[K, V], k : K) -> V? {
  self.load(k)
  self.dispatch()
  self.get(k)
}

///|
/// Seed the cache with a known value so a later `load` for `k` never hits the
/// backend (strawberry/Facebook DataLoader's `prime`).
pub fn[K, V] DataLoader::prime(self : DataLoader[K, V], k : K, v : V) -> Unit {
  let ks = (self.key)(k)
  if !self.cache.contains(ks) {
    self.cache[ks] = v
  }
}

///|
/// Drop the cached value for `k`, so the next `load`+`dispatch` reloads it.
pub fn[K, V] DataLoader::clear(self : DataLoader[K, V], k : K) -> Unit {
  self.cache.remove((self.key)(k))
}

///|
/// Drop the whole cache.
pub fn[K, V] DataLoader::clear_all(self : DataLoader[K, V]) -> Unit {
  self.cache.clear()
}
