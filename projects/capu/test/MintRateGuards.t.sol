// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {MintRateMath} from "@capu/libraries/MintRateMath.sol";

contract Trampoline {
    function rate(uint256 supply, uint256 base, uint256 power, uint256 target) external pure returns (uint256) {
        return MintRateMath.computeMintRate(supply, base, power, target);
    }
}

contract MintRateGuardsTest is Fixture {
    Trampoline internal tramp;

    function setUp() public {
        _deployStack();
        tramp = new Trampoline();

        // Put some CAPU into circulation so `setMintRateParams` has a live supply to validate against.
        _fund(alice, 1_000_000e18);
        vm.startPrank(alice);
        staking.stake(1_000_000e18);
        staking.lockAndMintCapu(1_000_000e18, 0);
        vm.stopPrank();
    }

    /// @dev A target far below the live supply puts the curve past its arithmetic ceiling, which
    ///      would brick minting and quoting for everyone. The setter must reject it in the same
    ///      transaction rather than accepting it and taking the system down.
    function test_SetMintRateParamsRejectsATargetThatWouldBrickTheCurve() public {
        uint256 liveSupply = capu.totalSupply();
        assertGt(liveSupply, 0, "need a live supply for this to be meaningful");

        // supply / target ≈ 100 → far past the ceiling.
        uint256 brickingTarget = liveSupply / 100;

        vm.prank(admin);
        vm.expectRevert();
        staking.setMintRateParams(DEFAULT_BASE_RATE, DEFAULT_ADJ_POWER, brickingTarget);

        // The live parameters must be untouched.
        assertEq(staking.targetCapuSupply(), DEFAULT_TARGET_SUPPLY, "params changed despite revert");

        // And minting still works.
        _fund(bob, 1_000e18);
        vm.startPrank(bob);
        staking.stake(1_000e18);
        staking.lockAndMintCapu(1_000e18, 0);
        vm.stopPrank();
    }

    /// @dev A legitimate recalibration must still go through.
    function test_SetMintRateParamsAcceptsASaneRecalibration() public {
        vm.prank(admin);
        staking.setMintRateParams(DEFAULT_BASE_RATE * 2, DEFAULT_ADJ_POWER, DEFAULT_TARGET_SUPPLY * 2);
        assertEq(staking.baseMintRate(), DEFAULT_BASE_RATE * 2);
        assertEq(staking.targetCapuSupply(), DEFAULT_TARGET_SUPPLY * 2);
    }

    /// @dev At the extreme end of the curve the library must fail with its own named error, not a
    ///      raw PRBMath overflow, so callers can tell a curve limit from an arithmetic accident.
    function test_ExtremeSupplyFailsWithExponentTooLargeNotAPrbMathOverflow() public {
        uint256 base = 334_480e18;
        uint256 power = 2e18;
        uint256 target = 300e18;

        // Just past the ceiling for these parameters (supply / target ≈ 3.96).
        uint256 supply = 1_188e18;

        vm.expectRevert(MintRateMath.ExponentTooLarge.selector);
        tramp.rate(supply, base, power, target);
    }
}
