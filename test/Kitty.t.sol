// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Kitty} from "../src/Kitty.sol";
import {LaunchFactoryMock, BrokenRegistry} from "./helpers/LaunchFactoryMock.sol";

contract KittyTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint64 constant LAUNCH = 42;
    address constant MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant SPENDER = address(0x5EED);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchFactoryMock factory;
    Kitty token;

    function setUp() public {
        factory = new LaunchFactoryMock();
        token = factory.deploy(MANAGER, LAUNCH);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
    }

    function test_metadataSupplyAndDeploymentConfiguration() public view {
        assertEq(token.name(), "Kitty");
        assertEq(token.symbol(), "KITTY");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.INITIAL_SUPPLY(), SUPPLY);
        assertEq(token.balanceOf(address(factory)), SUPPLY);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.factory(), address(factory));
        assertEq(token.poolManager(), MANAGER);
        assertEq(token.launchNumber(), LAUNCH);
        assertEq(token.rewardsDistributor(), DISTRIBUTOR);
        assertEq(token.DEAD(), DEAD);
    }

    function test_constructorMintsToActualDeployer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), address(this), SUPPLY);
        Kitty direct = new Kitty(address(factory), MANAGER, 0);
        assertEq(direct.balanceOf(address(this)), SUPPLY);
        assertEq(direct.balanceOf(address(factory)), 0);
    }

    function test_constructorRejectsZeroEndpoints() public {
        vm.expectRevert(Kitty.InvalidFactory.selector);
        new Kitty(address(0), MANAGER, LAUNCH);
        vm.expectRevert(Kitty.InvalidPoolManager.selector);
        new Kitty(address(factory), address(0), LAUNCH);
    }

    function test_ordinaryTransferDebitsGrossAndEmitsFeeThenNet() public {
        factory.move(token, ALICE, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, DEAD, 2 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 98 ether);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 100 ether));
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEAD), 2 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_taxRoundingAndConservation(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        factory.move(token, ALICE, amount);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, amount));
        uint256 fee = amount * 2 / 100;
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(BOB), amount - fee);
        assertEq(token.balanceOf(DEAD), fee);
        assertEq(token.balanceOf(address(factory)) + token.balanceOf(BOB) + token.balanceOf(DEAD), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_feeBoundaryInMinorUnits() public {
        uint256[5] memory amounts = [uint256(0), 1, 49, 50, 51];
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = amounts[i];
            factory.move(token, ALICE, amount);
            uint256 beforeBob = token.balanceOf(BOB);
            uint256 beforeDead = token.balanceOf(DEAD);
            vm.prank(ALICE);
            token.transfer(BOB, amount);
            assertEq(token.balanceOf(BOB) - beforeBob, amount - amount / 50);
            assertEq(token.balanceOf(DEAD) - beforeDead, amount / 50);
        }
    }

    function test_zeroTransferFromEmptyAccountEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(ALICE, BOB, 0);
        vm.prank(ALICE);
        assertTrue(token.transfer(BOB, 0));
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_allExemptEndpointsBothDirectionsWithTransferAndTransferFrom() public {
        address[3] memory endpoints = [address(factory), MANAGER, DISTRIBUTOR];
        for (uint256 i; i < endpoints.length; ++i) {
            address endpoint = endpoints[i];
            factory.move(token, ALICE, 400 ether);
            uint256 beforeEndpoint = token.balanceOf(endpoint);
            vm.prank(ALICE);
            token.transfer(endpoint, 100 ether);
            assertEq(token.balanceOf(endpoint), beforeEndpoint + 100 ether);
            vm.prank(endpoint);
            token.transfer(ALICE, 100 ether);
            assertEq(token.balanceOf(ALICE), 400 ether);

            vm.prank(ALICE);
            token.approve(SPENDER, 100 ether);
            vm.prank(SPENDER);
            token.transferFrom(ALICE, endpoint, 100 ether);
            assertEq(token.balanceOf(endpoint), beforeEndpoint + 100 ether);
            vm.prank(endpoint);
            token.approve(SPENDER, 100 ether);
            vm.prank(SPENDER);
            token.transferFrom(endpoint, ALICE, 100 ether);
            assertEq(token.balanceOf(ALICE), 400 ether);
            assertEq(token.balanceOf(DEAD), 0);
            vm.prank(ALICE);
            token.transfer(address(factory), 400 ether);
        }
    }

    function test_launchAllocationAndClaimsAreExact() public {
        factory.move(token, DISTRIBUTOR, SUPPLY / 10);
        factory.move(token, MANAGER, SUPPLY / 2);
        factory.move(token, ALICE, SUPPLY * 4 / 10);
        assertEq(token.balanceOf(address(factory)), 0);
        assertEq(token.balanceOf(DISTRIBUTOR), SUPPLY / 10);
        assertEq(token.balanceOf(MANAGER), SUPPLY / 2);
        assertEq(token.balanceOf(ALICE), SUPPLY * 4 / 10);
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, SUPPLY / 10);
        assertEq(token.balanceOf(BOB), SUPPLY / 10);
        vm.prank(MANAGER);
        token.transfer(BOB, 1_000 ether);
        assertEq(token.balanceOf(BOB), SUPPLY / 10 + 1_000 ether);
        vm.prank(BOB);
        token.transfer(MANAGER, 1_000 ether);
        assertEq(token.balanceOf(MANAGER), SUPPLY / 2);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_distributorIsResolvedAfterDeploymentAndTracksRegistry() public {
        factory.setDistributor(LAUNCH, address(0));
        factory.setDistributor(LAUNCH + 1, BOB);
        factory.move(token, DISTRIBUTOR, 200 ether);
        assertEq(token.rewardsDistributor(), address(0));
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
        factory.setDistributor(LAUNCH, DISTRIBUTOR);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);

        factory.setDistributor(LAUNCH, SPENDER);
        factory.move(token, DISTRIBUTOR, 100 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 198 ether);
        vm.prank(ALICE);
        token.transfer(SPENDER, 100 ether);
        assertEq(token.balanceOf(SPENDER), 100 ether);
    }

    function test_transferFromConsumesGrossAllowance() public {
        factory.move(token, ALICE, 100 ether);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(ALICE, SPENDER, 100 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(SPENDER, 100 ether));
        vm.prank(SPENDER);
        assertTrue(token.transferFrom(ALICE, BOB, 100 ether));
        assertEq(token.allowance(ALICE, SPENDER), 0);
        assertEq(token.balanceOf(BOB), 98 ether);
        assertEq(token.balanceOf(DEAD), 2 ether);
    }

    function test_infiniteAllowanceAndRevocation() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, type(uint256).max);
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 50 ether);
        assertEq(token.allowance(ALICE, SPENDER), type(uint256).max);
        vm.prank(ALICE);
        token.approve(SPENDER, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 0, 1));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 1);
    }

    function test_exemptSpenderStillPaysFeeForOrdinaryEndpoints() public {
        address[3] memory spenders = [address(factory), MANAGER, DISTRIBUTOR];
        factory.move(token, ALICE, 300 ether);
        for (uint256 i; i < spenders.length; ++i) {
            vm.prank(ALICE);
            token.approve(spenders[i], 100 ether);
            vm.prank(spenders[i]);
            token.transferFrom(ALICE, BOB, 100 ether);
        }
        assertEq(token.balanceOf(BOB), 294 ether);
        assertEq(token.balanceOf(DEAD), 6 ether);
    }

    function test_exemptionDoesNotGrantAllowance() public {
        factory.move(token, ALICE, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(factory), 0, 1)
        );
        vm.prank(address(factory));
        token.transferFrom(ALICE, address(factory), 1);
        assertEq(token.balanceOf(ALICE), 100 ether);
    }

    function test_insufficientGrossAllowanceRevertsAtomically() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 98 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, 98 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.allowance(ALICE, SPENDER), 98 ether);
    }

    function test_insufficientBalanceRestoresAllowance() public {
        factory.move(token, ALICE, 99 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 99 ether, 100 ether)
        );
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, 100 ether);
        assertEq(token.balanceOf(ALICE), 99 ether);
        assertEq(token.balanceOf(BOB), 0);
        assertEq(token.balanceOf(DEAD), 0);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
    }

    function test_maximumAmountCannotOverflowOrMoveFunds() public {
        factory.move(token, ALICE, 100 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100 ether, type(uint256).max)
        );
        vm.prank(ALICE);
        token.transfer(BOB, type(uint256).max);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_zeroAddressesRejectedEvenOnZeroAmounts() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), BOB, 0);
    }

    function test_invalidReceiverRestoresAllowance() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, 100 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(SPENDER);
        token.transferFrom(ALICE, address(0), 100 ether);
        assertEq(token.allowance(ALICE, SPENDER), 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);
        assertEq(token.balanceOf(DEAD), 0);
    }

    function test_selfTransferPaysOnlyFeeButRequiresGrossBalance() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 98 ether);
        assertEq(token.balanceOf(DEAD), 2 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 98 ether, 99 ether)
        );
        vm.prank(ALICE);
        token.transfer(ALICE, 99 ether);
    }

    function test_transferToDeadCreditsFullAmountWithoutChangingSupply() public {
        factory.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(DEAD, 100 ether);
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.balanceOf(DEAD), 100 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_deadSenderCannotSpendMoreThanGrossBalance() public {
        factory.move(token, DEAD, 99 ether);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, DEAD, 99 ether, 100 ether)
        );
        vm.prank(DEAD);
        token.transfer(ALICE, 100 ether);
    }

    function test_brokenRegistryCannotFreezeOrdinaryOrKnownExemptTransfers() public {
        for (uint256 mode; mode < 6; ++mode) {
            BrokenRegistry registry = new BrokenRegistry(mode);
            Kitty subject = new Kitty(address(registry), MANAGER, LAUNCH);
            assertEq(subject.rewardsDistributor(), address(0));
            assertTrue(subject.transfer(ALICE, 100 ether));
            assertEq(subject.balanceOf(ALICE), 98 ether);
            assertEq(subject.balanceOf(DEAD), 2 ether);
            subject.transfer(MANAGER, 100 ether);
            assertEq(subject.balanceOf(MANAGER), 100 ether);
            assertEq(registry.mode(), mode);
        }
    }

    function test_factoryWithoutCodeHasNoDistributorAndDoesNotFreezeTransfers() public {
        Kitty subject = new Kitty(address(0xFA), MANAGER, LAUNCH);
        assertEq(subject.rewardsDistributor(), address(0));
        subject.transfer(ALICE, 100 ether);
        assertEq(subject.balanceOf(ALICE), 98 ether);
    }

    function test_noPrivilegedMintFreezeOrSeizureEntrypoints() public {
        factory.move(token, ALICE, 100 ether);
        bytes[9] memory attempts = [
            abi.encodeWithSignature("mint(address,uint256)", ALICE, SUPPLY),
            abi.encodeWithSignature("initialize(address)", ALICE),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("blacklist(address)", ALICE),
            abi.encodeWithSignature("freeze(address)", ALICE),
            abi.encodeWithSignature("burnFrom(address,uint256)", ALICE, 100 ether),
            abi.encodeWithSignature("seize(address)", ALICE),
            abi.encodeWithSignature("upgradeTo(address)", ALICE),
            abi.encodeWithSignature("setFee(uint256)", 0)
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.prank(address(factory));
            (bool ok,) = address(token).call(attempts[i]);
            assertFalse(ok);
            vm.prank(BOB);
            (ok,) = address(token).call(attempts[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(ALICE), 100 ether);
        vm.prank(ALICE);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
    }

    function test_runtimeHasNoForbiddenOpcodes() public view {
        bytes memory runtime = address(token).code;
        assertLt(runtime.length, 24_576);
        for (uint256 i; i < runtime.length; ++i) {
            uint8 op = uint8(runtime[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
            } else {
                assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff);
            }
        }
    }
}
