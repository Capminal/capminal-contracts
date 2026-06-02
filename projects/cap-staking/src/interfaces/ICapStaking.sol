// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface ICapStaking {
    // Events
    event Staked(address indexed user, uint256 amount, uint256 lockWeeks, uint256 shares);
    event Unstaked(address indexed user, uint256 amount);
    event EmergencyUnlock(address indexed user, uint256 amount);

    // Views
    function stakeOf(address user) external view returns (uint256);
    function sharesOf(address user) external view returns (uint256);
    function totalStaked() external view returns (uint256);
    function totalShares() external view returns (uint256);
    function multiplierOf(address user) external view returns (uint256);
    function unlockTimeOf(address user) external view returns (uint256);

    // Mutations
    function stake(uint256 amount, uint256 lockWeeks) external;
    function unstake(uint256 amount) external;
    function emergencyUnlock(address user) external;
}
 

