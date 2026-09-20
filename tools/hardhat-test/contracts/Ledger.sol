// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// A deliberately richer contract than the foundry smoke test: persisted
/// storage (mapping + array), dynamic-array calldata handling, loops, keccak
/// hashing, an event, and require-revert paths. All opcodes pre-Cancun so the
/// etherlang node's EVM can execute the runtime bytecode faithfully.
contract Ledger {
    mapping(address => uint256) public balances;
    address[] public accounts;

    event Deposit(address indexed who, uint256 amount);
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /// Accumulate a deposit: reads/writes the caller's balance slot.
    function deposit(uint256 amount) public returns (uint256 newBalance) {
        require(amount > 0, "amount must be positive");
        uint256 b = balances[msg.sender];
        uint256 next = b + amount;
        require(next >= b, "overflow");
        balances[msg.sender] = next;
        if (b == 0) {
            accounts.push(msg.sender);
        }
        emit Deposit(msg.sender, amount);
        return next;
    }

    /// Move value between two addresses. Reverts when the source is broke.
    function transfer(address to, uint256 amount) public returns (bool) {
        require(to != address(0), "to zero address");
        uint256 fromBalance = balances[msg.sender];
        require(fromBalance >= amount, "insufficient balance");
        balances[msg.sender] = fromBalance - amount;
        balances[to] = balances[to] + amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    /// Sum of every tracked account balance (loops storage + calldata? no: loops storage array).
    function totalBalance() public view returns (uint256 total) {
        uint256 n = accounts.length;
        for (uint256 i = 0; i < n; i++) {
            total += balances[accounts[i]];
        }
        return total;
    }

    /// Pure arithmetic over a dynamic calldata array: sum of elements' squares.
    function sumSquares(uint256[] calldata xs) public pure returns (uint256) {
        uint256 total;
        for (uint256 i = 0; i < xs.length; i++) {
            total += xs[i] * xs[i];
        }
        return total;
    }

    /// keccak-based double hash, used to prove SHA3/keccak256 works in-node.
    function hashThrice(bytes calldata data) public pure returns (bytes32) {
        bytes32 once = keccak256(data);
        bytes32 twice = keccak256(abi.encodePacked(once));
        return keccak256(abi.encodePacked(once, twice));
    }

    /// A loop-counting fold used to exercise JUMPI/JUMPDEST-heavy code.
    function foldSum(uint256[] calldata xs) public pure returns (uint256) {
        uint256 acc;
        uint256 n = xs.length;
        for (uint256 i = 0; i < n; i++) {
            acc = acc + xs[i];
        }
        return acc;
    }
}