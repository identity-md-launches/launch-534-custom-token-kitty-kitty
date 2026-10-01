// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kitty} from "../../src/Kitty.sol";

contract LaunchFactoryMock {
    mapping(uint64 => address) public distributorOf;

    function deploy(address manager, uint64 number) external returns (Kitty) {
        return new Kitty(address(this), manager, number);
    }

    function setDistributor(uint64 number, address distributor) external {
        distributorOf[number] = distributor;
    }

    function move(Kitty token, address to, uint256 amount) external {
        require(token.transfer(to, amount));
    }
}

/// @dev Registry behavior deliberately violates the interface for failure-path tests.
contract BrokenRegistry {
    uint256 public mode;

    constructor(uint256 mode_) {
        mode = mode_;
    }

    fallback() external {
        uint256 behavior = mode;
        if (behavior == 0) revert("unavailable");
        assembly ("memory-safe") {
            switch behavior
            case 1 {
                mstore(0, 1)
                return(0, 1)
            }
            case 2 {
                mstore(0, not(0))
                return(0, 32)
            }
            case 3 {
                for {} 1 {} {}
            }
            case 4 {
                mstore(0, 1)
                mstore(32, 2)
                return(0, 64)
            }
            case 5 {
                sstore(0, 99)
                return(0, 32)
            }
        }
    }
}
