// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {MockFactory, MockERC20, HalfDepthPoolManager} from "./Mocks.sol";
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

/// @notice Drives the value-holding contracts of the launch (FirmVault, LpDesk's free NOTSTOCK and
/// IMD, Burner, GenesisSplitter, LpGovernor's stake) in random order with bounded inputs, and keeps
/// ghost totals of everything that entered the system from outside.
contract LaunchHandler is Test {
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    LaunchToken public token;
    LpDesk public desk;
    FirmVault public vault;
    GenesisSplitter public splitter;
    LpGovernor public gov;
    MockERC20 public imd;
    address public pm;

    address[] public actors;

    // ghosts
    uint256 public imdMinted; // IMD that entered from outside (fee transfers to FirmVault)
    uint256 public imdPaidToPool; // IMD the vault buyback paid the pool
    uint256 public notStockOutOfPool; // NOTSTOCK the pool paid out to dead on buybacks
    uint256 public deskBurned; // NOTSTOCK LpDesk.burn sent to dead
    uint256 public burnerBurned; // NOTSTOCK Burner.burn sent to dead
    uint256 public notStockToVault; // NOTSTOCK fee transfers to FirmVault
    uint256 public bucketHigh; // buyback bucket after the last call that may only raise it
    bool public violated;
    string public violation;

    uint256[] public recordedBlocks;
    mapping(uint256 => mapping(address => uint256)) public stakeAtBlock;
    mapping(uint256 => uint256) public totalAtBlock;

    constructor(LaunchToken t, LpDesk d, FirmVault v, GenesisSplitter s, LpGovernor g, address pm_) {
        token = t;
        desk = d;
        vault = v;
        splitter = s;
        gov = g;
        imd = MockERC20(IMD);
        pm = pm_;
        actors.push(address(0xA11CE));
        actors.push(address(0xB0B));
        actors.push(address(0xCA11));
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(PROJECT);
            token.transfer(actors[i], 10_000_000e18);
            vm.prank(actors[i]);
            token.approve(address(gov), type(uint256).max);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function recordedCount() external view returns (uint256) {
        return recordedBlocks.length;
    }

    function _fail(string memory why) internal {
        violated = true;
        violation = why;
    }

    // ------------------------------------------------------------ FirmVault

    /// A plain IMD fee transfer to FirmVault, as the launch factory pays the 1% share.
    function feeImd(uint256 amount) external {
        amount = bound(amount, 0, 1_000_000e18);
        imd.mint(address(vault), amount);
        imdMinted += amount;
    }

    /// A plain NOTSTOCK transfer to FirmVault.
    function feeNotStock(uint256 amount) external {
        amount = bound(amount, 0, 100_000e18);
        vm.prank(PROJECT);
        token.transfer(address(vault), amount);
        notStockToVault += amount;
    }

    function distributeImd(uint256 who) external {
        uint256 bucket = vault.buybackBucket();
        uint256 und = vault.undistributed();
        uint256 projBefore = imd.balanceOf(PROJECT);
        uint256 topBefore = desk.topUpBasket(IMD);
        uint256 freeBefore = desk.freeBalance(IMD);
        vm.prank(actors[who % actors.length]);
        vault.distribute(IMD);
        uint256 q = und / 4;
        if (vault.buybackBucket() != bucket + q) _fail("bucket share");
        if (imd.balanceOf(PROJECT) != projBefore + q) _fail("project share");
        if (desk.topUpBasket(IMD) != topBefore + q) _fail("top-up share");
        if (desk.freeBalance(IMD) != freeBefore + q) _fail("free share");
        if (vault.undistributed() != und - 4 * q || vault.undistributed() > 3) _fail("remainder");
    }

    function distributeNotStock(uint256 who) external {
        uint256 bal = token.balanceOf(address(vault));
        uint256 burnerBefore = token.balanceOf(desk.burner());
        uint256 bucket = vault.buybackBucket();
        vm.prank(actors[who % actors.length]);
        vault.distribute(address(token));
        if (token.balanceOf(desk.burner()) != burnerBefore + bal) _fail("NOTSTOCK to Burner");
        if (token.balanceOf(address(vault)) != 0) _fail("NOTSTOCK left in vault");
        if (vault.buybackBucket() != bucket) _fail("NOTSTOCK distribute moved bucket");
    }

    function vaultBuyback(uint256 amount, uint256 minOut) external {
        uint256 bucket = vault.buybackBucket();
        if (bucket == 0) return;
        amount = bound(amount, 1, bucket);
        // HalfDepthPoolManager consumes amount/2 and pays 1:1
        uint256 expectedPaid = amount / 2;
        if (expectedPaid == 0) return;
        minOut = bound(minOut, 0, expectedPaid * 2);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(DEV);
        try vault.buyback(amount, minOut) returns (uint256 out) {
            if (minOut > expectedPaid) _fail("buyback above output executed");
            if (out != expectedPaid) _fail("buyback out");
            if (token.balanceOf(DEAD) != deadBefore + out) _fail("buyback out not to dead");
            if (vault.buybackBucket() != bucket - expectedPaid) _fail("bucket drop");
            imdPaidToPool += expectedPaid;
            notStockOutOfPool += out;
        } catch (bytes memory err) {
            if (minOut <= expectedPaid) _fail("buyback below output reverted");
            if (bytes4(err) != FirmVault.BelowMinOut.selector) _fail("wrong buyback revert");
            if (vault.buybackBucket() != bucket) _fail("reverted buyback moved bucket");
        }
    }

    function strangerBuyback(uint256 amount, uint256 who) external {
        address s = who % 2 == 0 ? actors[who % actors.length] : PROJECT;
        vm.prank(s);
        try vault.buyback(amount, 0) {
            _fail("stranger buyback");
        } catch {}
    }

    function aboveBucketBuyback(uint256 extra) external {
        extra = bound(extra, 1, 1e30);
        uint256 bucket = vault.buybackBucket();
        vm.prank(DEV);
        try vault.buyback(bucket + extra, 0) {
            _fail("buyback above bucket");
        } catch {}
    }

    function strangerCredits(uint256 amount) external {
        vm.prank(actors[amount % actors.length]);
        try vault.creditFromDesk(amount) {
            _fail("creditFromDesk by stranger");
        } catch {}
        vm.prank(actors[amount % actors.length]);
        try desk.creditFromVault(amount) {
            _fail("creditFromVault by stranger");
        } catch {}
    }

    // ------------------------------------------------------------ LpDesk and Burner

    function deskBurn(uint256 amount) external {
        uint256 free = desk.freeBalance(address(token));
        amount = bound(amount, 0, free + 1e18);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(DEV);
        try desk.burn(amount) {
            if (amount > free) _fail("burn above free");
            if (token.balanceOf(DEAD) != deadBefore + amount) _fail("burn not to dead");
            deskBurned += amount;
        } catch {
            if (amount <= free) _fail("burn within free reverted");
        }
    }

    function strangerBurn(uint256 amount, uint256 who) external {
        vm.prank(actors[who % actors.length]);
        try desk.burn(bound(amount, 0, 1e18)) {
            _fail("stranger burn");
        } catch {}
    }

    function burnerBurn(uint256 who) external {
        address b = desk.burner();
        uint256 bal = token.balanceOf(b);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(actors[who % actors.length]);
        try Burner(b).burn() {
            if (token.balanceOf(DEAD) != deadBefore + bal) _fail("burner partial");
            burnerBurned += bal;
        } catch {
            if (bal != 0) _fail("burner with balance reverted");
        }
        if (token.balanceOf(b) != 0) _fail("burner kept NOTSTOCK");
    }

    function splitAgain(uint256 who) external {
        uint256 d = token.balanceOf(address(desk));
        uint256 v = token.balanceOf(DEV);
        vm.prank(actors[who % actors.length]);
        try splitter.split() {} catch {}
        if (token.balanceOf(address(desk)) != d || token.balanceOf(DEV) != v) _fail("second split moved");
    }

    // ------------------------------------------------------------ LpGovernor stake

    function stake(uint256 who, uint256 amount) external {
        address a = actors[who % actors.length];
        amount = bound(amount, 0, token.balanceOf(a));
        vm.prank(a);
        gov.stake(amount);
    }

    function unstake(uint256 who, uint256 amount) external {
        address a = actors[who % actors.length];
        uint256 s = gov.stakedOf(a);
        amount = bound(amount, 0, s + 1);
        uint256 balBefore = token.balanceOf(a);
        vm.prank(a);
        try gov.unstake(amount) {
            if (amount > s) _fail("unstake above stake");
            if (token.balanceOf(a) != balBefore + amount) _fail("unstake paid wrong");
        } catch {
            if (amount <= s) _fail("unstake within stake reverted");
        }
    }

    /// Ends the current block: records every actor's final stake in it, then moves on.
    function nextBlock(uint256 secs) external {
        secs = bound(secs, 1, 2 days);
        recordedBlocks.push(block.number);
        for (uint256 i; i < actors.length; ++i) {
            stakeAtBlock[block.number][actors[i]] = gov.stakedOf(actors[i]);
        }
        totalAtBlock[block.number] = gov.totalStaked();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + secs);
    }
}

