// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Simple} from "../src/Simple.sol";

/// True foundry-side guard: compiles Simple and proves its behavior inside
/// foundry's own EVM. run.sh then sends the SAME runtime bytecode to the
/// etherlang node via eth_call state override and cross-checks the result.
contract SimpleTest {
    function test_set_and_emit() public {
        Simple s = new Simple();
        s.set(7);
        require(s.stored() == 7, "stored should be 7");
    }

    function test_deploy_answer() public {
        Simple s = new Simple();
        require(s.answer() == 42, "answer should be 42");
    }
}