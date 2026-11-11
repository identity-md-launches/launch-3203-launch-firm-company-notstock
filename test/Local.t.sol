// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {MockFactory, MockERC20, MockOFT, BadOFT, OtherVault} from "./Mocks.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {Burner} from "../src/Burner.sol";
import {LpGovernor} from "../src/LpGovernor.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {VenueV3} from "../src/VenueV3.sol";
import {VenueV4} from "../src/VenueV4.sol";
import {DeskSwap} from "../src/DeskSwap.sol";
import {DeskMath} from "../src/DeskMath.sol";
import {OpenParams, KIND_V3, KIND_V4} from "../src/Interfaces.sol";

/// @notice Off-fork tests: token, sizes and module hashes, GenesisSplitter, Burner, FirmVault
/// distribute(), LpDesk burn and access, LpGovernor, registration record checks.
contract LocalTest is Test {
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    MockFactory f;
    LaunchToken token;
    LpDesk desk;
    FirmVault vault;
    GenesisSplitter splitter;
    LpGovernor gov;
    PriceGuard guard;
    MockERC20 imd;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        // IMD stands at its fixed address: a plain 18-decimal ERC-20 is etched there off the fork.
        MockERC20 impl = new MockERC20("Fren Pet", "IMD", 18);
        vm.etch(IMD, address(impl).code);
        imd = MockERC20(IMD);
        f = new MockFactory(DEV, PROJECT, DEV, IMD);
        token = f.token();
        desk = f.desk();
        vault = f.vault();
        splitter = f.splitter();
        desk.deployModule(0, type(LpGovernor).creationCode);
        desk.deployModule(1, type(PriceGuard).creationCode);
        desk.deployModule(2, type(VenueV3).creationCode);
        desk.deployModule(3, type(VenueV4).creationCode);
        desk.deployModule(4, type(DeskSwap).creationCode);
        gov = LpGovernor(desk.governor());
        guard = PriceGuard(desk.priceGuard());
    }

    function _register() internal {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        guard.registerNotStock(1);
        splitter.split();
    }

    // ------------------------------------------------------------ token

    function test_tokenSupplyAndTransfer() public {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.decimals(), 18);
        assertEq(token.name(), "notSTOCK");
        assertEq(token.symbol(), "NOTSTOCK");
        vm.prank(PROJECT);
        assertTrue(token.transfer(alice, 5e18));
        assertEq(token.balanceOf(alice), 5e18);
        vm.prank(alice);
        vm.expectRevert(LaunchToken.InsufficientBalance.selector);
        token.transfer(bob, 6e18);
    }

    // ------------------------------------------------------------ sizes and modules

    function test_sizesAndModuleHashes() public view {
        assertLt(address(desk).code.length, 24_576);
        assertLt(address(vault).code.length, 10_240);
        assertLt(address(splitter).code.length, 2_048);
        assertLt(desk.burner().code.length, 1_024);
        assertLt(desk.governor().code.length, 24_576);
        assertLt(desk.priceGuard().code.length, 24_576);
        assertLt(desk.venueV3().code.length, 24_576);
        assertLt(desk.venueV4().code.length, 24_576);
        assertLt(desk.deskSwap().code.length, 24_576);
        assertLt(type(LpDesk).creationCode.length, 49_152);
        assertEq(desk.GOVERNOR_CODE_HASH(), keccak256(type(LpGovernor).creationCode));
        assertEq(desk.GUARD_CODE_HASH(), keccak256(type(PriceGuard).creationCode));
        assertEq(desk.VENUE_V3_CODE_HASH(), keccak256(type(VenueV3).creationCode));
        assertEq(desk.VENUE_V4_CODE_HASH(), keccak256(type(VenueV4).creationCode));
        assertEq(desk.SWAP_CODE_HASH(), keccak256(type(DeskSwap).creationCode));
        assertEq(address(gov.lpDesk()), address(desk));
        assertEq(address(guard.lpDesk()), address(desk));
    }

    function test_deployModuleRejectsOtherCodeAndRepeat() public {
        vm.expectRevert(LpDesk.ModuleExists.selector);
        desk.deployModule(0, type(LpGovernor).creationCode);
        vm.expectRevert(LpDesk.BadModule.selector);
        desk.deployModule(0, type(PriceGuard).creationCode);
        vm.expectRevert(LpDesk.BadModule.selector);
        desk.deployModule(7, type(PriceGuard).creationCode);
    }

    function test_venueAndAssetListsAtDeploy() public view {
        PriceGuard.Venue[] memory v = guard.venues();
        assertEq(v.length, 6);
        assertEq(v[0].positionManager, 0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        assertEq(v[0].kind, KIND_V4);
        assertEq(v[1].positionManager, 0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1);
        assertEq(v[5].positionManager, 0x4857DB576eE0e45F10525eC59527BfD10beeC60b);
        PriceGuard.Asset[] memory a = guard.assets();
        assertEq(a.length, 13);
        assertEq(a[2].token, 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
        assertEq(a[2].decimals, 6);
        assertEq(a[3].decimals, 8);
        assertEq(a[4].token, 0xb2000000000000000000002D0BA3164cc74f58B7);
        assertEq(a[12].token, 0xb2000000000000000000007d16372840dF4dAbbe);
        assertEq(a[12].decimals, 8);
    }

    // ------------------------------------------------------------ registration

    function test_registrationChecksTheRecord() public {
        vm.expectRevert(PriceGuard.BadRecord.selector); // splitter holds nothing yet
        guard.registerNotStock(1);
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 - 1);
        vm.expectRevert(PriceGuard.BadRecord.selector);
        guard.registerNotStock(1);
        vm.prank(PROJECT);
        token.transfer(address(splitter), 1);
        f.setFee(3000);
        vm.expectRevert(PriceGuard.BadRecord.selector);
        guard.registerNotStock(1);
        f.setFee(12500);
        f.setHooks(address(0x1));
        vm.expectRevert(PriceGuard.BadRecord.selector);
        guard.registerNotStock(1);
        f.setHooks(f.poolHook());
        f.setRequester(address(new OtherVault()));
        vm.expectRevert(PriceGuard.BadRecord.selector);
        guard.registerNotStock(1);
        f.setRequester(address(vault));
        f.setArtifact(1, "LpDesk", address(0x9));
        vm.expectRevert(PriceGuard.BadRecord.selector);
        guard.registerNotStock(1);
        f.setArtifact(1, "LpDesk", address(desk));
        // extra tokens do not block
        vm.prank(PROJECT);
        token.transfer(address(splitter), 7);
        assertFalse(desk.registered());
        assertEq(desk.bootstrapEnd(), 0);
        guard.registerNotStock(1);
        assertTrue(desk.registered());
        assertEq(desk.firmVault(), address(vault));
        assertEq(desk.bootstrapEnd(), vm.getBlockTimestamp() + 604_800);
        vm.expectRevert(PriceGuard.AlreadyRegistered.selector);
        guard.registerNotStock(1);
    }

    // ------------------------------------------------------------ GenesisSplitter

    function test_splitOnce() public {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
        guard.registerNotStock(1);
        vm.prank(alice);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(DEV), 100_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        vm.expectRevert(GenesisSplitter.NothingToSplit.selector);
        splitter.split();
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
    }

    function test_splitRoundingPolicy() public {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 + 7);
        guard.registerNotStock(1);
        splitter.split();
        uint256 total = 600_000_000e18 + 7;
        uint256 dev = total * 10 / 60;
        assertEq(token.balanceOf(DEV), dev);
        assertEq(token.balanceOf(address(desk)), total - dev);
        assertEq(token.balanceOf(address(splitter)), 0);
    }

    // ------------------------------------------------------------ Burner

    function test_burner() public {
        Burner b = Burner(desk.burner());
        vm.expectRevert(Burner.NothingToBurn.selector);
        b.burn();
        vm.prank(PROJECT);
        token.transfer(address(b), 5e18);
        vm.prank(alice);
        b.burn();
        assertEq(token.balanceOf(DEAD), 5e18);
        assertEq(token.balanceOf(address(b)), 0);
    }

    // ------------------------------------------------------------ FirmVault

    function test_distributeImdExact() public {
        imd.mint(address(vault), 100e18);
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.distribute(IMD);
        _register();
        imd.mint(address(vault), 300e18);
        vm.prank(alice);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18);
        assertEq(imd.balanceOf(PROJECT), 100e18);
        assertEq(desk.topUpBasket(IMD), 100e18);
        assertEq(desk.freeBalance(IMD), 100e18);
        assertEq(desk.buybackBasket(IMD), 0);
        assertEq(imd.balanceOf(address(vault)), 100e18);
        assertEq(vault.undistributed(), 0);
        // repeat moves nothing
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18);
        assertEq(imd.balanceOf(PROJECT), 100e18);
        assertEq(desk.topUpBasket(IMD), 100e18);
        assertEq(desk.freeBalance(IMD), 100e18);
    }

    function test_distributeRemainderPolicy() public {
        _register();
        imd.mint(address(vault), 7);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 1);
        assertEq(imd.balanceOf(PROJECT), 1);
        assertEq(desk.topUpBasket(IMD), 1);
        assertEq(desk.freeBalance(IMD), 1);
        assertEq(vault.undistributed(), 3);
        imd.mint(address(vault), 1);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 2);
        assertEq(vault.undistributed(), 0);
    }

    function test_distributeNotStockAndOthers() public {
        _register();
        vm.prank(DEV);
        token.transfer(address(vault), 9e18);
        vault.distribute(address(token));
        assertEq(token.balanceOf(desk.burner()), 9e18);
        vm.expectRevert(FirmVault.UnsupportedToken.selector);
        vault.distribute(WETH);
    }

    function test_vaultCreditPaths() public {
        _register();
        vm.expectRevert(FirmVault.NotLpDesk.selector);
        vault.creditFromDesk(1);
        vm.expectRevert(LpDesk.NotFirmVault.selector);
        desk.creditFromVault(1);
        imd.mint(address(vault), 4e18);
        vm.prank(address(desk));
        vault.creditFromDesk(4e18);
        assertEq(vault.buybackBucket(), 4e18);
        assertEq(vault.undistributed(), 0);
        vm.prank(alice);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(1e18, 0);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vault.buyback(5e18, 0);
    }

    // ------------------------------------------------------------ LpDesk operator basics

    function test_burnAndAccess() public {
        _register();
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(1);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.burn(500_000_000e18 + 1);
        vm.prank(DEV);
        desk.burn(40e18);
        assertEq(token.balanceOf(DEAD), 40e18);
        assertEq(desk.freeBalance(address(token)), 500_000_000e18 - 40e18);
        vm.prank(DEV);
        desk.setOperator(alice);
        assertEq(desk.operator(), alice);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(1);
    }

    function test_directOpenNeedsBootstrapAndListedAsset() public {
        _register();
        OpenParams memory p = OpenParams(
            address(0x77),
            address(0x7C5f5A4bBd8fD63184577525326123B519429bDc),
            3000,
            60,
            -600,
            600,
            uint160(DeskMath.Q96),
            1e18,
            0,
            0
        );
        vm.prank(DEV);
        vm.expectRevert(LpDesk.UnlistedAsset.selector);
        desk.open(p);
        vm.warp(desk.bootstrapEnd());
        p.asset = WETH;
        vm.prank(DEV);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        desk.open(p);
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.open(p);
    }

    // ------------------------------------------------------------ governance

    function _stake(address who, uint256 amount) internal {
        vm.prank(DEV);
        token.transfer(who, amount);
        vm.startPrank(who);
        token.approve(address(gov), amount);
        gov.stake(amount);
        vm.stopPrank();
    }

    function test_stakeCheckpointsAndThreshold() public {
        _register();
        _stake(alice, 1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        _stake(bob, 1e18 - 1); // below 0.1%
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(gov.totalStaked(), 1001e18 - 1);
        assertEq(gov.stakedAt(alice, vm.getBlockNumber() - 1), 1000e18);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0x77));
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0x77));
        // unstake after creation does not change the checkpointed weight
        vm.prank(alice);
        gov.unstake(1000e18);
        assertEq(token.balanceOf(alice), 1000e18);
        vm.prank(alice);
        gov.vote(id, true);
        assertEq(gov.proposal(id).forVotes, 1000e18);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AlreadyVoted.selector);
        gov.vote(id, true);
        // a staker with no weight at the checkpoint cannot vote
        _stake(address(0xC0), 5e18);
        vm.prank(address(0xC0));
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, true);
    }

    function test_proposalLifecycleExecuteOnceVetoExpiry() public {
        _register();
        _stake(alice, 1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0x77));
        // second staker proposal of the kind is blocked, operator one is not
        vm.prank(alice);
        vm.expectRevert(LpGovernor.SlotTaken.selector);
        gov.proposeAddAsset(address(0x78));
        vm.prank(DEV);
        uint256 opId = gov.proposeAddAsset(address(0x78));
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.SlotTaken.selector);
        gov.proposeAddAsset(address(0x79));
        vm.prank(alice);
        gov.vote(id, true);
        vm.prank(alice);
        gov.vote(opId, false);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Passed));
        assertEq(uint8(gov.state(opId)), uint8(LpGovernor.State.Failed));
        // a failed proposal frees its slot
        vm.prank(DEV);
        gov.proposeAddAsset(address(0x79));
        vm.prank(alice);
        vm.expectRevert(LpGovernor.NotOperator.selector);
        gov.veto(id);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.NotInVetoWindow.selector);
        gov.veto(id);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Executable));
        vm.prank(bob);
        gov.execute(id);
        assertTrue(guard.isAsset(address(0x77)));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Executed));
    }

    function test_vetoCancelsAndExpiryBlocks() public {
        _register();
        _stake(alice, 1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0x77));
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 3 days + 1);
        vm.prank(DEV);
        gov.veto(id);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Vetoed));
        vm.warp(vm.getBlockTimestamp() + 2 days);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        // vetoed frees the slot; the new one expires if never executed
        vm.prank(alice);
        uint256 id2 = gov.proposeAddAsset(address(0x77));
        vm.prank(alice);
        gov.vote(id2, true);
        vm.warp(vm.getBlockTimestamp() + 3 days + 2 days + 259_200);
        assertEq(uint8(gov.state(id2)), uint8(LpGovernor.State.Expired));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id2);
        vm.prank(alice);
        gov.proposeAddAsset(address(0x77));
    }

    function test_quorumAndMajority() public {
        _register();
        _stake(alice, 970e18);
        _stake(bob, 30e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(bob);
        uint256 id = gov.proposeAddAsset(address(0x77));
        vm.prank(bob);
        gov.vote(id, true); // 3% exactly: quorum met
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Passed));
        vm.prank(DEV);
        uint256 id2 = gov.proposeAddAsset(address(0x78));
        vm.prank(bob);
        gov.vote(id2, true);
        vm.prank(alice);
        gov.vote(id2, false);
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint8(gov.state(id2)), uint8(LpGovernor.State.Failed));
        vm.warp(vm.getBlockTimestamp() + 5 days); // the passed proposal expires and frees its slot
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Expired));
        _stake(address(0xD1), 2e18); // above the 0.1% threshold, below the 3% quorum
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(address(0xD1));
        uint256 id3 = gov.proposeAddAsset(address(0x79));
        vm.prank(address(0xD1));
        gov.vote(id3, true); // below 3%
        vm.warp(vm.getBlockTimestamp() + 3 days);
        assertEq(uint8(gov.state(id3)), uint8(LpGovernor.State.Failed));
    }

    function test_addAssetAndVenueGates() public {
        _register();
        vm.startPrank(DEV);
        vm.expectRevert(PriceGuard.BadAsset.selector);
        gov.proposeAddAsset(address(0));
        vm.expectRevert(PriceGuard.BadAsset.selector);
        gov.proposeAddAsset(address(token));
        vm.expectRevert(PriceGuard.BadAsset.selector);
        gov.proposeAddAsset(WETH);
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(address(0), KIND_V3);
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, KIND_V3);
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(address(0x4444), KIND_V3);
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(address(token), KIND_V3); // factory() reverts
        vm.expectRevert(PriceGuard.BadVenue.selector);
        gov.proposeAddVenue(address(token), KIND_V4);
        vm.stopPrank();
        vm.expectRevert(PriceGuard.NotLpDesk.selector);
        guard.addAsset(address(0x77));
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.addAssetByGovernor(address(0x77));
    }

    function test_bridgeFlow() public {
        _register();
        MockOFT oft = new MockOFT(address(token));
        address bad = address(new BadOFT());
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.BadBridge.selector);
        gov.proposeAddBridge(bad, 30101, address(0xDE5C));
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.BadBridge.selector);
        gov.proposeBridgeOut(0, 1e18);
        _stake(alice, 1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(DEV);
        uint256 id = gov.proposeAddBridge(address(oft), 30101, address(0xDE5C));
        vm.prank(alice);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        gov.execute(id);
        assertEq(gov.bridgeCount(), 1);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.BadProposal.selector);
        gov.proposeBridgeOut(0, 500_000_000e18 + 1);
        vm.prank(DEV);
        uint256 out = gov.proposeBridgeOut(0, 1_000e18);
        vm.prank(alice);
        gov.vote(out, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.bridgeOut(address(oft), 30101, address(0xDE5C), 1, address(this));
        gov.execute(out);
        assertEq(oft.sent(), 1_000e18);
        assertEq(oft.lastEid(), 30101);
        assertEq(oft.lastTo(), bytes32(uint256(uint160(address(0xDE5C)))));
        assertEq(token.allowance(address(desk), address(oft)), 0);
        assertEq(gov.bridgedOut(0), 1_000e18);
        assertEq(desk.bridgedOutTotal(), 1_000e18);
        assertEq(token.balanceOf(address(desk)), 500_000_000e18 - 1_000e18);
    }

    // ------------------------------------------------------------ math

    function test_tickMathKnownValues() public pure {
        assertEq(DeskMath.sqrtRatioAtTick(0), uint160(DeskMath.Q96));
        assertEq(DeskMath.sqrtRatioAtTick(-887272), DeskMath.MIN_SQRT_RATIO);
        assertEq(DeskMath.sqrtRatioAtTick(887272), DeskMath.MAX_SQRT_RATIO);
        assertTrue(DeskMath.within(uint160(DeskMath.Q96), uint160(DeskMath.Q96 * 10024 / 10000)));
        assertFalse(DeskMath.within(uint160(DeskMath.Q96), uint160(DeskMath.Q96 * 10026 / 10000)));
        assertTrue(DeskMath.within(uint160(DeskMath.Q96 * 9976 / 10000), uint160(DeskMath.Q96)));
        assertFalse(DeskMath.within(uint160(DeskMath.Q96 * 9974 / 10000), uint160(DeskMath.Q96)));
    }

    function testFuzz_mulDivMatchesSmall(uint128 x, uint128 y, uint128 d) public pure {
        vm.assume(d > 0);
        assertEq(DeskMath.mulDiv(x, y, d), uint256(x) * uint256(y) / uint256(d));
    }

    function testFuzz_vaultSplitConserves(uint96 amount) public {
        _register();
        imd.mint(address(vault), amount);
        vault.distribute(IMD);
        uint256 q = uint256(amount) / 4;
        assertEq(vault.buybackBucket(), q);
        assertEq(imd.balanceOf(PROJECT), q);
        assertEq(desk.topUpBasket(IMD), q);
        assertEq(desk.freeBalance(IMD), q);
        assertEq(vault.undistributed(), uint256(amount) - 4 * q);
    }
}
