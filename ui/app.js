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
function plotWindow() {
  const end = data?.preview ? Date.parse(data.time) : Date.now();
  return { end, start: end - Number($("range").value) * 1000 };
}
function numeric(v) {
  return typeof v === "number" && Number.isFinite(v);
}
function recent(rows) {
  const { start, end } = plotWindow();
  return rows.filter(
    (r) => Date.parse(r.time) >= start && Date.parse(r.time) <= end,
  );
}
function voltageInstruments(stream) {
  $("voltageRails").replaceChildren();
  const last = stream.history.at(-1) || {};
  for (const [key, label, nom] of [
    ["v12", "+12V", 12],
    ["v5", "+5V", 5],
    ["v33", "AVCC3", 3.3],
  ]) {
    const v = last[key],
      valid = numeric(v),
      delta = valid ? (v / nom - 1) * 100 : null;
    const box = el("div", undefined, "rail-instrument"),
      caption = el("div", undefined, "rail-caption");
    caption.append(
      el("strong", label),
      el("span", fmt(v, 3), "rail-value"),
      el("small", "V"),
    );
    const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svg.setAttribute("viewBox", "0 0 300 40");
    svg.setAttribute("class", "rail-gauge");
    svg.setAttribute("role", "img");
    svg.setAttribute(
      "aria-label",
      `${label}: ${valid ? fmt(v, 3) + "V、基準から" + fmt(delta, 2) + "%" : "取得不可"}`,
    );
    let marks =
      '<line x1="10" y1="22" x2="290" y2="22" stroke="#3c494b" stroke-width="4"/>';
    for (let i = 0; i <= 10; i++)
      marks += `<line x1="${10 + i * 28}" y1="${i === 5 ? 5 : 15}" x2="${10 + i * 28}" y2="29" stroke="${i === 5 ? "#c1cfca" : "#5a6667"}"/>`;
    if (valid) {
      const x = 10 + (Math.max(-5, Math.min(5, delta)) + 5) * 28;
      marks += `<line x1="150" y1="22" x2="${x}" y2="22" stroke="#d9b982" stroke-width="4"/><circle cx="${x}" cy="22" r="5" fill="#ecd6ab" stroke="#151d20" stroke-width="2"/>`;
      if (Math.abs(delta) > 5)
        marks += `<text x="${delta > 0 ? 288 : 12}" y="11" fill="#f8c58d" font-size="13" text-anchor="middle">${delta > 0 ? "→" : "←"}</text>`;
    }
    svg.innerHTML = marks;
    const vals = recent(stream.history)
        .map((r) => r[key])
        .filter(numeric),
      detail = el("div", undefined, "rail-detail");
    detail.append(
      el("span", `基準 ${nom.toFixed(1)}V`),
      el("b", valid ? `${delta >= 0 ? "+" : ""}${fmt(delta, 2)}%` : "取得不可"),
    );
    box.append(
      caption,
      svg,
      detail,
      el(
        "p",
        vals.length
          ? `期間内 ${fmt(Math.min(...vals), 3)}–${fmt(Math.max(...vals), 3)} V`
          : "期間内のデータなし",
        "chart-note",
      ),
    );
    if (stream.state !== "recording")
      box.append(el("p", labels[stream.state] + " / 最終値", "tag bad"));
    $("voltageRails").append(box);
  }
}
function powerBars(rows) {
  const svg = $("powerChart"),
    { start, end } = plotWindow(),
    bins = Array(48).fill(null);
  for (const r of recent(rows)) {
    if (!numeric(r.gpuPower)) continue;
    const i = Math.min(
      47,
      Math.floor(((Date.parse(r.time) - start) / (end - start)) * 48),
    );
    bins[i] = Math.max(bins[i] ?? 0, r.gpuPower);
  }
  const ceiling = Math.max(
    50,
    Math.ceil(Math.max(...bins.filter(numeric), 0) / 50) * 50,
  );
  svg.setAttribute("viewBox", "0 0 400 150");
  let out = `<line x1="0" x2="400" y1="123" y2="123" stroke="#46504b"/><text x="0" y="13" fill="#a9b4ae" font-size="10">${ceiling} W</text>`;
  bins.forEach((v, i) => {
    if (v !== null) {
      const height = Math.max((v / ceiling) * 95, 1);
      out += `<rect x="${i * 8.3}" y="${123 - height}" width="5" height="${height}" rx="1" fill="#d6b584"/>`;
    }
  });
  out += `<text x="0" y="147" fill="#99aaa6" font-size="10">${clock(start)}</text><text x="398" y="147" text-anchor="end" fill="#99aaa6" font-size="10">${clock(end)}</text>`;
  if (!bins.some(numeric))
    out +=
      '<text x="200" y="75" text-anchor="middle" fill="#a9b4ae" font-size="12">表示期間内のデータがありません</text>';
  svg.innerHTML = out;
}
function continuity(streams) {
  const svg = $("continuityChart"),
    { start, end } = plotWindow();
  svg.setAttribute("viewBox", "0 0 600 115");
  const x = (t) => 82 + ((t - start) / (end - start)) * 508;
  let out = "";
  for (const [i, key] of ["cpu", "board", "activity"].entries()) {
    const y = 12 + i * 29,
      rows = recent(streams[key].history);
    let first = null,
      prev = null;
    out += `<text x="0" y="${y + 9}" fill="#b3c5d6" font-size="11">${["CPU", "BOARD", "GPU / OS"][i]}</text><rect x="82" y="${y}" width="508" height="11" rx="2" fill="#27343f"/>`;
    const segment = () => {
      if (first !== null)
        out += `<rect x="${x(first)}" y="${y}" width="${Math.max(2, x(prev.t) - x(first))}" height="11" rx="2" fill="${["#a4ddc4", "#cfb795", "#94b9e9"][i]}"/>`;
    };
    for (const r of rows) {
      const t = Date.parse(r.time);
      if (
        !prev ||
        t - prev.t > 6000 ||
        t < prev.t ||
        r.session !== prev.session
      ) {
        segment();
        first = t;
      }
      prev = { t, session: r.session };
    }
    segment();
  }
  out += `<text x="82" y="110" fill="#a4b4c2" font-size="10">${clock(start)}</text><text x="590" y="110" text-anchor="end" fill="#a4b4c2" font-size="10">${clock(end)}</text>`;
  svg.innerHTML = out;
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
  const { start, end } = plotWindow();
  let out =
    '<defs><linearGradient id="thermalFill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#9ce4b7" stop-opacity=".22"/><stop offset="100%" stop-color="#9ce4b7" stop-opacity="0"/></linearGradient></defs>';
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
      segments = [],
      segment = [],
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
        if (segment.length) segments.push(segment);
        segment = [];
        prev = null;
        continue;
      }
      const x = left + ((t - start) / (end - start)) * (w - left - right),
        y = top + ((max - v) / (max - min)) * (h - top - bottom);
      const fresh = prev && t - prev.t <= 6000 && prev.session === r.session;
      if (!fresh && segment.length) {
        segments.push(segment);
        segment = [];
      }
      segment.push([x, Math.max(top, Math.min(h - bottom, y))]);
      path += `${fresh ? "L" : "M"}${x.toFixed(1)},${Math.max(top, Math.min(h - bottom, y)).toFixed(1)} `;
      prev = { t, session: r.session };
      count++;
    }
    if (segment.length) segments.push(segment);
    if (s.key === "cpuTemp")
      for (const points of segments) {
        if (points.length < 2) continue;
        out += `<path d="M${points[0][0]},${h - bottom} ${points.map((p) => "L" + p.join(",")).join(" ")} L${points.at(-1)[0]},${h - bottom} Z" fill="url(#thermalFill)"/>`;
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
  ]) {
    $(id).textContent = fmt(latest(key)[id], dec);
    $(id).style.color = s[key].state === "recording" ? "" : "#f6c472";
  }
  chart(
    "tempChart",
    [
      { rows: s.cpu.history, key: "cpuTemp", color: "#b6efcc" },
      { rows: s.activity.history, key: "gpuTemp", color: "#8ebeff" },
    ],
    0,
    110,
  );
  voltageInstruments(s.board);
  powerBars(s.activity.history);
  continuity(s);
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
      el("span", label, "reason-label"),
      el(
        "span",
        s.activity.state !== "recording"
          ? "更新停止 / 最終状態"
          : v === "Active"
            ? "作動中"
            : v === "Not Active"
              ? "非作動"
              : "取得不可",
        "reason-state",
      ),
      el(
        "span",
        `累積 ${n != null && Number.isFinite(Number(n)) ? (Number(n) / 1e6).toFixed(6) + " 秒" : "—"}`,
        "counter",
      ),
    );
    row.classList.toggle("active", v === "Active");
    row.classList.toggle(
      "unknown",
      s.activity.state !== "recording" || !["Active", "Not Active"].includes(v),
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
  $("gapCount").textContent = issues.length
    ? `${issues.length} 件の確認項目`
    : "取得済み区間に欠測なし";
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
