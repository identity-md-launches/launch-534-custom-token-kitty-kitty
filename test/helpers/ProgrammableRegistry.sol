// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Kitty} from "../../src/Kitty.sol";

/// @notice A launch registry whose answer the test chooses: the plain mapping getter the real factory exposes,
///         or one of the ways a registry can misbehave at the ABI boundary. It deploys the token so that it is
///         the token's factory, and its behaviour can be changed while the token is live.
contract ProgrammableRegistry {
    enum Mode {
        Record, // return the stored record as one ABI address word
        Revert, // revert with a reason string
        RawWord, // return `word` verbatim as one 32-byte word, whatever it holds
        Sized, // return the record padded or truncated to `returnSize` bytes
        BurnGas // burn `gasToBurn` gas before returning the record
    }

    Mode public mode;
    uint256 public word;
    uint256 public returnSize;
    uint256 public gasToBurn;
    mapping(uint64 => address) public recordOf;

    function deploy(address manager, uint64 number) external returns (Kitty) {
        return new Kitty(address(this), manager, number);
    }

    function setRecord(uint64 number, address distributor) external {
        recordOf[number] = distributor;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setWord(uint256 word_) external {
        word = word_;
    }

    function setReturnSize(uint256 size) external {
        returnSize = size;
    }

    function setGasToBurn(uint256 amount) external {
        gasToBurn = amount;
    }

    function move(Kitty token, address to, uint256 amount) external returns (bool) {
        return token.transfer(to, amount);
    }

    function distributorOf(uint64 number) external view returns (address) {
        Mode current = mode;
        if (current == Mode.Record) return recordOf[number];
        if (current == Mode.Revert) revert("registry unavailable");
        if (current == Mode.RawWord) {
            uint256 value = word;
            assembly ("memory-safe") {
                mstore(0, value)
                return(0, 32)
            }
        }
        if (current == Mode.Sized) {
            address record = recordOf[number];
            uint256 size = returnSize;
            assembly {
                let p := mload(0x40)
                mstore(p, record)
                mstore(add(p, 32), 0)
                mstore(add(p, 64), 0)
                return(p, size)
            }
        }
        uint256 start = gasleft();
        uint256 target = gasToBurn;
        while (start - gasleft() < target) {}
        return recordOf[number];
    }
}
