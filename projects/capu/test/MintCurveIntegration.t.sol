// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {Fixture} from "./helpers/Fixture.sol";
import {MintRateMath} from "@capu/libraries/MintRateMath.sol";

/// @dev Regression suite for the mint curve being priced against the supply the mint itself
///      creates, rather than the supply it starts from.
contract MintCurveIntegrationTest is Fixture {
    uint256 internal constant LOCK = 240_000_000e18;

    function setUp() public {
        _deployStack();
        _fund(alice, LOCK);
        vm.prank(alice);
        staking.stake(LOCK);
    }

    /// @dev Splitting a mint into N calls re-reads the curve N times and is therefore correctly
    ///      priced. One call must never be a cheaper way to buy the same CAPU.
    function test_OneLargeMintNeverBeatsTheSameCapitalSplitAcrossCalls() public {
        uint256 snap = vm.snapshotState();

        uint256 chunks = 240;
        uint256 dx = LOCK / chunks;
        uint256 incremental;
        for (uint256 i = 0; i < chunks; i++) {
            vm.prank(alice);
            incremental += staking.lockAndMintCapu(dx, 0);
        }

        vm.revertToState(snap);

        vm.prank(alice);
        uint256 single = staking.lockAndMintCapu(LOCK, 0);

        assertLe(single, incremental, "one call minted more CAPU than the same capital split up");
    }

    /// @dev The quote a front-end shows must be what the mint actually pays out, at every size.
    function test_QuoteMatchesExecutionAtEverySize() public {
        uint256[5] memory sizes =
            [uint256(900e18), 1_000_000e18, 20_000_000e18, 90_000_000e18, LOCK];

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 snap = vm.snapshotState();

            uint256 quoted = staking.pendingMintAmount(sizes[i]);
            vm.prank(alice);
            uint256 minted = staking.lockAndMintCapu(sizes[i], 0);

            assertEq(minted, quoted, "pendingMintAmount diverged from lockAndMintCapu");

            vm.revertToState(snap);
        }
    }

    /// @dev Golden vectors: the exact integral of the curve, computed offline at high resolution.
    ///      The on-chain result must never exceed them (rounding stays in the protocol's favour)
    ///      and must stay close enough that honest minters are not meaningfully over-charged.
    function test_MatchesTheExactIntegralWithinToleranceAndNeverExceedsIt() public view {
        uint256[5] memory sizes =
            [uint256(900e18), 1_000_000e18, 20_000_000e18, 90_000_000e18, LOCK];
        // Integral of 1/rate over the same range, base 44,040 / power 2 / target 2,725, supply 0.
        uint256[5] memory exact = [
            uint256(20435967302452316),
            22706623767339000000,
            453088501794048000000,
            1762849186278560000000,
            2727466446715263000000
        ];

        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 got = staking.pendingMintAmount(sizes[i]);
            assertLe(got, exact[i], "minted more than the exact integral");
            assertApproxEqRel(got, exact[i], 0.005e18, "more than 0.5% below the exact integral");
        }
    }

    /// @dev The anti-gaming guarantee. The exact integral of the curve is the fair price; every
    ///      call under-mints against its own sub-integral, and sub-integrals compose, so NO
    ///      splitting strategy can extract more than the exact total. Splitting can only move a
    ///      caller closer to fair, never past it.
    function test_NoSplittingStrategyExceedsTheExactIntegral(uint8 rawChunks) public {
        uint256 chunks = uint256(rawChunks) % 200 + 1; // 1..200
        uint256 exact = 2727466446715263000000; // 240M CAP from supply 0, fixture parameters

        uint256 dx = LOCK / chunks;
        uint256 total;
        for (uint256 i = 0; i < chunks; i++) {
            vm.prank(alice);
            total += staking.lockAndMintCapu(dx, 0);
        }

        assertLe(total, exact, "a split extracted more than the exact integral");
    }

    /// @dev The rate carried by ScapLocked is what downstream analytics price mints from. Now that
    ///      a mint walks the curve, the starting rate is not what the caller paid — the event must
    ///      report the effective rate actually charged.
    function test_ScapLockedReportsTheEffectiveRateNotTheStartingRate() public {
        uint256 amount = 90_000_000e18;
        uint256 expectedCapu = staking.pendingMintAmount(amount);
        uint256 effectiveRate = (amount * 1e18) / expectedCapu;

        vm.recordLogs();
        vm.prank(alice);
        staking.lockAndMintCapu(amount, 0);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("ScapLocked(address,uint256,uint256,uint256)");
        uint256 reportedRate;
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == topic) {
                (, , reportedRate) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                found = true;
            }
        }
        assertTrue(found, "ScapLocked not emitted");
        assertApproxEqRel(reportedRate, effectiveRate, 0.0001e18, "event reported a rate the caller never paid");
    }

    /// @dev Gas is bounded by capping the number of steps, which caps a single mint. An oversized
    ///      mint must fail with the library's own named error, not run out of gas or mis-price.
    function test_AMintBeyondTheStepCapRevertsWithMintTooLarge() public {
        uint256 beyondCap = 6e13 * 1e18; // the cap sits near 4.65e13 CAP at fixture parameters
        _fund(bob, beyondCap);
        vm.startPrank(bob);
        staking.stake(beyondCap);
        vm.expectRevert(MintRateMath.MintTooLarge.selector);
        staking.lockAndMintCapu(beyondCap, 0);
        vm.stopPrank();
    }

    /// @dev The step cap must never bind on anything a real user could do. At the parameters
    ///      actually deployed on Base, locking the ENTIRE CAP supply in one call still goes
    ///      through — so no reachable mint is refused, and the cap only exists to bound gas.
    function test_TheStepCapCannotBindAtProductionParameters() public view {
        uint256 minted = MintRateMath.computeMintAmountIntegrated(
            1_000_000_000e18, // entire CAP total supply, in one call
            261668616816805581951, // live CAPU supply on Base
            334_480e18,
            2e18,
            300e18
        );
        assertGt(minted, 0, "the whole CAP supply must still be mintable in a single call");
    }
}