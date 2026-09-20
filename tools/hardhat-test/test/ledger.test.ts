import { ethers } from "ethers";

const NODE_RPC = process.env.ETHERRANG_RPC || "http://127.0.0.1:8546";
const SCRATCH = "0x1111111111111111111111111111111111111111";
const CALLER = "0x0000000000000000000000000000000000000000";

async function runtimeBytecode(name: string): Promise<string> {
  const art = await hre.artifacts.readArtifact(name);
  return art.deployedBytecode;
}

/// eth_call + code override against the etherlang node. Returns the raw hex
/// output, or `{reverted: <message>}` when the node's EVM correctly reverts.
async function nodeCall(
  runtime: string,
  data: string,
  stateDiff?: Record<string, string>,
): Promise<{ ok: string } | { reverted: string }> {
  const params = [
    { to: SCRATCH, from: CALLER, data },
    "latest",
    { [SCRATCH]: { code: runtime, stateDiff: stateDiff ?? {} } },
  ];
  const body = { jsonrpc: "2.0", id: 1, method: "eth_call", params };
  const resp = await fetch(NODE_RPC, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }).then((r) => r.json());
  if (typeof resp.result === "string") return { ok: resp.result };
  const msg = resp.error?.message ?? JSON.stringify(resp.error);
  return { reverted: msg };
}

describe("etherlang node EVM via eth_call code override", function () {
  this.timeout(30000);

  it("sumSquares([4,5,6]) = 4²+5²+6² = 77", async function () {
    const iface = new ethers.Interface(["function sumSquares(uint256[] calldata xs) pure returns (uint256)"]);
    const res = await nodeCall(await runtimeBytecode("Ledger"), iface.encodeFunctionData("sumSquares", [[4, 5, 6]]));
    if ("reverted" in res) throw new Error(`sumSquares reverted: ${res.reverted}`);
    const [got] = iface.decodeFunctionResult("sumSquares", res.ok);
    if (got !== 77n) throw new Error(`sumSquares: node=${got} expected=77`);
  });

  it("foldSum([1..5]) = 15", async function () {
    const iface = new ethers.Interface(["function foldSum(uint256[] calldata xs) pure returns (uint256)"]);
    const res = await nodeCall(await runtimeBytecode("Ledger"), iface.encodeFunctionData("foldSum", [[1, 2, 3, 4, 5]]));
    if ("reverted" in res) throw new Error(`foldSum reverted: ${res.reverted}`);
    const [got] = iface.decodeFunctionResult("foldSum", res.ok);
    if (got !== 15n) throw new Error(`foldSum: node=${got} expected=15`);
  });

  it("hashThrice(0xdeadbeef) matches ethers keccak reference", async function () {
    const iface = new ethers.Interface(["function hashThrice(bytes calldata data) pure returns (bytes32)"]);
    const res = await nodeCall(await runtimeBytecode("Ledger"), iface.encodeFunctionData("hashThrice", ["0xdeadbeef"]));
    if ("reverted" in res) throw new Error(`hashThrice reverted: ${res.reverted}`);
    const [got] = iface.decodeFunctionResult("hashThrice", res.ok);
    const ref = ethers.keccak256(
      ethers.concat([
        ethers.keccak256("0xdeadbeef"),
        ethers.keccak256(ethers.keccak256("0xdeadbeef")),
      ]),
    );
    if (got.toLowerCase() !== ref.toLowerCase()) throw new Error(`hashThrice: node=${got} expected=${ref}`);
  });

  it("deposit(5) with seeded balances[0]=7 yields 12", async function () {
    // balances is a mapping at storage slot 0 => slot(balances[addr]) = keccak(abi(addr,0)).
    const slot = ethers.keccak256(ethers.concat([ethers.zeroPadValue(CALLER, 32), ethers.zeroPadValue("0x0", 32)]));
    const seeded = "0x" + (7n).toString(16).padStart(64, "0");
    const iface = new ethers.Interface(["function deposit(uint256 amount) returns (uint256 newBalance)"]);
    const res = await nodeCall(await runtimeBytecode("Ledger"), iface.encodeFunctionData("deposit", [5]), {
      [slot]: seeded,
    });
    if ("reverted" in res) throw new Error(`deposit reverted: ${res.reverted}`);
    const [got] = iface.decodeFunctionResult("deposit", res.ok);
    if (got !== 12n) throw new Error(`deposit: node=${got} expected=12`);
  });

  it("transfer on a broke account reverts (require path honest)", async function () {
    const iface = new ethers.Interface(["function transfer(address to, uint256 amount) returns (bool)"]);
    const res = await nodeCall(await runtimeBytecode("Ledger"), iface.encodeFunctionData("transfer", [SCRATCH, 1]));
    if ("ok" in res) throw new Error(`transfer should have reverted, got ${res.ok}`);
  });
});