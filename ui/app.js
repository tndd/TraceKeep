const $ = (id) => document.getElementById(id);
const invoke = window.__TAURI__?.core?.invoke;
let data = null;
const names = {
  cpu: "CPUセンサー",
  board: "基板センサー",
  activity: "GPU・負荷・イベント",
};
const labels = {
  recording: "記録中",
  stale: "更新が止まっています",
  missing: "ログなし",
  error: "読み取りエラー",
  clock: "時刻を確認",
};
function el(tag, text, cls) {
  const e = document.createElement(tag);
  if (text !== undefined) e.textContent = text;
  if (cls) e.className = cls;
  return e;
}
function clock(t) {
  return new Date(t).toLocaleTimeString("ja-JP", {
    timeZone: "Asia/Tokyo",
    hour12: false,
  });
}
function fmt(v, d = 1) {
  return typeof v === "number" && Number.isFinite(v) ? v.toFixed(d) : "—";
}
function chart(id, series, min, max) {
  const svg = $(id),
    w = 640,
    h = 220,
    left = 48,
    right = 12,
    top = 15,
    bottom = 28;
  svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
  const end = Date.now(),
    start = end - Number($("range").value) * 1000;
  let out = "";
  for (let i = 0; i < 5; i++) {
    let val = min + ((max - min) * i) / 4,
      y = h - bottom - ((h - top - bottom) * i) / 4;
    out += `<line x1="${left}" y1="${y}" x2="${w - right}" y2="${y}" stroke="#29374a"/><text x="${left - 7}" y="${y + 4}" fill="#98aabe" font-size="11" text-anchor="end">${val.toFixed(max > 10 && min === 0 ? 0 : 2)}</text>`;
  }
  for (let i = 0; i < 3; i++) {
    let t = start + ((end - start) * i) / 2,
      x = left + ((w - left - right) * i) / 2;
    out += `<text x="${x}" y="${h - 5}" fill="#98aabe" font-size="11" text-anchor="${i === 0 ? "start" : i === 2 ? "end" : "middle"}">${clock(t)}</text>`;
  }
  let count = 0;
  for (const s of series) {
    let path = "",
      prev = null;
    for (const r of s.rows) {
      const t = Date.parse(r.time),
        v = r[s.key];
      if (
        t < start ||
        t > end ||
        typeof v !== "number" ||
        !Number.isFinite(v)
      ) {
        prev = null;
        continue;
      }
      const x = left + ((t - start) / (end - start)) * (w - left - right),
        y = top + ((max - v) / (max - min)) * (h - top - bottom);
      const fresh = prev && t - prev.t <= 6000 && prev.session === r.session;
      path += `${fresh ? "L" : "M"}${x.toFixed(1)},${Math.max(top, Math.min(h - bottom, y)).toFixed(1)} `;
      prev = { t, session: r.session };
      count++;
    }
    out += `<path d="${path}" fill="none" stroke="${s.color}" stroke-width="2"/>`;
  }
  if (!count)
    out += `<text x="320" y="110" text-anchor="middle" fill="#98aabe" font-size="14">表示期間内のデータがありません</text>`;
  svg.innerHTML = out;
}
function render() {
  if (!data) return;
  const s = data.streams;
  const bad = Object.keys(names).filter((k) => s[k].state !== "recording");
  $("banner").classList.toggle("bad", bad.length > 0);
  $("overall").textContent = bad.length
    ? bad.map((k) => names[k]).join("・") + "の記録を確認してください"
    : "3系統のログが更新されています";
  if (data.preview) $("overall").textContent = "開発プレビュー / 模擬データ";
  $("updated").textContent = "取得 " + clock(data.time) + " JST";
  $("streams").replaceChildren();
  for (const k of Object.keys(names)) {
    const box = el("div", undefined, "stream");
    box.append(
      el("strong", names[k]),
      el(
        "span",
        `${labels[s[k].state]} · ${s[k].age === null ? "—" : s[k].age.toFixed(1) + "秒前"}`,
        "tag" + (s[k].state === "recording" ? "" : " bad"),
      ),
    );
    $("streams").append(box);
  }
  const latest = (k) => s[k].history.at(-1) || {};
  for (const [id, key, dec] of [
    ["cpuTemp", "cpu", 1],
    ["gpuTemp", "activity", 1],
    ["gpuPower", "activity", 1],
    ["v12", "board", 3],
    ["v5", "board", 3],
    ["v33", "board", 3],
  ]) {
    $(id).textContent = fmt(latest(key)[id], dec);
    $(id).style.color = s[key].state === "recording" ? "" : "#f6c472";
  }
  chart(
    "tempChart",
    [
      { rows: s.cpu.history, key: "cpuTemp", color: "#67dbc0" },
      { rows: s.activity.history, key: "gpuTemp", color: "#7ca9ff" },
    ],
    0,
    110,
  );
  const rail = $("rail").value,
    nom = { v12: 12, v5: 5, v33: 3.3 }[rail];
  const vals = s.board.history
    .filter(
      (r) => Date.parse(r.time) > Date.now() - Number($("range").value) * 1000,
    )
    .map((r) => r[rail])
    .filter((v) => typeof v === "number" && Number.isFinite(v));
  chart(
    "voltChart",
    [{ rows: s.board.history, key: rail, color: "#f6c472" }],
    Math.min(nom * 0.95, ...vals),
    Math.max(nom * 1.05, ...vals),
  );
  const gpu = latest("activity").gpu || {};
  $("reasons").replaceChildren();
  for (const [label, flag, counter] of [
    ["外部電力制限", "hwPowerBrakeSlowdown", "hwPowerBrakeMicroseconds"],
    ["ハードウェア熱制限", "hwThermalSlowdown", "hwThermalMicroseconds"],
    ["ソフトウェア熱制限", "swThermalSlowdown", "swThermalMicroseconds"],
    ["設定電力枠による制限", "swPowerCap", "swPowerCapMicroseconds"],
  ]) {
    let row = el("div", undefined, "reason"),
      v = gpu[flag],
      n = gpu[counter];
    row.append(
      el("span", label),
      el(
        "span",
        `${v === "Active" ? "作動中" : v === "Not Active" ? "非作動" : "取得不可"} / ${n != null ? (Number(n) / 1e6).toFixed(6) + " 秒" : "—"}`,
        "counter",
      ),
    );
    $("reasons").append(row);
  }
  $("issues").replaceChildren();
  let issues = [];
  for (const k of Object.keys(names)) {
    if (s[k].state !== "recording")
      issues.push(names[k] + ": " + labels[s[k].state]);
    if (s[k].error) issues.push(s[k].error);
    for (const err of s[k].latest?.errors || [])
      issues.push(names[k] + ": " + err);
    for (const g of s[k].gaps)
      issues.push(
        clock(g.time) +
          " " +
          names[k] +
          " / " +
          g.seconds +
          "秒の間隔" +
          (g.sessionChanged ? "（記録処理の切り替わり）" : ""),
      );
    if (s[k].invalidLines)
      issues.push(
        names[k] + ": 読み取れなかった行 " + s[k].invalidLines + "件",
      );
  }
  for (const text of issues.slice(-15))
    $("issues").append(el("p", text, "muted"));
  if (!issues.length)
    $("issues").append(
      el("div", "取得済み区間に該当する問題はありません", "empty"),
    );
  const filter = $("filter").value.toLowerCase();
  $("sensors").replaceChildren();
  $("sensorCount").textContent =
    (s.board.latest?.sensors?.length || 0) + " CHANNELS / RAW DATA";
  for (const r of s.board.latest?.sensors || []) {
    if (!(r.name + " " + r.id).toLowerCase().includes(filter)) continue;
    const tr = el("tr");
    for (const text of [
      r.name,
      r.type,
      r.value === null
        ? "取得不可"
        : fmt(r.value, r.type === "Voltage" ? 3 : r.type === "Fan" ? 0 : 1),
      r.id,
    ])
      tr.append(el("td", text));
    $("sensors").append(tr);
  }
  $("events").replaceChildren();
  for (const ev of data.events) {
    const tr = el("tr");
    for (const text of [
      clock(ev.time),
      ev.provider,
      ev.id,
      { 1: "重大", 2: "エラー", 3: "警告", 4: "情報" }[ev.level] || ev.level,
    ])
      tr.append(el("td", text));
    $("events").append(tr);
  }
  $("paths").textContent = Object.keys(names)
    .map((k) => names[k] + "\n" + (s[k].path || "未作成"))
    .join("\n\n");
}
async function refresh() {
  try {
    if (invoke) {
      data = await invoke("get_snapshot");
    } else {
      const res = await fetch("preview.local.json", { cache: "no-store" });
      if (!res.ok) throw Error("Tauriアプリから開いてください。");
      data = await res.json();
      data.preview = true;
    }
    render();
    if (data.preview) {
      $("overall").textContent = "開発プレビュー / 模擬データ";
      $("banner").classList.add("preview");
    } else {
      $("banner").classList.remove("preview");
    }
  } catch (e) {
    $("banner").classList.add("bad");
    $("overall").textContent = "ログの取得を確認してください";
    $("notice").textContent = String(e);
  } finally {
    setTimeout(refresh, 2000);
  }
}
$("range").onchange = render;
$("rail").onchange = render;
$("filter").oninput = render;
$("export").onclick = async () => {
  try {
    if (!invoke) throw Error("保存はデスクトップアプリで利用できます。");
    const path = await invoke("save_snapshot");
    $("notice").textContent = "保存しました: " + path;
  } catch (e) {
    $("notice").textContent = String(e);
  }
};
$("settings").onclick = () => {
  if (data?.sources) {
    $("sensorRoot").value = data.sources.sensorRoot;
    $("activityRoot").value = data.sources.activityRoot;
  }
  $("settingsDialog").showModal();
};
$("settingsMobile").onclick = $("settings").onclick;
$("closeSettings").onclick = () => $("settingsDialog").close();
$("saveSettings").onclick = async () => {
  try {
    if (!invoke) throw Error("設定はデスクトップアプリで利用できます。");
    await invoke("set_sources", {
      sensorRoot: $("sensorRoot").value,
      activityRoot: $("activityRoot").value,
    });
    $("settingsDialog").close();
    $("notice").textContent = "ログの参照先を更新しました。";
  } catch (e) {
    $("settingsError").textContent = String(e);
  }
};
refresh();
