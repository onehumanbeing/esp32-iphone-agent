// Control page: live phone, bilingual live log, and a wall of step screenshots.
const $ = (id) => document.getElementById(id);

// ---- language ------------------------------------------------------------------------

let lang = "en";
try { lang = localStorage.getItem("lang") || "en"; } catch { /* private mode */ }
const t = (key) => I18N[lang][key] ?? I18N.en[key] ?? key;

function applyLang() {
  document.documentElement.lang = lang === "zh" ? "zh-CN" : "en";
  document.querySelectorAll("[data-i18n]").forEach((el) => { el.textContent = t(el.dataset.i18n); });
  document.querySelectorAll("[data-i18n-ph]").forEach((el) => { el.placeholder = t(el.dataset.i18nPh); });
  document.querySelectorAll("#lang button").forEach((b) => b.classList.toggle("on", b.dataset.lang === lang));
  $("examples").replaceChildren(...t("examples").map((text) => {
    const b = document.createElement("button");
    b.textContent = text;
    b.addEventListener("click", () => { $("task").value = text; start(text); });  // one click runs the demo
    return b;
  }));
  shown = "";  // re-render steps in the new language
  if (typeof applyMotion === "function") applyMotion();
}
document.querySelectorAll("#lang button").forEach((b) => b.addEventListener("click", () => {
  lang = b.dataset.lang;
  try { localStorage.setItem("lang", lang); } catch { /* private mode */ }
  applyLang();
}));

// ---- motion (tap ripples, flowing swipe paths); remembered per browser -------------------

let motion = !matchMedia("(prefers-reduced-motion: reduce)").matches;
try { motion = (localStorage.getItem("motion") || (motion ? "on" : "off")) === "on"; } catch { /* private mode */ }
function applyMotion() {
  document.body.classList.toggle("still", !motion);
  $("motion").textContent = t(motion ? "motionOn" : "motionOff");
}
$("motion").addEventListener("click", () => {
  motion = !motion;
  try { localStorage.setItem("motion", motion ? "on" : "off"); } catch { /* private mode */ }
  applyMotion();
});

const say = (key) => { $("msg").textContent = key ? t(key) : ""; };
async function post(path, body) {
  const r = await fetch(path, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body || {}) });
  const data = await r.json().catch(() => ({}));
  $("msg").textContent = r.ok ? "" : data.detail || r.statusText;
  return r.ok ? data : null;
}

// ---- step helpers --------------------------------------------------------------------

const fmt = (sec) => (sec == null ? "–" : sec < 10 ? `${sec.toFixed(1)}s` : `${Math.round(sec)}s`);
const isPlan = (s) => s.action.includes("plan");
const isBad = (s) => ["hiccup", "error", "fail"].includes(s.action);
const what = (s) => describeStep(s)[lang === "zh" ? 1 : 0];
// the model answers in English; a Chinese version is shown when it gives one
const why = (s) => (lang === "zh" && s.thought_zh) || s.thought || s.answer || s.reason || "";
const planText = (s) => (lang === "zh" && s.plan_zh) || s.plan || "";
const times = (s) => [s.think_s != null && `${t("thinking")} ${fmt(s.think_s)}`, s.act_s != null && `${t("doing")} ${fmt(s.act_s)}`].filter(Boolean).join(" · ");
const where = (s) => ({
  tap: () => ` (${s.x}, ${s.y})${s.precise ? " · precise" : ""}`, swipe: () => ` (${s.x1}, ${s.y1}) → (${s.x2}, ${s.y2})`,
  path: () => ` · ${s.points.length} pts`, circle: () => ` (${s.x}, ${s.y}) r=${s.r}`,
}[s.action] || (() => ""))();

