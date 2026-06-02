// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
   ██████╗ █████╗ ██████╗ ██╗   ██╗
  ██╔════╝██╔══██╗██╔══██╗██║   ██║
  ██║     ███████║██████╔╝██║   ██║
  ██║     ██╔══██║██╔═══╝ ██║   ██║
  ╚██████╗██║  ██║██║     ╚██████╔╝
   ╚═════╝╚═╝  ╚═╝╚═╝      ╚═════╝
        C A P M I N A L
     Compute Unit  ($1/day)
*/

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ICapu} from "@capu/interfaces/ICapu.sol";

/// @title Capu — Capminal Compute Unit (CAPU)
/// @notice ERC20 + built-in staking. Mint/burn restricted to MINTER_BURNER_ROLE (held by ScapStaking).
///         Users stake CAPU to receive AI Credit at $1/CAPU/day on the Capminal LLM Gateway.
///         AI Credit accounting is off-chain: the gateway indexes `Staked` / `Unstaked` events.
/// @dev    UUPS upgradeable. DEFAULT_ADMIN_ROLE controls upgrades, role grants, pause, and config.
contract Capu is
    ICapu,
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    // ---------- Roles ----------
    bytes32 public constant MINTER_BURNER_ROLE = keccak256("MINTER_BURNER_ROLE");

    // ---------- State ----------
    struct StakedInfo {
        uint128 amountStaked;
        uint128 cooldownAmount;
        uint64 cooldownReadyAt;
    }

    mapping(address => StakedInfo) internal _stakedInfos;
    uint256 public totalStakedCapu;
    uint256 public cooldownDuration;

    /// @dev Reserved storage slots for future upgrades (do not shrink).
    uint256[47] private __gap;

    // ---------- Initializer ----------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, uint256 initialCooldownDuration) external initializer {
        if (admin == address(0)) revert ZeroAmount(); // reuse error; admin must be set

        __ERC20_init("Capminal Compute Unit", "CAPU");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        cooldownDuration = initialCooldownDuration;
        emit CooldownDurationUpdated(0, initialCooldownDuration);
    }

    // ---------- Mint / burn ----------
    function mint(address to, uint256 amount) external onlyRole(MINTER_BURNER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(MINTER_BURNER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }

    // ---------- Staking ----------
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();

        _transfer(msg.sender, address(this), amount);

        StakedInfo storage info = _stakedInfos[msg.sender];
        uint256 newStaked = uint256(info.amountStaked) + amount;
        info.amountStaked = SafeCast.toUint128(newStaked);
        totalStakedCapu += amount;

        emit Staked(msg.sender, amount, newStaked);
    }

    /// @notice Move `amount` of staked CAPU into cooldown. Calling while a cooldown is
    ///         already active extends the ready-at timestamp for the *entire combined* balance —
    ///         matching the DIEM reference contract's behavior.
    /// @dev    NOT gated by whenNotPaused so users can always begin exiting their staked CAPU.
    ///         WARNING (single-slot cooldown): a second initiateUnstake re-arms readyAt for the
    ///         whole pending amount, re-locking any portion that had already finished cooling down
    ///         for a full extra cooldown period. Front-ends MUST warn users to finalize a ready
    ///         cooldown via unstake() before initiating a new one. (Self-inflicted only; bounded by
    ///         one cooldown — no third party can affect another user's queue.)
    function initiateUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();

        StakedInfo storage info = _stakedInfos[msg.sender];
        uint256 staked = uint256(info.amountStaked);
        if (amount > staked) revert InsufficientStaked(amount, staked);

        uint256 newStaked = staked - amount;
        uint256 newCooldown = uint256(info.cooldownAmount) + amount;
        uint256 readyAt = block.timestamp + cooldownDuration;

        info.amountStaked = SafeCast.toUint128(newStaked);
        info.cooldownAmount = SafeCast.toUint128(newCooldown);
        info.cooldownReadyAt = SafeCast.toUint64(readyAt);

        emit UnstakeInitiated(msg.sender, amount, readyAt);
    }

    function unstake() external nonReentrant {
        StakedInfo storage info = _stakedInfos[msg.sender];
        uint256 amount = uint256(info.cooldownAmount);
        if (amount == 0) revert NothingInCooldown();
        if (block.timestamp < info.cooldownReadyAt) revert CooldownNotElapsed(info.cooldownReadyAt);

        info.cooldownAmount = 0;
        info.cooldownReadyAt = 0;
        totalStakedCapu -= amount;

        _transfer(address(this), msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    // ---------- Views ----------
    function stakedOf(address user) external view returns (uint256) {
        return _stakedInfos[user].amountStaked;
    }

    function cooldownOf(address user) external view returns (uint256 amount, uint256 readyAt) {
        StakedInfo memory info = _stakedInfos[user];
        return (info.cooldownAmount, info.cooldownReadyAt);
    }

    // ---------- Admin ----------
    function setCooldownDuration(uint256 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = cooldownDuration;
        cooldownDuration = newDuration;
        emit CooldownDurationUpdated(old, newDuration);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ---------- UUPS ----------
    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