/// @notice Invariants over random call sequences for every contract of the launch that holds value.
contract LaunchInvariantTest is Test {
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant SUPPLY = 1_000_000_000e18;
    uint256 constant PM_NOTSTOCK = 50_000_000e18;

    MockFactory f;
    LaunchToken token;
    LpDesk desk;
    FirmVault vault;
    GenesisSplitter splitter;
    LpGovernor gov;
    MockERC20 imd;
    LaunchHandler h;
    address pm;

    function setUp() public {
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
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        PriceGuard(desk.priceGuard()).registerNotStock(1);
        splitter.split();
        pm = f.poolManager();
        vm.etch(pm, address(new HalfDepthPoolManager()).code);
        vm.prank(PROJECT);
        token.transfer(pm, PM_NOTSTOCK);
        h = new LaunchHandler(token, desk, vault, splitter, gov, pm);
        targetContract(address(h));
    }

    function _notStockHeld() internal view returns (uint256 s) {
        s = token.balanceOf(PROJECT) + token.balanceOf(DEV) + token.balanceOf(address(desk))
            + token.balanceOf(address(vault)) + token.balanceOf(address(splitter)) + token.balanceOf(desk.burner())
            + token.balanceOf(DEAD) + token.balanceOf(address(gov)) + token.balanceOf(pm);
        for (uint256 i; i < h.actorCount(); ++i) {
            s += token.balanceOf(h.actors(i));
        }
    }

    /// forge-config: default.invariant.runs = 48
    function invariant_noHandlerViolation() public view {
        assertFalse(h.violated(), h.violation());
    }

    /// forge-config: default.invariant.runs = 48
    function invariant_supplyFixedAndConserved() public view {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(_notStockHeld(), SUPPLY, "NOTSTOCK left the known holders");
    }

    /// The genesis split happened once: LpDesk got 500,000,000 and the dev wallet 100,000,000, and
    /// LpDesk's NOTSTOCK has dropped only by its own burns to dead.
    /// forge-config: default.invariant.runs = 48
    function invariant_genesisSplitAndDeskNotStock() public view {
        assertTrue(splitter.done());
        assertEq(token.balanceOf(address(splitter)), 0);
        assertEq(token.balanceOf(DEV), 100_000_000e18);
        assertEq(token.balanceOf(address(desk)), 500_000_000e18 - h.deskBurned());
        assertEq(desk.freeBalance(address(token)), token.balanceOf(address(desk)));
    }

    /// Dead holds exactly what LpDesk burned, Burner burned and buybacks bought; Burner plus dead
    /// hold every NOTSTOCK fee that reached FirmVault and was distributed.
    /// forge-config: default.invariant.runs = 48
    function invariant_deadAndBurner() public view {
        assertEq(token.balanceOf(DEAD), h.deskBurned() + h.burnerBurned() + h.notStockOutOfPool());
        assertEq(
            h.notStockToVault(),
            token.balanceOf(address(vault)) + token.balanceOf(desk.burner()) + h.burnerBurned(),
            "vault NOTSTOCK went somewhere other than Burner"
        );
        assertEq(token.balanceOf(pm), PM_NOTSTOCK - h.notStockOutOfPool());
    }

    /// IMD only enters as fees to FirmVault and only leaves to the SPEC 5 destinations (project
    /// wallet, LpDesk) or to the pool on a buyback. The four shares stay equal.
    /// forge-config: default.invariant.runs = 48
    function invariant_imdSplitAccounting() public view {
        uint256 project = imd.balanceOf(PROJECT);
        assertEq(
            imd.balanceOf(address(vault)) + imd.balanceOf(address(desk)) + project + imd.balanceOf(pm),
            h.imdMinted(),
            "IMD conservation"
        );
        assertEq(imd.balanceOf(pm), h.imdPaidToPool());
        assertGe(imd.balanceOf(address(vault)), vault.buybackBucket(), "bucket backed");
        assertEq(desk.topUpBasket(IMD), project, "top-up quarter equals project quarter");
        assertEq(desk.freeBalance(IMD), project, "free quarter equals project quarter");
        assertEq(desk.buybackBasket(IMD), 0, "IMD buyback goes to FirmVault, not a desk basket");
        assertEq(vault.buybackBucket() + h.imdPaidToPool(), project, "bucket quarter equals project quarter");
        assertEq(imd.balanceOf(address(vault)) - vault.buybackBucket(), vault.undistributed());
    }

    /// Governor custody: it holds exactly the stake it owes, and the total matches the sum.
    /// forge-config: default.invariant.runs = 48
    function invariant_governorStakeCustody() public view {
        uint256 sum;
        for (uint256 i; i < h.actorCount(); ++i) {
            sum += gov.stakedOf(h.actors(i));
        }
        assertEq(gov.totalStaked(), sum);
        assertEq(token.balanceOf(address(gov)), sum);
        assertEq(gov.totalStakedAt(block.number), gov.totalStaked());
    }

    /// Checkpoints: the weight read for any finished block is the stake held at the end of it.
    /// forge-config: default.invariant.runs = 48
    function invariant_checkpointsMatchHistory() public view {
        uint256 n = h.recordedCount();
        for (uint256 k; k < n; ++k) {
            uint256 b = h.recordedBlocks(k);
            for (uint256 i; i < h.actorCount(); ++i) {
                address a = h.actors(i);
                assertEq(gov.stakedAt(a, b), h.stakeAtBlock(b, a), "account checkpoint");
            }
            assertEq(gov.totalStakedAt(b), h.totalAtBlock(b), "total checkpoint");
        }
    }
}
