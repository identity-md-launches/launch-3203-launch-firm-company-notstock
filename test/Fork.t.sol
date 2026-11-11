// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "./vendor/forge-std/Test.sol";
import {Swapper} from "./Swapper.sol";
import {MockERC20} from "./Mocks.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";
import {LpGovernor} from "../src/LpGovernor.sol";
import {PriceGuard} from "../src/PriceGuard.sol";
import {VenueV3} from "../src/VenueV3.sol";
import {VenueV4} from "../src/VenueV4.sol";
import {DeskSwap} from "../src/DeskSwap.sol";
import {DeskMath} from "../src/DeskMath.sol";
import {IERC20, OpenParams, Position, PoolKey, KIND_V3, KIND_V4, KIND_CL} from "../src/Interfaces.sol";

interface IProjectFactory {
    struct Record {
        bytes32 kind;
        uint64 launchNumber;
        uint64 recordedAt;
        bytes32 sourceCommit;
        bytes32 manifestHash;
        bytes32 attestationHash;
        bytes32 verifierKey;
        string sourceRepoUrl;
    }

    struct ProjectParams {
        uint64 launchNumber;
        bytes32 kind;
        bytes tokenCreationCode;
        bytes32 tokenName;
        bytes[] contractCreationCodes;
        bytes32[] contractNames;
        address[] expectedContracts;
        uint256 totalSupply;
        uint16 poolBps;
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        address pairedCurrency;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        Record record;
        uint256[] agentIds;
        address requester;
    }

    function launch(ProjectParams calldata p) external returns (address, address[] memory, address);
    function deployer() external view returns (address);
    function poolManager() external view returns (address);
    function predictToken(uint64, bytes calldata) external view returns (address);
    function predictContract(uint64, uint256, bytes calldata) external view returns (address);
    function positionOf(uint64) external view returns (PoolKey memory, int24, int24, address);
    function setRequester(uint64, address) external;
    function distributorOf(uint64) external view returns (address);
}

