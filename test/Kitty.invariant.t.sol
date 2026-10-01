// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Kitty} from "../src/Kitty.sol";
import {LaunchFactoryMock} from "./helpers/LaunchFactoryMock.sol";

contract KittyHandler is Test {
    Kitty public immutable token;
    address[] public actors;
    uint256 public expectedDeadBalance;
    address private constant SPENDER = address(0x5EED);

    constructor(Kitty token_, address factory, address manager, address distributor) {
        token = token_;
        actors.push(factory);
        actors.push(manager);
        actors.push(distributor);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCAFE));
    }

    function move(uint256 fromSeed, uint256 toSeed, uint256 amountSeed, bool delegated) external {
        address from = actors[fromSeed % actors.length];
        address to = toSeed % (actors.length + 1) == actors.length ? token.DEAD() : actors[toSeed % (actors.length + 1)];
        uint256 amount = bound(amountSeed, 0, token.balanceOf(from));
        uint256 beforeFrom = token.balanceOf(from);
        uint256 beforeTo = token.balanceOf(to);
        bool exempt = from == actors[0] || to == actors[0] || from == actors[1] || to == actors[1] || from == actors[2]
            || to == actors[2];
        uint256 fee = exempt ? 0 : (amount * 2) / 100;

        if (delegated) {
            vm.prank(from);
            token.approve(SPENDER, amount);
            vm.prank(SPENDER);
            assertTrue(token.transferFrom(from, to, amount));
            assertEq(token.allowance(from, SPENDER), 0);
        } else {
            vm.prank(from);
            assertTrue(token.transfer(to, amount));
        }

        expectedDeadBalance += to == token.DEAD() ? amount : fee;
        if (from == to) {
            assertEq(token.balanceOf(from), beforeFrom - fee);
        } else {
            assertEq(token.balanceOf(from), beforeFrom - amount);
            assertEq(token.balanceOf(to), beforeTo + (to == token.DEAD() ? amount : amount - fee));
        }
    }

    function trackedBalanceSum() external view returns (uint256 sum) {
        sum = token.balanceOf(token.DEAD());
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
    }
}

contract KittyInvariantTest is Test {
    Kitty private token;
    KittyHandler private handler;

    function setUp() public {
        LaunchFactoryMock factory = new LaunchFactoryMock();
        address manager = address(0x9001);
        address distributor = address(0xD157);
        token = factory.deploy(manager, 42);
        factory.setDistributor(42, distributor);
        handler = new KittyHandler(token, address(factory), manager, distributor);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = KittyHandler.move.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyBalancesAndFeesAreConserved() public view {
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(handler.trackedBalanceSum(), token.totalSupply());
        assertEq(token.balanceOf(token.DEAD()), handler.expectedDeadBalance());
    }
}
