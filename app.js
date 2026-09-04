const STORAGE_KEY = "rover-a-controller";
const OUR_ROVER_HOST = "192.168.2.23";
const OUR_CAMERA_HOST = "192.168.2.24";
const MOTOR_IDS = ["m1", "m2", "m3", "m4"];
const POSITIONS = [
  ["fl", "FL"],
  ["fr", "FR"],
  ["bl", "BL"],
  ["br", "BR"],
];
const DEFAULT_PROFILE = {
  mapping: { m1: "fl", m2: "fr", m3: "bl", m4: "br" },
  invert: { m1: false, m2: false, m3: false, m4: false },
};

const state = {
  baseUrl: "",
  verifiedBaseUrl: "",
  cameraUrl: "",
  commandCount: 0,
  connected: false,
  driveTimer: null,
  activeVector: null,
  keyboard: new Set(),
  profile: cloneProfile(DEFAULT_PROFILE),
  direct: { m1: 0, m2: 0, m3: 0, m4: 0 },
  pollTimer: null,
  lastCommandAt: 0,
  wheelRequest: null,
  stopRequest: null,
  driveBusy: false,
  driveRevision: 0,
  sensorBusy: false,
};

const el = {
  connectionBadge: document.querySelector("#connectionBadge"),
  lastMessage: document.querySelector("#lastMessage"),
  chassisUrl: document.querySelector("#chassisUrl"),
  cameraUrl: document.querySelector("#cameraUrl"),
  connectButton: document.querySelector("#connectButton"),
  stopButton: document.querySelector("#stopButton"),
  holdStopButton: document.querySelector("#holdStopButton"),
  latencyValue: document.querySelector("#latencyValue"),
  cameraValue: document.querySelector("#cameraValue"),
  commandCount: document.querySelector("#commandCount"),
  speed: document.querySelector("#speed"),
  speedValue: document.querySelector("#speedValue"),
  timeout: document.querySelector("#timeout"),
  timeoutValue: document.querySelector("#timeoutValue"),
  cameraImage: document.querySelector("#cameraImage"),
  cameraFrame: document.querySelector(".camera-frame"),
  cameraMode: document.querySelector("#cameraMode"),
  streamButton: document.querySelector("#streamButton"),
  snapshotButton: document.querySelector("#snapshotButton"),
  cameraOffButton: document.querySelector("#cameraOffButton"),
  servo: document.querySelector("#servo"),
  servoValue: document.querySelector("#servoValue"),
  flash: document.querySelector("#flash"),
  flashValue: document.querySelector("#flashValue"),
  pollSensors: document.querySelector("#pollSensors"),
  refreshSensorsButton: document.querySelector("#refreshSensorsButton"),
  sensorTime: document.querySelector("#sensorTime"),
  sonarValue: document.querySelector("#sonarValue"),
  lineL: document.querySelector("#lineL"),
  lineM: document.querySelector("#lineM"),
  lineR: document.querySelector("#lineR"),
  lineLValue: document.querySelector("#lineLValue"),
  lineMValue: document.querySelector("#lineMValue"),
  lineRValue: document.querySelector("#lineRValue"),
  lineThreshold: document.querySelector("#lineThreshold"),
  lineThresholdValue: document.querySelector("#lineThresholdValue"),
  motorMapping: document.querySelector("#motorMapping"),
  resetMappingButton: document.querySelector("#resetMappingButton"),
  directMotors: document.querySelector("#directMotors"),
  sendDirectButton: document.querySelector("#sendDirectButton"),
  beepButton: document.querySelector("#beepButton"),
  freq: document.querySelector("#freq"),
  duration: document.querySelector("#duration"),
  melody: document.querySelector("#melody"),
  melodyButton: document.querySelector("#melodyButton"),
  clearLogButton: document.querySelector("#clearLogButton"),
  eventLog: document.querySelector("#eventLog"),
};

function cloneProfile(profile) {
  return JSON.parse(JSON.stringify(profile));
}

