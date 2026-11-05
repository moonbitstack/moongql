// Drives the conformance driver: it writes one JSON line per step and reads the
// events that step caused. The driver holds the application; this side holds the
// pipe, and stands in for a server.
import { spawn } from 'node:child_process';
import readline from 'node:readline';

export class Bridge {
  constructor(binary) {
    this.child = spawn(binary, [], { stdio: ['pipe', 'pipe', 'inherit'] });
    // The driver answers one step at a time and shares one pipe, so the steps
    // are serialised here: two callers cannot interleave their events.
    this.chain = Promise.resolve();
    this.pump = Promise.resolve();
    this.closedStream = false;
    this.pending = [];
    this.waiters = [];
    const lines = readline.createInterface({ input: this.child.stdout });
    lines.on('line', (line) => {
      if (!line.trim()) return;
      const event = JSON.parse(line);
      const waiter = this.waiters.shift();
      if (waiter) waiter(event);
      else this.pending.push(event);
    });
  }

  // The next event the driver prints.
  next(timeoutMs = 5000) {
    if (this.pending.length) return Promise.resolve(this.pending.shift());
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('driver timed out')), timeoutMs);
      this.waiters.push((event) => {
        clearTimeout(timer);
        resolve(event);
      });
    });
  }

  // Keep reading for a moment after a step ended: a subscription task writes its
  // frames after the message that started it has been answered.
  async drain(quietMs = 100) {
    const events = [];
    for (;;) {
      const event = await this.nextIfAny(quietMs);
      if (!event) return events;
      if (event.op === 'end') continue;
      events.push(event);
    }
  }

  nextIfAny(timeoutMs) {
    if (this.pending.length) return Promise.resolve(this.pending.shift());
    return new Promise((resolve) => {
      const waiter = (event) => {
        clearTimeout(timer);
        resolve(event);
      };
      const timer = setTimeout(() => {
        const at = this.waiters.indexOf(waiter);
        if (at >= 0) this.waiters.splice(at, 1);
        resolve(null);
      }, timeoutMs);
      this.waiters.push(waiter);
    });
  }

  write(step) {
    this.child.stdin.write(`${JSON.stringify(step)}\n`);
  }

  // Everything up to the step's `end` line.
  async untilEnd(timeoutMs = 5000) {
    const events = [];
    for (;;) {
      const event = await this.next(timeoutMs);
      if (event.op === 'end') return events;
      events.push(event);
    }
  }

  // One HTTP request, as the application answered it.
  http(options) {
    const run = this.chain.then(() => this.httpNow(options));
    this.chain = run.catch(() => {});
    return run;
  }

  async httpNow({
    method = 'POST',
    path = '/graphql',
    query = '',
    headers = [],
    body = '',
  }) {
    this.write({ op: 'http', method, path, query, headers, body });
    const events = await this.untilEnd();
    let status = 0;
    const outHeaders = [];
    let text = '';
    for (const event of events) {
      if (event.op === 'http_start') {
        status = event.status;
        outHeaders.push(...event.headers);
      } else if (event.op === 'http_body') {
        text += event.body;
      }
    }
    return { status, headers: outHeaders, body: text };
  }

  // A WebSocket as a stream rather than a call and a reply: the frames arrive
  // whenever the application produces them, so the caller is handed each event as
  // it lands and writes its own frames with `write`.
  openStream(path, subprotocols, onEvent) {
    this.write({ op: 'ws_open', path, subprotocols });
    this.pump = this.pump.then(async () => {
      for (;;) {
        const event = await this.nextIfAny(200);
        if (!event) {
          if (this.closedStream) return;
          continue;
        }
        if (event.op !== 'end') onEvent(event);
      }
    });
  }

  closeStream() {
    this.closedStream = true;
    this.write({ op: 'ws_close' });
  }

  wsOpen(path = '/graphql', subprotocols = []) {
    const run = this.chain.then(() => this.wsOpenNow(path, subprotocols));
    this.chain = run.catch(() => {});
    return run;
  }

  async wsOpenNow(path, subprotocols) {
    this.write({ op: 'ws_open', path, subprotocols });
    const events = await this.untilEnd();
    // The application runs in a task of its own, so its accept frame can follow
    // the step that started it.
    return events.concat(await this.drain());
  }

  wsSend(text) {
    const run = this.chain.then(() => this.wsSendNow(text));
    this.chain = run.catch(() => {});
    return run;
  }

  async wsSendNow(text) {
    this.write({ op: 'ws_send', text });
    const events = await this.untilEnd();
    return events.concat(await this.drain());
  }

  wsClose() {
    const run = this.chain.then(() => this.wsCloseNow());
    this.chain = run.catch(() => {});
    return run;
  }

  async wsCloseNow() {
    this.write({ op: 'ws_close' });
    return this.untilEnd();
  }

  async quit() {
    this.write({ op: 'quit' });
    await new Promise((resolve) => this.child.on('exit', resolve));
  }
}

// A `fetch` the specification's audit can call: same shape, same semantics, but
// the request goes to the application through the bridge instead of a socket.
export function fetchOver(bridge) {
  return async (url, init = {}) => {
    const target = new URL(url);
    const headers = [];
    const seen = new Headers(init.headers || {});
    seen.forEach((value, key) => headers.push([key, value]));
    let body = '';
    if (init.body !== undefined && init.body !== null) {
      body = typeof init.body === 'string' ? init.body : String(init.body);
    }
    const answer = await bridge.http({
      method: init.method || 'GET',
      path: target.pathname,
      query: target.search.replace(/^\?/, ''),
      headers,
      body,
    });
    return new Response(answer.body, {
      status: answer.status,
      headers: answer.headers,
    });
  };
}
