// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Capu} from "@capu/Capu.sol";
import {ScapStaking} from "@capu/ScapStaking.sol";
import {ICapu} from "@capu/interfaces/ICapu.sol";

import {MockTaxERC20} from "./helpers/MockTaxERC20.sol";

/// @notice H-1 regression: the real CAP token ("Capminal by Virtuals") is a fee-on-transfer token.
///         ScapStaking must mint sCAP and size the reward stream by the amount ACTUALLY received,
///         never the amount requested, so a transfer tax can never over-issue sCAP / over-promise
///         rewards and break the 1:1 CAP backing (which would block the last unstakers).
contract FeeOnTransferTest is Test {
    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");

    MockTaxERC20 internal cap;
    Capu internal capu;
    ScapStaking internal staking;

    uint256 internal constant TAX_BPS = 500; // 5%

    function setUp() public {
        cap = new MockTaxERC20("Capminal", "CAP", TAX_BPS);

        Capu capuImpl = new Capu();
        bytes memory capuInit = abi.encodeCall(Capu.initialize, (admin, 1 days));
        capu = Capu(address(new ERC1967Proxy(address(capuImpl), capuInit)));

        ScapStaking stakingImpl = new ScapStaking();
        bytes memory stakingInit = abi.encodeCall(
            ScapStaking.initialize, (admin, cap, ICapu(address(capu)), 7 days, 7 days, 44_040e18, 2e18, 2_725e18)
        );
        staking = ScapStaking(address(new ERC1967Proxy(address(stakingImpl), stakingInit)));

        bytes32 minterRole = capu.MINTER_BURNER_ROLE();
        vm.prank(admin);
        capu.grantRole(minterRole, address(staking));
    }

    function test_StakeMintsScapEqualToReceivedNotRequested() public {
        cap.mint(alice, 1000e18);
        vm.startPrank(alice);
        cap.approve(address(staking), type(uint256).max);
        staking.stake(1000e18);
        vm.stopPrank();

        // 5% tax → contract actually receives 950; sCAP minted must equal 950, not 1000.
        uint256 received = 1000e18 - (1000e18 * TAX_BPS) / 10_000;
        assertEq(cap.balanceOf(address(staking)), received, "contract holds taxed amount");
        assertEq(staking.balanceOf(alice), received, "sCAP == received, not requested");
        // Invariant: principal fully backed.
        assertGe(cap.balanceOf(address(staking)), staking.totalSupply());
    }

    function test_FullExitStaysSolventUnderTax() public {
        cap.mint(alice, 1000e18);
        vm.startPrank(alice);
        cap.approve(address(staking), type(uint256).max);
        staking.stake(1000e18);

        uint256 scap = staking.balanceOf(alice);
        staking.initiateUnstake(scap);
        vm.warp(block.timestamp + 7 days + 1);
        staking.finalizeUnstake();
        vm.stopPrank();

        // Contract fully drained of principal, no leftover owed, solvency invariant holds.
        assertEq(staking.totalSupply(), 0);
        assertGe(cap.balanceOf(address(staking)), staking.totalSupply());
    }

    function test_NotifyRewardSizesStreamByReceived() public {
        // Stake first so totalSupply > 0.
        cap.mint(alice, 1000e18);
        vm.startPrank(alice);
        cap.approve(address(staking), type(uint256).max);
        staking.stake(1000e18);
        vm.stopPrank();

        cap.mint(admin, 700e18);
        vm.startPrank(admin);
        cap.approve(address(staking), type(uint256).max);
        staking.notifyRewardAmount(700e18); // contract receives 665 after 5% tax
        vm.stopPrank();

        vm.warp(block.timestamp + 7 days + 1);

        // Reward stream is sized by the 665 actually received, so claim never exceeds it and the
        // contract stays solvent.
        uint256 earned = staking.earned(alice);
        uint256 receivedReward = 700e18 - (700e18 * TAX_BPS) / 10_000;
        assertApproxEqRel(earned, receivedReward, 0.01e18, "stream sized by received reward");

        vm.prank(alice);
        staking.claim();
        assertGe(cap.balanceOf(address(staking)), staking.totalSupply(), "solvent after claim");
    }
}
