// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Kitty} from "../src/Kitty.sol";
import {ProgrammableRegistry} from "./helpers/ProgrammableRegistry.sol";

/// @notice Inputs the implementation did not necessarily plan for: the registry answering in every wrong shape,
///         the registry gas budget, a claim starved of gas, rounding algebra over the whole amount range, split
///         and chained transfers, and recipients that are precompiles, contracts or the token itself.
contract KittyEdgeTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint64 constant LAUNCH = 7;
    address constant MANAGER = address(0x9001);
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    address constant CAROL = address(0xCA201);
    address constant SPENDER = address(0x5EED);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ProgrammableRegistry registry;
    Kitty token;

    function setUp() public {
        registry = new ProgrammableRegistry();
        token = registry.deploy(MANAGER, LAUNCH);
        registry.setRecord(LAUNCH, DISTRIBUTOR);
    }

    // ----------------------------------------------------------------- rounding algebra over the full range

    /// @dev Stated without recomputing the division: the fee is the largest whole number of fiftieths that fits,
    ///      and the fee plus what arrives is exactly what left.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeIsTwoPercentRoundedDownAndNothingIsLost(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        registry.move(token, ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        uint256 fee = token.balanceOf(DEAD);
        uint256 received = token.balanceOf(BOB);
        assertEq(received + fee, amount, "fee plus net is not the gross");
        assertLe(fee * 50, amount, "fee above two percent");
        assertLt(amount, fee * 50 + 50, "fee below two percent by a whole unit or more");
        assertEq(token.balanceOf(ALICE), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Splitting a transfer in two never pays more fee than one transfer, and saves at most one unit.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_splittingATransferSavesAtMostOneUnitOfFee(uint256 rawX, uint256 rawY) public {
        uint256 x = bound(rawX, 0, SUPPLY / 4);
        uint256 y = bound(rawY, 0, SUPPLY / 4);
        registry.move(token, ALICE, x + y);
        registry.move(token, CAROL, x + y);

        vm.startPrank(ALICE);
        token.transfer(BOB, x);
        token.transfer(BOB, y);
        vm.stopPrank();
        uint256 feeSplit = token.balanceOf(DEAD);

        vm.prank(CAROL);
        token.transfer(BOB, x + y);
        uint256 feeWhole = token.balanceOf(DEAD) - feeSplit;

        assertLe(feeSplit, feeWhole, "splitting paid more than a single transfer");
        assertLe(feeWhole, feeSplit + 1, "splitting saved more than one unit");
        assertEq(token.balanceOf(BOB) + token.balanceOf(DEAD), 2 * (x + y));
    }

    /// @dev Two ordinary hops compound: the second hop is taxed on the net of the first.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_twoHopsCompoundTheFee(uint256 rawAmount) public {
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        registry.move(token, ALICE, amount);
        vm.prank(ALICE);
        token.transfer(BOB, amount);
        uint256 firstFee = token.balanceOf(DEAD);
        uint256 bobHolds = token.balanceOf(BOB);
        vm.prank(BOB);
        token.transfer(CAROL, bobHolds);
        uint256 secondFee = token.balanceOf(DEAD) - firstFee;
        uint256 arrived = token.balanceOf(CAROL);

        assertGe(arrived, (amount * 2401) / 2500, "two hops kept less than 96.04 percent");
        assertLe(arrived, (amount * 2401) / 2500 + 2, "two hops kept more than 96.04 percent plus rounding");
        assertLe(secondFee, firstFee, "the second hop paid more than the first");
        assertEq(arrived + firstFee + secondFee, amount);
        assertEq(token.balanceOf(ALICE) + token.balanceOf(BOB), 0);
    }

    // ----------------------------------------------------------------- exemptions over the full range

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exemptEndpointsMoveWholeAmountsEitherWay(
        uint256 rawAmount,
        uint8 endpointSeed,
        bool outbound,
        bool delegated
    ) public {
        address[3] memory endpoints = [address(registry), MANAGER, DISTRIBUTOR];
        address endpoint = endpoints[endpointSeed % 3];
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        address from = outbound ? endpoint : ALICE;
        address to = outbound ? ALICE : endpoint;
        if (from != address(registry)) registry.move(token, from, amount);
        uint256 fromBefore = token.balanceOf(from);
        uint256 toBefore = token.balanceOf(to);

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

        assertEq(token.balanceOf(from), fromBefore - amount, "exempt sender debited the wrong amount");
        assertEq(token.balanceOf(to), toBefore + amount, "exempt transfer arrived short");
        assertEq(token.balanceOf(DEAD), 0, "an exempt transfer paid a fee");
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// @dev Any recipient at all: precompiles, the token itself, the test contract, the sender, the dead
    ///      address, the launch endpoints. Only the three endpoints are exempt; everything else pays.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_anyRecipientPaysTheFeeUnlessItIsALaunchEndpoint(address to, uint256 rawAmount) public {
        if (to == address(0)) to = address(1);
        uint256 amount = bound(rawAmount, 0, SUPPLY);
        registry.move(token, ALICE, amount);
        uint256 toBefore = token.balanceOf(to);
        uint256 aliceBefore = token.balanceOf(ALICE);
        uint256 deadBefore = token.balanceOf(DEAD);

        vm.prank(ALICE);
        assertTrue(token.transfer(to, amount));

        bool exempt = to == address(registry) || to == MANAGER || to == DISTRIBUTOR;
        uint256 deadDelta = token.balanceOf(DEAD) - deadBefore;
        uint256 fee = deadDelta;
        if (exempt) {
            assertEq(deadDelta, 0, "an exempt recipient paid a fee");
        } else if (to != DEAD) {
            assertLe(fee * 50, amount, "fee above two percent");
            assertLt(amount, fee * 50 + 50, "fee below two percent");
        }

        if (to == ALICE) {
            assertEq(token.balanceOf(ALICE), aliceBefore - fee, "self-transfer did not cost exactly the fee");
        } else if (to == DEAD) {
            assertEq(token.balanceOf(DEAD), deadBefore + amount, "a burn to dead arrived short");
            assertEq(token.balanceOf(ALICE), aliceBefore - amount);
        } else {
            assertEq(token.balanceOf(to), toBefore + amount - fee, "recipient did not get the net");
            assertEq(token.balanceOf(ALICE), aliceBefore - amount);
            assertEq(token.balanceOf(DEAD), deadBefore + fee);
        }
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_exemptSelfTransferIsFreeAndOrdinarySelfTransferIsNot() public {
        registry.move(token, MANAGER, 100 ether);
        registry.move(token, DISTRIBUTOR, 100 ether);
        registry.move(token, ALICE, 100 ether);
        vm.prank(MANAGER);
        token.transfer(MANAGER, 100 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(DISTRIBUTOR, 100 ether);
        vm.prank(address(registry));
        token.transfer(address(registry), SUPPLY - 300 ether);
        assertEq(token.balanceOf(MANAGER), 100 ether);
        assertEq(token.balanceOf(DISTRIBUTOR), 100 ether);
        assertEq(token.balanceOf(address(registry)), SUPPLY - 300 ether);
        assertEq(token.balanceOf(DEAD), 0);
        vm.prank(ALICE);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 98 ether);
        assertEq(token.balanceOf(DEAD), 2 ether);
    }

    // ----------------------------------------------------------------- allowances at the boundary

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_transferFromFailsAtomicallyBeyondAllowanceOrBalance(uint256 rawAllowance, uint256 rawAmount)
        public
    {
        uint256 allowance = bound(rawAllowance, 0, 200 ether);
        uint256 amount = bound(rawAmount, 0, 200 ether);
        registry.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.approve(SPENDER, allowance);

        bool allowed = allowance >= amount;
        bool funded = amount <= 100 ether;
        if (!allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, SPENDER, allowance, amount)
            );
        } else if (!funded) {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 100 ether, amount)
            );
        }
        vm.prank(SPENDER);
        token.transferFrom(ALICE, BOB, amount);

        if (allowed && funded) {
            assertEq(token.allowance(ALICE, SPENDER), allowance - amount, "allowance not spent gross");
            assertEq(token.balanceOf(ALICE), 100 ether - amount);
            assertEq(token.balanceOf(BOB) + token.balanceOf(DEAD), amount);
            assertLe(token.balanceOf(DEAD) * 50, amount);
        } else {
            assertEq(token.allowance(ALICE, SPENDER), allowance, "a failed transferFrom changed the allowance");
            assertEq(token.balanceOf(ALICE), 100 ether);
            assertEq(token.balanceOf(BOB), 0);
            assertEq(token.balanceOf(DEAD), 0);
        }
    }

    // ----------------------------------------------------------------- the registry answering in every shape

    /// @dev One raw word comes back. It is an address only if it is a canonical one; anything with high bits set
    ///      is refused rather than truncated, so a corrupt registry cannot name an unintended exempt address.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_registryWordIsOnlyAcceptedWhenCanonical(uint256 word) public {
        registry.setMode(ProgrammableRegistry.Mode.RawWord);
        registry.setWord(word);
        address expected = word <= type(uint160).max ? address(uint160(word)) : address(0);
        assertEq(token.rewardsDistributor(), expected, "non-canonical word decoded as an address");

        registry.move(token, ALICE, 100 ether);
        address to = expected == address(0) ? BOB : expected;
        uint256 toBefore = token.balanceOf(to);
        vm.prank(ALICE);
        token.transfer(to, 100 ether);
        if (expected == address(0)) {
            assertEq(token.balanceOf(DEAD), 2 ether, "no distributor resolved, yet no fee was taken");
            assertEq(token.balanceOf(BOB), 98 ether);
        } else if (expected == ALICE) {
            assertEq(token.balanceOf(ALICE), 100 ether, "exempt self-transfer cost something");
        } else {
            assertEq(token.balanceOf(to), toBefore + 100 ether, "resolved distributor was taxed");
            assertEq(token.balanceOf(ALICE), 0);
        }
    }

    function test_registryWordBoundaries() public {
        registry.setMode(ProgrammableRegistry.Mode.RawWord);
        uint256 max160 = uint256(type(uint160).max);
        uint256[5] memory words = [
            max160,
            max160 + 1,
            uint256(1) << 255,
            type(uint256).max,
            uint256(uint160(DISTRIBUTOR)) | (uint256(1) << 160)
        ];
        address[5] memory expected = [address(type(uint160).max), address(0), address(0), address(0), address(0)];
        for (uint256 i; i < words.length; ++i) {
            registry.setWord(words[i]);
            assertEq(token.rewardsDistributor(), expected[i]);
        }
        registry.setWord(uint256(uint160(DISTRIBUTOR)));
        assertEq(token.rewardsDistributor(), DISTRIBUTOR);
        registry.setWord(0);
        assertEq(token.rewardsDistributor(), address(0));
    }

    function test_registryAnswerMustBeExactlyOneWord() public {
        registry.setMode(ProgrammableRegistry.Mode.Sized);
        uint256[7] memory sizes = [uint256(0), 1, 31, 32, 33, 64, 96];
        for (uint256 i; i < sizes.length; ++i) {
            registry.setReturnSize(sizes[i]);
            address expected = sizes[i] == 32 ? DISTRIBUTOR : address(0);
            assertEq(token.rewardsDistributor(), expected, "return size handling");
            registry.move(token, DISTRIBUTOR, 100 ether);
            uint256 bobBefore = token.balanceOf(BOB);
            vm.prank(DISTRIBUTOR);
            token.transfer(BOB, 100 ether);
            assertEq(token.balanceOf(BOB) - bobBefore, expected == address(0) ? 98 ether : 100 ether);
        }
    }

    /// @dev The registry call is capped at 30,000 gas. A registry well under the cap resolves; one over it does
    ///      not, and the transfer still completes with the fee rather than reverting.
    function test_registryGasBudgetIsBoundedAndNeverBlocksTransfers() public {
        registry.setMode(ProgrammableRegistry.Mode.BurnGas);
        registry.setGasToBurn(20_000);
        assertEq(token.rewardsDistributor(), DISTRIBUTOR, "a registry under the budget did not resolve");
        registry.move(token, DISTRIBUTOR, 200 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 100 ether);

        registry.setGasToBurn(40_000);
        assertEq(token.rewardsDistributor(), address(0), "a registry over the budget resolved");
        vm.prank(DISTRIBUTOR);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 198 ether, "distributor transfer with a dead registry was not taxed");
        assertEq(token.balanceOf(DEAD), 2 ether);
        registry.move(token, ALICE, 100 ether);
        vm.prank(ALICE);
        token.transfer(CAROL, 100 ether);
        assertEq(token.balanceOf(CAROL), 98 ether, "ordinary transfer blocked by an expensive registry");
    }

    /// @dev A claim called with too little gas must revert whole, never slip past the registry lookup and pay
    ///      the fee out of the distributor. Covers every gas limit up to well above what the claim needs.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_gasStarvedClaimRevertsWholeOrDeliversWhole(uint256 rawGas) public {
        uint256 gas = bound(rawGas, 0, 150_000);
        registry.move(token, DISTRIBUTOR, 100 ether);
        vm.prank(DISTRIBUTOR);
        (bool ok, bytes memory ret) =
            address(token).call{gas: gas}(abi.encodeWithSelector(token.transfer.selector, BOB, 100 ether));
        if (ok) {
            assertTrue(abi.decode(ret, (bool)));
            assertEq(token.balanceOf(BOB), 100 ether, "a starved claim paid the fee");
            assertEq(token.balanceOf(DISTRIBUTOR), 0);
        } else {
            assertEq(token.balanceOf(BOB), 0, "a reverted claim moved tokens");
            assertEq(token.balanceOf(DISTRIBUTOR), 100 ether);
        }
        assertEq(token.balanceOf(DEAD), 0, "a claim paid a fee under gas pressure");
    }

    function test_registryOutageMidLifeTaxesClaimsAndRecovers() public {
        registry.move(token, DISTRIBUTOR, 300 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 100 ether);

        registry.setMode(ProgrammableRegistry.Mode.Revert);
        assertEq(token.rewardsDistributor(), address(0));
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 198 ether, "a claim during an outage was not taxed");
        registry.move(token, MANAGER, 50 ether);
        vm.prank(MANAGER);
        token.transfer(ALICE, 50 ether);
        assertEq(token.balanceOf(ALICE), 248 ether, "manager exemption depended on the registry");

        registry.setMode(ProgrammableRegistry.Mode.Record);
        vm.prank(DISTRIBUTOR);
        token.transfer(ALICE, 100 ether);
        assertEq(token.balanceOf(ALICE), 348 ether, "exemption did not recover with the registry");
        assertEq(token.balanceOf(DEAD), 2 ether);
    }

    /// @dev The record can point at anyone, including an ordinary holder, the dead address or the factory
    ///      itself. Whatever it names is exempt, and nothing else changes.
    function test_recordMayNameAnyAddressAndOnlyThatAddressGainsExemption() public {
        registry.setRecord(LAUNCH, ALICE);
        registry.move(token, ALICE, 100 ether);
        registry.move(token, BOB, 100 ether);
        vm.prank(ALICE);
        token.transfer(CAROL, 100 ether);
        assertEq(token.balanceOf(CAROL), 100 ether, "named holder was taxed");
        vm.prank(BOB);
        token.transfer(CAROL, 100 ether);
        assertEq(token.balanceOf(CAROL), 198 ether, "unnamed holder was not taxed");
        registry.move(token, DISTRIBUTOR, 100 ether);
        vm.prank(DISTRIBUTOR);
        token.transfer(CAROL, 100 ether);
        assertEq(token.balanceOf(CAROL), 296 ether, "former distributor kept its exemption");

        registry.setRecord(LAUNCH, DEAD);
        vm.prank(CAROL);
        token.transfer(DEAD, 100 ether);
        assertEq(token.balanceOf(DEAD), 104 ether);
        vm.prank(CAROL);
        token.transfer(BOB, 100 ether);
        assertEq(token.balanceOf(BOB), 98 ether);
    }

    function test_constructorAcceptsManagerEqualToFactoryAndAnyLaunchNumber() public {
        Kitty same = new Kitty(address(registry), address(registry), type(uint64).max);
        assertEq(same.poolManager(), address(registry));
        assertEq(same.launchNumber(), type(uint64).max);
        assertEq(same.rewardsDistributor(), address(0));
        assertEq(same.balanceOf(address(this)), SUPPLY);
        same.transfer(ALICE, 100 ether);
        assertEq(same.balanceOf(ALICE), 98 ether);
    }
}
