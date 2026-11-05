// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// A live source of subscription events: something to pull from, and something to
/// stop. `next` answers `None` when the source has ended, which is the signal a
/// transport turns into the terminating `complete`.
///
/// The pull is asynchronous because the events are not there yet — they arrive
/// from a queue, a socket, or a database's change feed — and a subscription must
/// not look like a list that was computed up front.
pub struct Stream {
  pull : async () -> Json?
  stop : () -> Unit
}

///|
/// A stream over any pull, with a way to stop it. `stop` is called once, when the
/// subscriber goes away or the stream ends.
pub fn Stream::of(
  pull~ : async () -> Json?,
  stop~ : () -> Unit = () => (),
) -> Stream {
  { pull, stop, }
}

///|
/// The next event, or `None` when the source has ended. An error the source
/// raises is the subscriber's problem to report: it is not a field error, because
/// the payload it would belong to does not exist.
pub async fn Stream::next(self : Stream) -> Json? {
  let pull = self.pull
  pull()
}

///|
/// Stop the source. Called on the way out of a subscription: the client sent
/// `complete`, the socket closed, or the last event had already arrived.
pub fn Stream::close(self : Stream) -> Unit {
  let stop = self.stop
  stop()
}

///|
/// What a producer holds while it feeds a stream. Dropping every sender ends the
/// stream; `close` ends it at once.
pub struct Sender {
  queue : @aqueue.Queue[Json]
}

///|
/// A stream paired with the sender that feeds it. The queue is unbounded, so a
/// producer never blocks on a slow subscriber and never loses an event.
pub fn Stream::channel() -> (Stream, Sender) {
  let queue : @aqueue.Queue[Json] = @aqueue.Queue::Queue(kind=@aqueue.Unbounded)
  let stream = {
    pull: async fn() {
      let v = queue.get() catch { _ => return None }
      Some(v)
    },
    stop: () => queue.close(),
  }
  (stream, { queue, })
}

///|
/// Put an event into the stream. A closed stream refuses it, which is how a
/// producer learns that nobody is listening any more.
pub fn Sender::send(self : Sender, event : Json) -> Unit raise {
  self.queue.try_put(event) |> ignore
}

///|
/// End the stream: a pending or later `next` answers `None`.
pub fn Sender::close(self : Sender) -> Unit {
  self.queue.close()
}
