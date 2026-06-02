// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {UD60x18, ud, exp, unwrap} from "@prb/math/UD60x18.sol";

/// @title MintRateMath
/// @notice Dynamic CAPU mint rate formula:
///         mintRate = baseRate * exp(adjustmentPower * (currentSupply / targetSupply)^3)
///         capuOut  = scapAmount / mintRate
///
///         At supply = 0           → mintRate = baseRate         (cheapest mint)
///         At supply = targetSupply → mintRate = baseRate * e^p   (~7.4× at p=2)
///         At supply >> targetSupply → mintRate explodes (mint effectively disabled)
library MintRateMath {
    error TargetSupplyZero();
    error BaseRateZero();
    error ScapAmountZero();
    error ExponentTooLarge();
    error MintAmountZero();

    /// @dev PRBMath UD60x18.exp reverts above this input.
    uint256 internal constant MAX_EXP_INPUT = 133_084258667509499440;

    /// @notice Compute the mint rate at a given CAPU supply.
    /// @param currentSupply     current CAPU total supply (1e18)
    /// @param baseRate          base mint rate, in sCAP-per-CAPU (1e18, default 44_040e18)
    /// @param adjustmentPower   exponent coefficient (1e18, default 2e18)
    /// @param targetSupply      target CAPU supply (1e18, default 2_725e18)
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

        // mintRate = baseRate * multiplier           (UD60x18)
        mintRate = unwrap(ud(baseRate).mul(multiplier));
    }

    /// @notice Compute CAPU received when locking `scapAmount` sCAP.
    /// @dev    capuOut = scapAmount / mintRate
    function computeMintAmount(
        uint256 scapAmount,
        uint256 currentSupply,
        uint256 baseRate,
        uint256 adjustmentPower,
        uint256 targetSupply
    ) internal pure returns (uint256 capuAmount) {
        if (scapAmount == 0) revert ScapAmountZero();
        uint256 mintRate = computeMintRate(currentSupply, baseRate, adjustmentPower, targetSupply);
        capuAmount = unwrap(ud(scapAmount).div(ud(mintRate)));
        if (capuAmount == 0) revert MintAmountZero();
    }
}
