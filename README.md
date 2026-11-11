# The Firm: notSTOCK ($NOTSTOCK)

Don't work for the firm. Let the firm work for you.

Token notSTOCK, symbol NOTSTOCK, on Base (chain 8453), paired with IMD. 18 decimals,
1 000 000 000 NOTSTOCK, minted once at launch. The binding rules are in SPEC.md; the cash model is
in FINMODEL.md; every deviation the launch rules required is in ADAPTATION.md.

## Contracts (src/)

| Contract | Role | Constructor arguments (launch manifest) |
| --- | --- | --- |
| LaunchToken | notSTOCK / NOTSTOCK, fixed supply 1e27, no owner, mint, fee, pause or upgrade | none |
| LpDesk | the LP desk; creates Burner in its constructor | `$token`, operator `0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981`, project wallet `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C` |
| FirmVault | pool fee recipient, 25/25/25/25 distribute(), operator buyback to dead | project wallet `0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C`, `$contract:LpDesk` |
| GenesisSplitter | 50/60 to LpDesk, 10/60 to the dev wallet, once | `$contract:LpDesk`, dev wallet `0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981` |
| Burner | created by LpDesk; burn() sends its whole NOTSTOCK to dead | (LpDesk) |
| LpGovernor, PriceGuard, VenueV3, VenueV4, DeskSwap | LpDesk modules, deployed after launch by `deployModule(kind, creationCode)` (CREATE2, salt = kind, hash fixed in LpDesk) | none |

Deploy order in the one launch transaction: token, LpDesk (0), FirmVault (1), GenesisSplitter (2).
Manifest names: exactly `LpDesk`, `FirmVault`, `GenesisSplitter`. Nothing is called at deploy.
Launch addresses (token, LpDesk, FirmVault, GenesisSplitter, Burner, modules, pool key and pool id)
are filled in by IMD's launch after this work is accepted; the rehearsal in `test/Fork.t.sol`
reproduces the whole launch through the live factory `0x82EcAA82B8C1A64773D99295B1157EE502539736`.

Fixed addresses: IMD `0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105` (on-chain name "Fren Pet"),
dead `0x000000000000000000000000000000000000dEaD`, WETH `0x4200000000000000000000000000000000000006`.

## Tokenomics (1 000 000 000 NOTSTOCK)

- 10% swarm, by the launch policy (MerkleDistributor).
- 30% pool seed, NOTSTOCK/IMD, fee 12500 (1.25%), tick spacing 60, opening cap 2 500 IMD (set by the deployer).
- 60% to the project wallet, which transfers exactly 600 000 000 NOTSTOCK to GenesisSplitter:
  - 10% dev wallet (10/60), no automatic burn, no contract moves it.
  - 50% LpDesk (50/60), one free balance, no buckets.

## After launch (operational responsibilities)

1. Anyone: `script/DeployModules.s.sol` (`deploy(address lpDesk)`) calls `deployModule` for the
   five modules (kinds 0..4); each takes no constructor argument. Verification input per module:
   its file under src/, solc 0.8.26, via_ir, optimizer runs 1, evm cancun, bytecode_hash none.
