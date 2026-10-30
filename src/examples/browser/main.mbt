///|
/// Hands the demo schema to the page. The JS backend compiles a MoonBit
/// closure to a JavaScript function, so the showcase page calls the library
/// through these two names instead of re-implementing it in JavaScript.
///
///     moon build --target js   # docs.yml copies the emitted .js to docs/engine/
#cfg(target="js")
extern "js" fn expose(name : String, run : (String) -> String) -> Unit =
  #|(name, run) => { globalThis[name] = run }

///|
#cfg(target="js")
extern "js" fn expose_schema(name : String, sdl : () -> String) -> Unit =
  #|(name, sdl) => { globalThis[name] = sdl }

///|
/// On the JS target the two names land on `globalThis` for the page to call.
#cfg(target="js")
#coverage.skip
fn main {
  expose("moongqlRun", run)
  expose_schema("moongqlSdl", sdl)
}

///|
/// Every other target builds this package too, because the workspace is checked
/// and tested on all four; there is nothing for them to run.
#cfg(not(target="js"))
fn main {

}
