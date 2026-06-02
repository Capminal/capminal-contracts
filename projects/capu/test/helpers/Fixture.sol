// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Capu} from "@capu/Capu.sol";
import {ScapStaking} from "@capu/ScapStaking.sol";
import {ICapu} from "@capu/interfaces/ICapu.sol";

import {MockERC20} from "./MockERC20.sol";

abstract contract Fixture is Test {
    // Capminal mainnet calibration: 30-day payback at CAP ≈ $0.0006812.
    //   baseMintRate     = 30 / 0.0006812 ≈ 44,040 CAP per CAPU
    //   targetCapuSupply ≈ 240M / (2 × 44,040) ≈ 2,725 CAPU  (≈ 80% × 300M CAP locked at target)
    uint256 internal constant DEFAULT_UNBONDING = 7 days;
    uint256 internal constant DEFAULT_REWARDS_DURATION = 7 days;
    uint256 internal constant DEFAULT_CAPU_COOLDOWN = 1 days;
    uint256 internal constant DEFAULT_BASE_RATE = 44_040e18;
    uint256 internal constant DEFAULT_ADJ_POWER = 2e18;
    uint256 internal constant DEFAULT_TARGET_SUPPLY = 2_725e18;

    address internal admin = makeAddr("admin");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal cap;
    Capu internal capu;
    ScapStaking internal staking;

    function _deployStack() internal {
        cap = new MockERC20("Capminal", "CAP");

        // Capu proxy
        Capu capuImpl = new Capu();
        bytes memory capuInit = abi.encodeCall(Capu.initialize, (admin, DEFAULT_CAPU_COOLDOWN));
        capu = Capu(address(new ERC1967Proxy(address(capuImpl), capuInit)));

        // ScapStaking proxy
        ScapStaking stakingImpl = new ScapStaking();
        bytes memory stakingInit = abi.encodeCall(
            ScapStaking.initialize,
            (
                admin,
                cap,
                ICapu(address(capu)),
                DEFAULT_UNBONDING,
                DEFAULT_REWARDS_DURATION,
                DEFAULT_BASE_RATE,
                DEFAULT_ADJ_POWER,
                DEFAULT_TARGET_SUPPLY
            )
        );
        staking = ScapStaking(address(new ERC1967Proxy(address(stakingImpl), stakingInit)));

        // Wire: ScapStaking is the only minter/burner of CAPU.
        bytes32 minterRole = capu.MINTER_BURNER_ROLE();
        vm.prank(admin);
        capu.grantRole(minterRole, address(staking));
    }

    function _fund(address user, uint256 amount) internal {
        cap.mint(user, amount);
        vm.prank(user);
        cap.approve(address(staking), type(uint256).max);
    }
}