2. Project wallet: transfer exactly 600 000 000 NOTSTOCK to GenesisSplitter.
3. Project wallet (the launch's paying wallet / `requester`): `ProjectFactory.setRequester(launchNumber, FirmVault)`.
   The factory only lets the recorded requester call it, so the launch must be paid by the project wallet.
4. Anyone: `PriceGuard.registerNotStock(launchNumber)` (checks the factory record, stores the pool
   key, FirmVault and the block time; the 7-day bootstrap starts here).
5. Anyone: `GenesisSplitter.split()`: LpDesk 500 000 000, dev wallet 100 000 000.
6. Anyone, whenever fees arrive: `FirmVault.distribute(IMD)` / `distribute(NOTSTOCK)`; `Burner.burn()`.
7. Operator (dev wallet): positions during the bootstrap, close / shift / move / collect /
   increaseLiquidity / buyback / burn at any time, veto of passed proposals, FirmVault.buyback.

## Rules in short

- Pool fee to FirmVault: fees stay on FirmVault until anyone calls distribute(token). IMD: 25% buyback
  bucket, 25% project wallet, 25% LpDesk top-up basket of IMD, 25% LpDesk free IMD; NOTSTOCK 100% to
  Burner; any other token reverts. Quarters are floor(undistributed / 4); the remainder (at most
  3 wei) stays undistributed for the next call (ADAPTATION.md 1). The buyback bucket is spent only by
  `buyback(amount, minOut)` from LpDesk's operator: IMD swapped for NOTSTOCK in the launch pool at
  its price, minOut set by hand, all NOTSTOCK to dead.
- LpDesk positions only on listed venues: six at deploy (Uniswap v4 `0x7C5f…9bDc`, Uniswap v3
  `0x03a5…34f1`, PancakeSwap v3 `0x46A1…4364`, SushiSwap v3 `0x80C7…14de`, Aerodrome Slipstream
  `0x8279…5b72` and `0x4857…C60b`), more only by an AddVenue vote (V3, CL or V4 interface checks),
  never removed. Assets: IMD, WETH, USDC, cbBTC and the nine Coinbase stocks at deploy, more only by
  AddAsset. Every position pairs NOTSTOCK with one listed asset.
- Bootstrap: 604 800 seconds from registerNotStock the operator opens positions directly; later
  every open needs a passed, unvetoed LpGovernor proposal executed by anyone.
- Operator alone, any time: close (withdrawn amounts to free balance), shift range (re-split which
  side is single-sided), move liquidity between its positions, collect fees, increaseLiquidity from
  the top-up basket (no NOTSTOCK taken), buyback from the buyback basket (not IMD) in the position's
  own pool to dead, burn free NOTSTOCK to dead, hand over the operator role. No other power.
- Fees collected: NOTSTOCK 100% to Burner; every other token 25% buyback (IMD to FirmVault's bucket,
  others to that asset's buyback basket), 25% project wallet, 25% top-up basket, 25% free balance.
- Open: pool created at the given price if absent; otherwise the pool price must be within 0.5% of
  the given sqrtPriceX96; amount0Min/amount1Min at least 99.5% of the amounts at that price (an
  executed OpenPosition uses exactly 99.5%); amount above free balance reverts. `amount` is the
  NOTSTOCK the position takes, or the asset amount when the range takes no NOTSTOCK at that price.
- Shift, close and move take minimum outs set by hand; buyback takes minOut by hand; no contract minimum.
- LpGovernor: stake/unstake NOTSTOCK at will, weight checkpointed at the block before creation;
  proposer needs 0.1% of staked supply (operator: any); one open proposal per kind for stakers plus
  one per kind for the operator; 3-day vote, quorum 3% of staked at the checkpoint and more for than
  against, else failed; 2-day operator veto (cancel only); then 3 days to execute() once, else expired.
  BridgeOut sends free NOTSTOCK through the record's LayerZero OFT adapter only to its dstLpDesk,
  the caller paying the messaging fee as msg.value.
- LpDesk never deposits a position NFT into any staking, gauge or farm contract; positions earn only pool fees.
- No owner, mint, pause, upgrade or selfdestruct in any contract; no delegatecall, no linked library.
- Free balance of a token in LpDesk = its balance minus the top-up and buyback baskets; NOTSTOCK has
  no baskets, so NOTSTOCK sent by plain transfer is free at once.

## Trust assumptions

- The operator (dev wallet) controls timing and slippage of every position action and the two
  buybacks; it cannot move any asset to a wallet other than the project wallet.
- Venues and assets are outside contracts with their own owners (USDC, cbBTC and the stocks can
  blocklist or pause); a paused asset blocks the positions holding it.
- The launch factory's requester must be the project wallet for setRequester to succeed.

## Tests

- `forge test`: off-fork suite (`test/Local.t.sol`): token, sizes and module hashes, registration
  record checks, GenesisSplitter, Burner, FirmVault distribute (exact quarters, remainder policy,
  repeat no-op, fuzz conservation), LpDesk access and burn, LpGovernor (checkpoints, threshold,
  quorum, majority, slots, veto window, execute once, expiry, bridge flow with a mock OFT), gates.
  The fork suite skips off the fork.
- `forge test --fork-url <base rpc>`: `test/Fork.t.sol`: the full rehearsal through the live
  factory (gas under 16 777 216, supply 10/30/10/50, FirmVault as requester), then on each of the six
  venues: open at an exact price, trades, collect with the 25/25/25/25 split and NOTSTOCK to Burner,
  asset-only position, top-up rules, shift with minimum outs, buyback to dead, close to free balance;
  AddVenue of BaseSwap and the 0.5% price check; governance open after the bootstrap; FirmVault
  buyback in the launch pool; an added 8-decimal asset.
- forge-std is vendored under `test/vendor/forge-std`.

## Files

- SPEC.md: binding specification. ADAPTATION.md: every adaptation and why.
- FINMODEL.md: 12-month cash model, three scenarios.
- SITE.md: rules of the website, built by a separate order.
- brand/: logo, logo-64, compare.
