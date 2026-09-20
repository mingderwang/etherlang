import { ethers } from "ethers";
import hre from "hardhat";

const NODE_RPC = process.env.ETHERRANG_RPC || "http://127.0.0.1:8546";
const SCRATCH = "0x1111111111111111111111111111111111111111";
const CALLER = "0x0000000000000000000000000000000000000000";

async function runtimeBytecode(): Promise<string> {
  const art = await hre.artifacts.readArtifact("Ledger");
  return art.deployedBytecode;
}

async function nodeCall(data: string, stateDiff?: Record<string, string>) {
  const runtime = await runtimeBytecode();
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
  return { reverted: resp.error?.message ?? JSON.stringify(resp.error) };
}

function expect(cond: boolean, msg: string) {
  if (!cond) {
    console.error(`FAIL: ${msg}`);
    process.exitCode = 1;
  } else {
    console.log(`ok: ${msg}`);
  }
}

async function main() {
  const iface = new ethers.Interface([
    "function sumSquares(uint256[] calldata xs) pure returns (uint256)",
    "function foldSum(uint256[] calldata xs) pure returns (uint256)",
    "function hashThrice(bytes calldata data) pure returns (bytes32)",
    "function deposit(uint256 amount) returns (uint256 newBalance)",
    "function transfer(address to, uint256 amount) returns (bool)",
  ]);

  // 1. dynamic calldata array + loop + mul
  let r = await nodeCall(iface.encodeFunctionData("sumSquares", [[4, 5, 6]]));
  if ("ok" in r) {
    const [v] = iface.decodeFunctionResult("sumSquares", r.ok);
    expect(v === 77n, `sumSquares([4,5,6]) = ${v} (expected 77)`);
  } else expect(false, `sumSquares reverted: ${r.reverted}`);

  // 2. loop fold
  r = await nodeCall(iface.encodeFunctionData("foldSum", [[1, 2, 3, 4, 5]]));
  if ("ok" in r) {
    const [v] = iface.decodeFunctionResult("foldSum", r.ok);
    expect(v === 15n, `foldSum([1..5]) = ${v} (expected 15)`);
  } else expect(false, `foldSum reverted: ${r.reverted}`);

  // 3. keccak256 double hash
  r = await nodeCall(iface.encodeFunctionData("hashThrice", ["0xdeadbeef"]));
  if ("ok" in r) {
    const [v] = iface.decodeFunctionResult("hashThrice", r.ok);
    const once = ethers.keccak256("0xdeadbeef");
    const ref = ethers.keccak256(ethers.concat([once, ethers.keccak256(once)]));
    expect(v.toLowerCase() === ref.toLowerCase(), `hashThrice(0xdeadbeef) matches ethers keccak reference`);
  } else expect(false, `hashThrice reverted: ${r.reverted}`);

  // 4. storage read/write via seeded stateDiff: balances[0]=7, deposit(5) -> 12
  const slot = ethers.keccak256(ethers.concat([ethers.zeroPadValue(CALLER, 32), ethers.zeroPadValue("0x00", 32)]));
  r = await nodeCall(iface.encodeFunctionData("deposit", [5]), {
    [slot]: "0x" + (7n).toString(16).padStart(64, "0"),
  });
  if ("ok" in r) {
    const [v] = iface.decodeFunctionResult("deposit", r.ok);
    expect(v === 12n, `deposit(5) on seeded balance 7 = ${v} (expected 12)`);
  } else expect(false, `deposit reverted: ${r.reverted}`);

  // 5. require-revert: transfer from a 0-balance account must revert
  r = await nodeCall(iface.encodeFunctionData("transfer", [SCRATCH, 1]));
  expect("reverted" in r, `transfer from empty account reverts (got ${"ok" in r ? r.ok : r.reverted})`);

  console.log(process.exitCode ? "\nFAILURES present" : "\nAll node EVM checks passed");
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});