// Draw what the AI did on its screenshot (coordinates are 0-1000): yellow on black, plus a hand for taps.
// .ripple and .flow shapes are animated in CSS; body.still turns the motion off.
let aspect = 0.461;  // frame width / height, from the server
function overlay(s) {
  const svg = (inner) => `<svg viewBox="0 0 1000 1000" preserveAspectRatio="none">${inner}</svg>`;
  const stroke = (shape) =>  // black casing under a yellow line, so it shows on any background
    `${shape.replace("/>", ` style="stroke:#000;fill:none" stroke-width="9" vector-effect="non-scaling-stroke" stroke-linecap="round" stroke-linejoin="round"/>`)}
     ${shape.replace("/>", ` style="stroke:var(--hl);fill:none" stroke-width="5" vector-effect="non-scaling-stroke" stroke-linecap="round" stroke-linejoin="round"/>`)}`;
  const dot = (x, y, r) => `<ellipse cx="${x}" cy="${y}" rx="${r}" ry="${r * aspect}" style="fill:var(--hl);stroke:#000" stroke-width="2" vector-effect="non-scaling-stroke"/>`;
  const pts = (list) => list.map(([x, y]) => `${x},${y}`).join(" ");
  const flow = (list) =>  // dashes that travel along the stroke, in its direction
    `<polyline class="flow" points="${pts(list)}" style="stroke:#000;fill:none" stroke-width="2.5" vector-effect="non-scaling-stroke" stroke-linecap="round"/>`;
  switch (s.action) {
    case "tap": {  // red, so the tap point stands out from the yellow swipe paths
      const ring = (cls, r, w, color) => `<ellipse class="${cls}" cx="${s.x}" cy="${s.y}" rx="${r}" ry="${r * aspect}" style="stroke:${color};fill:none" stroke-width="${w}" vector-effect="non-scaling-stroke"/>`;
      return svg(ring("ripple", 100, 7, "var(--tap)") + ring("", 100, 11, "#000") + ring("", 100, 6, "var(--tap)") +
        `<ellipse cx="${s.x}" cy="${s.y}" rx="22" ry="${22 * aspect}" style="fill:var(--tap);stroke:#fff" stroke-width="3" vector-effect="non-scaling-stroke"/>`);
    }
    case "swipe": {
      const a = Math.atan2((s.y2 - s.y1) / aspect, s.x2 - s.x1), l = 45;
      const head = (d) => [s.x2 - l * Math.cos(a + d), s.y2 - l * aspect * Math.sin(a + d)];
      return svg(stroke(`<polyline points="${pts([[s.x1, s.y1], [s.x2, s.y2]])}"/>`) + flow([[s.x1, s.y1], [s.x2, s.y2]]) +
        stroke(`<polyline points="${pts([head(0.5), [s.x2, s.y2], head(-0.5)])}"/>`) + dot(s.x1, s.y1, 14));
    }
    case "path":
      return svg(stroke(`<polyline points="${pts(s.points)}"/>`) + flow(s.points) + dot(...s.points[0], 12));
    case "circle":
      return svg(stroke(`<ellipse cx="${s.x}" cy="${s.y}" rx="${s.r}" ry="${s.r * aspect}"/>`));
    default:
      return "";
  }
}
// the 👆 sits on top of the svg as text, so it is not stretched
function hand(s) {
  if (s.action !== "tap") return "";
  return `<span class="hand" style="left:${s.x / 10}%;top:${s.y / 10}%">👆</span>`;
}

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text) e.textContent = text;
  return e;
}

// Log line in the chosen language, newest at the bottom.
function logLine(s) {
  const li = el("li", isBad(s) ? "bad" : "");
  const head = el("div");
  head.append(el("span", "time", new Date(s.t * 1000).toLocaleTimeString()), el("span", "what", what(s) + where(s)));
  li.append(head);
  const text = planText(s) || why(s);
  if (text) li.append(el("div", "why", text));
  if (times(s)) li.append(el("div", "meta", times(s)));
  return li;
}

// Wall card: screenshot with the action drawn on it.
function card(s, index, number, scale, runId) {
  const c = el("div", "card" + (isBad(s) ? " bad" : ""));
  if (s.shot) {
    const shot = el("div", "shot");
    const img = el("img");
    img.loading = "lazy";
    img.src = `/api/steps/${index}.jpg?run=${runId}`;
    const ov = el("div", "overlay");
    ov.innerHTML = overlay(s) + hand(s);
    shot.append(img, ov);
    shot.addEventListener("click", () => zoom(img.src, s));
    c.append(shot);
  }
  const body = el("div", "body");
  body.append(el("div", "no", isPlan(s) ? t("planner") : lang === "zh" ? `第 ${number} 步` : `${t("step")} ${number}`),
    el("div", "what", what(s)), el("div", "why", isPlan(s) ? "" : why(s)));
  if (s.think_s != null) {
    const bar = el("div", "bar");
    const a = el("div", "think"), b = el("div", "act");
    a.style.width = `${(s.think_s / scale) * 100}%`;
    b.style.width = `${((s.act_s || 0) / scale) * 100}%`;
    bar.append(a, b);
    body.append(bar, el("div", "times", times(s)));
  }
  c.append(body);
  return c;
}

