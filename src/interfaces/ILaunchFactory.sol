// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The launch registry resolves the distributor after the token is deployed.
interface ILaunchFactory {
    function distributorOf(uint64 launchNumber) external view returns (address);
}
