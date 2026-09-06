// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UD60x18, ud, exp, unwrap} from "@prb/math/UD60x18.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title MintRateMath
/// @notice Dynamic CAPU mint rate formula:
///         mintRate = baseRate * exp(adjustmentPower * (currentSupply / targetSupply)^3)
///
///         At supply = 0            → mintRate = baseRate        (cheapest mint)
///         At supply = targetSupply → mintRate = baseRate * e^p  (~7.4× at p=2)
///         At supply >> targetSupply → mintRate explodes (mint effectively disabled)
///
///         A mint is priced by integrating that curve over the supply the mint itself creates
///         (`computeMintAmountIntegrated`), NOT by dividing by a single rate read up front — the
///         latter would let one large call buy the whole amount at the price of its first unit.
library MintRateMath {
    error TargetSupplyZero();
    error BaseRateZero();
    error ScapAmountZero();
    error ExponentTooLarge();
    error MintAmountZero();
    error MintTooLarge();

    /// @dev PRBMath UD60x18.exp reverts above this input.
    uint256 internal constant MAX_EXP_INPUT = 133_084258667509499440;

    /// @dev A stepped mint advances supply by at most `targetSupply / STEPS_PER_TARGET` per step,
    ///      which bounds the pricing error against the true integral to roughly one step.
    uint256 internal constant STEPS_PER_TARGET = 64;

    /// @dev Hard bound on loop iterations, so gas stays bounded. It also caps how far one call can
    ///      move supply, to `MAX_STEPS / STEPS_PER_TARGET` = 2× targetSupply of CAPU. A mint beyond
    ///      that must be split, which costs the caller nothing: every call re-reads the curve, so
    ///      the split pays the same total.
    uint256 internal constant MAX_STEPS = 128;

    /// @notice Compute the mint rate at a given CAPU supply.
    /// @param currentSupply     current CAPU total supply (1e18)
    /// @param baseRate          base mint rate, in sCAP-per-CAPU (1e18)
    /// @param adjustmentPower   exponent coefficient (1e18)
    /// @param targetSupply      target CAPU supply (1e18)
    /// @dev   Parameters are set per deployment and retuned live via `setMintRateParams`; read them
    ///        from the deployed contract rather than assuming any particular calibration here.
    /// @return mintRate         sCAP required to mint 1 CAPU (1e18)
    function computeMintRate(uint256 currentSupply, uint256 baseRate, uint256 adjustmentPower, uint256 targetSupply)
        internal
        pure
        returns (uint256 mintRate)
    {
        if (targetSupply == 0) revert TargetSupplyZero();
        if (baseRate == 0) revert BaseRateZero();

        // ratio = currentSupply / targetSupply       (UD60x18)
        UD60x18 ratio = ud(currentSupply).div(ud(targetSupply));

        // ratioCubed = ratio^3                       (UD60x18)
        UD60x18 ratioCubed = ratio.mul(ratio).mul(ratio);

        // exponent = adjustmentPower * ratio^3       (UD60x18)
        UD60x18 exponent = ud(adjustmentPower).mul(ratioCubed);

        // Bail out before PRBMath reverts so callers can surface a clean error.
        if (unwrap(exponent) > MAX_EXP_INPUT) revert ExponentTooLarge();

        // multiplier = e^exponent                    (UD60x18)
        UD60x18 multiplier = exp(exponent);

        // The exponent guard above is not sufficient on its own: `baseRate * multiplier` overflows
        // PRBMath's mulDiv18 at a LOWER supply than `exp` itself fails, so without this check the
        // curve's upper limit surfaces as a raw PRBMath_MulDiv18_Overflow rather than a named error.
        // `multiplier >= 1e18` always (the exponent is non-negative), so the bound below fits in a
        // uint256 and is exact.
        if (baseRate > Math.mulDiv(type(uint256).max, 1e18, unwrap(multiplier))) revert ExponentTooLarge();

        // mintRate = baseRate * multiplier           (UD60x18)
        mintRate = unwrap(ud(baseRate).mul(multiplier));
    }

    /// @notice Compute CAPU received when locking `scapAmount` sCAP, pricing the mint against the
    ///         supply it creates rather than the supply it starts from.
    /// @dev    Reading the rate once and applying it linearly to the whole amount would let a
    ///         caller who submits a large mint as one call pay the rate of the first unit for every
    ///         unit. This walks the curve instead: each step advances supply by at most
    ///         `targetSupply / STEPS_PER_TARGET` and re-reads the rate, which is the numerical
    ///         integration the curve calibration assumes.
    ///
    ///         Reverts `MintTooLarge` if the mint cannot be covered in `MAX_STEPS` steps. Splitting
    ///         such a mint across calls yields the same total, since every call re-reads the curve.
    function computeMintAmountIntegrated(
        uint256 scapAmount,
        uint256 currentSupply,
        uint256 baseRate,
        uint256 adjustmentPower,
        uint256 targetSupply
    ) internal pure returns (uint256 capuAmount) {
        if (scapAmount == 0) revert ScapAmountZero();
        if (targetSupply == 0) revert TargetSupplyZero();

        // CAPU minted per step. Degenerate targets below STEPS_PER_TARGET wei collapse to one step
        // rather than looping without progress.
        uint256 stepSize = targetSupply / STEPS_PER_TARGET;
        if (stepSize == 0) stepSize = targetSupply;

        uint256 remaining = scapAmount;
        uint256 supply = currentSupply;

        for (uint256 i = 0; i < MAX_STEPS; ++i) {
            if (remaining == 0) break;

            uint256 rateLo = computeMintRate(supply, baseRate, adjustmentPower, targetSupply);

            uint256 stepCapu = stepSize;

            // Never plan a step larger than `remaining` could buy at the cheapest rate it will see.
            uint256 affordable = unwrap(ud(remaining).div(ud(rateLo)));
            if (affordable == 0) {
                // What is left cannot buy a single wei of CAPU. Absorb it as dust rather than
                // reverting, matching the floor-division behaviour of the rate formula.
                remaining = 0;
                break;
            }
            if (affordable < stepCapu) stepCapu = affordable;

            uint256 rateHi = computeMintRate(supply + stepCapu, baseRate, adjustmentPower, targetSupply);

            // Trapezoid rule. `computeMintRate` is convex in supply, so the trapezoid over-states the
            // sCAP the step really costs — rounding stays in the protocol's favour — while converging
            // quadratically in step size instead of linearly. Written as lo + (hi - lo)/2 because
            // lo + hi can overflow at extreme rates; rateHi >= rateLo since the curve is monotonic.
            uint256 avgRate = rateLo + (rateHi - rateLo) / 2;

            uint256 stepScap = unwrap(ud(stepCapu).mul(ud(avgRate)));
            if (stepScap > remaining) stepScap = remaining;
            stepCapu = unwrap(ud(stepScap).div(ud(avgRate)));

            supply += stepCapu;
            capuAmount += stepCapu;
            remaining -= stepScap;
        }

        if (remaining > 0) revert MintTooLarge();
        if (capuAmount == 0) revert MintAmountZero();
    }
}
