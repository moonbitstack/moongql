// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// The conformance driver needs a standard input and a standard output, which
/// only the native backend has. On the others the program says so and stops: a
/// package marked executable must have a `main` everywhere, and this is the one
/// that makes the reason plain instead of failing to link.
#cfg(not(target="native"))
fn main {
  println(
    "the conformance driver runs on the native backend: moon build --target native",
  )
}
