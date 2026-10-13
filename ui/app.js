const $ = (id) => document.getElementById(id);
const invoke = window.__TAURI__?.core?.invoke;
let data = null;
const names = {
  cpu: "CPUセンサー",
  board: "基板センサー",
  activity: "GPU・負荷",
};
const labels = {
  recording: "記録中",
  stale: "更新が止まっています",
  missing: "ログなし",
  error: "読み取りエラー",
  clock: "時刻を確認",
  disabled: "収集対象外",
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
function distribution(values, nominal) {
  const vals = values.filter(numeric);
  if (!vals.length) return null;
  const lo = Math.min(nominal, ...vals),
    hi = Math.max(nominal, ...vals);
  const padding = Math.max((hi - lo) * 0.16, nominal * 0.001);
  const min = lo - padding,
    max = hi + padding,
    bins = Array(24).fill(0);
  for (const v of vals)
    bins[
      Math.min(23, Math.max(0, Math.floor(((v - min) / (max - min)) * 24)))
    ]++;
  const modal = bins.indexOf(Math.max(...bins)),
    width = (max - min) / 24;
  return {
    min,
    max,
    bins,
    count: vals.length,
    low: Math.min(...vals),
    high: Math.max(...vals),
    modeLow: min + modal * width,
    modeHigh: min + (modal + 1) * width,
    modeCount: bins[modal],
  };
}
function voltageInstruments(stream) {
  const key = $("rail").value,
    nom = { v12: 12, v5: 5, v33: 3.3 }[key],
    last = stream.history.at(-1) || {},
    v = last[key];
  const d = distribution(
      recent(stream.history).map((r) => r[key]),
      nom,
    ),
    svg = $("voltageDistribution");
  $("voltageCurrent").textContent = fmt(v, 3);
  $("voltageDelta").textContent =
    stream.state !== "recording"
      ? labels[stream.state] + " / 最終値"
      : numeric(v)
        ? `基準 ${fmt(nom, 1)} V から ${v >= nom ? "+" : ""}${fmt((v / nom - 1) * 100, 2)}%`
        : "現在値を取得できません";
  svg.setAttribute("viewBox", "0 0 380 180");
  let out = "";
  if (!d || d.count < 10) {
    out =
      '<text x="190" y="80" text-anchor="middle" fill="#b5c0bd" font-size="12">分布には10件以上の測定が必要です</text>';
    $("distributionSummary").textContent = `表示期間内 ${d?.count || 0} 件`;
  } else {
    const x = (n) => 35 + ((n - d.min) / (d.max - d.min)) * 330,
      base = 142,
      top = 30,
      peak = Math.max(...d.bins),
      step = 330 / 24;
    out = `<text x="0" y="15" fill="#aebbb6" font-size="10">測定回数（最大 ${peak} 回）</text>`;
    for (const count of [0, peak]) {
      const y = base - (count / peak) * (base - top);
      out += `<line x1="35" y1="${y}" x2="365" y2="${y}" stroke="#33403c"/><text x="29" y="${y + 4}" text-anchor="end" fill="#aebbb6" font-size="10">${count}</text>`;
    }
    let path = `M35,${base}`;
    d.bins.forEach((n, i) => {
      const y = base - (n / peak) * (base - top);
      path += ` L${35 + i * step},${y} L${35 + (i + 1) * step},${y}`;
    });
    path += ` L365,${base} Z`;
    out += `<path d="${path}" fill="#d9b98255" stroke="#dbc398" stroke-width="1.4"/><line x1="${x(nom)}" y1="22" x2="${x(nom)}" y2="${base}" stroke="#a3b3ba" stroke-dasharray="4 4"/>`;
    if (numeric(v))
      out += `<line x1="${x(v)}" y1="22" x2="${x(v)}" y2="${base}" stroke="#fce1ad" stroke-width="2"/><circle cx="${x(v)}" cy="22" r="3" fill="#fce1ad"/>`;
    for (const [value, anchor] of [
      [d.min, "start"],
      [(d.min + d.max) / 2, "middle"],
      [d.max, "end"],
    ])
      out += `<text x="${x(value)}" y="166" text-anchor="${anchor}" fill="#b7c5bd" font-size="10">${fmt(value, 3)} V</text>`;
    $("distributionSummary").textContent =
      d.low === d.high
        ? `${d.count} 件とも ${fmt(d.low, 3)} V を記録`
        : `最も多い範囲：${fmt(d.modeLow, 3)}–${fmt(d.modeHigh, 3)} V（${Math.round((d.modeCount / d.count) * 100)}%）`;
  }
  svg.innerHTML = out;
  svg.setAttribute(
    "aria-label",
    d
      ? `実測電圧分布、${d.count}件、最小${fmt(d.low, 3)}V、最大${fmt(d.high, 3)}V。基準${nom}V、現在${fmt(v, 3)}V。`
      : "分布のデータなし",
  );
  $("voltageExtent").textContent = d
    ? `最小 ${fmt(d.low, 3)} / 最大 ${fmt(d.high, 3)} V · ${d.count} 件`
    : "表示期間内の測定データがありません";
}
function powerTrend(rows) {
  const vals = recent(rows)
    .map((r) => r.gpuPower)
    .filter(numeric);
  $("powerPeak").textContent = vals.length
    ? fmt(Math.max(...vals), 1) + " W"
    : "—";
  $("powerMean").textContent = vals.length
    ? fmt(vals.reduce((a, b) => a + b, 0) / vals.length, 1) + " W"
    : "—";
  chart(
    "powerChart",
    [{ rows, key: "gpuPower", color: "#d6b584" }],
    0,
    Math.max(50, Math.ceil(Math.max(...vals, 0) / 50) * 50),
  );
}
function recordingFacts(stream) {
  const rows = recent(stream.history),
    gaps = [];
  for (let i = 1; i < rows.length; i++) {
    const seconds =
      (Date.parse(rows[i].time) - Date.parse(rows[i - 1].time)) / 1000;
    if (seconds > 6) gaps.push({ time: rows[i].time, seconds });
  }
  return {
    count: rows.length,
    first: rows[0]?.time,
    last: rows.at(-1)?.time,
    gaps,
  };
}
function continuity(streams) {
  $("recordingRows").replaceChildren();
  let gaps = 0,
    allLive = true,
    enough = true;
  for (const key of Object.keys(names)) {
    const s = streams[key],
      f = recordingFacts(s);
    gaps += f.gaps.length;
    allLive &&= s.state === "recording";
    enough &&= f.count >= 2;
    const row = el("div", undefined, "recording-row"),
      title = el("div");
    title.append(
      el("strong", names[key]),
      el(
        "span",
        `${numeric(s.age) ? fmt(s.age, 1) + "秒前に保存" : "保存時刻なし"}`,
        "muted",
      ),
    );
    const detail = el("div", undefined, "recording-detail");
    detail.append(
      el(
        "b",
        s.state !== "recording"
          ? labels[s.state]
          : f.count < 2
            ? "比較できる記録が不足"
            : f.gaps.length
              ? `途切れ ${f.gaps.length} 回`
              : "途切れなし",
        s.state !== "recording" || f.gaps.length ? "tag bad" : "tag",
      ),
    );
    detail.append(
      el(
        "span",
        f.count
          ? `${clock(f.first)}–${clock(f.last)} / ${f.count} 件`
          : "表示期間内のデータなし",
        "muted",
      ),
    );
    row.append(title, detail);
    $("recordingRows").append(row);
  }
  $("recordingVerdict").textContent = !allLive
    ? "更新が止まった記録があります"
    : !enough
      ? "記録中です。比較するデータを待っています"
      : gaps
        ? `記録中ですが、${gaps} 回の途切れがあります`
        : "3系統とも記録が続いています";
}
function chart(id, series, min, max) {
  const svg = $(id),
    w = id === "powerChart" ? 400 : 640,
    h = id === "powerChart" ? 175 : 220,
    left = id === "powerChart" ? 32 : 48,
    right = 12,
    top = 15,
    bottom = 28;
  svg.setAttribute("viewBox", `0 0 ${w} ${h}`);
  const { start, end } = plotWindow();
  let out = `<defs><linearGradient id="${id}Fill" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#9ce4b7" stop-opacity=".22"/><stop offset="100%" stop-color="#9ce4b7" stop-opacity="0"/></linearGradient></defs>`;
  const ticks = id === "powerChart" ? 2 : 4;
  for (let i = 0; i <= ticks; i++) {
    let val = min + ((max - min) * i) / ticks,
      y = h - bottom - ((h - top - bottom) * i) / ticks;
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
        !Number.isFinite(t) ||
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
      const fresh =
        prev && t >= prev.t && t - prev.t <= 6000 && prev.session === r.session;
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
        out += `<path d="M${points[0][0]},${h - bottom} ${points.map((p) => "L" + p.join(",")).join(" ")} L${points.at(-1)[0]},${h - bottom} Z" fill="url(#${id}Fill)"/>`;
      }
    out += `<path d="${path}" fill="none" stroke="${s.color}" stroke-width="2"/>`;
    for (const points of segments)
      if (points.length === 1)
        out += `<circle cx="${points[0][0]}" cy="${points[0][1]}" r="2.5" fill="${s.color}"/>`;
  }
  if (!count)
    out += `<text x="${w / 2}" y="${h / 2}" text-anchor="middle" fill="#98aabe" font-size="12">表示期間内のデータがありません</text>`;
  svg.innerHTML = out;
}
function render() {
  if (!data) return;
  const s = data.streams;
  const bad = Object.keys(names).filter((k) => !["recording","disabled"].includes(s[k].state));
  $("banner").classList.toggle("bad", bad.length > 0);
  $("overall").textContent = bad.length
    ? bad.map((k) => names[k]).join("・") + "の記録を確認してください"
    : "3系統のログが更新されています";
  if (data.recorder) {
    $("overall").textContent = data.recorder.label;
    $("banner").classList.toggle("bad", !["recording","stopped"].includes(data.recorder.state));
  }
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
  powerTrend(s.activity.history);
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
    for (const g of recordingFacts(s[k]).gaps)
      issues.push(
        clock(g.time) +
          " " +
          names[k] +
          " / " +
          g.seconds +
          "秒間、次の記録まで間隔あり" +
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
    : "記録状態";
  if (!issues.length)
    $("issues").append(
      el(
        "div",
        "取得済み区間に6秒を超える間隔・取得エラーはありません。",
        "empty",
      ),
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
