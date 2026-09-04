const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const { test } = require("node:test");
const vm = require("node:vm");

const source = readFileSync(require.resolve("../app.js"), "utf8").replace(/\nboot\(\);\s*$/, "");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function waitFor(predicate) {
  for (let i = 0; i < 100; i += 1) {
    if (predicate()) return;
    await sleep(10);
  }
  assert.fail("Condition did not become true");
}

function setup(t) {
  const timers = new Set();
  const requests = [];
  const listeners = {};
  const elements = new Map();
  const element = () => ({
    value: "", textContent: "", dataset: {}, children: [],
    classList: { add() {}, remove() {} },
    append() {}, prepend() {}, removeAttribute() {},
  });
  const context = vm.createContext({
    URL, AbortController, performance, console,
    setTimeout(callback, delay) {
      const timer = setTimeout(callback, delay);
      timers.add(timer);
      return timer;
    },
    clearTimeout, setInterval, clearInterval,
    document: {
      querySelector(selector) {
        if (!elements.has(selector)) elements.set(selector, element());
        return elements.get(selector);
      },
      querySelectorAll: () => [], createElement: element, addEventListener() {},
    },
    window: { addEventListener(name, fn) { listeners[name] = fn; } },
    fetch(url, init) {
      return new Promise((resolve, reject) => {
        const request = {
          url: new URL(url), init, time: Date.now(), reject,
          respond(data = { ok: true }) {
            resolve({ ok: true, headers: new Headers({ "content-type": "application/json" }), json: async () => data });
          },
        };
        requests.push(request);
        init.signal.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
      });
    },
  });
  vm.runInContext(source + `
    state.baseUrl = state.verifiedBaseUrl = "http://192.168.2.23";
    state.connected = true;
    el.speed.value = "55";
    el.timeout.value = "450";
    globalThis.api = { state, startDrive, stopDrive, refreshSensors, requestRobot, bindKeyboard };
  `, context);
  t.after(() => { for (const timer of timers) clearTimeout(timer); });
  return { ...context.api, requests, listeners };
}

test("slow response keeps one wheel request and only the newest direction", async (t) => {
  const c = setup(t);
  c.startDrive([0, 1, 0]);
  c.startDrive([-1, 0, 0]);
  c.startDrive([0, 0, 1]);
  await sleep(280);
  assert.equal(c.requests.length, 1);
  c.requests[0].respond();
  await waitFor(() => c.requests.length === 2);
  const next = c.requests[1];
  assert.equal(next.init.method, "GET");
  assert.equal(next.init.cache, "no-store");
  assert.equal(next.url.hostname, "192.168.2.23");
  assert.equal(next.url.searchParams.get("m1"), "55");
  assert.equal(next.url.searchParams.get("m2"), "-55");
  const stop = c.stopDrive();
  next.respond();
  await waitFor(() => c.requests.length === 3);
  c.requests[2].respond();
  await stop;
});

test("STOP discards queued turns, waits for current command and clears held keys", async (t) => {
  const c = setup(t);
  c.startDrive([0, 1, 0]);
  c.startDrive([0, 0, 1]);
  c.state.keyboard.add("KeyW");
  const stopped = c.stopDrive();
  assert.equal(c.stopDrive(), stopped);
  c.startDrive([0, -1, 0]);
  assert.equal(c.requests.length, 1);
  c.requests[0].respond();
  await waitFor(() => c.requests.length === 2);
  assert.equal(c.requests[1].url.pathname, "/stop");
  assert.ok(c.requests[1].time - c.requests[0].time >= 50);
  c.requests[1].respond();
  await stopped;
  await sleep(260);
  assert.equal(c.requests.length, 2);
  assert.equal(c.state.keyboard.size, 0);
  assert.equal(c.state.activeVector, null);
});

test("network failure stops renewal and disarms driving", async (t) => {
  const c = setup(t);
  c.startDrive([0, 1, 0]);
  c.requests[0].reject(new Error("network failure"));
  await waitFor(() => c.requests.length === 2);
  assert.equal(c.requests[1].url.pathname, "/stop");
  c.requests[1].respond();
  await waitFor(() => !c.state.driveBusy);
  assert.equal(c.state.connected, false);
  c.startDrive([0, 0, 1]);
  await sleep(100);
  assert.equal(c.requests.length, 2);
});

test("sensor requests cannot overlap or start while driving", async (t) => {
  const c = setup(t);
  const pending = c.refreshSensors();
  await c.refreshSensors();
  assert.equal(c.requests.length, 1);
  c.requests[0].respond();
  await pending;
  c.state.activeVector = [0, 1, 0];
  await c.refreshSensors();
  assert.equal(c.requests.length, 1);
});

test("deadline aborts a hanging request", async (t) => {
  const c = setup(t);
  await assert.rejects(c.requestRobot("/status", { safe: true, method: "GET", deadline: 20 }));
  assert.equal(c.requests[0].init.signal.aborted, true);
});

test("other rover addresses are rejected before fetch", async (t) => {
  const c = setup(t);
  c.state.baseUrl = "http://192.168.2.25";
  await assert.rejects(c.requestRobot("/status", { safe: true, method: "GET" }));
  assert.equal(c.requests.length, 0);
});

test("keyboard auto-repeat cannot restart movement after STOP", async (t) => {
  const c = setup(t);
  c.bindKeyboard();
  c.listeners.keydown({ code: "KeyW", repeat: true, target: {}, preventDefault() {} });
  assert.equal(c.requests.length, 0);
  assert.equal(c.state.keyboard.size, 0);
});
