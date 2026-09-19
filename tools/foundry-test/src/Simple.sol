// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// Minimal contract: no deployment/mining needed to exercise it — the
/// etherlang node executes this runtime bytecode through `eth_call` with a
/// state override (see run.sh).
contract Simple {
    uint256 public stored;

    event Stored(uint256 value);

    function set(uint256 value) public {
        stored = value;
        emit Stored(value);
    }

    function answer() public pure returns (uint256) {
        return 40 + 2;
    }

    function echo(bytes memory data) public pure returns (bytes memory) {
        return data;
    }
}