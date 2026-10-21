// Copyright 2026 Leo Cheng
// SPDX-License-Identifier: Apache-2.0

// The façade: every subpackage's public surface re-exported as it was, so
// `@moongql.X` is still the X it was before the split. A program that wants only
// one stage imports that subpackage and links nothing else. Enum constructors
// do not travel through `pub using`, so a match on one names its subpackage:
// `@lang.Value::String(s)`, not `@moongql.Value::String(s)`.

///|
pub using @lang {
  type Argument,
  type Definition,
  type Directive,
  type Document,
  type FragmentDefinition,
  type GqlError,
  type GqlSyntaxError,
  type OperationDefinition,
  type OperationType,
  type Pos,
  type QueryField,
  type Selection,
  type Token,
  type TokenKind,
  type TypeRef,
  type Value,
  type VariableDefinition,
  parse,
  tokenize,
}

///|
pub using @schema {
  type AppliedDirective,
  type DirectiveDef,
  type EnumType,
  type Field,
  type FieldDirectiveHook,
  type GqlType,
  type ObjectType,
  type ScalarType,
  type Schema,
  type TypeKind,
  type UnionType,
}

///|
pub using @valid {validate}

///|
pub using @exec {
  type ResolveInfo,
  type ResolverError,
  type Resolvers,
  type Subscribers,
  type SubscriptionResult,
  create_source_event_stream,
  execute,
  execute_subscription,
}

///|
pub using @federation {type EntityDef, type EntityResolver, type Federation}

///|
pub using @server {
  type GqlWs,
  graphiql_html,
  graphql_app,
  graphql_handler,
  graphql_ws_handler,
}

///|
pub using @loader {type DataLoader}