function loadSettings() {
  try {
    const saved = JSON.parse(localStorage.getItem(STORAGE_KEY) || "{}");
    el.chassisUrl.value = saved.baseUrl || `http://${OUR_ROVER_HOST}`;
    el.cameraUrl.value = saved.cameraUrl || "";
    el.speed.value = saved.speed || "55";
    el.timeout.value = saved.timeout || "450";
    el.servo.value = saved.servo || "90";
    el.flash.value = saved.flash || "0";
    el.lineThreshold.value = saved.lineThreshold || "2000";
    state.profile = saved.profile ? { ...cloneProfile(DEFAULT_PROFILE), ...saved.profile } : cloneProfile(DEFAULT_PROFILE);
    state.profile.mapping = { ...DEFAULT_PROFILE.mapping, ...(state.profile.mapping || {}) };
    state.profile.invert = { ...DEFAULT_PROFILE.invert, ...(state.profile.invert || {}) };
  } catch {
    state.profile = cloneProfile(DEFAULT_PROFILE);
  }
  syncLabels();
}

function saveSettings() {
  localStorage.setItem(
    STORAGE_KEY,
    JSON.stringify({
      baseUrl: el.chassisUrl.value,
      cameraUrl: el.cameraUrl.value,
      speed: el.speed.value,
      timeout: el.timeout.value,
      servo: el.servo.value,
      flash: el.flash.value,
      lineThreshold: el.lineThreshold.value,
      profile: state.profile,
    }),
  );
}

function syncLabels() {
  el.speedValue.textContent = el.speed.value;
  el.timeoutValue.textContent = `${el.timeout.value} мс`;
  el.servoValue.textContent = `${el.servo.value}°`;
  el.flashValue.textContent = el.flash.value;
  el.lineThresholdValue.textContent = el.lineThreshold.value;
}

