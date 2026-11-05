// Playground logic, without any DOM: reads the fork, builds and installs recipes, runs flows.
// The page imports "viem" through an import map; Node tests resolve it from node_modules.
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  encodeAbiParameters,
  encodeFunctionData,
  formatUnits,
  getAddress,
  http,
  isAddress,
  keccak256,
  pad,
  stringToHex,
  toHex,
  zeroAddress,
  zeroHash,
  BaseError,
  ContractFunctionRevertedError,
} from "viem";

export const RPC = "http://127.0.0.1:8545";
export const ANY_ADDR = "0xFFfFfFffFFfffFFfFFfFFFFFffFFFffffFfFFFfF";
export const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
export const PERMISSIONS = ["TRIGGER", "MANAGER", "CHECKPOINT", "RECORD_CLAIM"];
export const permissionId = (name) => keccak256(toHex(`${name}_PERMISSION`));

// Anvil's second and third accounts, used as default payroll recipients
const ALICE = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8";
const BOB = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC";

// Placeholders, as in src/lib/placeholders.sol
const TAG = BigInt(keccak256(toHex("capital-pipeline.placeholder"))) & ((1n << 160n) - 1n) & ~0xffffn;
const placeholder = (index) => getAddress(pad(toHex(TAG | BigInt(index)), { size: 20 }));
export const DAO_REF = placeholder(0xffff);
export const PLUGIN_REF = placeholder(0xfffe);
export const ref = (index) => placeholder(index);

// Parsing what people type

/** "DAO", "PLUGIN", "ANY", "ref(2)" or an address → the address the recipe carries */
export function target(text) {
  const t = String(text ?? "").trim();
  if (t === "DAO") return DAO_REF;
  if (t === "PLUGIN") return PLUGIN_REF;
  if (t === "ANY") return ANY_ADDR;
  const m = t.match(/^ref\((\d+)\)$/);
  if (m) return ref(Number(m[1]));
  if (isAddress(t)) return getAddress(t);
  throw new Error(`"${t}" is not an address, DAO, PLUGIN, ANY or ref(i)`);
}

/** "1000", "10e18" or "1.5e18" → bigint */
export function amount(text) {
  const t = String(text ?? "").trim();
  const m = t.match(/^(\d+)(?:\.(\d+))?e(\d+)$/);
  if (m) {
    const [, whole, decimals = "", exponent] = m;
    if (decimals.length > Number(exponent)) throw new Error(`"${t}" has more decimals than its exponent`);
    return BigInt(whole + decimals.padEnd(Number(exponent), "0"));
  }
  if (!/^\d+$/.test(t)) throw new Error(`"${t}" is not a whole number (e.g. 1000 or 10e18)`);
  return BigInt(t);
}

