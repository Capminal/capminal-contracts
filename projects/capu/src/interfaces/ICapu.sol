// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title ICapu
/// @notice Capminal Compute Unit (CAPU) — non-ERC20 surface. Holders see an ERC20 directly;
///         this interface declares the staking + mint/burn extensions on top.
///         Built-in stake / initiateUnstake / unstake so the off-chain Capminal LLM Gateway
///         indexer can credit AI usage via the `Staked` / `Unstaked` events.
interface ICapu {
    // ---------- Errors ----------
    error ZeroAmount();
    error InsufficientStaked(uint256 requested, uint256 available);
    error CooldownNotElapsed(uint256 readyAt);
    error CooldownAlreadyActive();
    error NothingInCooldown();

    // ---------- Events ----------
    event Staked(address indexed user, uint256 amount, uint256 totalStaked);
    event UnstakeInitiated(address indexed user, uint256 amount, uint256 readyAt);
    event Unstaked(address indexed user, uint256 amount);
    event CooldownDurationUpdated(uint256 oldDuration, uint256 newDuration);

    // ---------- Mint / burn (MINTER_BURNER_ROLE) ----------
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;

    // ---------- Staking ----------
    function stake(uint256 amount) external;
    function initiateUnstake(uint256 amount) external;
    function unstake() external;

    // ---------- Views ----------
    function stakedOf(address user) external view returns (uint256);
    function cooldownOf(address user) external view returns (uint256 amount, uint256 readyAt);
    function totalStakedCapu() external view returns (uint256);
    function cooldownDuration() external view returns (uint256);
}
