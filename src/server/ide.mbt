///|
/// The in-browser IDE a `GET` on the GraphQL endpoint serves. Three of them are
/// on offer, each loaded from a CDN at a pinned version, and the whole thing can
/// be turned off:
///
///   * **GraphiQL** (`graphiql`, the default) — the GraphQL Foundation's
///     reference IDE, MIT-licensed and the one kept current with the
///     specification. Version 5 carries the Monaco editor, a plugin system (the
///     explorer and history plugins are enabled here) and a fetcher that speaks
///     `graphql-transport-ws`, so it runs subscriptions too.
///
///   * **Apollo Sandbox** (`apollo_sandbox`) — Apollo's Explorer, embedded as an
///     iframe. It needs no Apollo account and introspects the endpoint on load.
///
///   * **Altair** (`altair`) — the fullest of the three: environments, saved
///     collections, and subscriptions over WebSocket or SSE.
///
/// Every asset is pinned to an exact version, so a page served today keeps
/// working when the CDN moves on. The IDE is a development surface: it
/// introspects the schema and runs arbitrary operations, which is why `off`
/// exists for anything but a development deployment.

///|
/// Which IDE the endpoint serves.
pub(all) enum IdeKind {
  GraphiQL
  ApolloSandbox
  Altair
  Off
} derive(Eq)

///|
/// The IDE a `GET` without a `?query=` is answered with. `subscription_endpoint`
/// is where the IDE opens its WebSocket: left as `None`, each page derives one
/// from the page's own location (the same host, `wss:` over HTTPS), which is
/// right for an endpoint served next to the IDE.
pub(all) struct Ide {
  kind : IdeKind
  subscription_endpoint : String?
}

///|
/// GraphiQL, the reference IDE — the default.
pub let graphiql : Ide = { kind: GraphiQL, subscription_endpoint: None, }

///|
/// Apollo Sandbox, embedded as an iframe.
pub let apollo_sandbox : Ide = {
  kind: ApolloSandbox,
  subscription_endpoint: None,
}

///|
/// Altair, the IDE with environments and saved collections.
pub let altair : Ide = { kind: Altair, subscription_endpoint: None, }

///|
/// No IDE at all: a `GET` without a `?query=` is a 405.
pub let off : Ide = { kind: Off, subscription_endpoint: None, }

///|
/// Whether this configuration serves no IDE.
pub fn Ide::is_off(self : Ide) -> Bool {
  self.kind == Off
}

///|
/// The page title the IDE's HTML carries.
pub fn Ide::title(self : Ide) -> String {
  match self.kind {
    GraphiQL => "GraphiQL"
    ApolloSandbox => "Apollo Sandbox"
    Altair => "Altair"
    Off => ""
  }
}

///|
/// The full HTML page mounting this IDE against `endpoint`. `Off` has no page,
/// and answers the empty string.
pub fn Ide::html(self : Ide, endpoint~ : String = "/graphql") -> String {
  match self.kind {
    GraphiQL => graphiql_page(endpoint, self.subscription_endpoint)
    ApolloSandbox => apollo_page(endpoint)
    Altair => altair_page(endpoint, self.subscription_endpoint)
    Off => ""
  }
}

///|
/// The GraphiQL page up to the fetcher's endpoint literal. React, GraphiQL and
/// the plugins load from esm.sh through an import map, so nothing is bundled
/// into the page: it is a string, not a build artefact.
fn graphiql_head() -> String {
  let head =
    #|<!DOCTYPE html>
    #|<html lang="en">
    #|<head>
    #|  <meta charset="utf-8" />
    #|  <title>GraphiQL</title>
    #|  <meta name="viewport" content="width=device-width, initial-scale=1" />
    #|  <link rel="stylesheet" href="https://esm.sh/graphiql@5.4.0/dist/style.css" />
    #|  <link rel="stylesheet" href="https://esm.sh/@graphiql/plugin-explorer@5.1.5/dist/style.css" />
    #|  <style>
    #|    body { margin: 0; }
    #|    #graphiql { height: 100dvh; }
    #|    .loading { height: 100dvh; display: flex; align-items: center; justify-content: center; font-family: system-ui, sans-serif; color: #6b7280; }
    #|  </style>
    #|  <script type="importmap">
    #|    {
    #|      "imports": {
    #|        "react": "https://esm.sh/react@19.3.1",
    #|        "react/": "https://esm.sh/react@19.3.1/",
    #|        "react-dom": "https://esm.sh/react-dom@19.3.1",
    #|        "react-dom/": "https://esm.sh/react-dom@19.3.1/",
    #|        "graphiql": "https://esm.sh/graphiql@5.4.0?standalone&external=react,react-dom,@graphiql/react,graphql",
    #|        "graphiql/": "https://esm.sh/graphiql@5.4.0/",
    #|        "@graphiql/react": "https://esm.sh/@graphiql/react@0.39.1?standalone&external=react,react-dom,graphql,@graphiql/toolkit,@emotion/is-prop-valid",
    #|        "@graphiql/toolkit": "https://esm.sh/@graphiql/toolkit@0.12.1?standalone&external=graphql",
    #|        "@graphiql/plugin-explorer": "https://esm.sh/@graphiql/plugin-explorer@5.1.5?standalone&external=react,@graphiql/react,graphql",
    #|        "graphql": "https://esm.sh/graphql@17.0.2",
    #|        "@emotion/is-prop-valid": "data:text/javascript,"
    #|      }
    #|    }
    #|  </script>
    #|</head>
    #|<body>
    #|  <div id="graphiql"><div class="loading">Loading GraphiQL…</div></div>
    #|  <script type="module">
    #|    import React from 'react';
    #|    import ReactDOM from 'react-dom/client';
    #|    import { GraphiQL, HISTORY_PLUGIN } from 'graphiql';
    #|    import { explorerPlugin } from '@graphiql/plugin-explorer';
    #|    import { createGraphiQLFetcher } from '@graphiql/toolkit';
    #|    import 'graphiql/setup-workers/esm.sh';
    #|    const fetcher = createGraphiQLFetcher({ url: '
  head
}