function zoom(src, s) {
  $("zoom-img").src = src;
  $("zoom-overlay").innerHTML = overlay(s) + hand(s);
  $("zoom-text").textContent = `${what(s)} — ${why(s)}`;
  $("zoom").showModal();
}
$("zoom").addEventListener("click", () => $("zoom").close());

// ---- live phone: click = tap, drag = swipe, wheel = scroll --------------------------

const live = $("live");
let down = null, calibrating = false, calibrationBusy = false;
let typingReady = false;
const keyboard = $("phone-keyboard");
const manualInput = createKeyboardQueue(
  (path, body) => typingReady && !calibrating && !calibrationBusy ? post(path, body) : Promise.resolve(null),
  () => say("keyboardFailed"),
);
connectPhoneKeyboard({
  element: keyboard,
  available: () => typingReady && !calibrating && !calibrationBusy && !$("zoom").open && live.hasAttribute("src"),
  text: text => manualInput.push("/api/type", { text }),
  key: text => manualInput.push("/api/key", { text }),
  blocked: () => say("keyboardBlocked"),
  release: () => stop(),
});
keyboard.addEventListener("blur", () => manualInput.clear());
window.addEventListener("blur", () => { manualInput.clear(); keyboard.blur(); });
function frac(e) {
  const r = live.getBoundingClientRect(), ratio = live.naturalWidth / live.naturalHeight || r.width / r.height;
  const w = Math.min(r.width, r.height * ratio), h = w / ratio;  // object-fit: contain box
  const x = (e.clientX - r.left - (r.width - w) / 2) / w, y = (e.clientY - r.top - (r.height - h) / 2) / h;
  return { x: Math.min(Math.max(x, 0), 1), y: Math.min(Math.max(y, 0), 1) };
}
live.addEventListener("pointerdown", (e) => { keyboard.focus({ preventScroll: true }); down = frac(e); });
live.addEventListener("pointerup", async (e) => {
  if (!down) return;
  const up = frac(e), from = down;
  down = null;
  if (calibrating) {
    calibrating = false;
    const ok = await post("/api/calibrate/finish", up);
    calibrationHint(ok ? "calOk" : null);
  } else if (Math.hypot(up.x - from.x, up.y - from.y) < 0.02) {
    manualInput.push("/api/tap", up);
  } else {
    manualInput.push("/api/swipe", { x1: from.x, y1: from.y, x2: up.x, y2: up.y });
  }
});
let wheelAt = 0;
live.addEventListener("wheel", (e) => {
  e.preventDefault();
  if (Date.now() - wheelAt < 250) return;
  wheelAt = Date.now();
  manualInput.push("/api/scroll", { ...frac(e), lines: e.deltaY > 0 ? -3 : 3 });
}, { passive: false });

// Show a frame, or nothing when the phone is gone, so a stale screenshot never lingers.
function showFrame(url) {
  const old = live.src;
  if (url) live.src = url; else live.removeAttribute("src");
  if (!url) { typingReady = false; manualInput.clear(); keyboard.blur(); }
  if (old.startsWith("blob:")) URL.revokeObjectURL(old);
  $("hint").hidden = Boolean(url);
}

// Keep fetching the latest frame (works in every browser, unlike MJPEG).
async function refreshLive() {
  try {
    const r = await fetch(`/api/frame.jpg?${Date.now()}`);
    showFrame(r.ok ? URL.createObjectURL(await r.blob()) : "");
  } catch { showFrame(""); }  // server restarting
  setTimeout(refreshLive, 150);
}

// ---- controls ------------------------------------------------------------------------

document.querySelectorAll("[data-post]").forEach((b) => b.addEventListener("click", () => manualInput.push(b.dataset.post)));
// Calibration instructions show right under the phone, where the user is looking.
function calibrationHint(key) {
  $("caption").textContent = t(key || "liveCaption");
  $("caption").classList.toggle("callout", Boolean(key));
  live.parentElement.classList.toggle("calibrating", key === "calNow");
  if (key === "calOk") setTimeout(() => calibrationHint(null), 4000);
}
$("cal").addEventListener("click", async () => {
  manualInput.clear();
  keyboard.blur();
  calibrationHint("calFinding");
  calibrationBusy = true;
  let r;
  try { r = await post("/api/calibrate/start"); } finally { calibrationBusy = false; }
  if (!r) return calibrationHint(null);
  if (r.auto) return calibrationHint("calOk");  // found the pointer by itself
  calibrating = true;
  calibrationHint("calNow");
});
$("type").addEventListener("click", async () => { if (await manualInput.push("/api/type", { text: $("text").value })) $("text").value = ""; });
$("press").addEventListener("click", () => manualInput.push("/api/key", { text: $("key").value }));
function start(task) {
  if (!task) return say("needTask");
  typingReady = false;
  manualInput.clear();
  keyboard.blur();
  post("/api/agent", { text: task });
}
$("run").addEventListener("click", () => start($("task").value.trim()));
function stop() {
  manualInput.clear();
  keyboard.blur();
  down = null;
  return post("/api/agent/stop");
}
$("stop").addEventListener("click", stop);
$("clear").addEventListener("click", async () => {
  if (await post("/api/agent/clear")) { $("task").value = ""; say(null); }
});
$("estop").addEventListener("click", stop);
document.addEventListener("keydown", (e) => { if (e.key === "Escape" && !$("zoom").open) stop(); });