/** "1, 2" → [1, 2] */
export const numbers = (text) =>
  String(text ?? "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean)
    .map((s) => {
      if (!/^\d+$/.test(s)) throw new Error(`"${s}" is not a whole number`);
      return Number(s);
    });

function arg(type, value, where) {
  try {
    if (type === "address") return target(value);
    if (type.startsWith("uint")) return amount(value);
    if (type === "bytes32") {
      if (!/^0x[0-9a-fA-F]{64}$/.test(String(value).trim())) throw new Error(`"${value}" is not 32 bytes of hex`);
      return String(value).trim();
    }
  } catch (e) {
    throw new Error(`${where}: ${e.message}`);
  }
  throw new Error(`${where}: unsupported type ${type}`);
}

// Connecting

/** @param load (path) => Promise<json>, relative to the repo root */
export async function connect(load, rpc = RPC) {
  const [deployment, abis, build] = await Promise.all([
    load("playground/deployment.json"),
    load("playground/abis.json"),
    load("metadata/build.json"),
  ]);
  const meta = {};
  await Promise.all(
    Object.keys(deployment.components).map(async (id) => {
      meta[id] = await load(`metadata/components/${id.split("@")[0]}.json`);
    }),
  );

  const chain = defineChain({
    id: deployment.chainId,
    name: "Sepolia fork",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const transport = http(rpc);
  const errors = uniqueErrors(Object.values(abis).flat());
  const implToId = Object.fromEntries(Object.entries(deployment.components).map(([id, a]) => [a.toLowerCase(), id]));

  return {
    deployment,
    abis,
    meta,
    errors,
    implToId,
    installParams: abiParam(build.pluginSetup.prepareInstallation.inputs[0]),
    pub: createPublicClient({ chain, transport }),
    wallet: createWalletClient({ chain, transport, account: deployment.account }),
    test: createTestClient({ chain, transport, mode: "anvil" }),
  };
}

const abiParam = ({ name, type, components }) =>
  components ? { name, type, components: components.map(abiParam) } : { name, type };

function uniqueErrors(abi) {
  const seen = new Map();
  for (const item of abi.filter((x) => x.type === "error")) {
    seen.set(`${item.name}(${item.inputs.map((i) => i.type).join(",")})`, item);
  }
  return [...seen.values()];
}

// Recipes

const component = (id, args) => ({ id, args: { dao: "DAO", ...args } });
const stream = (token) =>
  component("FundedStreamBudget@1", { token, amountPerEpoch: "10e18", maxBudget: "0", epochInterval: "86400" });
const openFill = (tokenB) =>
  component("OpenFillAction@1", {
    budget: "ref(0)",
    demandedToken: tokenB,
    demandPerFill: "1000e18",
    minDemandedPerOffered: "50e18",
  });
const leaf = (action) => ({ action, children: "", weights: "" });
const swapGrants = (manager) => [
  { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
  { where: "PLUGIN", who: manager, permission: "MANAGER" },
  { where: "ref(0)", who: manager, permission: "MANAGER" },
  { where: "ref(1)", who: manager, permission: "MANAGER" },
  { where: "ref(0)", who: "DAO", permission: "CHECKPOINT" },
  { where: "ref(0)", who: "ref(1)", permission: "CHECKPOINT" },
];

/** The recipes in script/Recipes.sol, as editable state */
export function templates({ tokenA, tokenB, account }) {
  return {
    "Buy and burn": {
      components: [stream(tokenA), openFill(tokenB), component("BurnAction@1", {})],
      budget: 0,
      nodes: [{ action: 1, children: "1", weights: "" }, leaf(2)],
      grants: swapGrants(account),
    },
    "Buyback with a fee": {
      components: [stream(tokenA), openFill(tokenB), component("BurnAction@1", {}), component("TransferAction@1", { to: BOB })],
      budget: 0,
      nodes: [{ action: 1, children: "1, 2", weights: "950000, 50000" }, leaf(2), leaf(3)],
      grants: swapGrants(account),
    },
    Payroll: {
      components: [stream(tokenA), component("TransferAction@1", { to: ALICE }), component("TransferAction@1", { to: BOB })],
      budget: 0,
      nodes: [{ action: null, children: "1, 2", weights: "700000, 300000" }, leaf(1), leaf(2)],
      grants: [
        { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
        { where: "PLUGIN", who: account, permission: "MANAGER" },
        { where: "ref(0)", who: account, permission: "MANAGER" },
        { where: "ref(0)", who: "DAO", permission: "CHECKPOINT" },
      ],
    },
    "Merkle claim": {
      components: [
        component("BalanceBudget@1", { token: tokenA }),
        component("MerkleClaimAction@1", { budget: "ref(0)", root: merkleLeaf(account, 100n * 10n ** 18n) }),
        component("TransferToBeneficiaryAction@1", {}),
      ],
      budget: 0,
      nodes: [{ action: 1, children: "1", weights: "" }, leaf(2)],
      grants: [
        { where: "PLUGIN", who: "ANY", permission: "TRIGGER" },
        { where: "PLUGIN", who: account, permission: "MANAGER" },
        { where: "ref(1)", who: account, permission: "MANAGER" },
        { where: "ref(1)", who: "DAO", permission: "RECORD_CLAIM" },
      ],
    },
  };
}

/** A one-leaf Merkle tree: its root is the leaf, and the proof is empty */
export const merkleLeaf = (account, cumulative) =>
  keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [account, cumulative])));

/** The recipe as `abi.encode(InstallParams)`; throws a readable error for anything mistyped */
export function encodeRecipe(ctx, recipe) {
  const components = recipe.components.map((c, i) => {
    const inputs = ctx.meta[c.id].initialize.inputs;
    const args = inputs.map((input) => arg(input.type, c.args[input.name], `ref(${i}) ${input.name}`));
    const initData = encodeFunctionData({ abi: ctx.abis[c.id.split("@")[0]], functionName: "initialize", args });
    return { id: stringToHex(c.id, { size: 32 }), initData };
  });
  const params = {
    components,
    budget: ref(recipe.budget),
    nodes: recipe.nodes.map((n, i) => ({
      action: n.action === null ? zeroAddress : ref(n.action),
      children: wrap(`node ${i} children`, () => numbers(n.children)),
      weights: wrap(`node ${i} weights`, () => numbers(n.weights)),
    })),
    grants: recipe.grants.map((g, i) => ({
      where: wrap(`grant ${i} where`, () => target(g.where)),
      who: wrap(`grant ${i} who`, () => target(g.who)),
      permissionId: permissionId(g.permission),
    })),
  };
  return encodeAbiParameters([ctx.installParams], [params]);
}

function wrap(where, fn) {
  try {
    return fn();
  } catch (e) {
    throw new Error(`${where}: ${e.message}`);
  }
}

/** The tree as text, e.g. for a preview */
export function describeTree(nodes, label) {
  if (nodes.length === 0) return "(no nodes)";
  const lines = [];
  const seen = new Set();
  const walk = (index, prefix, last, share) => {
    const node = nodes[index];
    const connector = index === 0 ? "" : last ? "└─ " : "├─ ";
    if (!node || seen.has(index)) return lines.push(`${prefix}${connector}${share}invalid child ${index}`);
    seen.add(index);
    lines.push(`${prefix}${connector}${share}${label(node, index)}`);
    const children = node.children;
    const weights = node.weights;
    children.forEach((child, k) => {
      const pct = weights.length ? `${Number(weights[k]) / 10000}% → ` : "";
      walk(child, index === 0 ? "" : prefix + (last ? "   " : "│  "), k === children.length - 1, pct);
    });
  };
  walk(0, "", true, "");
  return lines.join("\n");
}

// Transactions

/** Simulates, sends and waits; throws with the decoded revert */
export async function write(ctx, call) {
  try {
    const { request, result } = await ctx.pub.simulateContract({
      ...call,
      abi: [...call.abi, ...ctx.errors],
      account: ctx.deployment.account,
    });
    const hash = await ctx.wallet.writeContract(request);
    const receipt = await ctx.pub.waitForTransactionReceipt({ hash });
    if (receipt.status !== "success") throw new Error(`transaction ${hash} reverted`);
    return { receipt, result };
  } catch (e) {
    throw new Error(describeError(e));
  }
}

export function describeError(e) {
  if (e instanceof BaseError) {
    const revert = e.walk((err) => err instanceof ContractFunctionRevertedError);
    if (revert?.data?.errorName) {
      const args = (revert.data.args ?? []).map((a) => (typeof a === "bigint" ? a.toString() : String(a)));
      return `${revert.data.errorName}(${args.join(", ")})`;
    }
    return e.shortMessage ?? e.message;
  }
  return e.message ?? String(e);
}

/** Prepares the installation through Aragon's PluginSetupProcessor, then executes the three
 *  proposal actions as the DAO (the playground account holds EXECUTE on it). */
export async function install(ctx, recipe) {
  const { dao, pluginRepo, pluginSetupProcessor: psp } = ctx.deployment;
  const data = encodeRecipe(ctx, recipe);
  const setupRef = { versionTag: { release: 1, build: 1 }, pluginSetupRepo: pluginRepo };

  const { result } = await write(ctx, {
    address: psp,
    abi: ctx.abis.psp,
    functionName: "prepareInstallation",
    args: [dao, { pluginSetupRef: setupRef, data }],
  });
  const [plugin, prepared] = result;

  const helpersHash = keccak256(encodeAbiParameters([{ type: "address[]" }], [prepared.helpers]));
  const apply = { pluginSetupRef: setupRef, plugin, permissions: prepared.permissions, helpersHash };
  const root = keccak256(toHex("ROOT_PERMISSION"));
  const actions = [
    { to: dao, value: 0n, data: encodeFunctionData({ abi: ctx.abis.dao, functionName: "grant", args: [dao, psp, root] }) },
    { to: psp, value: 0n, data: encodeFunctionData({ abi: ctx.abis.psp, functionName: "applyInstallation", args: [dao, apply] }) },
    { to: dao, value: 0n, data: encodeFunctionData({ abi: ctx.abis.dao, functionName: "revoke", args: [dao, psp, root] }) },
  ];
  await write(ctx, { address: dao, abi: ctx.abis.dao, functionName: "execute", args: [zeroHash, actions, 0n] });
  return plugin;
}

// Reading

const read = (ctx, address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });

const SYMBOLS = new Map();
async function symbol(ctx, token) {
  if (token.toLowerCase() === NATIVE.toLowerCase()) return "ETH";
  if (!SYMBOLS.has(token)) SYMBOLS.set(token, await read(ctx, token, ctx.abis.token, "symbol").catch(() => token.slice(0, 8)));
  return SYMBOLS.get(token);
}

export const units = (value) => {
  const [whole, decimals = ""] = formatUnits(value, 18).split(".");
  return decimals ? `${whole}.${decimals.slice(0, 4)}` : whole;
};

async function balance(ctx, token, account) {
  if (token.toLowerCase() === NATIVE.toLowerCase()) return ctx.pub.getBalance({ address: account });
  return read(ctx, token, ctx.abis.token, "balanceOf", [account]);
}

export async function status(ctx) {
  const { dao, filler, tokenA, tokenB } = ctx.deployment;
  const [block, daoA, daoB, fillerB, daoEth] = await Promise.all([
    ctx.pub.getBlock(),
    balance(ctx, tokenA, dao),
    balance(ctx, tokenB, dao),
    balance(ctx, tokenB, filler),
    ctx.pub.getBalance({ address: dao }),
  ]);
  return { block: block.number, time: new Date(Number(block.timestamp) * 1000), daoA, daoB, fillerB, daoEth };
}

/** Which registered implementation a clone runs, from its EIP-1167 code */
async function identify(ctx, address) {
  const code = (await ctx.pub.getCode({ address })) ?? "0x";
  const m = code.match(/^0x363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3$/i);
  return m ? (ctx.implToId[`0x${m[1]}`.toLowerCase()] ?? "unknown") : "not a clone";
}

/** A component's kind and the settings worth showing */
export async function describeComponent(ctx, address) {
  if (address === zeroAddress) return { address, id: "branch", name: "branch (no action)", details: [] };
  const id = await identify(ctx, address);
  const name = id.split("@")[0];
  const abi = ctx.abis[name];
  const get = (fn) => read(ctx, address, abi, fn);
  const details = [];
  if (name === "FundedStreamBudget" || name === "BalanceBudget") {
    const token = await get("token");
    const sym = await symbol(ctx, token);
    details.push(`available ${units(await get("available"))} ${sym}`);
    if (name === "FundedStreamBudget") {
      details.push(`${units(await get("amountPerEpoch"))} ${sym} per ${await get("epochInterval")}s`);
    }
  } else if (name === "OpenFillAction") {
    const demanded = await symbol(ctx, await get("demandedToken"));
    details.push(`demands ${units(await get("demandPerFill"))} ${demanded} per fill`);
    details.push(`offers at most ${units(await get("maxOffered"))}`);
  } else if (name === "MerkleClaimAction") {
    details.push(`root ${(await get("root")).slice(0, 10)}…`);
  } else if (name === "TransferAction") {
    details.push(`to ${await get("recipient")}`);
  }
  return { address, id, name, details };
}

/** Every flow installed in the playground DAO, newest first */
export async function flows(ctx) {
  const { dao, pluginSetupProcessor: psp, startBlock } = ctx.deployment;
  const logs = await ctx.pub.getContractEvents({
    address: psp,
    abi: ctx.abis.psp,
    eventName: "InstallationApplied",
    args: { dao },
    fromBlock: BigInt(startBlock) + 1n,
  });
  return Promise.all(logs.reverse().map((log) => readFlow(ctx, log.args.plugin)));
}

export async function readFlow(ctx, plugin) {
  const [budget, nodes, paused] = await Promise.all([
    read(ctx, plugin, ctx.abis.plugin, "budget"),
    read(ctx, plugin, ctx.abis.plugin, "nodes"),
    read(ctx, plugin, ctx.abis.plugin, "paused"),
  ]);
  const [budgetInfo, ...actions] = await Promise.all([
    describeComponent(ctx, budget),
    ...nodes.map((n) => describeComponent(ctx, n.action)),
  ]);
  return {
    plugin,
    paused,
    budget: budgetInfo,
    nodes: nodes.map((n, i) => ({ ...actions[i], children: n.children.map(Number), weights: n.weights.map(Number) })),
  };
}

// Running flows

/** The playground filler takes the root OpenFill offer, paying from its own balance */
export const fill = (ctx, plugin) =>
  write(ctx, { address: ctx.deployment.filler, abi: ctx.abis.filler, functionName: "fill", args: [plugin] });

export const trigger = (ctx, plugin) =>
  write(ctx, { address: plugin, abi: ctx.abis.plugin, functionName: "trigger", args: [[]] });

/** Claims `cumulative` for the playground account from a one-leaf Merkle tree (empty proof) */
export async function claim(ctx, plugin, nodeCount, cumulative) {
  const data = Array(nodeCount).fill("0x");
  data[0] = encodeAbiParameters(
    [{ type: "address" }, { type: "uint256" }, { type: "bytes32[]" }, { type: "address" }],
    [ctx.deployment.account, cumulative, [], zeroAddress],
  );
  return write(ctx, { address: plugin, abi: ctx.abis.plugin, functionName: "trigger", args: [data] });
}

export async function advance(ctx, seconds) {
  await ctx.test.increaseTime({ seconds });
  await ctx.test.mine({ blocks: 1 });
}
