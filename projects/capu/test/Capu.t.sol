// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Fixture} from "./helpers/Fixture.sol";
import {ICapu} from "@capu/interfaces/ICapu.sol";

contract CapuTest is Fixture {
    function setUp() public {
        _deployStack();
    }

    function test_MintBurnRequiresRole() public {
        vm.expectRevert();
        capu.mint(alice, 1e18);
    }

    function test_StakeMovesBalanceAndEmitsEvent() public {
        // Mint some CAPU to alice directly via the staking proxy (it has the role).
        vm.prank(address(staking));
        capu.mint(alice, 100e18);

        vm.startPrank(alice);
        vm.expectEmit(true, false, false, true);
        emit ICapu.Staked(alice, 40e18, 40e18);
        capu.stake(40e18);
        vm.stopPrank();

        assertEq(capu.stakedOf(alice), 40e18);
        assertEq(capu.balanceOf(alice), 60e18);
        assertEq(capu.balanceOf(address(capu)), 40e18);
        assertEq(capu.totalStakedCapu(), 40e18);
    }

    function test_UnstakeFlowRespectsCooldown() public {
        vm.prank(address(staking));
        capu.mint(alice, 50e18);

        vm.startPrank(alice);
        capu.stake(50e18);
        capu.initiateUnstake(50e18);

        // Cooldown not elapsed → revert
        vm.expectRevert();
        capu.unstake();

        vm.warp(block.timestamp + DEFAULT_CAPU_COOLDOWN + 1);
        capu.unstake();
        vm.stopPrank();

        assertEq(capu.balanceOf(alice), 50e18);
        assertEq(capu.stakedOf(alice), 0);
        assertEq(capu.totalStakedCapu(), 0);
    }

    function test_PauseBlocksStake() public {
        vm.prank(address(staking));
        capu.mint(alice, 10e18);

        vm.prank(admin);
        capu.pause();

        vm.expectRevert();
        vm.prank(alice);
        capu.stake(1e18);
    }
}
