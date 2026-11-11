# Adaptations to SPEC.md (commit 2d14646)

Each entry is a change the launch rules or a reproduced finding required. No rate, recipient,
limit, split or power was changed.

## 1. Integer policy for the exact splits (audit finding 2b1a1bad, reproduced)

7 wei of IMD cannot be split into four exact quarters. SPEC 2.2 ("whole undistributed balance"),
SPEC 2 ("exactly 25/25/25/25") and SPEC 6 ("no rounding dust left unaccounted") conflict for any
amount that is not a multiple of 4. The previous attempt stopped on this; the launch rules say to
decide it. Policy, asserted by tests (`test_distributeRemainderPolicy`, `testFuzz_vaultSplitConserves`,
`test_splitRoundingPolicy`):

- FirmVault.distribute(IMD): each quarter is floor(undistributed / 4). The remainder (at most 3 wei)
  stays undistributed and is split by the next call, so nothing is lost and every quarter stays
  exactly equal. Undistributed = balance minus the buyback bucket, as SPEC 2.2 defines it.
- LpDesk collected fees (every token but NOTSTOCK): buyback, project wallet and top-up shares are
  each floor(amount / 4); the free balance receives the rest (the fourth quarter plus at most 3 wei),
  because free balance is by definition what is outside the baskets. NOTSTOCK is 100% to Burner.
- GenesisSplitter: the dev wallet receives floor(balance * 10 / 60); LpDesk receives the rest, so
  the splitter holds 0 afterwards and a second call moves nothing (it reverts with NothingToSplit).
  With exactly 600 000 000 NOTSTOCK the shares are exactly 100 000 000 and 500 000 000.

## 2. Registration compares the pool fee with the constant 12500 (audit finding 8102019c, reproduced)

SPEC 2b compares the recorded pool fee with `fees().poolFee()`, a value the LaunchFees owner can
change after the launch, which would make registration, split() and distribute() impossible without
an outside owner's action (contradicting SPEC 0). PriceGuard compares the recorded key's fee with
the constant 12500 that SPEC 3 fixes, and the hooks with the factory's immutable `poolHook()`.

## 3. Live factory ABI uses uint64 launch numbers (audit finding 08049dc0, reproduced)

`positionOf(uint64)`, `setRequester(uint64,address)` and `artifactsOf(uint64)`; the SPEC text
says `launchNumber` without a width. All calls use uint64.

## 4. Module creation-code hashes are literal constants in LpDesk

SPEC 2 wants each module's creation code hash as a constant in LpDesk. Embedding
`type(Module).creationCode` would put five modules' code into LpDesk's initcode (over 49 152
bytes), so the hashes are literal constants, regenerated whenever a module or the compiler settings
change (`forge inspect <Module> bytecode | cast keccak`) and asserted equal to
`keccak256(type(Module).creationCode)` by `test_sizesAndModuleHashes`.

## 5. Uniswap v4 position manager settles from its own balance

The v4 PositionManager pays with Permit2 when the payer is the caller. To avoid a Permit2
dependency, VenueV4 transfers the amounts to the position manager and uses SETTLE with
`payerIsUser = false`, then SWEEP returns leftovers to LpDesk, all inside one call.

## 6. Tokenized stocks in tests

The B20 stock addresses carry EIP-7702 delegation code on Base, which the fork resolves before any
`vm.etch`-ed code, so the SPEC 6 option of etching a test token at a stock address is not usable
with forge 1.9. The asset list test checks their addresses and decimals as constants; an added
8-decimal asset is exercised through AddAsset instead (`test_addedEightDecimalAssetOpens`).

## 7. Position report for v4

Uniswap v4 keeps no per-position "tokens owed" outside a liquidity change, so `positionReport`
returns 0 pending fees for v4 positions; `collect()` reports the actual amounts in its event.
For V3 and CL it returns the manager's recorded tokensOwed.

## Findings that did not reproduce or needed no code change

- 9e2de4de (setRequester caller): SPEC 1 already makes the project wallet the paying wallet
  (`requester`). The rehearsal passes it as `requester`; README lists it under "After launch".
- 347bd9b3 (FirmAddresses library): kept as is, unused by the contracts.
- Findings f9e55c01, dd1758ee, a55684d0, 89e63743, 5570cfce, 42a581e5 (missing contracts, tests,
  script): resolved by this delivery.
