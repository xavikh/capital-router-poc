// Recipes as Drawflow graphs: a budget box feeds a root box, every box feeds its children, and
// leaves have no output. No DOM here: graphs are Drawflow's export format (plain JSON).
// Box data keys are lowercase: HTML lowercases attribute names, so Drawflow stores what is typed
// into a `df-demandPerFill` input under `demandperfill`.

export const BRANCH = "branch";
const KINDS = {
  FundedStreamBudget: "budget",
  BalanceBudget: "budget",
  OpenFillAction: "root",
  MerkleClaimAction: "root",
  TransferAction: "leaf",
  TransferToBeneficiaryAction: "leaf",
  BurnAction: "leaf",
  KeepAction: "leaf",
};
const SETTERS = new Set(["FundedStreamBudget", "OpenFillAction", "MerkleClaimAction"]);
const HIDDEN = new Set(["dao", "budget"]); // always DAO_REF, and the flow's budget

const nameOf = (id) => id.split("@")[0];
const key = (inputName) => inputName.toLowerCase();
const lowerKeys = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [key(k), v]));
export const kindOf = (id) => (id === BRANCH ? "branch" : (KINDS[nameOf(id)] ?? "leaf"));
export const ports = (id) => ({ budget: [0, 1], root: [1, 1], branch: [1, 1], leaf: [1, 0] })[kindOf(id)];

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);

/** The box's inner HTML. `df-<key>` inputs are bound by Drawflow to the box's data. */
export function nodeHtml(id, meta) {
  const kind = kindOf(id);
  const inputs = id === BRANCH ? [] : meta[id].initialize.inputs.filter((i) => !HIDDEN.has(i.name));
  const fields = inputs
    .map((i) => `<label title="${esc(i.description)}">${esc(i.name)}<input df-${key(i.name)}></label>`)
    .join("");
  const share = kind === "budget" ? "" : `<label class="share" title="Parts of 1,000,000 of the parent's output, when the parent has 2+ children">share<input df-share></label>`;
  const title = id === BRANCH ? "Branch (no action)" : nameOf(id);
  return `<div class="box-title">${esc(title)}<span class="box-kind">${kind}</span></div>${fields}${share}`;
}

