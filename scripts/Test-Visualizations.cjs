const { test } = require("node:test");
const assert = require("node:assert/strict");
const vm = require("node:vm");
const fs = require("node:fs");
const path = require("node:path");
function harness() {
  const elements = new Map();
  function element() {
    return {
      children: [],
      attributes: {},
      value: "300",
      innerHTML: "",
      style: {},
      classList: { toggle() {}, add() {}, remove() {} },
      append(...nodes) {
        this.children.push(...nodes);
      },
      replaceChildren() {
        this.children = [];
      },
      setAttribute(k, v) {
        this.attributes[k] = v;
      },
    };
  }
  const context = vm.createContext({
    window: {},
    document: {
      getElementById(id) {
        if (!elements.has(id)) elements.set(id, element());
        return elements.get(id);
      },
      createElement: element,
      createElementNS: element,
    },
    Date,
    Number,
    Math,
    console,
  });
  const source = fs
    .readFileSync(path.join(__dirname, "../ui/app.js"), "utf8")
    .replace(/refresh\(\);\s*$/, "");
  vm.runInContext(source, context);
  vm.runInContext('data={preview:true,time:"2026-10-12T12:00:00Z"}', context);
  return { run: (code) => vm.runInContext(code, context), elements };
}
test("missing power stays blank; a measured zero remains visible", () => {
  const h = harness();
  h.run("powerTrend([{time:data.time,gpuPower:null}])");
  assert.match(h.elements.get("powerChart").innerHTML, /データがありません/);
  assert.equal(h.elements.get("powerPeak").textContent, "—");
  h.run("powerTrend([{time:data.time,gpuPower:0}])");
  assert.match(h.elements.get("powerChart").innerHTML, /<circle/);
  assert.equal(h.elements.get("powerPeak").textContent, "0.0 W");
});
test("recording reports a real interval, ignoring history outside selection", () => {
  const h = harness();
  const facts = h.run(
    `recordingFacts({history:[{time:'2026-10-12T11:40:00Z'},{time:'2026-10-12T11:59:40Z'},{time:'2026-10-12T11:59:42Z'},{time:'2026-10-12T11:59:54Z'}]})`,
  );
  assert.equal(facts.count, 3);
  assert.equal(facts.gaps.length, 1);
  assert.equal(facts.gaps[0].seconds, 12);
});
test("constant voltages stay a single occupied interval; counts conserved", () => {
  const h = harness();
  const d = h.run("distribution([5.06,5.06,null,NaN,5.06],5)");
  assert.equal(d.count, 3);
  assert.equal(
    d.bins.reduce((a, b) => a + b, 0),
    3,
  );
  assert.equal(d.bins.filter((n) => n > 0).length, 1);
  assert.ok(d.min < 5);
  assert.ok(d.max > 5.06);
  assert.equal(d.low, d.high);
});
test("voltage outliers remain in distribution, no clipping to nominal range", () => {
  const d = harness().run("distribution([12.1,12.1,14],12)");
  assert.equal(d.high, 14);
  assert.ok(d.max > 14);
  assert.equal(
    d.bins.reduce((a, b) => a + b, 0),
    3,
  );
});
test("missing voltage has no fabricated distribution", () => {
  const h = harness();
  h.run(
    '$("rail").value="v12";voltageInstruments({state:"recording",history:[]})',
  );
  assert.equal(h.elements.get("voltageCurrent").textContent, "—");
  assert.doesNotMatch(h.elements.get("voltageDistribution").innerHTML, /<path/);
});
test("a fresh empty stream never claims continuous recording", () => {
  const h = harness();
  h.run(
    'const empty={state:"recording",age:0,history:[]};continuity({cpu:empty,board:empty,activity:empty})',
  );
  assert.match(h.elements.get("recordingVerdict").textContent, /待っています/);
});
test("thermal area does not fill across a missing interval", () => {
  const h = harness();
  h.run(
    `chart('tempChart',[{key:'cpuTemp',color:'#fff',rows:[{time:'2026-10-12T11:59:30Z',cpuTemp:50,session:'a'},{time:'2026-10-12T11:59:32Z',cpuTemp:52,session:'a'},{time:'2026-10-12T11:59:50Z',cpuTemp:55,session:'a'},{time:'2026-10-12T11:59:52Z',cpuTemp:56,session:'a'}]}],0,110)`,
  );
  assert.equal(
    (
      h.elements
        .get("tempChart")
        .innerHTML.match(/fill="url\(#tempChartFill\)"/g) || []
    ).length,
    2,
  );
});
