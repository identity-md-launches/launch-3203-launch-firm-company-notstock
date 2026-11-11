// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {MockFactory, MockERC20} from "./Mocks.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {LpGovernor} from "../src/LpGovernor.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {VenueV3} from "../src/VenueV3.sol";
import {VenueV4} from "../src/VenueV4.sol";
import {DeskSwap} from "../src/DeskSwap.sol";
import {OpenParams} from "../src/Interfaces.sol";

/// @notice Boundary and failure paths: exact second of every governance window, exact quorum,
/// threshold and majority, same-block checkpoint weight, operator handover, governor-only entry
/// points, the genesis split for any balance.
contract EdgeCasesTest is Test {
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
    address carol = address(0xCA201);

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
        guard = PriceGuard(desk.priceGuard());
        vm.deal(alice, 1 ether);
        vm.deal(bob, 1 ether);
        vm.deal(DEV, 1 ether);
    }

    function _register() internal {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        guard.registerNotStock(1);
        splitter.split();
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(PROJECT);
        token.transfer(who, amount);
        vm.startPrank(who);
        token.approve(address(gov), amount);
        gov.stake(amount);
        vm.stopPrank();
    }

    // ------------------------------------------------------------ governance windows

    function test_windowsAtTheExactSecond() public {
        _register();
        _stake(alice, 1000e18);
        vm.roll(block.number + 1);
        uint256 t0 = block.timestamp;
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0x77));
        (uint256 voteEnd, uint256 vetoEnd, uint256 expiry) = gov.deadlines(id);
        assertEq(voteEnd, t0 + 3 days);
        assertEq(vetoEnd, voteEnd + 2 days);
        assertEq(expiry, vetoEnd + 3 days);

        // last second of the vote
        vm.warp(voteEnd - 1);
        vm.prank(alice);
        gov.vote(id, true);
        // vote closed exactly at voteEnd
        vm.warp(voteEnd);
        _stake(bob, 1e18);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.NotActive.selector);
        gov.vote(id, false);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Passed));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);

        // last second of the veto window: still Passed, not executable
        vm.warp(vetoEnd - 1);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Passed));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        // veto window closed exactly at vetoEnd
        vm.warp(vetoEnd);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.NotInVetoWindow.selector);
        gov.veto(id);
        // last second of the execute window works; a value is refused for a non-BridgeOut kind
        vm.warp(expiry - 1);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.ValueNotAllowed.selector);
        gov.execute{value: 1}(id);
        vm.prank(bob);
        gov.execute(id);
        assertTrue(guard.isAsset(address(0x77)));
        vm.warp(expiry + 10);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Executed));
    }

    function test_expiresAtTheExactSecond() public {
        _register();
        _stake(alice, 1000e18);
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0x77));
        vm.prank(alice);
        gov.vote(id, true);
        (,, uint256 expiry) = gov.deadlines(id);
        vm.warp(expiry);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Expired));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.NotInVetoWindow.selector);
        gov.veto(id);
        assertFalse(guard.isAsset(address(0x77)));
        // an expired proposal frees the staker slot of its kind
        vm.prank(alice);
        gov.proposeAddAsset(address(0x78));
    }

    function test_vetoOnLastSecondCancelsForGood() public {
        _register();
        _stake(alice, 1000e18);
        vm.roll(block.number + 1);
        vm.prank(alice);
        uint256 id = gov.proposeAddAsset(address(0x77));
        vm.prank(alice);
        gov.vote(id, true);
        (, uint256 vetoEnd,) = gov.deadlines(id);
        vm.warp(vetoEnd - 1);
        vm.prank(DEV);
        gov.veto(id);
        vm.warp(vetoEnd);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Vetoed));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.NotInVetoWindow.selector);
        gov.veto(id);
    }

    // ------------------------------------------------------------ quorum, majority, threshold

    function _quorumCase(uint256 voterStake, uint256 restStake, bool tie) internal returns (LpGovernor.State) {
        _register();
        _stake(alice, restStake);
        _stake(bob, voterStake);
        vm.roll(block.number + 1);
        vm.prank(DEV);
        uint256 id = gov.proposeAddAsset(address(0x77));
        vm.prank(bob);
        gov.vote(id, true);
        if (tie) {
            vm.prank(alice);
            gov.vote(id, false);
        }
        vm.warp(block.timestamp + 3 days);
        return gov.state(id);
    }

    function test_quorumExactlyThreePercentPasses() public {
        assertEq(uint8(_quorumCase(3e18, 97e18, false)), uint8(LpGovernor.State.Passed));
    }

    function test_quorumOneWeiShortFails() public {
        assertEq(uint8(_quorumCase(3e18 - 1, 97e18 + 1, false)), uint8(LpGovernor.State.Failed));
    }

    function test_tieFails() public {
        assertEq(uint8(_quorumCase(50e18, 50e18, true)), uint8(LpGovernor.State.Failed));
    }

    function test_failedIsPermanent() public {
        _quorumCase(3e18 - 1, 97e18 + 1, false);
        vm.warp(block.timestamp + 30 days);
        assertEq(uint8(gov.state(0)), uint8(LpGovernor.State.Failed));
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(0);
    }

    function test_thresholdExactlyPointOnePercent() public {
        _register();
        _stake(alice, 1e18);
        _stake(bob, 999e18);
        vm.prank(alice);
        gov.proposeAddAsset(address(0x77));
        // one more wei staked elsewhere puts alice below 0.1%
        _stake(carol, 1);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0x79));
        // no stake at all
        vm.prank(address(0xD00D));
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0x78));
    }

    // ------------------------------------------------------------ checkpoint weight

    function test_weightIsTheBlockBeforeCreation() public {
        _register();
        _stake(alice, 100e18);
        vm.roll(block.number + 1);
        // bob stakes in the creation block: no weight on this proposal
        _stake(bob, 1_000e18);
        vm.prank(DEV);
        uint256 id = gov.proposeAddAsset(address(0x77));
        assertEq(gov.proposal(id).totalAtCheckpoint, 100e18);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, false);
        // alice unstakes after creation and keeps her checkpointed weight; a fresh account she
        // funds gets none
        vm.roll(block.number + 1);
        vm.prank(alice);
        gov.unstake(100e18);
        vm.prank(alice);
        token.approve(address(gov), 100e18);
        vm.prank(alice);
        token.transfer(carol, 100e18);
        vm.startPrank(carol);
        token.approve(address(gov), 100e18);
        gov.stake(100e18);
        vm.expectRevert(LpGovernor.NoWeight.selector);
        gov.vote(id, false);
        vm.stopPrank();
        vm.prank(alice);
        gov.vote(id, true);
        assertEq(gov.proposal(id).forVotes, 100e18);
        vm.warp(block.timestamp + 3 days);
        assertEq(uint8(gov.state(id)), uint8(LpGovernor.State.Passed));
    }

    function test_unstakeAboveStakeReverts() public {
        _register();
        _stake(alice, 5e18);
        vm.prank(alice);
        vm.expectRevert(LpGovernor.AboveStake.selector);
        gov.unstake(5e18 + 1);
        vm.prank(bob);
        vm.expectRevert(LpGovernor.AboveStake.selector);
        gov.unstake(1);
    }

    // ------------------------------------------------------------ roles and entry points

    function test_operatorHandover() public {
        _register();
        vm.prank(alice);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.setOperator(alice);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.ZeroAddress.selector);
        desk.setOperator(address(0));
        vm.prank(DEV);
        desk.setOperator(alice);
        assertEq(desk.operator(), alice);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.burn(1);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(0, 0);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(alice);
        desk.burn(7e18);
        assertEq(token.balanceOf(DEAD) - deadBefore, 7e18);
        // the new operator proposes without stake; the old one is now a plain account
        vm.prank(alice);
        gov.proposeAddAsset(address(0x77));
        vm.prank(DEV);
        vm.expectRevert(LpGovernor.BelowThreshold.selector);
        gov.proposeAddAsset(address(0x78));
    }

    function test_governorOnlyEntryPoints() public {
        _register();
        OpenParams memory p;
        vm.startPrank(DEV);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.openByGovernor(p);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.addAssetByGovernor(address(0x77));
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.addVenueByGovernor(address(0x77), 1);
        vm.expectRevert(LpDesk.NotGovernor.selector);
        desk.bridgeOut(address(0x77), 1, address(0x78), 1, DEV);
        vm.stopPrank();
        vm.expectRevert(FirmVault.NotPoolManager.selector);
        vault.unlockCallback("");
    }

    function test_burnExactlyFreeThenNothing() public {
        _register();
        uint256 free = desk.freeBalance(address(token));
        assertEq(free, 500_000_000e18);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.burn(free + 1);
        vm.prank(DEV);
        desk.burn(free);
        assertEq(token.balanceOf(address(desk)), 0);
        assertEq(token.balanceOf(DEAD), free);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.AboveFree.selector);
        desk.burn(1);
    }

    function test_distributeTinyAmounts() public {
        _register();
        imd.mint(address(vault), 3);
        vault.distribute(IMD);
        assertEq(vault.undistributed(), 3, "below 4 wei nothing moves");
        assertEq(imd.balanceOf(PROJECT), 0);
        imd.mint(address(vault), 1);
        vault.distribute(IMD);
        assertEq(vault.undistributed(), 0);
        assertEq(vault.buybackBucket(), 1);
        assertEq(imd.balanceOf(PROJECT), 1);
        assertEq(desk.topUpBasket(IMD), 1);
        assertEq(desk.freeBalance(IMD), 1);
        // an empty NOTSTOCK distribute moves nothing and does not revert
        vault.distribute(address(token));
        assertEq(token.balanceOf(desk.burner()), 0);
    }

    // ------------------------------------------------------------ genesis split

    /// forge-config: default.fuzz.runs = 512
    function testFuzz_splitAnyBalanceOnce(uint256 extra) public {
        extra = bound(extra, 0, 400_000_000e18);
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 + extra);
        vm.stopPrank();
        guard.registerNotStock(1);
        uint256 bal = token.balanceOf(address(splitter));
        splitter.split();
        uint256 dev = token.balanceOf(DEV);
        uint256 toDesk = token.balanceOf(address(desk));
        assertEq(dev, bal * 10 / 60);
        assertEq(dev + toDesk, bal, "no wei left behind");
        assertLe(toDesk * 10, dev * 50 + 50, "desk share is 50/60 up to rounding");
        assertGe(toDesk * 10, dev * 50);
        assertEq(token.balanceOf(address(splitter)), 0);
        if (extra == 0) {
            assertEq(dev, 100_000_000e18);
            assertEq(toDesk, 500_000_000e18);
        }
        vm.expectRevert(GenesisSplitter.AlreadySplit.selector);
        splitter.split();
        assertEq(token.balanceOf(DEV), dev);
        assertEq(token.balanceOf(address(desk)), toDesk);
    }

    function test_registerBelowSixtyPercentReverts() public {
        vm.prank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18 - 1);
        vm.expectRevert(PriceGuard.BadRecord.selector);
        guard.registerNotStock(1);
        vm.expectRevert(GenesisSplitter.NotRegistered.selector);
        splitter.split();
        vm.expectRevert(FirmVault.NotRegistered.selector);
        vault.distribute(IMD);
        assertEq(desk.bootstrapEnd(), 0);
    }
}
