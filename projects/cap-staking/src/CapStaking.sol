// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@cap-staking/interfaces/ICapStaking.sol";

/// @title Cap Staking Contract
/// @notice Allows users to stake CAP tokens with lock periods for share rewards
/// @dev Implements lock mechanism with multipliers (1x-5x) for 1W-96W periods
contract CapStaking is Ownable, ReentrancyGuard, ICapStaking {
    using SafeERC20 for IERC20;

    // ============ Constants ============
    uint256 public constant MIN_LOCK_WEEKS = 1;
    uint256 public constant MAX_LOCK_WEEKS = 96;
    uint256 public constant WEEKS = 7 days;
    uint256 public constant MULTIPLIER_BASE = 100; // 1x = 100

    // ============ State Variables ============
    IERC20 public immutable stakingToken;

    struct StakePosition {
        uint256 amount;      // Total CAP staked
        uint256 shares;      // Calculated shares (amount × multiplier)
        uint256 lockWeeks;   // Lock duration in weeks
        uint256 unlockTime;  // When tokens can be unstaked
    }

    mapping(address => StakePosition) public stakes;
    uint256 public totalStakedAmount;
    uint256 public totalSharesAmount;

    // ============ Custom Errors ============
    error ZeroAmount();
    error InvalidLockWeeks(uint256 lockWeeks);
    error StillLocked(uint256 unlockTime);
    error InsufficientStake(uint256 requested, uint256 available);
    error NoStakePosition();

    // ============ Constructor ============
    constructor(IERC20 _stakingToken, address _owner) Ownable(_owner) {
        stakingToken = _stakingToken;
    }

    // ============ External Functions ============

    /// @notice Stake CAP tokens with a lock period
    /// @param amount Amount of CAP tokens to stake
    /// @param lockWeeks Lock duration in weeks (1-96)
    /// @dev Reverts if user already has position with incompatible lock period
    function stake(uint256 amount, uint256 lockWeeks) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (lockWeeks < MIN_LOCK_WEEKS || lockWeeks > MAX_LOCK_WEEKS) {
            revert InvalidLockWeeks(lockWeeks);
        }

        // Transfer tokens from user
        stakingToken.safeTransferFrom(msg.sender, address(this), amount);

        StakePosition storage position = stakes[msg.sender];
        
        // Store old shares before updating
        uint256 oldShares = position.shares;
        
        if (position.amount == 0) {
            // New position
            uint256 shares = _calculateShares(amount, lockWeeks);
            uint256 unlockTime = block.timestamp + lockWeeks * WEEKS;
            
            position.amount = amount;
            position.shares = shares;
            position.lockWeeks = lockWeeks;
            position.unlockTime = unlockTime;
        } else {
            // Existing position
            if (lockWeeks < position.lockWeeks) {
                // Keep old lock duration, recalculate shares based on total amount
                position.amount += amount;
                position.shares = _calculateShares(position.amount, position.lockWeeks);
            } else {
                // Update lock duration and recalculate shares
                position.amount += amount;
                position.lockWeeks = lockWeeks;
                position.shares = _calculateShares(position.amount, lockWeeks);
                // Use max to ensure user doesn't get locked longer than intended
                // If new unlock time is earlier than old, keep the old (longer) unlock time
                uint256 newUnlockTime = block.timestamp + lockWeeks * WEEKS;
                position.unlockTime = Math.max(position.unlockTime, newUnlockTime);
            }
        }

        // Update totals
        totalStakedAmount += amount;
        // Update total shares: subtract old shares, add new shares
        totalSharesAmount = totalSharesAmount - oldShares + position.shares;

        emit Staked(msg.sender, amount, lockWeeks, position.shares);
    }

    /// @notice Unstake CAP tokens after lock period expires
    /// @param amount Amount of CAP tokens to unstake
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        
        StakePosition storage position = stakes[msg.sender];
        if (position.amount == 0) revert NoStakePosition();
        if (block.timestamp < position.unlockTime) {
            revert StillLocked(position.unlockTime);
        }
        if (amount > position.amount) {
            revert InsufficientStake(amount, position.amount);
        }

        // Calculate shares to remove proportionally
        uint256 sharesToRemove = Math.mulDiv(amount, position.shares, position.amount);

        // Update position
        position.amount -= amount;
        position.shares -= sharesToRemove;

        // Update totals
        totalStakedAmount -= amount;
        totalSharesAmount -= sharesToRemove;

        // If position is empty, delete it
        if (position.amount == 0) {
            delete stakes[msg.sender];
        }

        // Transfer tokens to user
        stakingToken.safeTransfer(msg.sender, amount);

        emit Unstaked(msg.sender, amount);
    }

    /// @notice Emergency unlock for any user (owner only)
    /// @param user Address of user to emergency unlock
    function emergencyUnlock(address user) external onlyOwner {
        StakePosition storage position = stakes[user];
        if (position.amount == 0) revert NoStakePosition();

        uint256 amount = position.amount;
        uint256 shares = position.shares;

        // Update totals
        totalStakedAmount -= amount;
        totalSharesAmount -= shares;

        // Delete position
        delete stakes[user];

        // Transfer tokens to user
        stakingToken.safeTransfer(user, amount);

        emit EmergencyUnlock(user, amount);
    }

    // ============ View Functions ============

    /// @notice Get staked amount for a user
    /// @param user Address of the user
    /// @return Amount of CAP tokens staked
    function stakeOf(address user) external view returns (uint256) {
        return stakes[user].amount;
    }

    /// @notice Get shares for a user
    /// @param user Address of the user
    /// @return Number of shares held
    function sharesOf(address user) external view returns (uint256) {
        return stakes[user].shares;
    }

    /// @notice Get total staked amount across all users
    /// @return Total amount of CAP tokens staked
    function totalStaked() external view returns (uint256) {
        return totalStakedAmount;
    }

    /// @notice Get total shares across all users
    /// @return Total number of shares
    function totalShares() external view returns (uint256) {
        return totalSharesAmount;
    }

    /// @notice Get multiplier for a user based on their lock period
    /// @param user Address of the user
    /// @return Multiplier (100 = 1x, 500 = 5x)
    function multiplierOf(address user) external view returns (uint256) {
        return _calculateMultiplier(stakes[user].lockWeeks);
    }

    /// @notice Get unlock time for a user
    /// @param user Address of the user
    /// @return Timestamp when tokens can be unstaked
    function unlockTimeOf(address user) external view returns (uint256) {
        return stakes[user].unlockTime;
    }

    // ============ Internal Functions ============

    /// @notice Calculate multiplier based on lock weeks
    /// @param lockWeeks Number of weeks to lock
    /// @return Multiplier (100-500) linearly scaled from 1W-96W
    function _calculateMultiplier(uint256 lockWeeks) internal pure returns (uint256) {
        if (lockWeeks == 0) return 0;
        // Linear scaling: 1W = 100 (1x), 96W = 500 (5x)
        // Safe subtraction: lockWeeks >= 1, so lockWeeks - 1 is safe
        uint256 adjustedWeeks = lockWeeks - 1;
        if (adjustedWeeks == 0) {
            return 100; // 1 week = 1x multiplier
        }
        return 100 + Math.mulDiv(adjustedWeeks, 400, 95);
    }

    /// @notice Calculate shares based on amount and lock weeks
    /// @param amount Amount of tokens
    /// @param lockWeeks Number of weeks to lock
    /// @return Number of shares
    function _calculateShares(uint256 amount, uint256 lockWeeks) internal pure returns (uint256) {
        uint256 multiplier = _calculateMultiplier(lockWeeks);
        return Math.mulDiv(amount, multiplier, MULTIPLIER_BASE);
    }
}
 

