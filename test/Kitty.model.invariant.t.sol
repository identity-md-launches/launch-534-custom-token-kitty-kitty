// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Kitty} from "../src/Kitty.sol";
import {ProgrammableRegistry} from "./helpers/ProgrammableRegistry.sol";

/// @notice Drives the token with raw (unbounded) and bounded transfers, delegated transfers, approvals, and
///         changes to the launch registry while the token is live. A shadow ledger written from the
///         specification is the oracle: two percent of every ordinary transfer, rounded down, goes to the dead
///         address; a transfer with the factory, the pool manager or the registry's current distributor at either
///         end moves whole; a transfer beyond a balance or an allowance reverts and moves nothing.
contract KittyModelHandler is Test {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Kitty public immutable token;
    ProgrammableRegistry public immutable registry;
    address public immutable manager;
    uint64 public immutable launchNumber;

    /// @dev Senders and spenders: factory, manager, three holders, and the address the record usually names.
    address[] public actors;
    /// @dev Everything the ledger tracks: the actors plus the dead address, which only ever receives.
    address[] public tracked;
    /// @dev What the registry record may be pointed at mid-sequence.
    address[] public candidates;

    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;
    /// @dev Every (owner, spender) pair an approval has ever touched, so the invariant checks only live pairs.
    address[] public allowanceOwners;
    address[] public allowanceSpenders;
    mapping(address => mapping(address => bool)) private allowanceTouched;
    uint256 public expectedFees;
    uint256 public expectedDirectToDead;
    address public expectedDistributor;

    uint256 public successfulTransfers;
    uint256 public rejectedTransfers;
    uint256 public exemptTransfers;

    constructor(Kitty token_, ProgrammableRegistry registry_, address manager_, uint64 launchNumber_) {
        token = token_;
        registry = registry_;
        manager = manager_;
        launchNumber = launchNumber_;

        address distributor = address(0xD157);
        actors.push(address(registry_));
        actors.push(manager_);
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA201));
        actors.push(distributor);
        for (uint256 i; i < actors.length; ++i) {
            tracked.push(actors[i]);
        }
        tracked.push(DEAD);

        candidates.push(address(0));
        candidates.push(distributor);
        candidates.push(address(0xA11CE));
        candidates.push(manager_);
        candidates.push(address(registry_));
        candidates.push(DEAD);

        registry_.setMode(ProgrammableRegistry.Mode.Record);
        registry_.setRecord(launchNumber_, distributor);
        expectedDistributor = distributor;
        expectedBalance[address(registry_)] = token_.totalSupply();
    }

    // ----------------------------------------------------------------- raw handlers: unrestricted amounts

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        _transfer(_actor(fromSeed), _recipient(toSeed), amount);
    }

    function transferFrom(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amount) public {
        _transferFrom(_actor(spenderSeed), _actor(fromSeed), _recipient(toSeed), amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, bool unlimited) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 value = unlimited ? type(uint256).max : amount;
        vm.prank(owner);
        assertTrue(token.approve(spender, value), "approve returned false");
        expectedAllowance[owner][spender] = value;
        if (!allowanceTouched[owner][spender]) {
            allowanceTouched[owner][spender] = true;
            allowanceOwners.push(owner);
            allowanceSpenders.push(spender);
        }
        assertEq(token.allowance(owner, spender), value, "allowance not recorded");
    }

    // ----------------------------------------------------------------- bounded handlers: reach the deep paths

    function transferBounded(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address from = _actor(fromSeed);
        _transfer(from, _recipient(toSeed), bound(amountSeed, 0, token.balanceOf(from)));
    }

    function transferEverything(uint256 fromSeed, uint256 toSeed) public {
        address from = _actor(fromSeed);
        _transfer(from, _recipient(toSeed), token.balanceOf(from));
    }

    function transferDust(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        _transfer(_actor(fromSeed), _recipient(toSeed), bound(amountSeed, 0, 100));
    }

    function transferFromBounded(uint256 spenderSeed, uint256 fromSeed, uint256 toSeed, uint256 amountSeed) public {
        address spender = _actor(spenderSeed);
        address from = _actor(fromSeed);
        uint256 cap = token.balanceOf(from);
        uint256 allowance = token.allowance(from, spender);
        if (allowance < cap) cap = allowance;
        _transferFrom(spender, from, _recipient(toSeed), bound(amountSeed, 0, cap));
    }

    // ----------------------------------------------------------------- registry: who is exempt can change

    function configureRegistry(uint256 modeSeed, uint256 candidateSeed, uint256 shapeSeed) public {
        address candidate = candidates[candidateSeed % candidates.length];
        registry.setRecord(launchNumber, candidate);
        uint256 mode = modeSeed % 5;
        if (mode == 0) {
            registry.setMode(ProgrammableRegistry.Mode.Record);
            expectedDistributor = candidate;
        } else if (mode == 1) {
            registry.setMode(ProgrammableRegistry.Mode.Revert);
            expectedDistributor = address(0);
        } else if (mode == 2) {
            uint256[3] memory highBits = [uint256(0), 1, 1 << 95];
            uint256 high = highBits[shapeSeed % 3];
            registry.setMode(ProgrammableRegistry.Mode.RawWord);
            registry.setWord(uint256(uint160(candidate)) | (high << 160));
            expectedDistributor = high == 0 ? candidate : address(0);
        } else if (mode == 3) {
            uint256[6] memory sizes = [uint256(0), 1, 31, 32, 33, 64];
            uint256 size = sizes[shapeSeed % 6];
            registry.setMode(ProgrammableRegistry.Mode.Sized);
            registry.setReturnSize(size);
            expectedDistributor = size == 32 ? candidate : address(0);
        } else {
            uint256[3] memory budgets = [uint256(1_000), 20_000, 40_000];
            uint256 budget = budgets[shapeSeed % 3];
            registry.setMode(ProgrammableRegistry.Mode.BurnGas);
            registry.setGasToBurn(budget);
            expectedDistributor = budget < 30_000 ? candidate : address(0);
        }
        assertEq(token.rewardsDistributor(), expectedDistributor, "distributor resolution after registry change");
    }

    // ----------------------------------------------------------------- views for the invariants

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function trackedCount() external view returns (uint256) {
        return tracked.length;
    }

    function allowancePairCount() external view returns (uint256) {
        return allowanceOwners.length;
    }

    // ----------------------------------------------------------------- internals

    function _transfer(address from, address to, uint256 amount) private {
        uint256 balance = token.balanceOf(from);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(from);
        try token.transfer(to, amount) returns (bool ok) {
            assertTrue(ok, "transfer returned false");
            assertLe(amount, balance, "a transfer above the sender's balance succeeded");
            _settle(from, to, amount);
        } catch (bytes memory err) {
            assertGt(amount, balance, "a transfer within the sender's balance reverted");
            assertEq(bytes4(err), IERC20Errors.ERC20InsufficientBalance.selector, "unexpected revert reason");
            ++rejectedTransfers;
        }
        assertGe(token.balanceOf(DEAD), deadBefore, "the dead balance went down");
    }

    function _transferFrom(address spender, address from, address to, uint256 amount) private {
        uint256 allowance = token.allowance(from, spender);
        uint256 balance = token.balanceOf(from);
        uint256 deadBefore = token.balanceOf(DEAD);
        bool unlimited = allowance == type(uint256).max;
        bool allowed = unlimited || allowance >= amount;
        vm.prank(spender);
        try token.transferFrom(from, to, amount) returns (bool ok) {
            assertTrue(ok, "transferFrom returned false");
            assertTrue(allowed, "a transferFrom above the allowance succeeded");
            assertLe(amount, balance, "a transferFrom above the owner's balance succeeded");
            if (!unlimited) expectedAllowance[from][spender] = allowance - amount;
            assertEq(token.allowance(from, spender), expectedAllowance[from][spender], "gross allowance not spent");
            _settle(from, to, amount);
        } catch (bytes memory err) {
            if (!allowed) {
                assertEq(bytes4(err), IERC20Errors.ERC20InsufficientAllowance.selector, "unexpected revert reason");
            } else {
                assertGt(amount, balance, "a covered transferFrom reverted");
                assertEq(bytes4(err), IERC20Errors.ERC20InsufficientBalance.selector, "unexpected revert reason");
            }
            assertEq(token.allowance(from, spender), allowance, "a failed transferFrom changed the allowance");
            ++rejectedTransfers;
        }
        assertGe(token.balanceOf(DEAD), deadBefore, "the dead balance went down");
    }

    /// @dev The specification, applied to the shadow ledger.
    function _settle(address from, address to, uint256 amount) private {
        bool exempt = _exemptPerSpecification(from, to);
        uint256 fee = exempt ? 0 : (amount * 2) / 100;
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount - fee;
        expectedBalance[DEAD] += fee;
        expectedFees += fee;
        if (to == DEAD) expectedDirectToDead += amount - fee;
        ++successfulTransfers;
        if (exempt) ++exemptTransfers;
    }

    function _exemptPerSpecification(address from, address to) private view returns (bool) {
        if (from == address(registry) || to == address(registry)) return true;
        if (from == manager || to == manager) return true;
        address distributor = expectedDistributor;
        return distributor != address(0) && (from == distributor || to == distributor);
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _recipient(uint256 seed) private view returns (address) {
        return tracked[seed % tracked.length];
    }
}

