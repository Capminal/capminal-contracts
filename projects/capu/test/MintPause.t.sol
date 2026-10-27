// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {IScapStaking} from "@capu/interfaces/IScapStaking.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev `mintPaused` is a narrower switch than `pause()`: it closes ONLY lockAndMintCapu, so the
///      admin can stop new CAPU issuance while CAP staking, reward streaming and every exit path
///      keep running exactly as before.
contract MintPauseTest is Fixture {
    function setUp() public {
        _deployStack();
        _fund(alice, 10_000e18);
    }

    function test_MintPausedDefaultsToFalse() public view {
        assertFalse(staking.mintPaused());
    }

    function test_OnlyAdminCanSetMintPaused() public {
        bytes32 adminRole = staking.DEFAULT_ADMIN_ROLE();
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, adminRole)
        );
        staking.setMintPaused(true);
        assertFalse(staking.mintPaused());
    }

    function test_SetMintPausedEmitsAndStoresFlag() public {
        vm.prank(admin);
        vm.expectEmit(address(staking));
        emit IScapStaking.MintPausedUpdated(true);
        staking.setMintPaused(true);
        assertTrue(staking.mintPaused());

        vm.prank(admin);
        vm.expectEmit(address(staking));
        emit IScapStaking.MintPausedUpdated(false);
        staking.setMintPaused(false);
        assertFalse(staking.mintPaused());
    }

    function test_MintPausedBlocksLockAndMintCapu() public {
        vm.prank(alice);
        staking.stake(1_000e18);

        vm.prank(admin);
        staking.setMintPaused(true);

        vm.prank(alice);
        vm.expectRevert(IScapStaking.MintPaused.selector);
        staking.lockAndMintCapu(500e18, 0);
    }

    function test_MintPausedStillQuotesPendingMintAmount() public {
        vm.prank(admin);
        staking.setMintPaused(true);
        // The view keeps working so a frontend can still show the rate while minting is closed.
        assertGt(staking.pendingMintAmount(500e18), 0);
    }

    function test_UnpausingMintReopensLockAndMintCapu() public {
        vm.prank(alice);
        staking.stake(1_000e18);

        vm.startPrank(admin);
        staking.setMintPaused(true);
        staking.setMintPaused(false);
        vm.stopPrank();

        vm.prank(alice);
        uint256 minted = staking.lockAndMintCapu(500e18, 0);
        assertGt(minted, 0);
    }

    function test_MintPausedLeavesStakeAndRewardsOpen() public {
        vm.prank(admin);
        staking.setMintPaused(true);

        // Stake CAP still mints sCAP 1:1.
        vm.prank(alice);
        staking.stake(1_000e18);
        assertEq(staking.balanceOf(alice), 1_000e18);

        // Rewards still stream and can be claimed.
        cap.mint(admin, 7_000e18);
        vm.startPrank(admin);
        cap.approve(address(staking), 7_000e18);
        staking.notifyRewardAmount(7_000e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        assertGt(staking.earned(alice), 0);

        vm.prank(alice);
        uint256 claimed = staking.claim();
        assertGt(claimed, 0);
        assertEq(cap.balanceOf(alice), 9_000e18 + claimed);
    }

    function test_MintPausedLeavesUnstakeOpen() public {
        vm.prank(alice);
        staking.stake(1_000e18);

        vm.prank(admin);
        staking.setMintPaused(true);

        vm.startPrank(alice);
        staking.initiateUnstake(400e18);
        vm.warp(block.timestamp + DEFAULT_UNBONDING + 1);
        staking.finalizeUnstake();
        vm.stopPrank();

        assertEq(staking.balanceOf(alice), 600e18);
        assertEq(cap.balanceOf(alice), 9_400e18);
    }

    function test_MintPausedLeavesBurnAndUnlockOpen() public {
        vm.startPrank(alice);
        staking.stake(1_000e18);
        uint256 minted = staking.lockAndMintCapu(800e18, 0);
        vm.stopPrank();

        vm.prank(admin);
        staking.setMintPaused(true);

        // Users who already minted can always burn their CAPU and free their collateral.
        vm.prank(alice);
        uint256 unlocked = staking.burnAndUnlockScap(minted);
        assertEq(unlocked, 800e18);
        assertEq(staking.lockedScap(alice), 0);
        assertEq(staking.mintedCapuOf(alice), 0);
        assertEq(IERC20(address(capu)).balanceOf(alice), 0);
    }

    function test_MintPausedIsIndependentOfGlobalPause() public {
        vm.prank(alice);
        staking.stake(1_000e18);

        // Global pause closes both stake and mint; clearing it while mintPaused is set must keep
        // mint closed and stake open.
        vm.startPrank(admin);
        staking.setMintPaused(true);
        staking.pause();
        staking.unpause();
        vm.stopPrank();

        assertTrue(staking.mintPaused());

        vm.prank(alice);
        staking.stake(100e18);

        vm.prank(alice);
        vm.expectRevert(IScapStaking.MintPaused.selector);
        staking.lockAndMintCapu(100e18, 0);
    }
}