function logEvent(message, type = "info") {
  const item = document.createElement("li");
  const time = document.createElement("time");
  const text = document.createElement("span");
  time.textContent = new Date().toLocaleTimeString("ru-RU", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
  text.textContent = message;
  item.dataset.type = type;
  item.append(time, text);
  el.eventLog.prepend(item);
  while (el.eventLog.children.length > 80) {
    el.eventLog.lastElementChild.remove();
  }
}

function setBadge(mode, label) {
  el.connectionBadge.className = `status-badge status-${mode}`;
  el.connectionBadge.textContent = label;
}

function setMessage(message, mode = "info") {
  el.lastMessage.textContent = message;
  if (mode === "error") {
    setBadge("error", "error");
  }
}

function normalizeBaseUrl(value) {
  const trimmed = value.trim();
  if (!trimmed) return "";
  const withProtocol = /^https?:\/\//i.test(trimmed) ? trimmed : `http://${trimmed}`;
  const url = new URL(withProtocol);
  url.pathname = url.pathname.replace(/\/+$/, "");
  url.search = "";
  url.hash = "";
  return url.toString().replace(/\/$/, "");
}

function inferCameraUrl(chassisUrl) {
  try {
    const url = new URL(chassisUrl);
    const octets = url.hostname.split(".").map((part) => Number(part));
    if (octets.length !== 4 || octets.some((part) => Number.isNaN(part))) return "";
    if (octets[3] >= 255) return "";
    octets[3] += 1;
    url.hostname = octets.join(".");
    url.port = "";
    return url.toString().replace(/\/$/, "");
  } catch {
    return "";
  }
}

function cameraStreamUrl(cameraUrl) {
  const url = new URL(cameraUrl);
  url.port = "81";
  url.pathname = "/stream";
  url.search = "";
  return url.toString();
}

function cameraPathUrl(path, params = {}) {
  const url = new URL(state.cameraUrl);
  url.pathname = path;
  url.search = "";
  for (const [key, value] of Object.entries(params)) {
    url.searchParams.set(key, value);
  }
  return url.toString();
}

async function requestRobot(path, options = {}) {
  if (!state.baseUrl) {
    throw new Error("Нет адреса шасси");
  }
  const host = new URL(state.baseUrl).hostname;
  if (host !== OUR_ROVER_HOST) {
    throw new Error(`Запрос заблокирован: разрешён только наш ровер ${OUR_ROVER_HOST}`);
  }
  if (options.safe !== true) {
    if (!state.connected || state.verifiedBaseUrl !== state.baseUrl) {
      throw new Error("Сначала проверьте наш ровер через /status");
    }
  }

  const started = performance.now();
  const url = new URL(`${state.baseUrl}${path}`);
  for (const [key, value] of Object.entries(options.query || {})) {
    url.searchParams.set(key, value);
  }
  const init =
    options.method === "GET"
      ? { method: "GET", cache: "no-store" }
      : {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: options.body === undefined ? undefined : JSON.stringify(options.body),
        };

  const controller = new AbortController();
  const deadline = setTimeout(() => controller.abort(), options.deadline || 3000);
  let data = null;
  let response;
  try {
    response = await fetch(url, { ...init, signal: controller.signal, redirect: "error" });
    const contentType = response.headers.get("content-type") || "";
    if (contentType.includes("application/json")) {
      data = await response.json();
    } else {
      const text = await response.text();
      data = text ? { text } : {};
    }
  } catch (error) {
    if (controller.signal.aborted) throw new Error("Ровер не ответил вовремя. Проверьте связь");
    throw error;
  } finally {
    clearTimeout(deadline);
  }
  el.latencyValue.textContent = `${Math.round(performance.now() - started)} мс`;

  if (!response.ok || data?.ok === false) {
    throw new Error(data?.error || `HTTP ${response.status}`);
  }

  state.commandCount += options.countCommand === false ? 0 : 1;
  el.commandCount.textContent = String(state.commandCount);
  return data;
}

function getDriveTiming() {
  return {
    timeout: Number(el.timeout.value),
    interval: Math.max(90, Math.min(240, Math.round(Number(el.timeout.value) / 2))),
  };
}

function computePositionSpeeds(vector) {
  const speed = Number(el.speed.value);
  const [xRaw, yRaw, rRaw] = vector;
  const magnitude = Math.max(1, Math.abs(xRaw) + Math.abs(yRaw) + Math.abs(rRaw));
  const x = xRaw / magnitude;
  const y = yRaw / magnitude;
  const r = rRaw / magnitude;

  return {
    fl: (y + x + r) * speed,
    fr: (y - x - r) * speed,
    bl: (y - x + r) * speed,
    br: (y + x - r) * speed,
  };
}

function positionSpeedsToMotors(positionSpeeds) {
  const motors = {};
  for (const id of MOTOR_IDS) {
    const position = state.profile.mapping[id];
    const direction = state.profile.invert[id] ? -1 : 1;
    motors[id] = Math.round((positionSpeeds[position] || 0) * direction);
  }
  return clampMotorPayload(motors);
}

function clampMotorPayload(values) {
  const payload = {};
  for (const id of MOTOR_IDS) {
    const value = Number(values[id] || 0);
    payload[id] = Math.max(-100, Math.min(100, Math.round(value)));
  }
  return payload;
}

async function sendWheels(values, timeout = Number(el.timeout.value), label = "wheels") {
  if (state.wheelRequest || state.stopRequest) throw new Error("Дождитесь завершения команды");
  state.lastCommandAt = Date.now();
  const request = requestRobot("/wheels", {
    method: "GET",
    query: { ...clampMotorPayload(values), timeout },
    deadline: 1200,
  });
  state.wheelRequest = request;
  try {
    await request;
    if (!state.stopRequest) {
      setBadge("online", "online");
      setMessage(label);
    }
  } finally {
    state.wheelRequest = null;
  }
}

async function sendVector(vector) {
  const positionSpeeds = computePositionSpeeds(vector);
  const motors = positionSpeedsToMotors(positionSpeeds);
  await sendWheels(motors, getDriveTiming().timeout, `drive ${motors.m1}/${motors.m2}/${motors.m3}/${motors.m4}`);
}

function startDrive(vector) {
  if (!state.connected || state.stopRequest) return;
  state.activeVector = vector;
  state.driveRevision += 1;
  pumpDrive();
}

async function pumpDrive() {
  clearTimeout(state.driveTimer);
  if (state.driveBusy || !state.activeVector || state.stopRequest) return;
  const delay = 55 - (Date.now() - state.lastCommandAt);
  if (delay > 0) {
    state.driveTimer = setTimeout(pumpDrive, delay);
    return;
  }
  state.driveBusy = true;
  const revision = state.driveRevision;
  try {
    await sendVector(state.activeVector);
  } catch (error) {
    await stopDrive();
    state.connected = false;
    state.verifiedBaseUrl = "";
    handleError(error);
  } finally {
    state.driveBusy = false;
    if (state.activeVector && !state.stopRequest) {
      const interval = revision === state.driveRevision ? getDriveTiming().interval : 55;
      state.driveTimer = setTimeout(pumpDrive, Math.max(0, interval - (Date.now() - state.lastCommandAt)));
    }
  }
}

function stopDrive() {
  clearTimeout(state.driveTimer);
  state.driveTimer = null;
  state.activeVector = null;
  state.keyboard.clear();
  state.driveRevision += 1;
  for (const button of document.querySelectorAll(".drive-button.is-pressed")) {
    button.classList.remove("is-pressed");
  }
  if (state.stopRequest) return state.stopRequest;
  if (!state.connected) return Promise.resolve();
  // Finish the sole in-flight wheel request before STOP; discard unsent directions.
  state.stopRequest = (async () => {
    try {
      if (state.wheelRequest) await state.wheelRequest.catch(() => {});
      const delay = 55 - (Date.now() - state.lastCommandAt);
      if (delay > 0) await new Promise((resolve) => setTimeout(resolve, delay));
      state.lastCommandAt = Date.now();
      await requestRobot("/stop", { method: "GET", deadline: 1200 });
      setBadge("online", "online");
      setMessage("stop");
      logEvent("Остановка отправлена");
    } catch (error) {
      state.connected = false;
      state.verifiedBaseUrl = "";
      handleError(error);
    } finally {
      state.stopRequest = null;
    }
  })();
  return state.stopRequest;
}

function handleError(error) {
  const message = error instanceof Error ? error.message : String(error);
  setMessage(message, "error");
  logEvent(message, "error");
}

async function connect() {
  try {
    state.baseUrl = normalizeBaseUrl(el.chassisUrl.value);
    if (!state.baseUrl) {
      throw new Error("Введите адрес шасси");
    }
    el.chassisUrl.value = state.baseUrl;
    state.cameraUrl = el.cameraUrl.value ? normalizeBaseUrl(el.cameraUrl.value) : inferCameraUrl(state.baseUrl);

    const host = new URL(state.baseUrl).hostname;
    if (host !== OUR_ROVER_HOST) {
      throw new Error(`Это не адрес нашего ровера: нужен ${OUR_ROVER_HOST}`);
    }

    const status = await requestRobot("/status", { method: "GET", countCommand: false, safe: true });
    if (status?.camera) {
      state.cameraUrl = normalizeBaseUrl(status.camera);
    }
    if (state.cameraUrl) {
      el.cameraUrl.value = state.cameraUrl;
      el.cameraValue.textContent = new URL(state.cameraUrl).host;
    }
    state.connected = true;
    state.verifiedBaseUrl = state.baseUrl;
    setBadge("online", "online");
    setMessage("Связь с шасси есть");
    logEvent("Подключение проверено");
    saveSettings();
  } catch (error) {
    state.connected = false;
    state.verifiedBaseUrl = "";
    handleError(error);
  }
}

function startStream() {
  try {
    state.cameraUrl = normalizeBaseUrl(el.cameraUrl.value || state.cameraUrl);
    if (!state.cameraUrl) throw new Error("Нет адреса камеры");
    if (new URL(state.cameraUrl).hostname !== OUR_CAMERA_HOST) {
      throw new Error(`Камера заблокирована: разрешён только ${OUR_CAMERA_HOST}`);
    }
    el.cameraUrl.value = state.cameraUrl;
    const stream = cameraStreamUrl(state.cameraUrl);
    el.cameraImage.src = stream;
    el.cameraFrame.classList.add("has-image");
    el.cameraMode.textContent = "MJPEG stream";
    el.streamButton.classList.add("active");
    el.snapshotButton.classList.remove("active");
    saveSettings();
  } catch (error) {
    handleError(error);
  }
}

function takeSnapshot() {
  try {
    state.cameraUrl = normalizeBaseUrl(el.cameraUrl.value || state.cameraUrl);
    if (!state.cameraUrl) throw new Error("Нет адреса камеры");
    if (new URL(state.cameraUrl).hostname !== OUR_CAMERA_HOST) {
      throw new Error(`Камера заблокирована: разрешён только ${OUR_CAMERA_HOST}`);
    }
    el.cameraUrl.value = state.cameraUrl;
    el.cameraImage.src = cameraPathUrl("/snapshot", { t: Date.now() });
    el.cameraFrame.classList.add("has-image");
    el.cameraMode.textContent = "snapshot";
    el.snapshotButton.classList.add("active");
    el.streamButton.classList.remove("active");
    saveSettings();
  } catch (error) {
    handleError(error);
  }
}

function stopCamera() {
  el.cameraImage.removeAttribute("src");
  el.cameraFrame.classList.remove("has-image");
  el.cameraMode.textContent = "видео выключено";
  el.streamButton.classList.remove("active");
  el.snapshotButton.classList.remove("active");
}

async function updateServo() {
  syncLabels();
  saveSettings();
  try {
    const data = await requestRobot("/servo", { body: { cam: Number(el.servo.value) } });
    if (typeof data?.cam === "number") {
      el.servo.value = data.cam;
      syncLabels();
    }
  } catch (error) {
    handleError(error);
  }
}

async function updateFlash() {
  syncLabels();
  saveSettings();
  try {
    state.cameraUrl = normalizeBaseUrl(el.cameraUrl.value || state.cameraUrl);
    if (!state.cameraUrl) throw new Error("Нет адреса камеры");
    if (new URL(state.cameraUrl).hostname !== OUR_CAMERA_HOST) {
      throw new Error(`Камера заблокирована: разрешён только ${OUR_CAMERA_HOST}`);
    }
    await fetch(cameraPathUrl("/flash", { v: el.flash.value }), { cache: "no-store" });
    logEvent(`Свет: ${el.flash.value}`);
  } catch (error) {
    handleError(error);
  }
}

async function refreshSensors() {
  if (state.sensorBusy || state.activeVector || state.wheelRequest || state.stopRequest) return;
  state.sensorBusy = true;
  try {
    const data = await requestRobot("/sensors", { method: "GET", countCommand: false, safe: true });
    renderSensors(data);
    setBadge("online", "online");
  } catch (error) {
    handleError(error);
  } finally {
    state.sensorBusy = false;
  }
}

function renderSensors(data) {
  const sonar = data?.sonar || data;
  if (sonar?.valid === false) {
    el.sonarValue.textContent = "--";
  } else if (typeof sonar?.cm === "number") {
    el.sonarValue.textContent = `${sonar.cm.toFixed(1)} см`;
  }

  const line = data?.line || data;
  for (const [key, meter, text] of [
    ["l", el.lineL, el.lineLValue],
    ["m", el.lineM, el.lineMValue],
    ["r", el.lineR, el.lineRValue],
  ]) {
    if (typeof line?.[key] === "number") {
      meter.value = line[key];
      text.textContent = String(line[key]);
    }
  }

  el.sensorTime.textContent = new Date().toLocaleTimeString("ru-RU", {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  });
}

function setSensorPolling(enabled) {
  clearInterval(state.pollTimer);
  state.pollTimer = null;
  if (enabled) {
    refreshSensors();
    state.pollTimer = setInterval(refreshSensors, 1000);
  }
}

function renderMotorMapping() {
  el.motorMapping.replaceChildren();
  for (const id of MOTOR_IDS) {
    const row = document.createElement("article");
    row.className = "motor-row";
    row.innerHTML = `
      <header>
        <span class="motor-name">${id.toUpperCase()}</span>
        <select aria-label="Позиция ${id.toUpperCase()}">
          ${POSITIONS.map(([value, label]) => `<option value="${value}">${label}</option>`).join("")}
        </select>
      </header>
      <div class="motor-tests">
        <button type="button" data-test="${id}" data-power="45">+</button>
        <button type="button" data-test="${id}" data-power="-45">-</button>
      </div>
      <label class="invert-label">
        <input type="checkbox" />
        <span>инвертировать</span>
      </label>
    `;
    const select = row.querySelector("select");
    const invert = row.querySelector("input");
    select.value = state.profile.mapping[id];
    invert.checked = state.profile.invert[id];
    select.addEventListener("change", () => {
      state.profile.mapping[id] = select.value;
      saveSettings();
    });
    invert.addEventListener("change", () => {
      state.profile.invert[id] = invert.checked;
      saveSettings();
    });
    for (const button of row.querySelectorAll("[data-test]")) {
      button.addEventListener("click", () => testMotor(id, Number(button.dataset.power)));
    }
    el.motorMapping.append(row);
  }
}

function renderDirectMotors() {
  el.directMotors.replaceChildren();
  for (const id of MOTOR_IDS) {
    const row = document.createElement("div");
    row.className = "direct-row";
    row.innerHTML = `
      <label>
        <span>${id.toUpperCase()}</span>
        <strong>0</strong>
      </label>
      <input type="range" min="-100" max="100" step="1" value="0" aria-label="${id.toUpperCase()}" />
    `;
    const input = row.querySelector("input");
    const value = row.querySelector("strong");
    input.addEventListener("input", () => {
      state.direct[id] = Number(input.value);
      value.textContent = input.value;
    });
    el.directMotors.append(row);
  }
}

async function testMotor(id, power) {
  if (state.activeVector || Date.now() - state.lastCommandAt < 55) return;
  const payload = { m1: 0, m2: 0, m3: 0, m4: 0, [id]: power };
  try {
    await sendWheels(payload, 350, `${id.toUpperCase()} ${power}`);
    logEvent(`Тест ${id.toUpperCase()}: ${power}`);
  } catch (error) {
    handleError(error);
  }
}

async function sendDirect() {
  if (state.activeVector || Date.now() - state.lastCommandAt < 55) return;
  try {
    await sendWheels(state.direct, getDriveTiming().timeout, "direct");
    logEvent(`Direct: ${MOTOR_IDS.map((id) => state.direct[id]).join("/")}`);
  } catch (error) {
    handleError(error);
  }
}

async function beep() {
  try {
    const freq = Number(el.freq.value);
    const duration = Number(el.duration.value);
    await requestRobot("/buzzer", { body: { freq, duration } });
    logEvent(`Beep ${freq} Гц`);
  } catch (error) {
    handleError(error);
  }
}

async function playMelody() {
  try {
    const melody = el.melody.value.trim();
    if (!melody) throw new Error("Введите мелодию");
    await requestRobot("/buzzer", { body: { melody } });
    logEvent("Мелодия отправлена");
  } catch (error) {
    handleError(error);
  }
}

function bindDriveButtons() {
  for (const button of document.querySelectorAll(".drive-button")) {
    if (button.dataset.stop) {
      button.addEventListener("click", stopDrive);
      continue;
    }
    const vector = button.dataset.vector.split(",").map(Number);
    button.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      button.setPointerCapture(event.pointerId);
      button.classList.add("is-pressed");
      startDrive(vector);
    });
    button.addEventListener("pointerup", () => stopDrive());
    button.addEventListener("pointercancel", () => stopDrive());
    button.addEventListener("lostpointercapture", () => {
      if (button.classList.contains("is-pressed")) stopDrive();
    });
  }
}