contract KittyModelInvariantTest is Test {
    uint256 constant SUPPLY = 1_000_000_000 ether;
    uint64 constant LAUNCH = 7;
    address constant MANAGER = address(0x9001);

    Kitty token;
    ProgrammableRegistry registry;
    KittyModelHandler handler;

    function setUp() public {
        registry = new ProgrammableRegistry();
        token = registry.deploy(MANAGER, LAUNCH);
        handler = new KittyModelHandler(token, registry, MANAGER, LAUNCH);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = KittyModelHandler.transfer.selector;
        selectors[1] = KittyModelHandler.transferFrom.selector;
        selectors[2] = KittyModelHandler.approve.selector;
        selectors[3] = KittyModelHandler.transferBounded.selector;
        selectors[4] = KittyModelHandler.transferEverything.selector;
        selectors[5] = KittyModelHandler.transferDust.selector;
        selectors[6] = KittyModelHandler.transferFromBounded.selector;
        selectors[7] = KittyModelHandler.configureRegistry.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    function invariant_balancesSupplyAndFeesFollowTheSpecification() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed");
        assertEq(token.balanceOf(address(0)), 0, "the zero address holds tokens");
        uint256 sum;
        uint256 count = handler.trackedCount();
        for (uint256 i; i < count; ++i) {
            address account = handler.tracked(i);
            uint256 held = token.balanceOf(account);
            assertEq(held, handler.expectedBalance(account), "a balance left the specification");
            sum += held;
        }
        assertEq(sum, SUPPLY, "tracked balances do not sum to the supply");
        assertEq(
            token.balanceOf(handler.DEAD()),
            handler.expectedFees() + handler.expectedDirectToDead(),
            "the dead balance is not fees plus direct burns"
        );
    }

    /// forge-config: default.invariant.runs = 192
    /// forge-config: default.invariant.depth = 64
    function invariant_allowancesAndDistributorFollowTheModel() public view {
        uint256 pairs = handler.allowancePairCount();
        for (uint256 i; i < pairs; ++i) {
            address owner = handler.allowanceOwners(i);
            address spender = handler.allowanceSpenders(i);
            assertEq(token.allowance(owner, spender), handler.expectedAllowance(owner, spender), "allowance drift");
        }
        // A spender no approval can ever name must still have nothing.
        assertEq(token.allowance(handler.actors(2), address(0x5EED)), 0, "allowance appeared from nowhere");
        assertEq(token.rewardsDistributor(), handler.expectedDistributor(), "distributor drifted from the registry");
    }
}
