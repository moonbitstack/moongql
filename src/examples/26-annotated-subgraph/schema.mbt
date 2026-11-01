// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

///|
/// An entity: `key` is the fields a gateway refers to it by, and the fields carry
/// their federation directives.
#gql.type(key="id")
pub struct User {
  id : String
  #gql.field(shareable=true)
  name : String
}

///|
/// How a representation becomes a `User`. Its parameters are the key's fields.
#gql.reference
pub fn user_by_id(id : String) -> User? {
  if id == "1" {
    Some({ id, name: "ada", })
  } else {
    None
  }
}

///|
/// A check is a function of `ResolveInfo`.
pub fn signed_in(info : @moongql.ResolveInfo) -> Bool {
  info.ctx is String("ada")
}

///|
#gql.query
pub fn hello() -> String {
  "hello"
}

///|
#gql.query(permission="signed_in")
pub fn secret() -> String {
  "the answer"
}

///|
/// The array is the events: each one is a `next` to the subscriber.
#gql.subscription
pub fn countdown(from : Int32) -> Array[Int32] {
  Array::makei(from, i => from - i)
}
