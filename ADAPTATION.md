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

## 8. Open amounts and floors at the pool's price when the pool exists (review finding 7f08261c, reproduced)

SPEC 2 asks both that a pool within 0.5% of the given sqrtPriceX96 opens and that the minimums are
99.5% of the amounts "at that price". The venue mints at the pool's own price, so amounts computed
at the given price can fall short of 99.5% for a two-sided range after a move far inside the band
(0.3% below for -6000..6000 gives 98.85% of the token1 amount), and an executed OpenPosition, whose
price is fixed days before execute(), would revert unless the pool sat at exactly that price.
Resolution, keeping both constants: when the pool exists LpDesk checks it is within 0.5% of the
given price and then computes the amounts and the 99.5% floors at the pool's current price; only
when LpDesk creates the pool are they computed at the given price, which is then the pool's price.
The operator's amount0Min/amount1Min are therefore checked against the floors at the pool's price.
Tests: `test_openWithinBandAtPoolPrice` (fork), `test_unlistedVenueAndPriceCheck` (fork).

## 9. Buybacks debit only what the pool took (review findings a111b07e and a7409246, reproduced)

A v4 or V3 exact-input swap with the extreme price limit stops when the pool's liquidity is
exhausted and leaves input unconsumed. FirmVault.buyback and LpDesk.buyback used to debit the
bucket or basket by the requested amount, so the unspent part fell outside the bucket (FirmVault:
counted as undistributed and split by the next distribute(); LpDesk: returned by DeskSwap into the
free balance). Both now debit by the amount actually swapped (FirmVault from the PoolManager
delta, LpDesk from its balance change) and the rest stays reserved, as SPEC 5 and SPEC 2 require.
No rate or recipient changed. Tests: `test_vaultBuybackPartialFillKeepsBucket` (local, half-depth
pool manager), `test_deskBuybackPartialFillKeepsBasket` (fork, dust range on Uniswap v3).

## 10. GenesisSplitter splits once (review finding 57647087, reproduced)

split() now sets a `done` flag on the first successful split and reverts `AlreadySplit` afterwards,
so NOTSTOCK sent to the splitter later is never split again (it stays in the splitter; nothing in
the launch sends it any). Shares unchanged: 10/60 dev wallet, 50/60 LpDesk, at exactly
600 000 000 NOTSTOCK 100 000 000 and 500 000 000.

## 11. OpenPosition proposals check the token the range spends (review finding 81adb46e, reproduced)

`amount` is read as NOTSTOCK, or as the asset when the range takes no NOTSTOCK at the price. The
proposal check compared it with free NOTSTOCK only; LpDesk.checkOpenProposal now computes both
amounts at the effective price (entry 8) and reverts AboveFree when either exceeds its free balance,
so a proposal that would fail at execute() is not created and does not hold its slot.

## 12. Quorum rounds up (review finding f55e1956)

`state()` uses ceil(totalAtCheckpoint * 3 / 100) so that a vote under 3% never passes
(`test_quorumRoundsUp`). The difference is at most 1 wei of staked NOTSTOCK.

## 13. mulDiv Newton seed without the xor operator (review finding d836aef0)

`(3 * d) ^ 2` is OpenZeppelin's seed, which Slither (incorrect-exp) and Aderyn flag as a mistyped
exponent. The equivalent `d % 4 == 3 ? 3 * d + 2 : 3 * d - 2` (d is odd there) keeps the maths;
`testFuzz_mulDivLargeProducts` and `test_mulDivKnownLargeValues` check products above 2^256.

## 14. Test setups fund the pranked senders

On forge 1.8.3 a pranked state-changing call from an account with no ETH reverts in Base fork mode
(an environment effect, nothing in the contracts). The test setups `vm.deal` 1 ETH to every
pranked sender so the suite is green on a fork under either forge version.

## Findings that did not reproduce or needed no code change

- e64a04d6 (issuer blocklist of the project wallet): an outside issuer's power over its own token;
  the fee split pushes the project share as SPEC 2 fixes it, so a position in a blocklisting asset
  cannot be collected or closed while the blocklist lasts. Stated in README under trust assumptions;
  a pull bucket would add an asset path SPEC 2 does not list, so it is not made.
- bb129820 (bridge adapter trust): SPEC 2a makes token() the only adapter check and the operator's
  veto the safeguard; stated in README, no code change.
- 9e2de4de (setRequester caller): SPEC 1 already makes the project wallet the paying wallet
  (`requester`). The rehearsal passes it as `requester`; README lists it under "After launch".
- 347bd9b3 (FirmAddresses library): kept as is, unused by the contracts.
- Findings f9e55c01, dd1758ee, a55684d0, 89e63743, 5570cfce, 42a581e5 (missing contracts, tests,
  script): resolved by this delivery.