/// @notice Base mainnet fork: the launch rehearsal through the live factory, then the desk on
/// every venue of SPEC 2b, FirmVault buyback and governance opens. Skipped off the fork.
contract ForkTest is Test {
    IProjectFactory constant FACTORY = IProjectFactory(0x82EcAA82B8C1A64773D99295B1157EE502539736);
    address constant PROJECT = 0x3c587Eff6c96eAcF7E3dcC2CFf6416161386E48C;
    address constant DEV = 0x8Ad18E99F4C8d8406f9Ba8899CF308000518A981;
    address constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant BASESWAP = 0xDe151D5c92BfAA288Db4B67c21CD55d5826bCc93;
    uint64 constant LAUNCH = 777_777;

    LaunchToken token;
    LpDesk desk;
    FirmVault vault;
    GenesisSplitter splitter;
    LpGovernor gov;
    PriceGuard guard;
    Swapper swapper;
    uint256 launchGas;
    address distributor;

    function setUp() public {
        if (block.chainid != 8453) {
            vm.skip(true);
            return;
        }
        bytes memory tokenCode = type(LaunchToken).creationCode;
        address tokenAddr = FACTORY.predictToken(LAUNCH, tokenCode);
        bytes[] memory codes = new bytes[](3);
        codes[0] = abi.encodePacked(type(LpDesk).creationCode, abi.encode(tokenAddr, DEV, PROJECT));
        address deskAddr = FACTORY.predictContract(LAUNCH, 0, codes[0]);
        codes[1] = abi.encodePacked(type(FirmVault).creationCode, abi.encode(PROJECT, deskAddr));
        codes[2] = abi.encodePacked(type(GenesisSplitter).creationCode, abi.encode(deskAddr, DEV));
        address[] memory expected = new address[](3);
        expected[0] = deskAddr;
        expected[1] = FACTORY.predictContract(LAUNCH, 1, codes[1]);
        expected[2] = FACTORY.predictContract(LAUNCH, 2, codes[2]);
        bytes32[] memory names = new bytes32[](3);
        names[0] = "LpDesk";
        names[1] = "FirmVault";
        names[2] = "GenesisSplitter";
        bool token0 = tokenAddr < IMD;
        uint128 liq = token0
            ? DeskMath.liquidityForAmount0(
                DeskMath.sqrtRatioAtTick(60), DeskMath.sqrtRatioAtTick(887_220), 299_999_999e18
            )
            : DeskMath.liquidityForAmount1(
                DeskMath.sqrtRatioAtTick(-887_220), DeskMath.sqrtRatioAtTick(-60), 299_999_999e18
            );
        uint256[] memory agents = new uint256[](1);
        agents[0] = 1;
        IProjectFactory.ProjectParams memory p = IProjectFactory.ProjectParams({
            launchNumber: LAUNCH,
            kind: "evm_project",
            tokenCreationCode: tokenCode,
            tokenName: "LaunchToken",
            contractCreationCodes: codes,
            contractNames: names,
            expectedContracts: expected,
            totalSupply: 1_000_000_000e18,
            poolBps: 3000,
            remainderTo: PROJECT,
            merkleRoot: keccak256("rehearsal"),
            contributorLockSeconds: 1,
            sweepDelaySeconds: 1,
            pairedCurrency: IMD,
            tickSpacing: 60,
            sqrtPriceX96: uint160(DeskMath.Q96),
            tickLower: token0 ? int24(60) : int24(-887_220),
            tickUpper: token0 ? int24(887_220) : int24(-60),
            liquidity: liq,
            record: IProjectFactory.Record(
                "evm_project", LAUNCH, 0, keccak256("src"), keccak256("m"), keccak256("a"), keccak256("k"), "rehearsal"
            ),
            agentIds: agents,
            requester: PROJECT
        });
        vm.prank(FACTORY.deployer());
        uint256 g = gasleft();
        (address t, address[] memory cs, address d) = FACTORY.launch(p);
        launchGas = g - gasleft();
        distributor = d;
        token = LaunchToken(t);
        desk = LpDesk(cs[0]);
        vault = FirmVault(cs[1]);
        splitter = GenesisSplitter(cs[2]);
        assertEq(t, tokenAddr);
        desk.deployModule(0, type(LpGovernor).creationCode);
        desk.deployModule(1, type(PriceGuard).creationCode);
        desk.deployModule(2, type(VenueV3).creationCode);
        desk.deployModule(3, type(VenueV4).creationCode);
        desk.deployModule(4, type(DeskSwap).creationCode);
        gov = LpGovernor(desk.governor());
        guard = PriceGuard(desk.priceGuard());
        vm.startPrank(PROJECT);
        token.transfer(address(splitter), 600_000_000e18);
        FACTORY.setRequester(LAUNCH, address(vault));
        vm.stopPrank();
        guard.registerNotStock(LAUNCH);
        splitter.split();
        swapper = new Swapper();
    }

    function test_rehearsalSupplyAndRecord() public view {
        assertLt(launchGas, 16_777_216);
        assertEq(token.balanceOf(distributor), 100_000_000e18);
        assertEq(token.balanceOf(DEV), 100_000_000e18);
        assertEq(token.balanceOf(address(desk)), 500_000_000e18);
        assertEq(token.balanceOf(address(splitter)), 0);
        uint256 pool = token.balanceOf(FACTORY.poolManager());
        assertLe(pool, 300_000_000e18);
        assertEq(token.balanceOf(PROJECT), 300_000_000e18 - pool);
        (PoolKey memory key,,, address requester) = FACTORY.positionOf(LAUNCH);
        assertEq(requester, address(vault));
        assertEq(key.fee, 12500);
        PoolKey memory stored = desk.poolKey();
        assertEq(stored.currency0, key.currency0);
        assertEq(stored.hooks, key.hooks);
        assertEq(desk.firmVault(), address(vault));
        assertEq(desk.bootstrapEnd(), vm.getBlockTimestamp() + 604_800);
        assertLt(address(desk).code.length, 24_576);
        assertLt(address(vault).code.length, 10_240);
        assertLt(address(splitter).code.length, 2_048);
        assertLt(desk.burner().code.length, 1_024);
    }

    // ------------------------------------------------------------ helpers

    function _ticks(address venue, uint8 kind) internal view returns (uint24 fee, int24 ts) {
        if (kind == KIND_V4) return (3000, 60);
        if (kind == KIND_CL) return (0, venue == 0x4857DB576eE0e45F10525eC59527BfD10beeC60b ? int24(100) : int24(200));
        if (venue == 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364) return (2500, 50);
        return (3000, 60);
    }

    function _open(address venue, uint8 kind, int24 lo, int24 hi, uint256 amount) internal returns (uint256 id) {
        (uint24 fee, int24 ts) = _ticks(venue, kind);
        OpenParams memory p = OpenParams(WETH, venue, fee, ts, lo, hi, uint160(DeskMath.Q96), amount, 0, 0);
        (p.amount0Min, p.amount1Min) = _mins(p);
        vm.prank(DEV);
        id = desk.open(p);
    }

    function _mins(OpenParams memory p) internal view returns (uint256 m0, uint256 m1) {
        uint160 sa = DeskMath.sqrtRatioAtTick(p.tickLower);
        uint160 sb = DeskMath.sqrtRatioAtTick(p.tickUpper);
        bool not0 = address(token) < p.asset;
        uint128 l = DeskMath.liquidityForDriver(p.sqrtPriceX96, sa, sb, p.amount, not0);
        bool driver0 = not0;
        if (l == 0) {
            l = DeskMath.liquidityForDriver(p.sqrtPriceX96, sa, sb, p.amount, !not0);
            driver0 = !not0;
        }
        (uint256 d0, uint256 d1) = DeskMath.amountsForLiquidity(p.sqrtPriceX96, sa, sb, l);
        if (driver0) d0 = p.amount;
        else d1 = p.amount;
        m0 = d0 * 995 / 1000;
        m1 = d1 * 995 / 1000;
    }

    function _trade(uint256 id, uint256 amount) internal {
        Position memory p = desk.positionOf(id);
        deal(WETH, address(swapper), amount);
        vm.prank(DEV);
        token.transfer(address(swapper), amount);
        bool weth0 = p.token0 == WETH;
        if (p.kind == KIND_V4) {
            PoolKey memory key = PoolKey(p.token0, p.token1, p.fee, p.tickSpacing, address(0));
            address pm = VenueV4(desk.venueV4()).lpDesk() == address(desk) ? FACTORY.poolManager() : address(0);
            swapper.swapV4(pm, key, weth0, amount);
            swapper.swapV4(pm, key, !weth0, amount);
        } else {
            address pool = VenueV3(desk.venueV3()).pool(p);
            swapper.swapV3(pool, WETH, weth0, amount);
            swapper.swapV3(pool, address(token), !weth0, amount);
        }
    }

    struct Snap {
        uint256 freeW;
        uint256 topW;
        uint256 buyW;
        uint256 projW;
        uint256 burnerN;
        uint256 deskN;
    }

    function _snap() internal view returns (Snap memory s) {
        s.freeW = desk.freeBalance(WETH);
        s.topW = desk.topUpBasket(WETH);
        s.buyW = desk.buybackBasket(WETH);
        s.projW = IERC20(WETH).balanceOf(PROJECT);
        s.burnerN = token.balanceOf(desk.burner());
        s.deskN = token.balanceOf(address(desk));
    }

    /// @dev One venue: open two-sided, trade, collect (25/25/25/25 WETH, NOTSTOCK to Burner),
    /// asset-only position, top-up from the basket, shift, close to free balance, and buyback.
    function _exerciseVenue(address venue, uint8 kind) internal {
        deal(WETH, address(desk), 3_000_000e18);
        uint256 id = _open(venue, kind, -6000, 6000, 1_000_000e18);
        Position memory p = desk.positionOf(id);
        assertTrue(p.open);
        assertEq(p.venue, venue);
        (uint160 price, bool exists) =
            kind == KIND_V4 ? VenueV4(desk.venueV4()).poolPrice(p) : VenueV3(desk.venueV3()).poolPrice(p);
        assertTrue(exists);
        assertEq(price, uint160(DeskMath.Q96)); // created at exactly the given price
        _trade(id, 10_000e18);
        Snap memory b = _snap();
        vm.prank(DEV);
        desk.collect(id);
        Snap memory a = _snap();
        uint256 feeW = (a.freeW - b.freeW) + (a.topW - b.topW) + (a.buyW - b.buyW) + (a.projW - b.projW);
        assertGt(feeW, 0);
        uint256 q = feeW / 4;
        assertEq(a.buyW - b.buyW, q);
        assertEq(a.projW - b.projW, q);
        assertEq(a.topW - b.topW, q);
        assertEq(a.freeW - b.freeW, feeW - 3 * q);
        assertGt(a.burnerN - b.burnerN, 0);
        // asset-only range for top-up
        bool weth0 = WETH < address(token);
        uint256 id2 =
            _open(venue, kind, weth0 ? int24(600) : int24(-6000), weth0 ? int24(6000) : int24(-600), 10_000e18);
        uint256 top = desk.topUpBasket(WETH);
        uint256 nBefore = token.balanceOf(address(desk));
        Position memory p2 = desk.positionOf(id2);
        uint128 l = DeskMath.liquidityForDriver(
            uint160(DeskMath.Q96),
            DeskMath.sqrtRatioAtTick(p2.tickLower),
            DeskMath.sqrtRatioAtTick(p2.tickUpper),
            top,
            weth0
        );
        vm.prank(DEV);
        vm.expectRevert(LpDesk.AboveBasket.selector);
        desk.increaseLiquidity(id2, top + 1, uint160(DeskMath.Q96), 0);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.NeedsNotStock.selector);
        desk.increaseLiquidity(id, top, uint160(DeskMath.Q96), 0);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.increaseLiquidity(id2, top, uint160(DeskMath.Q96), uint128(uint256(l) * 994 / 1000));
        vm.prank(DEV);
        uint128 added = desk.increaseLiquidity(id2, top, uint160(DeskMath.Q96), uint128(uint256(l) * 995 / 1000));
        assertGe(added, uint128(uint256(l) * 995 / 1000));
        assertLt(desk.topUpBasket(WETH), top);
        assertEq(token.balanceOf(address(desk)), nBefore);
        // shift the two-sided one, operator minimum out respected
        vm.prank(DEV);
        vm.expectRevert(); // the venue's own slippage check fires first on an impossible minimum out
        desk.shift(id, -12000, 12000, type(uint256).max, 0, 0, 0);
        vm.prank(DEV);
        uint256 id3 = desk.shift(id, -12000, 12000, 0, 0, 0, 0);
        assertFalse(desk.positionOf(id).open);
        assertTrue(desk.positionOf(id3).open);
        // buyback from the WETH basket into dead
        uint256 bb = desk.buybackBasket(WETH);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.BelowMinimum.selector);
        desk.buyback(id3, bb, type(uint256).max);
        vm.prank(DEV);
        uint256 out = desk.buyback(id3, bb, 1);
        assertEq(desk.buybackBasket(WETH), 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, out);
        // close both: withdrawn amounts to free balance, baskets untouched except by the fee split
        b = _snap();
        vm.prank(DEV);
        vm.expectRevert();
        desk.close(id3, type(uint256).max, type(uint256).max);
        vm.prank(DEV);
        desk.close(id3, 0, 0);
        vm.prank(DEV);
        desk.close(id2, 0, 0);
        a = _snap();
        assertFalse(desk.positionOf(id3).open);
        assertGt(a.freeW, b.freeW);
        assertGt(a.deskN, b.deskN);
        // baskets and the project wallet move only by the fee split of the close (equal quarters)
        assertEq(a.buyW - b.buyW, a.projW - b.projW);
        assertEq(a.topW - b.topW, a.projW - b.projW);
        vm.prank(address(0xBAD));
        vm.expectRevert(LpDesk.NotOperator.selector);
        desk.close(id2, 0, 0);
        assertEq(IERC20(WETH).balanceOf(desk.venueV3()), 0);
        assertEq(IERC20(WETH).balanceOf(desk.venueV4()), 0);
        assertEq(IERC20(WETH).balanceOf(desk.deskSwap()), 0);
    }

    function test_uniswapV4() public {
        _exerciseVenue(0x7C5f5A4bBd8fD63184577525326123B519429bDc, KIND_V4);
    }

    function test_uniswapV3() public {
        _exerciseVenue(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, KIND_V3);
    }

    function test_pancakeV3() public {
        _exerciseVenue(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, KIND_V3);
    }

    function test_sushiV3() public {
        _exerciseVenue(0x80C7DD17B01855a6D2347444a0FCC36136a314de, KIND_V3);
    }

    function test_aerodromeCL() public {
        _exerciseVenue(0x827922686190790b37229fd06084350E74485b72, KIND_CL);
    }

    function test_aerodromeCL2() public {
        _exerciseVenue(0x4857DB576eE0e45F10525eC59527BfD10beeC60b, KIND_CL);
    }

    function test_unlistedVenueAndPriceCheck() public {
        deal(WETH, address(desk), 3_000_000e18);
        OpenParams memory p = OpenParams(WETH, BASESWAP, 2500, 60, -6000, 6000, uint160(DeskMath.Q96), 1e18, 0, 0);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.UnlistedVenue.selector);
        desk.open(p);
        // AddVenue of BaseSwap by the operator, passed by a staker
        vm.prank(DEV);
        token.transfer(address(this), 1000e18);
        token.approve(address(gov), 1000e18);
        gov.stake(1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(DEV);
        uint256 id = gov.proposeAddVenue(BASESWAP, KIND_V3);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        gov.execute(id);
        assertEq(guard.venues().length, 7);
        (p.amount0Min, p.amount1Min) = _mins(p);
        vm.prank(DEV);
        uint256 pid = desk.open(p);
        // price moved more than 0.5%: a second open at the old price reverts, one at the new price opens
        _trade(pid, 2_000e18);
        deal(WETH, address(swapper), 200_000e18);
        swapper.swapV3(VenueV3(desk.venueV3()).pool(desk.positionOf(pid)), WETH, WETH < address(token), 200_000e18);
        vm.prank(DEV);
        vm.expectRevert(LpDesk.PriceOff.selector);
        desk.open(p);
        (uint160 now_,) = VenueV3(desk.venueV3()).poolPrice(desk.positionOf(pid));
        p.sqrtPriceX96 = now_;
        (p.amount0Min, p.amount1Min) = _mins(p);
        vm.prank(DEV);
        desk.open(p);
        // minimum below 99.5% reverts
        p.amount0Min = p.amount0Min * 99 / 100;
        p.amount1Min = p.amount1Min * 99 / 100;
        vm.prank(DEV);
        vm.expectRevert(LpDesk.MinTooLow.selector);
        desk.open(p);
        // amount above free balance reverts
        p.amount = 600_000_000e18;
        vm.prank(DEV);
        vm.expectRevert();
        desk.open(p);
        vm.prank(DEV);
        desk.close(pid, 0, 0);
    }

    function test_governanceOpenAfterBootstrap() public {
        deal(WETH, address(desk), 3_000_000e18);
        vm.warp(desk.bootstrapEnd());
        (uint24 fee, int24 ts) = _ticks(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, KIND_V3);
        OpenParams memory p = OpenParams(
            WETH,
            0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1,
            fee,
            ts,
            -6000,
            6000,
            uint160(DeskMath.Q96),
            1_000e18,
            0,
            0
        );
        vm.prank(DEV);
        vm.expectRevert(LpDesk.BootstrapOver.selector);
        desk.open(p);
        vm.prank(DEV);
        token.transfer(address(this), 1000e18);
        token.approve(address(gov), 1000e18);
        gov.stake(1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 id = gov.proposeOpenPosition(p);
        gov.vote(id, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        gov.execute(id);
        assertEq(desk.positionCount(), 1);
        assertTrue(desk.positionOf(0).open);
        vm.expectRevert(LpGovernor.NotExecutable.selector);
        gov.execute(id);
    }

    function test_vaultBuybackInLaunchPool() public {
        deal(IMD, address(vault), 400e18);
        vault.distribute(IMD);
        assertEq(vault.buybackBucket(), 100e18);
        assertEq(IERC20(IMD).balanceOf(PROJECT), 100e18);
        assertEq(desk.topUpBasket(IMD), 100e18);
        assertEq(desk.freeBalance(IMD), 100e18);
        vm.prank(address(0xBAD));
        vm.expectRevert(FirmVault.NotOperator.selector);
        vault.buyback(1e18, 0);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.BelowMinOut.selector);
        vault.buyback(50e18, type(uint256).max);
        uint256 deadBefore = token.balanceOf(DEAD);
        vm.prank(DEV);
        uint256 out = vault.buyback(50e18, 1);
        assertGt(out, 0);
        assertEq(token.balanceOf(DEAD) - deadBefore, out);
        assertEq(vault.buybackBucket(), 50e18);
        assertEq(IERC20(IMD).balanceOf(address(vault)), 50e18);
        vm.prank(DEV);
        vm.expectRevert(FirmVault.AboveBucket.selector);
        vault.buyback(51e18, 0);
    }

    /// @dev The B20 stock addresses carry EIP-7702 delegation code (0xef0100...) on Base, which the
    /// fork resolves before vm.etch's code, so no test calls them (SPEC 6); the asset list only
    /// checks their constants (Local.t.sol). An added 8-decimal asset opens like any other.
    function test_addedEightDecimalAssetOpens() public {
        MockERC20 stock = new MockERC20("GOOGLc", "GOOGLc", 8);
        stock.mint(address(desk), 1e30); // enough at the 1:1 opening price of the test
        vm.prank(DEV);
        token.transfer(address(this), 1000e18);
        token.approve(address(gov), 1000e18);
        gov.stake(1000e18);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 pid = gov.proposeAddAsset(address(stock));
        gov.vote(pid, true);
        vm.warp(vm.getBlockTimestamp() + 5 days);
        gov.execute(pid);
        (uint24 fee, int24 ts) = _ticks(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, KIND_V3);
        OpenParams memory p = OpenParams(
            address(stock),
            0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1,
            fee,
            ts,
            -6000,
            6000,
            uint160(DeskMath.Q96),
            1_000e18,
            0,
            0
        );
        (p.amount0Min, p.amount1Min) = _mins(p);
        vm.prank(DEV);
        uint256 id = desk.open(p);
        vm.prank(DEV);
        desk.collect(id);
        vm.prank(DEV);
        desk.close(id, 0, 0);
        assertFalse(desk.positionOf(id).open);
        assertEq(stock.balanceOf(desk.venueV3()), 0);
    }
}