/** Default settings for a new box */
export function defaultData(id, { tokenA, tokenB }) {
  const defaults = {
    FundedStreamBudget: { token: tokenA, amountPerEpoch: "10e18", maxBudget: "0", epochInterval: "86400" },
    BalanceBudget: { token: tokenA },
    OpenFillAction: { demandedToken: tokenB, demandPerFill: "1000e18", minDemandedPerOffered: "50e18" },
    MerkleClaimAction: { root: "0x" + "00".repeat(32) },
    TransferAction: { to: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8" },
  };
  return { ...lowerKeys(defaults[nameOf(id)] ?? {}), ...(kindOf(id) === "budget" ? {} : { share: "500000" }) };
}

const box = (id, name, data, meta, x, y) => {
  const [inputs, outputs] = ports(name);
  return {
    id,
    name,
    data,
    class: kindOf(name),
    html: nodeHtml(name, meta),
    typenode: false,
    inputs: inputs ? { input_1: { connections: [] } } : {},
    outputs: outputs ? { output_1: { connections: [] } } : {},
    pos_x: x,
    pos_y: y,
  };
};

const connect = (boxes, from, to) => {
  boxes[from].outputs.output_1.connections.push({ node: String(to), output: "input_1" });
  boxes[to].inputs.input_1.connections.push({ node: String(from), input: "output_1" });
};

/** A recipe (lib.templates format) as a laid-out graph */
export function recipeToGraph(recipe, meta) {
  const args = (c) => lowerKeys(Object.fromEntries(Object.entries(c.args).filter(([k]) => !HIDDEN.has(k))));
  const children = recipe.nodes.map((n) => numbers(n.children));
  const weights = recipe.nodes.map((n) => numbers(n.weights));

  // Leaves take consecutive rows; a parent sits level with the middle of its children
  const row = [];
  const depth = [];
  let next = 0;
  const place = (i, d) => {
    depth[i] = d;
    if (children[i].length === 0) return (row[i] = next++);
    children[i].forEach((c) => place(c, d + 1));
    row[i] = children[i].reduce((sum, c) => sum + row[c], 0) / children[i].length;
  };
  if (recipe.nodes.length) place(0, 0);

  const boxes = {};
  const budget = recipe.components[recipe.budget];
  boxes[1] = box(1, budget.id, args(budget), meta, 40, 60 + (row[0] ?? 0) * 170);
  recipe.nodes.forEach((n, i) => {
    const name = n.action === null ? BRANCH : recipe.components[n.action].id;
    const parent = children.findIndex((list) => list.includes(i));
    const position = parent === -1 ? -1 : children[parent].indexOf(i);
    const share = parent !== -1 && weights[parent].length ? String(weights[parent][position]) : "1000000";
    const data = { ...(n.action === null ? {} : args(recipe.components[n.action])), share };
    boxes[i + 2] = box(i + 2, name, data, meta, 340 + depth[i] * 300, 60 + row[i] * 170);
  });
  if (recipe.nodes.length) connect(boxes, 1, 2);
  children.forEach((list, i) => list.forEach((c) => connect(boxes, i + 2, c + 2)));
  return { drawflow: { Home: { data: boxes } } };
}

/** The recipe a graph describes; throws a readable error for anything that isn't a valid tree */
export function graphToRecipe(graph, account, meta) {
  const data = graph.drawflow.Home.data;
  const all = Object.values(data);
  const label = (b) => `${b.name === BRANCH ? "Branch" : nameOf(b.name)} (box ${b.id})`;
  const kids = (b) =>
    (b.outputs.output_1?.connections ?? []).map((c) => data[c.node]).sort((a, z) => a.pos_y - z.pos_y);

  const budgets = all.filter((b) => kindOf(b.name) === "budget");
  if (budgets.length !== 1) throw new Error(`Add exactly one budget (there are ${budgets.length})`);
  const [budget] = budgets;
  const roots = kids(budget);
  if (roots.length !== 1) throw new Error("Connect the budget to exactly one box: the root");

  // Breadth first from the root, so every child comes after its parent
  const order = [];
  const seen = new Set();
  const queue = [roots[0]];
  while (queue.length) {
    const b = queue.shift();
    if (seen.has(b.id)) throw new Error(`${label(b)} has more than one parent`);
    seen.add(b.id);
    order.push(b);
    if ((b.inputs.input_1?.connections ?? []).length > 1) throw new Error(`${label(b)} has more than one parent`);
    queue.push(...kids(b));
  }
  const loose = all.filter((b) => b !== budget && !seen.has(b.id));
  if (loose.length) throw new Error(`${label(loose[0])} isn't connected to the tree`);

  const position = new Map(order.map((b, i) => [b.id, i]));
  const component = (b) => {
    const args = { dao: "DAO", budget: "ref(0)" };
    for (const input of meta[b.name].initialize.inputs) {
      if (!HIDDEN.has(input.name)) args[input.name] = b.data[key(input.name)] ?? "";
    }
    return { id: b.name, args };
  };
  const components = [component(budget)];
  const refs = new Map();
  for (const b of order) {
    if (b.name === BRANCH) continue;
    refs.set(b.id, components.length);
    components.push(component(b));
  }

  const nodes = order.map((b) => {
    const list = kids(b);
    if (b.name === BRANCH && list.length < 2) throw new Error(`${label(b)} needs at least 2 children`);
    let weights = "";
    if (list.length >= 2) {
      const shares = list.map((k) => String(k.data.share ?? "").trim());
      const sum = shares.reduce((s, x) => s + (/^\d+$/.test(x) ? Number(x) : NaN), 0);
      if (sum !== 1_000_000) throw new Error(`The shares under ${label(b)} add up to ${shares.join(" + ")}, not 1,000,000`);
      weights = shares.join(", ");
    }
    return {
      action: b.name === BRANCH ? null : refs.get(b.id),
      children: list.map((k) => position.get(k.id)).join(", "),
      weights,
    };
  });

  return { components, budget: 0, nodes, grants: suggestGrants(components, account) };
}

/** The permissions a recipe of these components needs (the same rules as script/Recipes.sol) */
export function suggestGrants(components, manager) {
  const grants = [
    { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
    { where: "PLUGIN", who: manager, permission: "MANAGER" },
  ];
  components.forEach((c, i) => {
    if (SETTERS.has(nameOf(c.id))) grants.push({ where: `ref(${i})`, who: manager, permission: "MANAGER" });
  });
  components.forEach((c, i) => {
    const name = nameOf(c.id);
    if (name === "FundedStreamBudget") {
      grants.push({ where: `ref(${i})`, who: "DAO", permission: "CHECKPOINT" });
      components.forEach((other, j) => {
        if (nameOf(other.id) === "OpenFillAction") grants.push({ where: `ref(${i})`, who: `ref(${j})`, permission: "CHECKPOINT" });
      });
    }
    if (name === "MerkleClaimAction") grants.push({ where: `ref(${i})`, who: "DAO", permission: "RECORD_CLAIM" });
  });
  return grants;
}

const numbers = (text) =>
  String(text ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map(Number);
