// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ILaunchFactory} from "./interfaces/ILaunchFactory.sol";

/// @notice Fixed-supply KITTY with a 2% dead-address fee on ordinary transfers.
/// @dev Exemptions depend on transfer endpoints, including for transferFrom.
contract Kitty is ERC20 {
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable poolManager;
    uint64 public immutable launchNumber;

    error InvalidFactory();
    error InvalidPoolManager();

    /// @param factory_ Factory exposing distributorOf(uint64) for this launch.
    /// @param poolManager_ Pool manager whose incoming and outgoing transfers are exempt.
    /// @param launchNumber_ Registry key for the launch's rewards distributor.
    constructor(address factory_, address poolManager_, uint64 launchNumber_) ERC20("Kitty", "KITTY") {
        if (factory_ == address(0)) revert InvalidFactory();
        if (poolManager_ == address(0)) revert InvalidPoolManager();
        factory = factory_;
        poolManager = poolManager_;
        launchNumber = launchNumber_;
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice Current distributor, or zero if the registry has no usable answer.
    /// @dev A bounded STATICCALL prevents a broken registry from blocking holder transfers.
    ///      Only one ABI word is copied, so oversized return data cannot exhaust caller memory.
    function rewardsDistributor() public view returns (address) {
        bytes memory input = abi.encodeCall(ILaunchFactory.distributorOf, (launchNumber));
        address registry = factory;
        bool ok;
        uint256 size;
        uint256 result;
        assembly ("memory-safe") {
            mstore(0, 0)
            ok := staticcall(30000, registry, add(input, 32), mload(input), 0, 32)
            size := returndatasize()
            result := mload(0)
        }
        if (!ok || size != 32 || result > type(uint160).max) return address(0);
        // The range check above ensures the returned ABI word fits in an address.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(result));
    }

    function _update(address from, address to, uint256 value) internal override {
        // The only mint is the constructor. There is no external mint or burn function.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }

        // Check the gross debit before splitting, including self-transfers and transfers to DEAD.
        uint256 balance = balanceOf(from);
        if (balance < value) revert ERC20InsufficientBalance(from, balance, value);

        // floor(value * 2 / 100), without multiplication overflow.
        uint256 fee = value / 50;
        if (fee != 0 && !_isExempt(from, to)) {
            super._update(from, DEAD, fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }

    function _isExempt(address from, address to) private view returns (bool) {
        if (from == factory || to == factory || from == poolManager || to == poolManager) return true;
        address distributor = rewardsDistributor();
        return distributor != address(0) && (from == distributor || to == distributor);
    }
}
