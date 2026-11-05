// The playground page: renders the fork's state and the recipe builder, and wires the buttons.
import * as lib from "./lib.js";

const $ = (selector) => document.querySelector(selector);
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const clone = (x) => JSON.parse(JSON.stringify(x));
const load = (path) =>
  fetch(`../${path}`).then((r) => {
    if (!r.ok) throw new Error(`${path}: HTTP ${r.status}`);
    return r.json();
  });

const SAVED = "capital-pipeline-recipes";
let ctx;
let templates;
let recipe;
let recipeName = "";

// Saved recipes (this browser only)

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

// Builder

function useRecipe(name, value) {
  recipeName = name;
  recipe = clone(value);
  renderBuilder();
}

const refOptions = (selected, extra = []) =>
  [...extra, ...recipe.components.map((c, i) => [`ref(${i})`, `ref(${i}) ${c.id.split("@")[0]}`])]
    .map(([v, label]) => `<option value="${esc(v)}" ${v === selected ? "selected" : ""}>${esc(label)}</option>`)
    .join("");

function renderComponent(c, i) {
  const ids = Object.keys(ctx.deployment.components);
  const inputs = ctx.meta[c.id].initialize.inputs;
  const fields = inputs
    .map(
      (input) => `<label title="${esc(input.description)}">${esc(input.name)} <span class="hint">${esc(input.type)}</span></label>
        <input class="wide" data-field="components.${i}.args.${input.name}" value="${esc(c.args[input.name] ?? "")}" title="${esc(input.description)}">`,
    )
    .join("");
  return `<div class="component">
    <div class="row">
      <strong>ref(${i})</strong>
      <select data-field="components.${i}.id">${ids.map((id) => `<option ${id === c.id ? "selected" : ""}>${id}</option>`).join("")}</select>
      <button data-remove="components.${i}">Remove</button>
    </div>
    <div class="fields">${fields}</div>
  </div>`;
}

function renderBuilder() {
  const savedNames = Object.keys(saved());
  const nodes = recipe.nodes
    .map(
      (n, i) => `<tr>
        <td>${i}</td>
        <td><select data-field="nodes.${i}.action">${refOptions(n.action === null ? "" : `ref(${n.action})`, [["", "none (branch)"]])}</select></td>
        <td><input data-field="nodes.${i}.children" value="${esc(n.children)}" placeholder="e.g. 1, 2"></td>
        <td><input data-field="nodes.${i}.weights" value="${esc(n.weights)}" placeholder="e.g. 950000, 50000"></td>
        <td><button data-remove="nodes.${i}">Remove</button></td>
      </tr>`,
    )
    .join("");
  const grants = recipe.grants
    .map(
      (g, i) => `<tr>
        <td><select data-field="grants.${i}.where">${refOptions(g.where, [["PLUGIN", "PLUGIN"]])}</select></td>
        <td><input class="wide" data-field="grants.${i}.who" value="${esc(g.who)}"></td>
        <td><select data-field="grants.${i}.permission">${lib.PERMISSIONS.map((p) => `<option ${p === g.permission ? "selected" : ""}>${p}</option>`).join("")}</select></td>
        <td><button data-remove="grants.${i}">Remove</button></td>
      </tr>`,
    )
    .join("");

  $("#builder-body").innerHTML = `
    <div class="row">Start from:
      ${Object.keys(templates).map((t) => `<button data-template="${esc(t)}">${esc(t)}</button>`).join("")}
      <button data-template="">Empty</button>
    </div>
    <div class="row">Saved:
      <select id="saved-list">${savedNames.map((n) => `<option>${esc(n)}</option>`).join("")}</select>
      <button data-saved="load" ${savedNames.length ? "" : "disabled"}>Load</button>
      <button data-saved="delete" ${savedNames.length ? "" : "disabled"}>Delete</button>
      <input id="recipe-name" value="${esc(recipeName)}" placeholder="Recipe name">
      <button data-saved="save">Save</button>
    </div>

    <h3>Components <span class="hint">cloned in this order; nodes, budget and grants point at them with ref(i)</span></h3>
    ${recipe.components.map(renderComponent).join("")}
    <button data-add="components">Add component</button>

    <h3>Budget</h3>
    <select data-field="budget">${refOptions(`ref(${recipe.budget})`)}</select>

    <h3>Tree <span class="hint">node 0 is the root; weights are parts of 1,000,000, one per child when there are 2+</span></h3>
    <table><tr><th>Node</th><th>Action</th><th>Children</th><th>Weights</th><th></th></tr>${nodes}</table>
    <button data-add="nodes">Add node</button>

    <h3>Permissions <span class="hint">EXECUTE and CONFIGURE are always granted</span></h3>
    <table><tr><th>On</th><th>To</th><th>Permission</th><th></th></tr>${grants}</table>
    <button data-add="grants">Add permission</button>

    <h3>Preview</h3>
    <pre id="preview"></pre>
    <div class="row">
      <button class="primary" id="install">Install into the DAO</button>
      <span id="install-log" class="log"></span>
    </div>`;
  renderPreview();
}

