///|
/// wasm-gc is the one target without an async entry point in `moonbitlang/async`
/// (`run_async_main` is native, js and wasm only), so this example, whose `main`
/// awaits, is built for those three. This program is what the fourth target
/// gets: it says so rather than failing to link.
fn main {
  println(
    "The MCP example needs an async runtime. Build it for native, wasm or js.",
  )
}