///|
/// The GraphiQL page after the fetcher's endpoint literal. The subscription URL
/// is only spelled out when one was configured; otherwise the fetcher derives it
/// from the endpoint, which is the same host over `ws:` or `wss:`.
fn graphiql_tail(subscription : String?) -> String {
  let sub = match subscription {
    Some(u) => ", subscriptionUrl: '" + u + "'"
    None => ""
  }
  let tail =
    #|' });
    #|    const plugins = [HISTORY_PLUGIN, explorerPlugin()];
    #|    const root = ReactDOM.createRoot(document.getElementById('graphiql'));
    #|    root.render(React.createElement(GraphiQL, {
    #|      fetcher,
    #|      plugins,
    #|      defaultEditorToolsVisibility: true,
    #|      defaultQuery: '# A starter query — edit it, then press the play button.\n{\n  __typename\n}\n',
    #|    }));
    #|  </script>
    #|</body>
    #|</html>
  sub + tail
}

///|
/// The GraphiQL page, wired to fetch against `endpoint`.
fn graphiql_page(endpoint : String, subscription : String?) -> String {
  graphiql_head() + endpoint + graphiql_tail(subscription)
}

///|
/// The Apollo Sandbox page: a full-height container the embedded Sandbox mounts
/// an iframe into, pointed at an absolute endpoint URL (the iframe's requests
/// are sent by this page, but a relative URL would read as relative to the
/// iframe). Sandbox opens its subscription socket on the endpoint itself, so
/// `subscription_endpoint` has nothing to say to it.
fn apollo_page(endpoint : String) -> String {
  let head =
    #|<!DOCTYPE html>
    #|<html lang="en">
    #|<head>
    #|  <meta charset="utf-8" />
    #|  <title>Apollo Sandbox</title>
    #|  <meta name="viewport" content="width=device-width, initial-scale=1" />
    #|  <style>
    #|    body { margin: 0; }
    #|    #sandbox { height: 100dvh; }
    #|    #sandbox iframe { width: 100%; height: 100%; border: none; }
    #|  </style>
    #|</head>
    #|<body>
    #|  <div id="sandbox"></div>
    #|  <script type="module">
    #|    import { ApolloSandbox } from 'https://esm.sh/@apollo/sandbox@2.7.4';
    #|    const endpoint = new URL('
  let tail =
    #|', location.href).href;
    #|    new ApolloSandbox({
    #|      target: '#sandbox',
    #|      initialEndpoint: endpoint,
    #|      endpointIsEditable: true,
    #|      hideCookieToggle: true,
    #|    });
    #|  </script>
    #|</body>
    #|</html>
  head + endpoint + tail
}

///|
/// The Altair page. Altair's static build reads its endpoint and its subscription
/// endpoint from the page's globals before its own bundle loads, so the whole
/// configuration is three assignments followed by the two scripts. Every asset is
/// pinned to an exact version, so a page served today keeps working when the CDN
/// moves on.
fn altair_page(endpoint : String, subscription : String?) -> String {
  let sub = match subscription {
    Some(u) => "'" + u + "'"
    None =>
      "(u => (u.protocol === 'https:' ? 'wss:' : 'ws:') + '//' + u.host + u.pathname)(new URL(endpoint, location.href))"
  }
  let head =
    #|<!DOCTYPE html>
    #|<html lang="en">
    #|<head>
    #|  <meta charset="utf-8" />
    #|  <title>Altair</title>
    #|  <meta name="viewport" content="width=device-width, initial-scale=1" />
    #|  <link rel="icon" href="https://unpkg.com/altair-static@8.5.11/build/dist/favicon.ico" />
    #|  <link rel="stylesheet" href="https://unpkg.com/altair-static@8.5.11/build/dist/styles.css" />
    #|  <style>body { margin: 0; }</style>
    #|  <script>
    #|    const endpoint = '
  let mid =
    #|';
    #|    window.__ALTAIR_ENDPOINT_URL__ = endpoint;
    #|    window.__ALTAIR_SUBSCRIPTIONS_ENDPOINT__ =
  let tail =
    #|;
    #|    window.__ALTAIR_WEB_APP__ = true;
    #|  </script>
    #|  <script type="module" src="https://unpkg.com/altair-static@8.5.11/build/dist/polyfills.js"></script>
    #|  <script type="module" src="https://unpkg.com/altair-static@8.5.11/build/dist/main.js"></script>
    #|</head>
    #|<body><app-root></app-root></body>
    #|</html>
  head + endpoint + mid + " " + sub + tail
}

///|
pub extend IdeKind with Eq::{not_equal, equal}
