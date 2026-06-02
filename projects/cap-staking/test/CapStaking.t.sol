// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@cap-staking/CapStaking.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1000000 * 10**18); // Mint 1M tokens
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract CapStakingTest is Test {
    CapStaking public staking;
    MockERC20 public token;
    
    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public charlie = address(0x4);

    function setUp() public {
        vm.startPrank(owner);
        token = new MockERC20("Test Token", "TEST");
        staking = new CapStaking(token, owner);
        vm.stopPrank();

        // Give tokens to test users
        token.mint(alice, 10000 * 10**18);
        token.mint(bob, 10000 * 10**18);
        token.mint(charlie, 10000 * 10**18);
    }

    // ============ Setup Tests ============

    function testCompile() public {
        assertTrue(address(staking) != address(0));
        assertTrue(address(token) != address(0));
    }


    function testInitialState() public {
        assertEq(staking.totalStaked(), 0);
        assertEq(staking.totalShares(), 0);
        assertEq(staking.stakeOf(alice), 0);
        assertEq(staking.sharesOf(alice), 0);
    }

    // ============ Stake Tests ============

    function testStake_NewPosition() public {
        uint256 amount = 1000 * 10**18;
        uint256 lockWeeks = 12;

        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        assertEq(staking.stakeOf(alice), amount);
        assertEq(staking.totalStaked(), amount);
        assertTrue(staking.sharesOf(alice) > 0);
        assertTrue(staking.unlockTimeOf(alice) > block.timestamp);
        uint256 expectedMultiplier = 100 + uint256((lockWeeks - 1) * 400) / 95;
        assertEq(staking.multiplierOf(alice), expectedMultiplier);
    }

    function testStake_AddToExisting_ShorterLock() public {
        uint256 amount1 = 1000 * 10**18;
        uint256 amount2 = 500 * 10**18;
        uint256 lockWeeks1 = 24;
        uint256 lockWeeks2 = 12; // Shorter than original

        // First stake
        vm.startPrank(alice);
        token.approve(address(staking), amount1);
        staking.stake(amount1, lockWeeks1);
        uint256 originalUnlockTime = staking.unlockTimeOf(alice);
        uint256 originalShares = staking.sharesOf(alice);
        vm.stopPrank();

        // Second stake with shorter lock
        vm.startPrank(alice);
        token.approve(address(staking), amount2);
        staking.stake(amount2, lockWeeks2);
        vm.stopPrank();

        assertEq(staking.stakeOf(alice), amount1 + amount2);
        assertEq(staking.unlockTimeOf(alice), originalUnlockTime); // Should keep original unlock time
        assertTrue(staking.sharesOf(alice) > originalShares); // Should have more shares
        uint256 expectedMultiplier1 = 100 + uint256((lockWeeks1 - 1) * 400) / 95;
        assertEq(staking.multiplierOf(alice), expectedMultiplier1); // Should keep original multiplier
    }

    function testStake_AddToExisting_LongerLock() public {
        uint256 amount1 = 1000 * 10**18;
        uint256 amount2 = 500 * 10**18;
        uint256 lockWeeks1 = 12;
        uint256 lockWeeks2 = 24; // Longer than original

        // First stake
        vm.startPrank(alice);
        token.approve(address(staking), amount1);
        staking.stake(amount1, lockWeeks1);
        uint256 originalUnlockTime = staking.unlockTimeOf(alice);
        vm.stopPrank();

        // Second stake with longer lock
        vm.startPrank(alice);
        token.approve(address(staking), amount2);
        staking.stake(amount2, lockWeeks2);
        vm.stopPrank();

        assertEq(staking.stakeOf(alice), amount1 + amount2);
        // Should extend unlock time since new lock is longer
        assertTrue(staking.unlockTimeOf(alice) > originalUnlockTime);
        uint256 expectedMultiplier2 = 100 + uint256((lockWeeks2 - 1) * 400) / 95;
        assertEq(staking.multiplierOf(alice), expectedMultiplier2); // Should use new multiplier
    }


    function testStake_MultiplierCalculation() public {
        uint256 amount = 1000 * 10**18;

        // Test 1 week (1x multiplier)
        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, 1);
        assertEq(staking.multiplierOf(alice), 100); // 1x
        vm.stopPrank();

        // Test 96 weeks (5x multiplier)
        vm.startPrank(bob);
        token.approve(address(staking), amount);
        staking.stake(amount, 96);
        assertEq(staking.multiplierOf(bob), 500); // 5x
        vm.stopPrank();

        // Test mid-point (48 weeks should be ~3x)
        vm.startPrank(charlie);
        token.approve(address(staking), amount);
        staking.stake(amount, 48);
        uint256 expectedMultiplier = 100 + uint256(47 * 400) / 95;
        assertEq(staking.multiplierOf(charlie), expectedMultiplier); // ~3x
        vm.stopPrank();
    }

    // ============ Unstake Tests ============

    function testUnstake_AfterUnlock() public {
        uint256 amount = 1000 * 10**18;
        uint256 lockWeeks = 1; // 1 week

        // Stake
        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        // Fast forward past unlock time
        vm.warp(block.timestamp + 8 days);

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(amount);

        assertEq(staking.stakeOf(alice), 0);
        assertEq(staking.sharesOf(alice), 0);
        assertEq(token.balanceOf(alice), balanceBefore + amount);
        assertEq(staking.totalStaked(), 0);
    }

    function testUnstake_Partial() public {
        uint256 amount = 1000 * 10**18;
        uint256 lockWeeks = 1;

        // Stake
        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        // Fast forward past unlock time
        vm.warp(block.timestamp + 8 days);

        uint256 unstakeAmount = amount / 2;
        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(alice);
        staking.unstake(unstakeAmount);

        assertEq(staking.stakeOf(alice), amount - unstakeAmount);
        assertTrue(staking.sharesOf(alice) > 0);
        assertEq(token.balanceOf(alice), balanceBefore + unstakeAmount);
        assertEq(staking.totalStaked(), amount - unstakeAmount);
    }

    // ============ Emergency Unlock Tests ============

    function testEmergencyUnlock_OwnerCanUnlock() public {
        uint256 amount = 1000 * 10**18;
        uint256 lockWeeks = 24;

        // Stake
        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        uint256 balanceBefore = token.balanceOf(alice);
        vm.prank(owner);
        staking.emergencyUnlock(alice);

        assertEq(staking.stakeOf(alice), 0);
        assertEq(staking.sharesOf(alice), 0);
        assertEq(token.balanceOf(alice), balanceBefore + amount);
        assertEq(staking.totalStaked(), 0);
    }

    // ============ Revert Tests ============

    function testRevert_Stake_ZeroAmount() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("ZeroAmount()"));
        staking.stake(0, 12);
        vm.stopPrank();
    }

    function testRevert_Stake_InvalidLockWeeks() public {
        vm.startPrank(alice);
        token.approve(address(staking), 1000 * 10**18);

        vm.expectRevert(abi.encodeWithSignature("InvalidLockWeeks(uint256)", 0));
        staking.stake(1000 * 10**18, 0);

        vm.expectRevert(abi.encodeWithSignature("InvalidLockWeeks(uint256)", 97));
        staking.stake(1000 * 10**18, 97);
        vm.stopPrank();
    }

    function testRevert_Unstake_StillLocked() public {
        uint256 amount = 1000 * 10**18;
        uint256 lockWeeks = 24;

        // Stake
        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        // Try to unstake before unlock time
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSignature("StillLocked(uint256)", staking.unlockTimeOf(alice)));
        staking.unstake(amount);
        vm.stopPrank();
    }

    function testRevert_Unstake_NoStake() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("NoStakePosition()"));
        staking.unstake(1000 * 10**18);
    }

    function testRevert_EmergencyUnlock_OnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        staking.emergencyUnlock(bob);
    }

    function testRevert_EmergencyUnlock_NoStake() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("NoStakePosition()"));
        staking.emergencyUnlock(alice);
    }

    // ============ View Function Tests ============

    function testViews_AccurateData() public {
        uint256 amount = 1000 * 10**18;
        uint256 lockWeeks = 12;

        // Stake
        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        // Check all view functions
        assertEq(staking.stakeOf(alice), amount);
        assertTrue(staking.sharesOf(alice) > 0);
        assertEq(staking.totalStaked(), amount);
        assertEq(staking.totalShares(), staking.sharesOf(alice));
        uint256 expectedMultiplier = 100 + uint256((lockWeeks - 1) * 400) / 95;
        assertEq(staking.multiplierOf(alice), expectedMultiplier);
        assertTrue(staking.unlockTimeOf(alice) > block.timestamp);
    }

    // ============ Fuzz Tests ============

    function testFuzz_StakeAmount(uint256 amount) public {
        vm.assume(amount > 0 && amount <= 10000 * 10**18); // Limit to available tokens
        uint256 lockWeeks = 12;

        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        assertEq(staking.stakeOf(alice), amount);
        assertTrue(staking.sharesOf(alice) > 0);
    }

    function testFuzz_LockWeeks(uint256 lockWeeks) public {
        vm.assume(lockWeeks >= 1 && lockWeeks <= 96);
        uint256 amount = 1000 * 10**18;

        vm.startPrank(alice);
        token.approve(address(staking), amount);
        staking.stake(amount, lockWeeks);
        vm.stopPrank();

        assertEq(staking.stakeOf(alice), amount);
        uint256 expectedMultiplier = 100 + uint256((lockWeeks - 1) * 400) / 95;
        assertEq(staking.multiplierOf(alice), expectedMultiplier);
    }

    // ============ Invariant Tests ============

    function testInvariant_TotalSharesMatchesSum() public {
        uint256 amount1 = 1000 * 10**18;
        uint256 amount2 = 500 * 10**18;
        uint256 lockWeeks1 = 12;
        uint256 lockWeeks2 = 24;

        // Stake from multiple users
        vm.startPrank(alice);
        token.approve(address(staking), amount1);
        staking.stake(amount1, lockWeeks1);
        vm.stopPrank();

        vm.startPrank(bob);
        token.approve(address(staking), amount2);
        staking.stake(amount2, lockWeeks2);
        vm.stopPrank();

        // Check invariant
        uint256 totalShares = staking.sharesOf(alice) + staking.sharesOf(bob);
        assertEq(staking.totalShares(), totalShares);
    }
}
 

