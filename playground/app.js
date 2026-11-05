// The playground page: the fork's state, a graph editor for recipes, and the installed flows.
// Drawflow is loaded as a classic script (window.Drawflow) before this module runs.
import * as lib from "./lib.js";
import * as graph from "./graph.js";

const $ = (selector) => document.querySelector(selector);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const load = (path) =>
  fetch(`../${path}`).then((r) => {
    if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
    return r.json();
  });

const SAVED = "capital-pipeline-graphs";
let ctx;
let editor;
let recipe = null; // the recipe the graph describes, or null while it isn't valid

// Saved graphs (this browser only)

function saved() {
  try {
    return JSON.parse(localStorage.getItem(SAVED) ?? "{}");
  } catch {
    return {};
  }
}
function storeSaved(all) {
  try {
    localStorage.setItem(SAVED, JSON.stringify(all));
  } catch {
    /* storage unavailable: saving is a convenience */
  }
}
function renderSaved(selected = "") {
  const names = Object.keys(saved());
  $("#saved-list").innerHTML = names.map((n) => `<option ${n === selected ? "selected" : ""}>${esc(n)}</option>`).join("");
  $("#saved-load").disabled = $("#saved-delete").disabled = names.length === 0;
}

// Status

async function refresh() {
  const { dao, filler } = ctx.deployment;
  const s = await lib.status(ctx);
  $("#status").innerHTML = `
    <span>Block ${s.block} · ${s.time.toISOString().slice(0, 16).replace("T", " ")} UTC</span>
    <span>DAO <span class="mono" title="${dao}">${short(dao)}</span>: ${lib.units(s.daoA)} A · ${lib.units(s.daoB)} B</span>
    <span>Filler <span class="mono" title="${filler}">${short(filler)}</span>: ${lib.units(s.fillerB)} B</span>
    <span class="row">Advance time
      <button data-advance="3600">+1 hour</button>
      <button data-advance="86400">+1 day</button>
      <button data-advance="604800">+1 week</button>
    </span>`;
  await renderFlows();
}

// Graph editor

const GROUPS = [
  ["Budgets", ["FundedStreamBudget@1", "BalanceBudget@1"]],
  ["Root actions", ["OpenFillAction@1", "MerkleClaimAction@1"]],
  ["Splits", [graph.BRANCH]],
  ["Leaves", ["TransferAction@1", "TransferToBeneficiaryAction@1", "BurnAction@1", "KeepAction@1"]],
];

function renderPalette() {
  $("#palette").innerHTML =
    GROUPS.map(
      ([title, ids]) =>
        `<h4>${title}</h4>${ids
          .map((id) => `<button data-box="${id}">${id === graph.BRANCH ? "Branch" : esc(id.split("@")[0])}</button>`)
          .join("")}`,
    ).join("") +
    `<p class="hint">Drag from a box's right dot to another box's left dot to connect them. Click a box or a link and press Delete to remove it. Children are ordered top to bottom.</p>`;
}

function addBox(id) {
  const canvas = $("#canvas").getBoundingClientRect();
  const x = (canvas.width / 2 - editor.canvas_x) / editor.zoom - 110 + Math.random() * 40;
  const y = (canvas.height / 3 - editor.canvas_y) / editor.zoom + Math.random() * 40;
  const [inputs, outputs] = graph.ports(id);
  editor.addNode(id, inputs, outputs, x, y, graph.kindOf(id), graph.defaultData(id, ctx.deployment), graph.nodeHtml(id, ctx.meta));
}

function loadGraph(data) {
  editor.import(data);
  updatePreview();
}

function loadTemplate(name) {
  if (!name) return loadGraph({ drawflow: { Home: { data: {} } } });
  loadGraph(graph.recipeToGraph(lib.templates(ctx.deployment)[name], ctx.meta));
  $("#recipe-name").value = name;
}

function updatePreview() {
  const preview = $("#preview");
  try {
    recipe = graph.graphToRecipe(editor.export(), ctx.deployment.account, ctx.meta);
    const name = (i) => `ref(${i}) ${recipe.components[i].id.split("@")[0]}`;
    const nodes = recipe.nodes.map((n) => ({ ...n, children: lib.numbers(n.children), weights: lib.numbers(n.weights) }));
    const tree = lib.describeTree(nodes, (n) => (n.action === null ? "branch (no action)" : name(n.action)));
    const who = (w) => w.replace(/ref\((\d+)\)/, (_, i) => name(Number(i))).replace(ctx.deployment.account, "you");
    const grants = recipe.grants.map((g) => `  ${g.permission} on ${who(g.where)} → ${who(g.who)}`).join("\n");
    const bytes = (lib.encodeRecipe(ctx, recipe).length - 2) / 2;
    preview.className = "";
    preview.textContent = `budget  ${name(0)}\n${tree}\n\nPermissions (besides EXECUTE and CONFIGURE)\n${grants}\n\n${bytes} bytes of install data`;
    $("#install").disabled = false;
  } catch (e) {
    recipe = null;
    preview.className = "bad";
    preview.textContent = e.message;
    $("#install").disabled = true;
  }
}

async function installRecipe(button) {
  const log = $("#install-log");
  button.disabled = true;
  log.className = "log";
  log.textContent = "Preparing through Aragon's PluginSetupProcessor, then executing the proposal actions…";
  try {
    const plugin = await lib.install(ctx, recipe);
    log.className = "log ok";
    log.textContent = `Installed: plugin ${plugin}`;
    await refresh();
  } catch (e) {
    log.className = "log bad";
    log.textContent = e.message;
  } finally {
    button.disabled = false;
  }
}

