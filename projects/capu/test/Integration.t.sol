// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture} from "./helpers/Fixture.sol";

/// @notice End-to-end scenario mirroring the user journey in `docs/capu.txt`:
///         CAP → sCAP → lock → mint CAPU → stake CAPU (AI Credit) → unstake CAPU → burn → unlock sCAP → unstake CAP
contract IntegrationTest is Fixture {
    function setUp() public {
        _deployStack();
    }

    function test_FullJourney() public {
        // ---- Bước 1: Alice stake CAP ----
        _fund(alice, 1_000e18);
        vm.prank(alice);
        staking.stake(1_000e18);
        assertEq(staking.balanceOf(alice), 1_000e18);

        // ---- Bước 2: Alice lock sCAP → mint CAPU ----
        vm.prank(alice);
        uint256 minted = staking.lockAndMintCapu(900e18, 0);
        assertGt(minted, 0);
        assertEq(staking.lockedScap(alice), 900e18);

        // ---- Bước 3: Alice stake CAPU để nhận AI Credit ----
        vm.prank(alice);
        capu.stake(minted);
        assertEq(capu.stakedOf(alice), minted);

        // ---- Bước 4 (preparation): unstake CAPU cooldown ----
        vm.prank(alice);
        capu.initiateUnstake(minted);
        vm.warp(block.timestamp + DEFAULT_CAPU_COOLDOWN + 1);
        vm.prank(alice);
        capu.unstake();
        assertEq(capu.balanceOf(alice), minted);

        // ---- Bước 4: Burn CAPU → unlock sCAP ----
        vm.prank(alice);
        uint256 unlocked = staking.burnAndUnlockScap(minted);
        assertEq(unlocked, 900e18);
        assertEq(staking.lockedScap(alice), 0);

        // ---- Final: unstake sCAP back to CAP ----
        vm.startPrank(alice);
        staking.initiateUnstake(1_000e18);
        vm.warp(block.timestamp + DEFAULT_UNBONDING + 1);
        staking.finalizeUnstake();
        vm.stopPrank();

        assertEq(cap.balanceOf(alice), 1_000e18);
        assertEq(staking.balanceOf(alice), 0);
    }
}
