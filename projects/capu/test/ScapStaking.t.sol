// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {IScapStaking} from "@capu/interfaces/IScapStaking.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ScapStakingTest is Fixture {
    function setUp() public {
        _deployStack();
    }

    function test_StakeMintsScapOneToOne() public {
        _fund(alice, 1000e18);
        vm.prank(alice);
        staking.stake(500e18);

        assertEq(staking.balanceOf(alice), 500e18);
        assertEq(cap.balanceOf(address(staking)), 500e18);
        assertEq(staking.availableOf(alice), 500e18);
        assertEq(staking.lockedOf(alice), 0);
    }

    function test_InitiateAndFinalizeUnstake() public {
        _fund(alice, 100e18);
        vm.startPrank(alice);
        staking.stake(100e18);
        staking.initiateUnstake(40e18);

        // Cooldown not elapsed
        vm.expectRevert();
        staking.finalizeUnstake();

        vm.warp(block.timestamp + DEFAULT_UNBONDING + 1);
        staking.finalizeUnstake();
        vm.stopPrank();

        assertEq(staking.balanceOf(alice), 60e18);
        assertEq(cap.balanceOf(alice), 40e18);
    }

    function test_CannotUnstakeLockedScap() public {
        _fund(alice, 1000e18);
        vm.startPrank(alice);
        staking.stake(1000e18);
        staking.lockAndMintCapu(900e18, 0); // locks 900 sCAP
        // available = 100, requesting 200 must revert
        vm.expectRevert();
        staking.initiateUnstake(200e18);
        vm.stopPrank();
    }

    function test_LockAndMintEmitsAndUpdatesAccounting() public {
        _fund(alice, 1000e18);
        vm.startPrank(alice);
        staking.stake(1000e18);

        uint256 expected = staking.pendingMintAmount(900e18);
        assertGt(expected, 0);

        uint256 minted = staking.lockAndMintCapu(900e18, 0);
        vm.stopPrank();

        assertEq(minted, expected);
        assertEq(staking.lockedScap(alice), 900e18);
        assertEq(staking.mintedCapuOf(alice), minted);
        assertEq(IERC20(address(capu)).totalSupply(), minted);
    }

    function test_BurnUnlocksOriginalScapRatio() public {
        _fund(alice, 1000e18);
        vm.startPrank(alice);
        staking.stake(1000e18);
        uint256 minted = staking.lockAndMintCapu(800e18, 0);

        // Burn half of the CAPU → should unlock half of the originally locked sCAP (400).
        // Tolerance covers the natural floor-div dust when `minted` is odd:
        //   dust = lockedScap / mintedCapu (the smallest non-divisible unit).
        uint256 unlocked = staking.burnAndUnlockScap(minted / 2);
        vm.stopPrank();

        uint256 maxDust = 800e18 / minted + 1;
        assertApproxEqAbs(unlocked, 400e18, maxDust, "half burn returns half of original lock");
        assertEq(staking.lockedScap(alice), 800e18 - unlocked);
    }

    function test_BurnUnlockIndependentOfCurrentRate() public {
        // Alice mints at supply=0 (cheapest rate).
        _fund(alice, 1000e18);
        vm.prank(alice);
        staking.stake(1000e18);
        vm.prank(alice);
        uint256 aliceMinted = staking.lockAndMintCapu(900e18, 0);

        // Bob mints later when supply is already large → rate higher, fewer CAPU per sCAP.
        _fund(bob, 10_000e18);
        vm.prank(bob);
        staking.stake(10_000e18);
        vm.prank(bob);
        staking.lockAndMintCapu(9_000e18, 0);

        // Alice burns ALL her CAPU → must get back exactly her original 900 sCAP, regardless of current rate.
        vm.prank(alice);
        uint256 unlocked = staking.burnAndUnlockScap(aliceMinted);
        assertApproxEqAbs(unlocked, 900e18, 1, "Alice always reclaims her original locked sCAP");
        assertEq(staking.lockedScap(alice), 0);
        assertEq(staking.mintedCapuOf(alice), 0);
    }

    function test_MintRespectsMinCapuOut() public {
        _fund(alice, 1000e18);
        vm.startPrank(alice);
        staking.stake(1000e18);

        uint256 expected = staking.pendingMintAmount(900e18);
        // Asking for more than achievable must revert with SlippageExceeded.
        vm.expectRevert(abi.encodeWithSelector(IScapStaking.SlippageExceeded.selector, expected, expected + 1));
        staking.lockAndMintCapu(900e18, expected + 1);

        // Exactly `expected` is fine.
        uint256 minted = staking.lockAndMintCapu(900e18, expected);
        assertEq(minted, expected);
        vm.stopPrank();
    }

    function test_RewardStreamsOverPeriod() public {
        _fund(alice, 1000e18);
        vm.prank(alice);
        staking.stake(1000e18);

        // Admin funds 700 CAP across 7 days → 100 CAP/day.
        cap.mint(admin, 700e18);
        vm.startPrank(admin);
        cap.approve(address(staking), type(uint256).max);
        staking.notifyRewardAmount(700e18);
        vm.stopPrank();

        // After 1 day, sole staker should have ~100 CAP earned.
        vm.warp(block.timestamp + 1 days);
        uint256 earned = staking.earned(alice);
        assertApproxEqRel(earned, 100e18, 0.01e18);

        // After full period, ~700 CAP earned.
        vm.warp(block.timestamp + 6 days);
        earned = staking.earned(alice);
        assertApproxEqRel(earned, 700e18, 0.01e18);

        // Claim transfers CAP.
        vm.prank(alice);
        uint256 claimed = staking.claim();
        assertApproxEqRel(claimed, 700e18, 0.01e18);
    }

    /// @notice With the 80/20 protocol cut removed, a locked staker now earns 100% of rewards.
    function test_LockedPortionGetsFullReward() public {
        _fund(alice, 1000e18);
        vm.prank(alice);
        staking.stake(1000e18);

        // Lock 500 sCAP → half of balance is locked. Should make NO difference to rewards now.
        vm.prank(alice);
        staking.lockAndMintCapu(500e18, 0);

        cap.mint(admin, 700e18);
        vm.startPrank(admin);
        cap.approve(address(staking), type(uint256).max);
        staking.notifyRewardAmount(700e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        // Sole staker, no protocol cut → full ~700 CAP regardless of locked portion.
        vm.prank(alice);
        uint256 claimed = staking.claim();
        assertApproxEqRel(claimed, 700e18, 0.01e18, "locked staker earns 100% of rewards");
    }

    /// @notice C-1 regression: sCAP is non-transferable, so the fresh-receiver reward-drain vector
    ///         is closed. Any user-to-user transfer reverts; only stake (mint) / unstake (burn) move balance.
    function test_ScapIsNonTransferable() public {
        _fund(alice, 1000e18);
        vm.startPrank(alice);
        staking.stake(1000e18);

        // Even fully-unlocked sCAP cannot be transferred.
        vm.expectRevert(IScapStaking.NonTransferable.selector);
        staking.transfer(bob, 100e18);

        // approve itself is allowed (no balance moves), but transferFrom is blocked by _update.
        staking.approve(bob, 100e18);
        vm.stopPrank();

        vm.prank(bob);
        vm.expectRevert(IScapStaking.NonTransferable.selector);
        staking.transferFrom(alice, bob, 100e18);

        // Stake/unstake still work (mint/burn).
        vm.startPrank(alice);
        staking.initiateUnstake(100e18);
        vm.warp(block.timestamp + DEFAULT_UNBONDING + 1);
        staking.finalizeUnstake();
        vm.stopPrank();
        assertEq(cap.balanceOf(alice), 100e18);
        assertEq(staking.balanceOf(alice), 900e18);
    }

    /// @notice L-1 regression: rewards notified while totalSupply()==0 are NOT stranded — they carry
    ///         over to the first staker instead of becoming dead CAP in the commingled pool.
    function test_RewardsNotifiedBeforeStakeAreNotStranded() public {
        cap.mint(admin, 700e18);
        vm.startPrank(admin);
        cap.approve(address(staking), type(uint256).max);
        staking.notifyRewardAmount(700e18); // totalSupply() == 0 at this point
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days); // a day passes with no stakers

        _fund(alice, 1000e18);
        vm.prank(alice);
        staking.stake(1000e18);

        vm.warp(block.timestamp + 6 days); // period ends

        // Sole staker collects the FULL 700 including the empty-pool day — nothing stranded.
        uint256 earned = staking.earned(alice);
        assertApproxEqRel(earned, 700e18, 0.01e18, "no reward stranded during empty-pool window");
    }

    /// @notice C-1 PoC: the historical drain required transferring sCAP to a fresh (uncheckpointed)
    ///         address and re-claiming the same streamed rewards. With non-transferable sCAP the
    ///         very first step reverts, so the drain is impossible and total payout stays bounded.
    function test_RewardDrainViaTransferIsImpossible() public {
        _fund(alice, 1000e18);
        vm.prank(alice);
        staking.stake(1000e18);

        cap.mint(admin, 700e18);
        vm.startPrank(admin);
        cap.approve(address(staking), type(uint256).max);
        staking.notifyRewardAmount(700e18);
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days);

        // Alice claims her legitimate ~700.
        vm.prank(alice);
        uint256 claimed = staking.claim();

        // The drain step — moving sCAP to a fresh wallet to re-claim — reverts.
        vm.prank(alice);
        vm.expectRevert(IScapStaking.NonTransferable.selector);
        staking.transfer(bob, 1000e18);

        // Total CAP paid out never exceeds what was streamed; contract stays solvent (>= principal).
        assertLe(claimed, 700e18 + 1);
        assertGe(cap.balanceOf(address(staking)), staking.totalSupply());
    }
}
