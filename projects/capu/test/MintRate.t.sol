// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MintRateMath} from "@capu/libraries/MintRateMath.sol";

/// @dev External trampoline so `vm.expectRevert` can observe reverts from the pure library.
contract MintRateTrampoline {
    function rate(uint256 supply, uint256 base, uint256 power, uint256 target) external pure returns (uint256) {
        return MintRateMath.computeMintRate(supply, base, power, target);
    }
}

contract MintRateTest is Test {
    uint256 constant BASE = 90e18;
    uint256 constant POWER = 2e18;
    uint256 constant TARGET = 38_000e18;

    MintRateTrampoline trampoline;

    function setUp() public {
        trampoline = new MintRateTrampoline();
    }

    function test_RateAtZeroSupplyEqualsBase() public pure {
        uint256 rate = MintRateMath.computeMintRate(0, BASE, POWER, TARGET);
        assertEq(rate, BASE, "rate at supply=0 must equal baseRate");
    }

    function test_RateAtTargetMatchesEPow2() public pure {
        // expected ≈ 90 * e^2 ≈ 665.0918e18
        uint256 rate = MintRateMath.computeMintRate(TARGET, BASE, POWER, TARGET);
        assertApproxEqRel(rate, 665e18, 0.01e18, "expected ~ baseRate * e^2 within 1%");
    }

    function test_RateIsMonotonicInSupply(uint128 a, uint128 b) public pure {
        vm.assume(a < b);
        vm.assume(uint256(b) < 2 * TARGET); // keep exponent in bounds
        uint256 rA = MintRateMath.computeMintRate(a, BASE, POWER, TARGET);
        uint256 rB = MintRateMath.computeMintRate(b, BASE, POWER, TARGET);
        assertLe(rA, rB, "rate must be non-decreasing in supply");
    }

    function test_MintAmountInversionStable() public pure {
        // At supply 0: locking 90 sCAP should mint ~1 CAPU.
        uint256 amount = MintRateMath.computeMintAmount(90e18, 0, BASE, POWER, TARGET);
        assertApproxEqRel(amount, 1e18, 0.0001e18, "approx 1 CAPU per 90 sCAP at supply=0");
    }

    function test_ExponentTooLargeReverts() public {
        uint256 huge = TARGET * 10;
        vm.expectRevert(MintRateMath.ExponentTooLarge.selector);
        trampoline.rate(huge, BASE, POWER, TARGET);
    }

    function test_TargetSupplyZeroReverts() public {
        vm.expectRevert(MintRateMath.TargetSupplyZero.selector);
        trampoline.rate(1, BASE, POWER, 0);
    }

    function test_BaseRateZeroReverts() public {
        vm.expectRevert(MintRateMath.BaseRateZero.selector);
        trampoline.rate(0, 0, POWER, TARGET);
    }
}
