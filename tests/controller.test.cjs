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
    replaceChildren() {}, addEventListener() {},
    querySelector: () => element(), querySelectorAll: () => [],
  });
  const saved = new Map();
  const context = vm.createContext({
    URL, AbortController, performance, console,
    localStorage: { setItem: (key, value) => saved.set(key, value), getItem: (key) => saved.get(key) },
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
    state.baseUrl = state.verifiedBaseUrl = "http://127.0.0.1:17777";
    state.connected = true;
    el.speed.value = "55";
    el.timeout.value = "450";
    globalThis.api = { state, startDrive, stopDrive, refreshSensors, requestRobot, bindKeyboard,
      computePositionSpeeds, positionSpeedsToMotors, vectorFromKeyboard,
      validateProfile, profileFromObservations, reassignPosition, parseCalibrationFile,
      testMotor, startCalibration, nextCalibrationStep };
  `, context);
  t.after(() => { for (const timer of timers) clearTimeout(timer); });
  return { ...context.api, requests, listeners, elements, saved };
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
  assert.equal(next.url.hostname, "127.0.0.1");
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

test("direct rover addresses are rejected so commands always cross the phone", async (t) => {
  const c = setup(t);
  c.state.baseUrl = "http://192.168.2.23";
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

test("Q/E commands all four wheels even with held translation keys", (t) => {
  const c = setup(t);
  for (const turn of [-1, 1]) {
    for (const x of [-1, 0, 1]) {
      for (const y of [-1, 0, 1]) {
        const values = c.computePositionSpeeds([x, y, turn]);
        assert.deepEqual({ ...values }, { fl: turn * 55, fr: -turn * 55, bl: turn * 55, br: -turn * 55 });
      }
    }
  }
});

test("forward, sideways and diagonal commands retain their existing values", (t) => {
  const c = setup(t);
  for (const x of [-1, 0, 1]) {
    for (const y of [-1, 0, 1]) {
      const scale = 55 / Math.max(1, Math.abs(x) + Math.abs(y));
      const values = c.computePositionSpeeds([x, y, 0]);
      assert.deepEqual({ ...values }, {
        fl: (y + x) * scale, fr: (y - x) * scale,
        bl: (y - x) * scale, br: (y + x) * scale,
      });
    }
  }
});

test("turns respect calibrated motor positions and polarity", (t) => {
  const c = setup(t);
  c.state.profile.mapping = { m1: "br", m2: "bl", m3: "fr", m4: "fl" };
  c.state.profile.invert = { m1: true, m2: false, m3: false, m4: true };
  const right = c.positionSpeedsToMotors(c.computePositionSpeeds([0, 0, 1]));
  const left = c.positionSpeedsToMotors(c.computePositionSpeeds([0, 0, -1]));
  assert.deepEqual({ ...right }, { m1: 55, m2: 55, m3: -55, m4: -55 });
  for (const id of Object.keys(right)) assert.equal(left[id], -right[id]);
});

test("releasing Q restores held strafe without retaining a mixed turn", (t) => {
  const c = setup(t);
  c.state.keyboard.add("KeyD");
  c.state.keyboard.add("KeyQ");
  assert.deepEqual({ ...c.computePositionSpeeds(c.vectorFromKeyboard()) }, { fl: -55, fr: 55, bl: -55, br: 55 });
  c.state.keyboard.delete("KeyQ");
  assert.deepEqual({ ...c.computePositionSpeeds(c.vectorFromKeyboard()) }, { fl: 55, fr: -55, bl: -55, br: 55 });
});

test("observations determine all motor positions and forward polarity", (t) => {
  const c = setup(t);
  const profile = c.profileFromObservations({
    m1: { position: "br", direction: "backward" },
    m2: { position: "fr", direction: "forward" },
    m3: { position: "bl", direction: "backward" },
    m4: { position: "fl", direction: "forward" },
  });
  assert.deepEqual({ ...profile.mapping }, { m1: "br", m2: "fr", m3: "bl", m4: "fl" });
  assert.deepEqual({ ...profile.invert }, { m1: true, m2: false, m3: true, m4: false });
  c.state.profile = profile;
  assert.deepEqual({ ...c.positionSpeedsToMotors(c.computePositionSpeeds([0, 0, 1])) },
    { m1: 55, m2: -55, m3: -55, m4: 55 });
});

test("diagonal swap explains unchanged translation but incorrect turn", (t) => {
  const c = setup(t);
  const payload = (vector) => ({ ...c.positionSpeedsToMotors(c.computePositionSpeeds(vector)) });
  const forward = payload([0, 1, 0]);
  const strafe = payload([1, 0, 0]);
  const turn = payload([0, 0, 1]);
  c.reassignPosition(c.state.profile, "m1", "br");
  assert.deepEqual(payload([0, 1, 0]), forward);
  assert.deepEqual(payload([1, 0, 0]), strafe);
  assert.notDeepEqual(payload([0, 0, 1]), turn);
  assert.equal(c.state.profile.mapping.m4, "fl");
  c.validateProfile(c.state.profile);
});

test("duplicate positions, missing observations and invalid polarity are rejected", (t) => {
  const c = setup(t);
  assert.throws(() => c.profileFromObservations({}));
  c.state.profile.mapping.m1 = "fr";
  assert.throws(() => c.validateProfile(c.state.profile));
  assert.throws(() => c.positionSpeedsToMotors({ fl: 55, fr: -55, bl: 55, br: -55 }));
  c.state.profile.mapping.m1 = "fl";
  c.state.profile.invert.m1 = "false";
  assert.throws(() => c.validateProfile(c.state.profile));
});

test("calibration import validates identity and ignores non-profile settings", (t) => {
  const c = setup(t);
  const file = { version: 1, rover: "192.168.2.23", profile: c.state.profile, speed: 100, baseUrl: "http://example.com" };
  const profile = c.parseCalibrationFile(JSON.stringify(file));
  assert.deepEqual(JSON.parse(JSON.stringify(profile)), JSON.parse(JSON.stringify(c.state.profile)));
  assert.equal(profile.baseUrl, undefined);
  assert.throws(() => c.parseCalibrationFile(JSON.stringify({ ...file, rover: "192.168.2.25" })));
  assert.throws(() => c.parseCalibrationFile(JSON.stringify({ ...file, version: 2 })));
  assert.equal(c.requests.length, 0);
});

test("wizard starts without guessed observations and preserves existing mapping", (t) => {
  const c = setup(t);
  const original = JSON.stringify(c.state.profile);
  c.startCalibration();
  assert.equal(Object.keys(c.state.calibration.observations).length, 0);
  c.nextCalibrationStep();
  assert.equal(c.state.calibration.step, 0);
  assert.equal(JSON.stringify(c.state.profile), original);
  c.startDrive([0, 0, 1]);
  assert.equal(c.requests.length, 0);
});

test("calibration pulse drives exactly one motor and blocks overlapping tests", async (t) => {
  const c = setup(t);
  const pending = c.testMotor("m3", 45);
  assert.equal(await c.testMotor("m4", 45), false);
  const request = c.requests[0];
  assert.equal(request.url.searchParams.get("m1"), "0");
  assert.equal(request.url.searchParams.get("m2"), "0");
  assert.equal(request.url.searchParams.get("m3"), "45");
  assert.equal(request.url.searchParams.get("m4"), "0");
  assert.equal(request.url.searchParams.get("timeout"), "350");
  request.respond();
  assert.equal(await pending, true);
  c.startDrive([0, 0, 1]);
  assert.equal(await c.testMotor("m4", 45), false);
  assert.equal(c.requests.length, 1);
});

test("wizard applies and persists observations only after the fourth step", (t) => {
  const c = setup(t);
  const original = JSON.stringify(c.state.profile);
  c.startCalibration();
  for (const [index, position] of ["br", "fr", "bl", "fl"].entries()) {
    c.elements.get("#observedPosition").value = position;
    c.elements.get("#observedDirection").value = index === 0 ? "backward" : "forward";
    c.nextCalibrationStep();
    if (index < 3) assert.equal(JSON.stringify(c.state.profile), original);
  }
  assert.equal(c.state.calibration, null);
  assert.equal(c.state.profile.mapping.m1, "br");
  assert.equal(c.state.profile.invert.m1, true);
  assert.equal(c.state.profile.source, "observed");
  const saved = JSON.parse(c.saved.get("rover-a-controller"));
  assert.deepEqual(saved.profile, JSON.parse(JSON.stringify(c.state.profile)));
  assert.equal(c.requests.length, 0);
});

test("movement keys pressed during calibration are not retained", (t) => {
  const c = setup(t);
  c.startCalibration();
  c.bindKeyboard();
  c.listeners.keydown({ code: "KeyW", repeat: false, target: {}, preventDefault() {} });
  assert.equal(c.state.keyboard.size, 0);
  assert.equal(c.requests.length, 0);
});