function vectorFromKeyboard() {
  let x = 0;
  let y = 0;
  let r = 0;
  if (state.keyboard.has("KeyW") || state.keyboard.has("ArrowUp")) y += 1;
  if (state.keyboard.has("KeyS") || state.keyboard.has("ArrowDown")) y -= 1;
  if (state.keyboard.has("KeyD") || state.keyboard.has("ArrowRight")) x += 1;
  if (state.keyboard.has("KeyA") || state.keyboard.has("ArrowLeft")) x -= 1;
  if (state.keyboard.has("KeyE")) r += 1;
  if (state.keyboard.has("KeyQ")) r -= 1;
  return [x, y, r];
}

function shouldIgnoreKeyboard(event) {
  const tagName = event.target?.tagName;
  return tagName === "INPUT" || tagName === "TEXTAREA" || tagName === "SELECT";
}

function updateKeyboardDrive() {
  const vector = vectorFromKeyboard();
  if (vector.every((value) => value === 0)) {
    if (state.activeVector) stopDrive();
    return;
  }
  startDrive(vector);
}

function bindKeyboard() {
  window.addEventListener("keydown", (event) => {
    if (shouldIgnoreKeyboard(event)) return;
    if (event.code === "Space" || event.code === "Escape") {
      event.preventDefault();
      stopDrive();
      return;
    }
    if (["KeyW", "KeyA", "KeyS", "KeyD", "KeyQ", "KeyE", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(event.code)) {
      event.preventDefault();
      if (event.repeat) return;
      state.keyboard.add(event.code);
      updateKeyboardDrive();
    }
  });

  window.addEventListener("keyup", (event) => {
    if (state.keyboard.delete(event.code)) {
      event.preventDefault();
      updateKeyboardDrive();
    }
  });

  window.addEventListener("blur", stopDrive);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stopDrive();
  });
}

