// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IScapStaking
/// @notice Stake CAP → mint sCAP receipt; lock sCAP → mint CAPU via dynamic mint rate.
///         Burn CAPU unlocks the *original* sCAP that was locked (rate-independent).
interface IScapStaking {
    // ---------- Errors ----------
    error ZeroAmount();
    error ZeroAddress();
    error InsufficientAvailable(uint256 requested, uint256 available);
    error InsufficientLocked(uint256 requested, uint256 locked);
    error CooldownNotElapsed(uint256 readyAt);
    error NothingUnbonding();
    error RewardRateZero();
    error RewardPeriodActive();
    error MintAmountZero();
    error NonTransferable();
    error InsufficientReserves();
    error SlippageExceeded(uint256 minted, uint256 minCapuOut);

    // ---------- Events ----------
    event Staked(address indexed user, uint256 capAmount, uint256 scapMinted);
    event UnstakeInitiated(address indexed user, uint256 amount, uint256 readyAt);
    event UnstakeFinalized(address indexed user, uint256 amount);
    event ScapLocked(address indexed user, uint256 scapAmount, uint256 capuMinted, uint256 mintRate);
    event ScapUnlocked(address indexed user, uint256 capuBurned, uint256 scapUnlocked);
    event RewardAdded(uint256 amount, uint256 newRewardRate, uint256 periodFinish);
    event RewardsDurationUpdated(uint256 oldDuration, uint256 newDuration);
    event RewardClaimed(address indexed user, uint256 amount);
    event MintRateParamsUpdated(uint256 baseRate, uint256 adjustmentPower, uint256 targetSupply);
    event UnbondingDurationUpdated(uint256 oldDuration, uint256 newDuration);

    // ---------- User mutations ----------
    function stake(uint256 capAmount) external;
    function initiateUnstake(uint256 amount) external;
    function finalizeUnstake() external;
    function lockAndMintCapu(uint256 scapAmount, uint256 minCapuOut) external returns (uint256 capuMinted);
    function burnAndUnlockScap(uint256 capuAmount) external returns (uint256 scapUnlocked);
    function claim() external returns (uint256 amount);

    // ---------- Views ----------
    function availableOf(address user) external view returns (uint256);
    function lockedOf(address user) external view returns (uint256);
    function mintedCapuOf(address user) external view returns (uint256);
    function earned(address user) external view returns (uint256);
    function pendingMintAmount(uint256 scapAmount) external view returns (uint256);

    // ---------- Admin ----------
    function notifyRewardAmount(uint256 capAmount) external;
    function setRewardsDuration(uint256 newDuration) external;
    function setUnbondingDuration(uint256 newDuration) external;
    function setMintRateParams(uint256 baseRate, uint256 adjustmentPower, uint256 targetSupply) external;
    function pause() external;
    function unpause() external;
}
