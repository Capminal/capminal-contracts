// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/*
   ███████╗ ██████╗ █████╗ ██████╗
   ██╔════╝██╔════╝██╔══██╗██╔══██╗
   ███████╗██║     ███████║██████╔╝
   ╚════██║██║     ██╔══██║██╔═══╝
   ███████║╚██████╗██║  ██║██║
   ╚══════╝ ╚═════╝╚═╝  ╚═╝╚═╝
        C A P M I N A L
       Staked CAP receipt
*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IScapStaking} from "@capu/interfaces/IScapStaking.sol";
import {ICapu} from "@capu/interfaces/ICapu.sol";
import {MintRateMath} from "@capu/libraries/MintRateMath.sol";

/// @title ScapStaking — sCAP receipt + CAPU mint vault
/// @notice Capminal's capital-asset staking layer. Stake CAP → receive sCAP 1:1 → optionally
///         lock sCAP to mint CAPU via dynamic mint rate. Burn CAPU unlocks the *original*
///         amount of sCAP that was locked (rate-independent — protects early minters).
/// @dev    UUPS upgradeable. Single reward stream in CAP using Synthetix-style streaming math.
///         100% of streamed CAP rewards go to sCAP stakers (no protocol cut).
///         sCAP is NON-TRANSFERABLE: it is only minted on stake and burned on unstake. This keeps
///         the reward accounting sound (every balance change is checkpointed by stake/unstake) and
///         removes the need to checkpoint rewards on ERC20 transfers.
contract ScapStaking is
    IScapStaking,
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ---------- Constants ----------
    uint256 public constant SCALE = 1e18;
    uint256 public constant MIN_REWARD_DURATION = 1 days;

    // ---------- Immutable-ish (set in initializer) ----------
    IERC20 public capToken;
    ICapu public capu;

    // ---------- Unbonding ----------
    struct UnbondingInfo {
        uint128 amount;
        uint64 readyAt;
    }

    mapping(address => UnbondingInfo) internal _unbondings;
    uint256 public unbondingDuration; // default 7 days

    // ---------- Lock / mint accounting ----------
    mapping(address => uint256) public lockedScap;
    mapping(address => uint256) public mintedCapuOf;

    // ---------- Mint rate params ----------
    uint256 public baseMintRate; // 1e18 scaled — sCAP needed per 1 CAPU at supply=0
    uint256 public adjustmentPower; // 1e18 scaled
    uint256 public targetCapuSupply; // 1e18 scaled

    // ---------- Reward streaming (Synthetix-style, single token = CAP) ----------
    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate; // CAP per second (1e18 scaled)
    uint256 public lastUpdateTime;
    uint256 public accRewardPerShare; // Q1e18, denom = totalSupply (sCAP)

    mapping(address => uint256) public userRewardPerSharePaid;
    mapping(address => uint256) public rewards; // earned but unclaimed

    /// @dev Reserved storage slots for future upgrades.
    uint256[42] private __gap;

    // ---------- Initializer ----------
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        IERC20 _capToken,
        ICapu _capu,
        uint256 _unbondingDuration,
        uint256 _rewardsDuration,
        uint256 _baseMintRate,
        uint256 _adjustmentPower,
        uint256 _targetCapuSupply
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        if (address(_capToken) == address(0)) revert ZeroAddress();
        if (address(_capu) == address(0)) revert ZeroAddress();
        if (_rewardsDuration < MIN_REWARD_DURATION) revert RewardRateZero();

        __ERC20_init("Staked CAP", "sCAP");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        capToken = _capToken;
        capu = _capu;
        unbondingDuration = _unbondingDuration;
        rewardsDuration = _rewardsDuration;
        baseMintRate = _baseMintRate;
        adjustmentPower = _adjustmentPower;
        targetCapuSupply = _targetCapuSupply;

        emit MintRateParamsUpdated(_baseMintRate, _adjustmentPower, _targetCapuSupply);
        emit UnbondingDurationUpdated(0, _unbondingDuration);
        emit RewardsDurationUpdated(0, _rewardsDuration);
    }

    // ---------- Reward bookkeeping (Synthetix pattern) ----------
    function lastTimeRewardApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish;
    }

    function _currentAccRewardPerShare() internal view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return accRewardPerShare;
        uint256 elapsed = lastTimeRewardApplicable() - lastUpdateTime;
        if (elapsed == 0 || rewardRate == 0) return accRewardPerShare;
        return accRewardPerShare + Math.mulDiv(elapsed * rewardRate, SCALE, supply);
    }

    /// @dev Updates global accumulator and snapshots the user's pending reward. 100% of accrued
    ///      rewards go to the staker. When totalSupply()==0 the accumulator does not advance, so we
    ///      also leave lastUpdateTime untouched — that way the reward for an empty-pool window is
    ///      not silently stranded but is carried over to the next staker (no dead CAP).
    modifier updateReward(address user) {
        uint256 acc = _currentAccRewardPerShare();
        accRewardPerShare = acc;
        if (totalSupply() > 0) {
            lastUpdateTime = lastTimeRewardApplicable();
        }

        if (user != address(0)) {
            uint256 bal = balanceOf(user);
            if (bal > 0) {
                rewards[user] += Math.mulDiv(bal, acc - userRewardPerSharePaid[user], SCALE);
            }
            userRewardPerSharePaid[user] = acc;
        }
        _;
    }

    /// @dev Reverts if the contract no longer holds enough CAP to back every staker's principal
    ///      (principal == sCAP totalSupply). Defense-in-depth: turns any accounting/funding
    ///      shortfall into a clean revert instead of a silent first-come-first-served drain.
    function _requireSolvent() internal view {
        if (capToken.balanceOf(address(this)) < totalSupply()) revert InsufficientReserves();
    }

    // ---------- Staking ----------
    function stake(uint256 capAmount) external nonReentrant whenNotPaused updateReward(msg.sender) {
        if (capAmount == 0) revert ZeroAmount();

        // Measure the amount actually received so a fee-on-transfer / taxed CAP token can never
        // cause sCAP to be over-issued relative to the CAP held (which would break solvency).
        uint256 balBefore = capToken.balanceOf(address(this));
        capToken.safeTransferFrom(msg.sender, address(this), capAmount);
        uint256 received = capToken.balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();

        _mint(msg.sender, received); // sCAP 1:1 with CAP actually received

        emit Staked(msg.sender, received, received);
    }

    /// @notice Move sCAP from available balance into the unbonding queue. Locked sCAP
    ///         (sCAP collateralizing minted CAPU) cannot be unstaked until burned.
    /// @dev    NOT gated by whenNotPaused so users can always begin exiting their principal.
    ///         NOTE: calling again while an unbonding is already pending re-arms readyAt for the
    ///         entire combined balance (single-slot queue). Front-ends MUST warn users that a new
    ///         initiateUnstake delays the already-cooling amount by a full unbonding period.
    function initiateUnstake(uint256 amount) external nonReentrant updateReward(msg.sender) {
        if (amount == 0) revert ZeroAmount();
        uint256 available = balanceOf(msg.sender) - lockedScap[msg.sender];
        if (amount > available) revert InsufficientAvailable(amount, available);

        _burn(msg.sender, amount);

        UnbondingInfo storage info = _unbondings[msg.sender];
        uint256 newAmount = uint256(info.amount) + amount;
        uint256 readyAt = block.timestamp + unbondingDuration;
        info.amount = SafeCast.toUint128(newAmount);
        info.readyAt = SafeCast.toUint64(readyAt);

        emit UnstakeInitiated(msg.sender, amount, readyAt);
    }

    function finalizeUnstake() external nonReentrant {
        UnbondingInfo storage info = _unbondings[msg.sender];
        uint256 amount = uint256(info.amount);
        if (amount == 0) revert NothingUnbonding();
        if (block.timestamp < info.readyAt) revert CooldownNotElapsed(info.readyAt);

        info.amount = 0;
        info.readyAt = 0;

        capToken.safeTransfer(msg.sender, amount);

        _requireSolvent();
        emit UnstakeFinalized(msg.sender, amount);
    }

    // ---------- Lock + mint CAPU ----------
    /// @param scapAmount sCAP to lock as collateral.
    /// @param minCapuOut slippage guard — revert if fewer than this many CAPU would be minted.
    ///        The mint rate depends on the *current* global CAPU supply, which other txs can move
    ///        in the same block; minCapuOut protects callers from an unfavourable rate.
    function lockAndMintCapu(uint256 scapAmount, uint256 minCapuOut)
        external
        nonReentrant
        whenNotPaused
        updateReward(msg.sender)
        returns (uint256 capuMinted)
    {
        if (scapAmount == 0) revert ZeroAmount();
        uint256 available = balanceOf(msg.sender) - lockedScap[msg.sender];
        if (scapAmount > available) revert InsufficientAvailable(scapAmount, available);

        uint256 currentCapuSupply = IERC20(address(capu)).totalSupply();
        capuMinted = MintRateMath.computeMintAmountIntegrated(
            scapAmount, currentCapuSupply, baseMintRate, adjustmentPower, targetCapuSupply
        );
        if (capuMinted == 0) revert MintAmountZero();
        if (capuMinted < minCapuOut) revert SlippageExceeded(capuMinted, minCapuOut);

        lockedScap[msg.sender] += scapAmount;
        mintedCapuOf[msg.sender] += capuMinted;

        capu.mint(msg.sender, capuMinted);

        // The mint walks the curve, so the rate at the start is not what the caller paid. Report the
        // effective rate actually charged (sCAP per CAPU) so indexers price mints correctly.
        emit ScapLocked(msg.sender, scapAmount, capuMinted, Math.mulDiv(scapAmount, SCALE, capuMinted));
    }

    /// @notice Burn CAPU and unlock the *original* sCAP that was locked when this CAPU was minted.
    /// @dev    Unlocked amount = lockedScap[user] × (capuAmount / mintedCapuOf[user]).
    ///         Independent of current mint rate — early minters never lose their original collateral.
    ///         NOT gated by whenNotPaused so users can always free their collateral and exit.
    function burnAndUnlockScap(uint256 capuAmount)
        external
        nonReentrant
        updateReward(msg.sender)
        returns (uint256 scapUnlocked)
    {
        if (capuAmount == 0) revert ZeroAmount();
        uint256 minted = mintedCapuOf[msg.sender];
        if (capuAmount > minted) revert InsufficientLocked(capuAmount, minted);

        uint256 locked = lockedScap[msg.sender];
        // Floor-division: the last burner sweeps the dust by burning the remaining minted balance.
        scapUnlocked = Math.mulDiv(locked, capuAmount, minted);

        mintedCapuOf[msg.sender] = minted - capuAmount;
        lockedScap[msg.sender] = locked - scapUnlocked;

        capu.burn(msg.sender, capuAmount);

        emit ScapUnlocked(msg.sender, capuAmount, scapUnlocked);
    }

    // ---------- Reward claim ----------
    /// @dev NOT gated by whenNotPaused so users can always pull earned rewards.
    function claim() external nonReentrant updateReward(msg.sender) returns (uint256 amount) {
        amount = rewards[msg.sender];
        if (amount == 0) return 0;
        rewards[msg.sender] = 0;
        capToken.safeTransfer(msg.sender, amount);
        _requireSolvent();
        emit RewardClaimed(msg.sender, amount);
    }

    // ---------- ERC20 transfers ----------
    /// @dev sCAP is non-transferable: only mint (from == 0) and burn (to == 0) are allowed.
    ///      Blocking transfers keeps the Synthetix reward accounting sound, since every balance
    ///      change then flows through stake/initiateUnstake which checkpoint rewards first.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) revert NonTransferable();
        super._update(from, to, value);
    }

    // ---------- Views ----------
    function availableOf(address user) external view returns (uint256) {
        return balanceOf(user) - lockedScap[user];
    }

    function lockedOf(address user) external view returns (uint256) {
        return lockedScap[user];
    }

    function earned(address user) external view returns (uint256) {
        uint256 acc = _currentAccRewardPerShare();
        uint256 bal = balanceOf(user);
        if (bal == 0) return rewards[user];
        return rewards[user] + Math.mulDiv(bal, acc - userRewardPerSharePaid[user], SCALE);
    }

    function pendingMintAmount(uint256 scapAmount) external view returns (uint256) {
        return MintRateMath.computeMintAmountIntegrated(
            scapAmount, IERC20(address(capu)).totalSupply(), baseMintRate, adjustmentPower, targetCapuSupply
        );
    }

    function unbondingOf(address user) external view returns (uint256 amount, uint256 readyAt) {
        UnbondingInfo memory info = _unbondings[user];
        return (info.amount, info.readyAt);
    }

    // ---------- Admin ----------
    function notifyRewardAmount(uint256 capAmount) external onlyRole(DEFAULT_ADMIN_ROLE) updateReward(address(0)) {
        if (capAmount == 0) revert ZeroAmount();

        // Use the amount actually received (fee-on-transfer safe) to size the stream so the
        // reward rate can never promise more CAP than the contract was funded with.
        uint256 balBefore = capToken.balanceOf(address(this));
        capToken.safeTransferFrom(msg.sender, address(this), capAmount);
        uint256 received = capToken.balanceOf(address(this)) - balBefore;

        uint256 newRate;
        if (block.timestamp >= periodFinish) {
            newRate = received / rewardsDuration;
        } else {
            uint256 leftover = (periodFinish - block.timestamp) * rewardRate;
            newRate = (received + leftover) / rewardsDuration;
        }
        if (newRate == 0) revert RewardRateZero();

        rewardRate = newRate;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;

        emit RewardAdded(received, newRate, periodFinish);
    }

    function setRewardsDuration(uint256 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (block.timestamp < periodFinish) revert RewardPeriodActive();
        if (newDuration < MIN_REWARD_DURATION) revert RewardRateZero();
        uint256 old = rewardsDuration;
        rewardsDuration = newDuration;
        emit RewardsDurationUpdated(old, newDuration);
    }

    function setUnbondingDuration(uint256 newDuration) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 old = unbondingDuration;
        unbondingDuration = newDuration;
        emit UnbondingDurationUpdated(old, newDuration);
    }

    function setMintRateParams(uint256 _baseRate, uint256 _power, uint256 _target)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // The new parameters must be able to price a mint at the CURRENT supply. A target far below
        // the live supply puts the curve past its arithmetic ceiling, which would take minting and
        // quoting down for every user until an admin noticed. Reverting the whole call is cheaper
        // than discovering it afterwards, and costs one exp() on a rarely-used admin path.
        MintRateMath.computeMintRate(IERC20(address(capu)).totalSupply(), _baseRate, _power, _target);

        baseMintRate = _baseRate;
        adjustmentPower = _power;
        targetCapuSupply = _target;
        emit MintRateParamsUpdated(_baseRate, _power, _target);
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