function wireEditor() {
  editor = new window.Drawflow($("#canvas"));
  editor.reroute = false;
  editor.start();
  for (const event of ["nodeCreated", "nodeRemoved", "connectionCreated", "connectionRemoved", "nodeDataChanged", "nodeMoved"]) {
    editor.on(event, updatePreview);
  }

  $("#builder").addEventListener("click", (e) => {
    const { box, template, zoom } = e.target.dataset;
    if (box) return addBox(box);
    if (template !== undefined) return loadTemplate(template);
    if (zoom) return { in: () => editor.zoom_in(), out: () => editor.zoom_out(), reset: () => editor.zoom_reset() }[zoom]();
    if (e.target.id === "install") return installRecipe(e.target);
    if (e.target.id === "saved-save") {
      const name = $("#recipe-name").value.trim() || "Untitled";
      storeSaved({ ...saved(), [name]: editor.export() });
      return renderSaved(name);
    }
    if (e.target.id === "saved-load") {
      const name = $("#saved-list").value;
      $("#recipe-name").value = name;
      return loadGraph(saved()[name]);
    }
    if (e.target.id === "saved-delete") {
      const all = saved();
      delete all[$("#saved-list").value];
      storeSaved(all);
      return renderSaved();
    }
  });
}

// Installed flows

async function renderFlows() {
  const all = await lib.flows(ctx);
  if (all.length === 0) {
    $("#flows").innerHTML = `<p class="hint">Nothing installed yet. Build a recipe above and install it.</p>`;
    return;
  }
  $("#flows").innerHTML = all
    .map((f) => {
      const root = f.nodes[0];
      const tree = lib.describeTree(f.nodes, (n) => [n.name, ...n.details].join(" · "));
      let run = `<button data-trigger="${f.plugin}">Trigger</button>`;
      if (root.name === "OpenFillAction") run = `<button data-fill="${f.plugin}">Fill with the playground filler</button>`;
      if (root.name === "MerkleClaimAction") {
        run = `<input data-cumulative="${f.plugin}" value="100e18" title="Cumulative amount in the tree">
          <button data-claim="${f.plugin}" data-nodes="${f.nodes.length}">Claim</button>`;
      }
      return `<div class="flow">
        <div class="row"><strong>Plugin</strong> <span class="mono">${f.plugin}</span>${f.paused ? ' <span class="bad">paused</span>' : ""}</div>
        <pre>budget  ${esc([f.budget.name, ...f.budget.details].join(" · "))}\n${esc(tree)}</pre>
        <div class="row">${run}<span class="log" data-log="${f.plugin}"></span></div>
      </div>`;
    })
    .join("");
}

async function runFlow(e) {
  const { fill, trigger, claim, nodes } = e.target.dataset;
  const plugin = fill ?? trigger ?? claim;
  if (!plugin) return;
  const log = document.querySelector(`[data-log="${plugin}"]`);
  e.target.disabled = true;
  log.className = "log";
  log.textContent = "Sending…";
  try {
    if (fill) await lib.fill(ctx, plugin);
    if (trigger) await lib.trigger(ctx, plugin);
    if (claim) {
      const cumulative = lib.amount(document.querySelector(`[data-cumulative="${plugin}"]`).value);
      await lib.claim(ctx, plugin, Number(nodes), cumulative);
    }
    await refresh();
    const after = document.querySelector(`[data-log="${plugin}"]`);
    after.className = "log ok";
    after.textContent = "Done";
  } catch (err) {
    log.className = "log bad";
    log.textContent = err.message;
    e.target.disabled = false;
  }
}

// Registry

function renderRegistry() {
  $("#registry").innerHTML = Object.entries(ctx.deployment.components)
    .map(([id, implementation]) => {
      const meta = ctx.meta[id];
      const inputs = meta.initialize.inputs
        .map((i) => `<tr><td class="mono">${esc(i.name)}</td><td class="mono">${esc(i.type)}</td><td>${esc(i.description)}</td></tr>`)
        .join("");
      return `<details>
        <summary><strong>${esc(id)}</strong> <span class="hint mono">${implementation}</span></summary>
        <p>${esc(meta.description)}</p>
        <table><tr><th>Input</th><th>Type</th><th>Meaning</th></tr>${inputs}</table>
      </details>`;
    })
    .join("");
}

// Start

async function start() {
  try {
    ctx = await lib.connect(load);
  } catch (e) {
    $("#status").innerHTML = `<span class="bad">Can't reach the playground (${esc(e.message)}). Run <code>playground/up.sh</code> first.</span>`;
    return;
  }
  $("#templates").innerHTML =
    Object.keys(lib.templates(ctx.deployment))
      .map((t) => `<button data-template="${esc(t)}">${esc(t)}</button>`)
      .join("") + `<button data-template="">Empty</button>`;
  renderPalette();
  renderSaved();
  wireEditor();
  loadTemplate("Buy and burn");
  $("#flows").addEventListener("click", runFlow);
  $("#status").addEventListener("click", async (e) => {
    if (!e.target.dataset.advance) return;
    await lib.advance(ctx, Number(e.target.dataset.advance));
    await refresh();
  });
  renderRegistry();
  await refresh();
}

start();