function renderPreview() {
  const label = (n) =>
    n.action === null
      ? "branch (no action)"
      : `ref(${n.action}) ${recipe.components[n.action]?.id.split("@")[0] ?? "missing component"}`;
  let tree;
  try {
    const nodes = recipe.nodes.map((n) => ({ ...n, children: lib.numbers(n.children), weights: lib.numbers(n.weights) }));
    const budget = recipe.components[recipe.budget]?.id.split("@")[0] ?? "missing";
    tree = `budget  ref(${recipe.budget}) ${budget}\n${lib.describeTree(nodes, label)}`;
  } catch (e) {
    tree = e.message;
  }
  let encoded;
  try {
    encoded = `${(lib.encodeRecipe(ctx, recipe).length - 2) / 2} bytes of install data`;
    $("#install").disabled = false;
  } catch (e) {
    encoded = `Can't encode yet: ${e.message}`;
    $("#install").disabled = true;
  }
  $("#preview").textContent = `${tree}\n\n${encoded}`;
}

const NEW = {
  components: () => ({ id: "KeepAction@1", args: { dao: "DAO" } }),
  nodes: () => ({ action: 0, children: "", weights: "" }),
  grants: () => ({ where: "PLUGIN", who: "ANY", permission: "TRIGGER" }),
};

function setField(path, value) {
  const keys = path.split(".");
  const last = keys.pop();
  const parent = keys.reduce((obj, k) => obj[k], recipe);
  if (path === "budget") return (recipe.budget = Number(value.match(/\d+/)[0]));
  if (last === "action") return (parent.action = value === "" ? null : Number(value.match(/\d+/)[0]));
  if (last === "id") {
    parent.id = value;
    const inputs = ctx.meta[value].initialize.inputs;
    parent.args = Object.fromEntries(inputs.map((i) => [i.name, i.name === "dao" ? "DAO" : (parent.args[i.name] ?? "")]));
    return renderBuilder();
  }
  parent[last] = value;
}

function wireBuilder() {
  const body = $("#builder-body");
  body.addEventListener("input", (e) => {
    if (!e.target.dataset.field) return;
    setField(e.target.dataset.field, e.target.value);
    renderPreview();
  });
  body.addEventListener("change", (e) => {
    if (e.target.tagName !== "SELECT" || !e.target.dataset.field) return;
    setField(e.target.dataset.field, e.target.value);
    renderPreview();
  });
  body.addEventListener("click", async (e) => {
    const { template, add, remove, saved: savedAction } = e.target.dataset;
    if (template !== undefined) {
      const empty = { components: [], budget: 0, nodes: [], grants: [NEW.grants()] };
      return useRecipe(template, template ? templates[template] : empty);
    }
    if (add) {
      recipe[add].push(NEW[add]());
      return renderBuilder();
    }
    if (remove) {
      const [list, index] = remove.split(".");
      recipe[list].splice(Number(index), 1);
      return renderBuilder();
    }
    if (savedAction) return handleSaved(savedAction);
    if (e.target.id === "install") return installRecipe(e.target);
  });
}

function handleSaved(action) {
  const all = saved();
  const selected = $("#saved-list").value;
  if (action === "load" && all[selected]) return useRecipe(selected, all[selected]);
  if (action === "delete") {
    delete all[selected];
    storeSaved(all);
    return renderBuilder();
  }
  if (action === "save") {
    const name = $("#recipe-name").value.trim() || "Untitled";
    all[name] = recipe;
    storeSaved(all);
    recipeName = name;
    renderBuilder();
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
  templates = lib.templates(ctx.deployment);
  wireBuilder();
  $("#flows").addEventListener("click", runFlow);
  $("#status").addEventListener("click", async (e) => {
    if (!e.target.dataset.advance) return;
    await lib.advance(ctx, Number(e.target.dataset.advance));
    await refresh();
  });
  useRecipe("Buy and burn", templates["Buy and burn"]);
  renderRegistry();
  await refresh();
}

start();