function bindControls() {
  el.connectButton.addEventListener("click", connect);
  el.stopButton.addEventListener("click", stopDrive);
  el.holdStopButton.addEventListener("click", stopDrive);
  el.streamButton.addEventListener("click", startStream);
  el.snapshotButton.addEventListener("click", takeSnapshot);
  el.cameraOffButton.addEventListener("click", stopCamera);
  el.refreshSensorsButton.addEventListener("click", refreshSensors);
  el.pollSensors.addEventListener("change", () => setSensorPolling(el.pollSensors.checked));
  el.resetMappingButton.addEventListener("click", () => {
    state.profile = cloneProfile(DEFAULT_PROFILE);
    renderMotorMapping();
    saveSettings();
    logEvent("Карта моторов сброшена");
  });
  el.sendDirectButton.addEventListener("click", sendDirect);
  el.beepButton.addEventListener("click", beep);
  el.melodyButton.addEventListener("click", playMelody);
  el.clearLogButton.addEventListener("click", () => el.eventLog.replaceChildren());

  for (const input of [el.chassisUrl, el.cameraUrl, el.speed, el.timeout, el.lineThreshold]) {
    input.addEventListener("input", () => {
      if (input === el.chassisUrl) {
        state.connected = false;
        state.verifiedBaseUrl = "";
        setBadge("offline", "offline");
        setMessage("Адрес изменён, снова нажмите Проверить");
      }
      syncLabels();
      saveSettings();
    });
  }

  el.servo.addEventListener("input", syncLabels);
  el.servo.addEventListener("change", updateServo);
  el.flash.addEventListener("input", syncLabels);
  el.flash.addEventListener("change", updateFlash);
}

function boot() {
  loadSettings();
  renderMotorMapping();
  renderDirectMotors();
  bindDriveButtons();
  bindKeyboard();
  bindControls();
  setBadge("offline", "offline");
  logEvent("Пульт готов");
}

boot();
