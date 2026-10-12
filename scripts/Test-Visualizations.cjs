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
test("missing power stays blank; a measured zero stays a bar", () => {
  const h = harness();
  h.run("powerBars([{time:data.time,gpuPower:null}])");
  assert.match(h.elements.get("powerChart").innerHTML, /データがありません/);
  h.run("powerBars([{time:data.time,gpuPower:0}])");
  assert.match(h.elements.get("powerChart").innerHTML, /<rect /);
  assert.doesNotMatch(
    h.elements.get("powerChart").innerHTML,
    /データがありません/,
  );
});
test("continuity splits at gaps and session boundaries", () => {
  const h = harness();
  h.run(
    `continuity({cpu:{history:[{time:'2026-10-12T11:59:40Z',session:'a'},{time:'2026-10-12T11:59:42Z',session:'a'},{time:'2026-10-12T11:59:54Z',session:'a'},{time:'2026-10-12T11:59:56Z',session:'b'}]},board:{history:[]},activity:{history:[]}})`,
  );
  const html = h.elements.get("continuityChart").innerHTML;
  assert.equal((html.match(/fill="#a4ddc4"/g) || []).length, 3);
});
test("voltage over-range remains explicit, missing voltage is not zero", () => {
  const h = harness();
  h.run(
    'voltageInstruments({state:"recording",history:[{time:data.time,v12:14,v5:null,v33:3.3}]})',
  );
  const rows = h.elements.get("voltageRails").children;
  assert.match(rows[0].children[1].innerHTML, /→/);
  assert.match(rows[0].children[1].attributes["aria-label"], /14.000V/);
  assert.match(rows[1].children[1].attributes["aria-label"], /取得不可/);
  assert.doesNotMatch(rows[1].children[1].innerHTML, /<circle/);
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
        .innerHTML.match(/fill="url\(#thermalFill\)"/g) || []
    ).length,
    2,
  );
});
