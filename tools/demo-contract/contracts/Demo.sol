// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract Demo {
    uint256 public base = 40;

    function answer(uint256 addend) external pure returns (uint256) {
        return 2 + addend;
    }

    function baseValue() external view returns (uint256) {
        return base;
    }

    function failUnless(bool ok) external pure returns (uint256) {
        require(ok, "Demo: boom");
        return 7;
    }
}
