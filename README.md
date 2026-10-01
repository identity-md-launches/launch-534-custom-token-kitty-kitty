# Kitty (KITTY)

Kitty is an immutable ERC-20 with 18 decimals. Its constructor mints exactly
1,000,000,000 KITTY (`1000000000000000000000000000` minor units) to `msg.sender`.
There is no owner, later minting, upgrade, pause, blacklist, confiscation, fee setter,
or token recovery function.

For an ordinary transfer of `amount`, the sender spends `amount`, the recipient
receives `amount - floor(amount / 50)`, and
`0x000000000000000000000000000000000000dEaD` receives `floor(amount / 50)`.
This is exactly 2%, rounded down to a whole minor unit. Sending tokens to the dead
address does **not** reduce `totalSupply()`. The dead address is assumed to be
uncontrolled; the contract does not impose a special spending restriction on it.

Both `transfer` and `transferFrom` are exempt when **either endpoint** is the
factory, pool manager, or current rewards distributor. An exempt address acting
only as the spender does not exempt unrelated holders' transfers and still needs
their allowance. Factory allocation, pool settlement in both directions, and
distributor claims therefore deliver the exact requested amounts.

`transferFrom` spends the gross allowance, including the fee. OpenZeppelin's
unlimited allowance convention is supported. Zero transfers succeed and emit a
`Transfer`; transfers below 50 minor units incur no fee. Ordinary self-transfers
cost only the fee but require the entire gross balance. A transfer to the dead
address credits it with the full amount. A taxable transfer with a nonzero fee
emits the fee `Transfer` first, then the net `Transfer`. Exempt transfers emit one
event. Sending to the zero address reverts.

## Deployment parameters

Artifact: `src/Kitty.sol:Kitty`

```solidity
constructor(address factory_, address poolManager_, uint64 launchNumber_)
```

| Argument | Meaning | Launch substitution |
| --- | --- | --- |
| `factory_` | Nonzero factory address providing `distributorOf(uint64)` | `$factory` |
| `poolManager_` | Nonzero Uniswap v4 pool manager address | `$poolManager` |
| `launchNumber_` | Exact launch key used by the factory registry | `$launchNumber` |

Creation input is `abi.encodePacked(type(Kitty).creationCode,
abi.encode(factory, poolManager, uint64(launchNumber)))`. All arguments are static.
The factory must execute CREATE/CREATE2 itself to receive the constructor supply;
deploying through a separate helper would mint to that helper. The constructor
does not require the configured factory to equal the actual deployer.

The factory and manager addresses and launch number are immutable. The distributor
is deliberately not a constructor argument: its address depends on the token.
Kitty resolves it at transfer time by calling `factory.distributorOf(launchNumber)`.
The token does not cache that result, so subsequent registry changes immediately
change the distributor exemption. A record for another launch grants no exemption.
There are no application contracts or initialization transactions to configure.

No chain addresses, pool allocation, opening market cap, or remainder recipient
were supplied. These remain launch configuration; the allocation numbers used in
tests are examples, not deployment economics. This project does not generate a
launch manifest, manage keys, broadcast, or deploy contracts to a network.

## Registry assumptions and operational responsibilities

The launch operator must verify the chain's factory and pool manager, select the
correct launch number, and populate the distributor mapping before any claims.
The constructor rejects zero endpoints but does not validate their deployed code
or interface. Check `rewardsDistributor()` against the intended distributor before
funding claims. Confirm the factory itself performs the token deployment and holds
the exact initial supply before allocation.

The registry must return one ABI-encoded address within a 30,000-gas STATICCALL.
A missing record, absent code, revert, malformed response, attempted state change,
or exhausted lookup gas resolves to zero. In that case ordinary transfers continue
with the fee; factory and manager transfers remain exempt. Distributor transfers
will also pay the fee until the registry works, so the operator must verify the
registry before claims. The gas bound suits a mapping getter; a more expensive
factory implementation must be evaluated before launch. The factory's control of
this mapping is a trust assumption: it can change who receives the distributor
exemption. Kitty exposes no such setter.

Only a bounded read-only external call occurs; it cannot reenter a state-changing
token operation. Transfer recipients receive no callbacks. Registry failure cannot
grant an allowance, move funds, grow supply, or pause holder transfers. The fee is
split through the inherited ERC-20 accounting after checking the gross balance,
so self-transfers and overlapping dead-address transfers preserve accounting.

Integrators outside the configured launch endpoints must account for net receipts.
Routing through an exempt endpoint can avoid the fee; the endpoint's own controls
determine whether such routing is possible. Other pools and routers receive no
automatic exemption. Users should approve only amounts needed for a particular use.

Before release, an independent contributor should review the contract and the actual
factory/distributor integration. Network deployment, explorer verification, launch
configuration, and monitoring the registry belong to the launch operator. There
are no token administrator keys or ongoing token maintenance calls.

## Build and checks

Install Foundry and Solidity **0.8.26** in the checking environment. The compiler
version is pinned in `foundry.toml`; no compiler binary is included. Dependencies
and their licenses are vendored as ordinary files (see [DEPENDENCIES.md](DEPENDENCIES.md)),
so once the compiler is available, compilation and testing need no network.
The project enables neither FFI nor filesystem cheatcode permissions.

```sh
forge build
forge test
forge fmt --check
```

The suite tests metadata and minting, launch allocation and claims, all six
exemption directions with both transfer methods, dynamic registry records,
rounding, fee events, allowances and revocation, invalid inputs, failed-transfer
rollback, self-transfers, dead-address accounting, registry failures, and absent
privileged entrypoints. A runtime scan checks the forbidden delegatecall,
callcode, and selfdestruct opcodes. Fuzz tests use 512 cases; stateful invariants
use 128 sequences of 64 calls with direct and delegated transfers, checking
balances, supply, fees, and per-transfer accounting after arbitrary sequences.

Tests are self-contained, use no environment variables, and do not depend on test
order or external RPCs. The launch test models token movements using a factory
mock and an exempt manager address; it does not exercise Uniswap's swap engine.
The supplied protected launch harness requires the network's separate launch
infrastructure and manifest-derived environment, and is not part of this local
suite. Slither and Mythril have not been run. Tests and local review are not an
independent security audit.