// ---- polling -------------------------------------------------------------------------

let shown = "";
async function poll() {
  try {
    const s = await (await fetch("/api/status")).json();
    const nextTypingReady = s.device && s.screen && !s.agent.running;
    if (!nextTypingReady) { manualInput.clear(); keyboard.blur(); }
    typingReady = nextTypingReady;
    let ready = true;
    $("setup").querySelectorAll("li").forEach((li) => { const ok = s[li.dataset.key]; li.classList.toggle("done", ok); ready &&= ok; });
    $("setup").classList.toggle("all-done", ready);

    const a = s.agent, steps = a.steps;
    $("run").disabled = a.running || !ready;
    $("examples").querySelectorAll("button").forEach((b) => { b.disabled = a.running || !ready; });
    $("stop").hidden = !a.running;
    $("clear").hidden = a.running || !steps.length;
    $("live-dot").classList.toggle("on", a.running);

    aspect = s.aspect || aspect;
    const avg = (xs) => (xs.length ? fmt(xs.reduce((n, x) => n + x, 0) / xs.length) : "–");
    const planned = steps.filter((x) => isPlan(x) && x.think_s != null).map((x) => x.think_s);
    const acted = steps.filter((x) => !isPlan(x) && x.think_s != null).map((x) => x.think_s);
    $("m-planner").textContent = s.models.planner;
    $("m-actor").textContent = s.models.actor;
    $("m-planner-s").textContent = `${planned.length}× · ${t("avg")} ${avg(planned)}`;
    $("m-actor-s").textContent = `${acted.length}× · ${t("avg")} ${avg(acted)}`;

    $("summary").hidden = !steps.length;
    const actions = steps.filter((x) => x.act_s != null);
    const end = a.running ? Date.now() / 1000 : steps.at(-1)?.t;
    const state = { done: "done", fail: "gaveUp", stopped: "stopped", error: "errorState" }[steps.at(-1)?.action];
    $("st-state").textContent = t(a.running ? "working" : state || "idle");
    $("st-steps").textContent = actions.length;
    $("st-time").textContent = steps.length ? fmt(end - steps[0].t) : "0s";
    $("st-step").textContent = actions.length ? fmt(actions.reduce((n, x) => n + (x.think_s || 0) + x.act_s, 0) / actions.length) : "–";

    const key = lang + JSON.stringify(steps);
    if (key !== shown) {
      shown = key;
      const plan = [...steps].reverse().find((x) => x.plan);
      $("plan").hidden = !plan;
      if (plan) $("plan-list").replaceChildren(...planText(plan).split("\n").map((l) => l.replace(/^\s*\d+[.)]\s*/, "").trim())
        .filter(Boolean).map((l) => el("li", "", l)));

      const logBox = $("log").parentElement, stick = logBox.scrollTop + logBox.clientHeight >= logBox.scrollHeight - 30;
      $("log").replaceChildren(...steps.map(logLine));
      if (stick) logBox.scrollTop = logBox.scrollHeight;  // follow the newest line

      const scale = Math.max(1, ...steps.map((x) => (x.think_s || 0) + (x.act_s || 0)));
      const runId = steps.length ? steps[0].t : "";
      let n = 0;
      const cards = steps.map((x, i) => card(x, i, isPlan(x) ? n : ++n, scale, runId));
      if (a.running && cards.length) cards.at(-1).classList.add("current");
      $("wall").replaceChildren(...cards.reverse());  // newest first
    }
  } catch { /* server restarting */ }
  setTimeout(poll, 500);
}

applyLang();
applyMotion();
refreshLive();
poll();
