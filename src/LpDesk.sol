// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IERC20,
    IERC721Approve,
    IOFT,
    ILaunchFactory,
    IVenueModule,
    IDeskSwap,
    IPriceGuard,
    IFirmVault,
    PoolKey,
    Position,
    OpenParams,
    KIND_V4
} from "./Interfaces.sol";
import {DeskMath} from "./DeskMath.sol";
import {Burner} from "./Burner.sol";

/// @notice SPEC 2: The Firm's liquidity desk. Holds NOTSTOCK and the assets of its positions;
/// opens positions on listed venues (operator during the 7-day bootstrap, governance after),
/// splits collected fees (NOTSTOCK to Burner; other tokens 25% buyback, 25% project wallet,
/// 25% top-up basket, 25% free balance), tops up, buys back to dead, burns free NOTSTOCK.
/// Free balance of a token = its balance here minus the two baskets; NOTSTOCK has no baskets.
contract LpDesk {
    uint256 public constant BOOTSTRAP_SECONDS = 604_800;
    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 public constant MODULE_GOVERNOR = 0;
    uint8 public constant MODULE_GUARD = 1;
    uint8 public constant MODULE_VENUE_V3 = 2;
    uint8 public constant MODULE_VENUE_V4 = 3;
    uint8 public constant MODULE_SWAP = 4;

    /// @dev keccak256(type(Module).creationCode) under foundry.toml; asserted by test/Modules.t.sol.
    bytes32 public constant GOVERNOR_CODE_HASH = 0x3e6c1227d91c268c8a4aa062f01f750ced09a6908277d3adc033d485d24b45ff;
    bytes32 public constant GUARD_CODE_HASH = 0x63e3dede37bc1b5874156de2dac43f31f9613e6d936eb8ba693e2c80518d876b;
    bytes32 public constant VENUE_V3_CODE_HASH = 0x53190319686976d31a42925fb419bf291af7b5554712810c211c9119779d86bf;
    bytes32 public constant VENUE_V4_CODE_HASH = 0x5321f0ef177b5c8fb60eed1ba89ddc76c70b1b44133b3d05d27af575f5435c42;
    bytes32 public constant SWAP_CODE_HASH = 0x38d317faba523548fe922c975671a4bbe3e04e3c2885565c05394083198c0fc4;

    address public immutable token;
    address public immutable launchFactory;
    address public immutable projectWallet;
    address public immutable burner;
    address public immutable governor;
    address public immutable priceGuard;
    address public immutable venueV3;
    address public immutable venueV4;
    address public immutable deskSwap;

    address public operator;
    mapping(address => uint256) public topUpBasket;
    mapping(address => uint256) public buybackBasket;
    mapping(address => bool) private _venueApproved;
    uint256 public bridgedOutTotal;
    Position[] private _positions;

    event ModuleDeployed(uint8 indexed kind, address module);
    event OperatorChanged(address indexed previous, address indexed next);
    event PositionOpened(uint256 indexed id, address venue, address asset, uint256 tokenId, uint128 liquidity);
    event PositionClosed(uint256 indexed id);
    event PositionShifted(uint256 indexed oldId, uint256 indexed newId);
    event BalanceMoved(uint256 indexed fromId, uint256 indexed toId, uint128 liquidity);
    event FeesSplit(address indexed asset, uint256 amount);
    event TopUp(uint256 indexed id, uint256 used, uint128 liquidity);
    event Buyback(uint256 indexed id, uint256 amountIn, uint256 amountOut);
    event Burned(uint256 amount);
    event BridgedOut(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount);
    event VaultCredit(uint256 amount);

    error NotOperator();
    error NotGovernor();
    error NotFirmVault();
    error BadModule();
    error ModuleExists();
    error ModuleMissing();
    error NotRegistered();
    error BootstrapOver();
    error UnlistedAsset();
    error UnlistedVenue();
    error PriceOff();
    error MinTooLow();
    error AboveFree();
    error AboveBasket();
    error NeedsNotStock();
    error BelowMinimum();
    error NotOpen();
    error PairMismatch();
    error IsImd();
    error ZeroAddress();
    error TransferFailed();
    error ZeroLiquidity();

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    modifier onlyGovernor() {
        if (msg.sender != governor || governor.code.length == 0) revert NotGovernor();
        _;
    }

    constructor(address token_, address operator_, address projectWallet_) {
        if (token_ == address(0) || operator_ == address(0) || projectWallet_ == address(0)) revert ZeroAddress();
        token = token_;
        operator = operator_;
        projectWallet = projectWallet_;
        launchFactory = msg.sender;
        burner = address(new Burner(address(this)));
        governor = _predict(MODULE_GOVERNOR, GOVERNOR_CODE_HASH);
        priceGuard = _predict(MODULE_GUARD, GUARD_CODE_HASH);
        venueV3 = _predict(MODULE_VENUE_V3, VENUE_V3_CODE_HASH);
        venueV4 = _predict(MODULE_VENUE_V4, VENUE_V4_CODE_HASH);
        deskSwap = _predict(MODULE_SWAP, SWAP_CODE_HASH);
    }

    // ---------------------------------------------------------------- modules

    function moduleCodeHash(uint8 kind) public pure returns (bytes32) {
        if (kind == MODULE_GOVERNOR) return GOVERNOR_CODE_HASH;
        if (kind == MODULE_GUARD) return GUARD_CODE_HASH;
        if (kind == MODULE_VENUE_V3) return VENUE_V3_CODE_HASH;
        if (kind == MODULE_VENUE_V4) return VENUE_V4_CODE_HASH;
        if (kind == MODULE_SWAP) return SWAP_CODE_HASH;
        revert BadModule();
    }

    function moduleAddress(uint8 kind) public view returns (address) {
        if (kind == MODULE_GOVERNOR) return governor;
        if (kind == MODULE_GUARD) return priceGuard;
        if (kind == MODULE_VENUE_V3) return venueV3;
        if (kind == MODULE_VENUE_V4) return venueV4;
        if (kind == MODULE_SWAP) return deskSwap;
        revert BadModule();
    }

    function moduleDeployed(uint8 kind) public view returns (bool) {
        return moduleAddress(kind).code.length > 0;
    }

    /// @notice Anyone deploys a module once, by CREATE2 with salt = kind, from its fixed creation code.
    function deployModule(uint8 kind, bytes calldata creationCode) external returns (address module) {
        if (keccak256(creationCode) != moduleCodeHash(kind)) revert BadModule();
        if (moduleDeployed(kind)) revert ModuleExists();
        bytes memory code = creationCode;
        bytes32 salt = bytes32(uint256(kind));
        assembly ("memory-safe") {
            module := create2(0, add(code, 0x20), mload(code), salt)
        }
        if (module == address(0) || module != moduleAddress(kind)) revert BadModule();
        emit ModuleDeployed(kind, module);
    }

    function _predict(uint8 kind, bytes32 hash) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(uint256(kind)), hash))))
        );
    }

    function _guard() private view returns (IPriceGuard) {
        if (!moduleDeployed(MODULE_GUARD)) revert ModuleMissing();
        return IPriceGuard(priceGuard);
    }

    function _venue(uint8 kind) private view returns (IVenueModule) {
        address m = kind == KIND_V4 ? venueV4 : venueV3;
        if (m.code.length == 0) revert ModuleMissing();
        return IVenueModule(m);
    }

    // ---------------------------------------------------------------- views

    function registered() public view returns (bool) {
        return moduleDeployed(MODULE_GUARD) && IPriceGuard(priceGuard).registeredAt() != 0;
    }

    function bootstrapEnd() public view returns (uint256) {
        if (!registered()) return 0;
        return uint256(IPriceGuard(priceGuard).registeredAt()) + BOOTSTRAP_SECONDS;
    }

    function firmVault() public view returns (address) {
        return _guard().firmVault();
    }

    function poolKey() external view returns (PoolKey memory) {
        return _guard().poolKey();
    }

    function launchFactoryPoolManager() external view returns (address) {
        return ILaunchFactory(launchFactory).poolManager();
    }

    function freeBalance(address t) public view returns (uint256) {
        return IERC20(t).balanceOf(address(this)) - topUpBasket[t] - buybackBasket[t];
    }

    function positionCount() external view returns (uint256) {
        return _positions.length;
    }

    function positionOf(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @notice Open position report: liquidity and pending fees from its venue module.
    function positionReport(uint256 id)
        external
        view
        returns (Position memory p, uint128 liquidity, uint256 fees0, uint256 fees1)
    {
        p = _positions[id];
        if (p.open) {
            IVenueModule m = _venue(p.kind);
            liquidity = m.liquidityOf(p);
            (fees0, fees1) = m.pendingFees(p);
        }
    }

    function openPositions() external view returns (uint256[] memory ids) {
        uint256 n;
        for (uint256 i; i < _positions.length; ++i) {
            if (_positions[i].open) ++n;
        }
        ids = new uint256[](n);
        uint256 j;
        for (uint256 i; i < _positions.length; ++i) {
            if (_positions[i].open) ids[j++] = i;
        }
    }

    // ---------------------------------------------------------------- operator

    function setOperator(address next) external onlyOperator {
        if (next == address(0)) revert ZeroAddress();
        emit OperatorChanged(operator, next);
        operator = next;
    }

    /// @notice Direct open, operator only, during the 7-day bootstrap.
    function open(OpenParams calldata p) external onlyOperator returns (uint256 id) {
        if (!registered()) revert NotRegistered();
        if (block.timestamp >= bootstrapEnd()) revert BootstrapOver();
        return _open(p, p.amount0Min, p.amount1Min);
    }

    /// @notice Open by an executed OpenPosition proposal; minimums are exactly 99.5% at its price.
    function openByGovernor(OpenParams calldata p) external onlyGovernor returns (uint256) {
        if (!registered()) revert NotRegistered();
        return _open(p, 0, 0);
    }

    /// @notice Checks an OpenPosition proposal: the pool for `p` is absent or within 0.5% of
    /// p.sqrtPriceX96, and the amounts the range takes at the effective price (the token `amount`
    /// is read as, and the other side) fit the free balances.
    function checkOpenProposal(OpenParams calldata p) external view {
        Position memory pos = _describe(p);
        (uint160 price,) = _effectivePrice(pos, p.sqrtPriceX96);
        (uint256 d0, uint256 d1) = _desired(pos, price, p.amount);
        if (d0 > freeBalance(pos.token0) || d1 > freeBalance(pos.token1)) revert AboveFree();
    }

    /// @dev The price amounts and floors are computed at: the pool's own price when the pool exists
    /// (it must be within 0.5% of the given one, else PriceOff), otherwise the given price, at which
    /// _open creates the pool (ADAPTATION.md 8).
    function _effectivePrice(Position memory pos, uint160 given) private view returns (uint160, bool) {
        (uint160 price, bool exists) = _venue(pos.kind).poolPrice(pos);
        if (!exists) return (given, false);
        if (!DeskMath.within(price, given)) revert PriceOff();
        return (price, true);
    }

    function _describe(OpenParams calldata p) private view returns (Position memory pos) {
        IPriceGuard g = _guard();
        if (p.asset == token || !g.isAsset(p.asset)) revert UnlistedAsset();
        (uint8 kind, bool listed) = g.venueKind(p.venue);
        if (!listed) revert UnlistedVenue();
        int24 ts = _venue(kind).tickSpacingFor(p.venue, kind, p.fee, p.tickSpacing);
        (address t0, address t1) = token < p.asset ? (token, p.asset) : (p.asset, token);
        pos = Position(p.venue, kind, p.asset, t0, t1, p.fee, ts, p.tickLower, p.tickUpper, 0, false);
    }

    function _open(OpenParams calldata p, uint256 min0, uint256 min1) private returns (uint256 id) {
        Position memory pos = _describe(p);
        IVenueModule m = _venue(pos.kind);
        (uint160 price, bool exists) = _effectivePrice(pos, p.sqrtPriceX96);
        if (!exists) m.createPool(pos, p.sqrtPriceX96);
        (uint256 d0, uint256 d1) = _desired(pos, price, p.amount);
        uint256 need0 = d0 * 995 / 1000;
        uint256 need1 = d1 * 995 / 1000;
        if (msg.sender == governor) (min0, min1) = (need0, need1);
        else if (min0 < need0 || min1 < need1) revert MinTooLow();
        if (d0 > freeBalance(pos.token0) || d1 > freeBalance(pos.token1)) revert AboveFree();
        _approveVenue(pos.venue, address(m));
        (uint256 tokenId, uint128 liquidity) = _mintInto(pos, m, d0, d1, min0, min1);
        pos.tokenId = tokenId;
        pos.open = true;
        id = _positions.length;
        _positions.push(pos);
        emit PositionOpened(id, pos.venue, pos.asset, tokenId, liquidity);
    }

    /// @dev Sends d0/d1 to the module, mints to this contract, and checks what the position took
    /// (the module returns what it did not use) against the minimums.
    function _mintInto(Position memory pos, IVenueModule m, uint256 d0, uint256 d1, uint256 min0, uint256 min1)
        private
        returns (uint256 tokenId, uint128 liquidity)
    {
        (uint256 b0, uint256 b1) = _balances(pos);
        _send(pos.token0, address(m), d0);
        _send(pos.token1, address(m), d1);
        (tokenId, liquidity) = m.mint(pos, d0, d1, min0, min1);
        if (liquidity == 0) revert ZeroLiquidity();
        (uint256 a0, uint256 a1) = _balances(pos);
        if (b0 - a0 < min0 || b1 - a1 < min1) revert BelowMinimum();
    }

    /// @dev Amounts the range takes at `sqrtPriceX96` for `amount` of NOTSTOCK (or of the asset,
    /// when the range takes no NOTSTOCK at that price).
    function _desired(Position memory pos, uint160 sqrtPriceX96, uint256 amount)
        private
        view
        returns (uint256 d0, uint256 d1)
    {
        uint160 sa = DeskMath.sqrtRatioAtTick(pos.tickLower);
        uint160 sb = DeskMath.sqrtRatioAtTick(pos.tickUpper);
        bool notStock0 = pos.token0 == token;
        uint128 l = DeskMath.liquidityForDriver(sqrtPriceX96, sa, sb, amount, notStock0);
        bool driver0 = notStock0;
        if (l == 0) {
            l = DeskMath.liquidityForDriver(sqrtPriceX96, sa, sb, amount, !notStock0);
            driver0 = !notStock0;
        }
        if (l == 0) revert ZeroLiquidity();
        (d0, d1) = DeskMath.amountsForLiquidity(sqrtPriceX96, sa, sb, l);
        if (driver0) d0 = amount;
        else d1 = amount;
    }

    function _approveVenue(address venue, address module) private {
        if (!_venueApproved[venue]) {
            _venueApproved[venue] = true;
            IERC721Approve(venue).setApprovalForAll(module, true);
        }
    }

    /// @notice Close: fees collected and split first, every withdrawn amount to free balance.
    function close(uint256 id, uint256 min0, uint256 min1) external onlyOperator {
        Position memory pos = _openPos(id);
        IVenueModule m = _venue(pos.kind);
        _collectAndSplit(pos, m);
        uint128 l = m.liquidityOf(pos);
        if (l > 0) {
            (uint256 b0, uint256 b1) = _balances(pos);
            m.decrease(pos, l, min0, min1);
            _checkReceived(pos, b0, b1, min0, min1);
        }
        _positions[id].open = false;
        emit PositionClosed(id);
    }

    function collect(uint256 id) external onlyOperator {
        Position memory pos = _openPos(id);
        _collectAndSplit(pos, _venue(pos.kind));
    }

    /// @notice Shift the range (also re-splits which side is single-sided): fees split, all liquidity
    /// withdrawn (at least out0Min/out1Min), re-deposited in the new range (at least in0Min/in1Min);
    /// the rest stays free. Returns the new position id.
    function shift(
        uint256 id,
        int24 newLower,
        int24 newUpper,
        uint256 out0Min,
        uint256 out1Min,
        uint256 in0Min,
        uint256 in1Min
    ) external onlyOperator returns (uint256 newId) {
        Position memory pos = _openPos(id);
        IVenueModule m = _venue(pos.kind);
        _collectAndSplit(pos, m);
        uint128 l = m.liquidityOf(pos);
        if (l == 0) revert ZeroLiquidity();
        (uint256 b0, uint256 b1) = _balances(pos);
        m.decrease(pos, l, out0Min, out1Min);
        (uint256 w0, uint256 w1) = _checkReceived(pos, b0, b1, out0Min, out1Min);
        _positions[id].open = false;
        Position memory np = pos;
        np.tickLower = newLower;
        np.tickUpper = newUpper;
        np.tokenId = 0;
        (uint256 tokenId,) = _mintInto(np, m, w0, w1, in0Min, in1Min);
        np.tokenId = tokenId;
        np.open = true;
        newId = _positions.length;
        _positions.push(np);
        emit PositionShifted(id, newId);
    }

    /// @notice Move `liquidity` from one open position into another of the same pair.
    function move(
        uint256 fromId,
        uint256 toId,
        uint128 liquidity,
        uint256 out0Min,
        uint256 out1Min,
        uint256 in0Min,
        uint256 in1Min
    ) external onlyOperator returns (uint128 added) {
        Position memory from = _openPos(fromId);
        Position memory to = _openPos(toId);
        if (from.token0 != to.token0 || from.token1 != to.token1 || fromId == toId) revert PairMismatch();
        IVenueModule mf = _venue(from.kind);
        IVenueModule mt = _venue(to.kind);
        _collectAndSplit(from, mf);
        _collectAndSplit(to, mt);
        (uint256 b0, uint256 b1) = _balances(from);
        mf.decrease(from, liquidity, out0Min, out1Min);
        (uint256 w0, uint256 w1) = _checkReceived(from, b0, b1, out0Min, out1Min);
        _send(to.token0, address(mt), w0);
        _send(to.token1, address(mt), w1);
        (b0, b1) = _balances(to);
        added = mt.increase(to, w0, w1);
        if (added == 0) revert ZeroLiquidity();
        uint256 a0 = IERC20(to.token0).balanceOf(address(this));
        uint256 a1 = IERC20(to.token1).balanceOf(address(this));
        if (w0 - (a0 - b0) < in0Min || w1 - (a1 - b1) < in1Min) revert BelowMinimum();
        emit BalanceMoved(fromId, toId, liquidity);
    }

    /// @notice Top-up from the asset's top-up basket only; no NOTSTOCK is taken.
    function increaseLiquidity(uint256 id, uint256 amount, uint160 sqrtPriceX96, uint128 minLiquidity)
        external
        onlyOperator
        returns (uint128 added)
    {
        Position memory pos = _openPos(id);
        if (amount > topUpBasket[pos.asset]) revert AboveBasket();
        IVenueModule m = _venue(pos.kind);
        (uint160 price, bool exists) = m.poolPrice(pos);
        if (!exists || !DeskMath.within(price, sqrtPriceX96)) revert PriceOff();
        uint160 sa = DeskMath.sqrtRatioAtTick(pos.tickLower);
        uint160 sb = DeskMath.sqrtRatioAtTick(pos.tickUpper);
        bool asset0 = pos.token0 == pos.asset;
        uint128 l = DeskMath.liquidityForDriver(sqrtPriceX96, sa, sb, amount, asset0);
        if (l == 0) revert NeedsNotStock();
        (uint256 d0, uint256 d1) = DeskMath.amountsForLiquidity(sqrtPriceX96, sa, sb, l);
        if ((asset0 ? d1 : d0) != 0) revert NeedsNotStock();
        if (minLiquidity < uint128(uint256(l) * 995 / 1000)) revert MinTooLow();
        _collectAndSplit(pos, m);
        uint256 notBefore = IERC20(token).balanceOf(address(this));
        uint256 assetBefore = IERC20(pos.asset).balanceOf(address(this));
        _send(pos.asset, address(m), amount);
        added = m.increase(pos, asset0 ? amount : 0, asset0 ? 0 : amount);
        if (added < minLiquidity) revert BelowMinimum();
        if (IERC20(token).balanceOf(address(this)) != notBefore) revert NeedsNotStock();
        uint256 used = assetBefore - IERC20(pos.asset).balanceOf(address(this));
        topUpBasket[pos.asset] -= used;
        emit TopUp(id, used, added);
    }

    /// @notice Buyback from the asset's buyback basket in the position's own pool; all NOTSTOCK to dead.
    /// The basket drops only by the asset the pool actually took: what DeskSwap returns unswapped
    /// on a partial fill stays in the basket.
    function buyback(uint256 id, uint256 amount, uint256 minOut) external onlyOperator returns (uint256 out) {
        Position memory pos = _openPos(id);
        if (pos.asset == IMD) revert IsImd();
        if (amount > buybackBasket[pos.asset]) revert AboveBasket();
        if (deskSwap.code.length == 0) revert ModuleMissing();
        buybackBasket[pos.asset] -= amount;
        uint256 deadBefore = IERC20(token).balanceOf(DEAD);
        uint256 assetBefore = IERC20(pos.asset).balanceOf(address(this));
        _send(pos.asset, deskSwap, amount);
        out = IDeskSwap(deskSwap).swap(pos, pos.asset, amount, DEAD);
        uint256 spent = assetBefore - IERC20(pos.asset).balanceOf(address(this));
        if (spent > amount) revert AboveBasket();
        buybackBasket[pos.asset] += amount - spent;
        if (out < minOut || IERC20(token).balanceOf(DEAD) - deadBefore < out) revert BelowMinimum();
        emit Buyback(id, spent, out);
    }

    /// @notice Burn free NOTSTOCK to the dead address.
    function burn(uint256 amount) external onlyOperator {
        if (amount > freeBalance(token)) revert AboveFree();
        _send(token, DEAD, amount);
        emit Burned(amount);
    }

    // ---------------------------------------------------------------- FirmVault and governance

    /// @notice FirmVault credit (SPEC 2): IMD transferred first; half to the top-up basket, half free.
    function creditFromVault(uint256 amount) external {
        if (msg.sender != firmVault()) revert NotFirmVault();
        topUpBasket[IMD] += amount / 2;
        if (topUpBasket[IMD] + buybackBasket[IMD] > IERC20(IMD).balanceOf(address(this))) revert AboveFree();
        emit VaultCredit(amount);
    }

    function addAssetByGovernor(address asset) external onlyGovernor {
        _guard().addAsset(asset);
    }

    function addVenueByGovernor(address venue, uint8 kind) external onlyGovernor {
        _guard().addVenue(venue, kind);
    }

    /// @notice Executed BridgeOut: exactly `amount` of free NOTSTOCK through the record's adapter to its dstLpDesk.
    function bridgeOut(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount, address refund)
        external
        payable
        onlyGovernor
    {
        if (amount > freeBalance(token)) revert AboveFree();
        uint256 before = IERC20(token).balanceOf(address(this));
        if (!IERC20(token).approve(adapter, amount)) revert TransferFailed();
        IOFT(adapter).send{value: msg.value}(
            IOFT.SendParam(dstEid, bytes32(uint256(uint160(dstLpDesk))), amount, amount, "", "", ""),
            IOFT.MessagingFee(msg.value, 0),
            refund
        );
        if (!IERC20(token).approve(adapter, 0)) revert TransferFailed();
        if (before - IERC20(token).balanceOf(address(this)) != amount) revert AboveFree();
        bridgedOutTotal += amount;
        emit BridgedOut(adapter, dstEid, dstLpDesk, amount);
    }

    // ---------------------------------------------------------------- internals

    function _openPos(uint256 id) private view returns (Position memory pos) {
        pos = _positions[id];
        if (!pos.open) revert NotOpen();
    }

    function _balances(Position memory pos) private view returns (uint256, uint256) {
        return (IERC20(pos.token0).balanceOf(address(this)), IERC20(pos.token1).balanceOf(address(this)));
    }

    function _checkReceived(Position memory pos, uint256 b0, uint256 b1, uint256 min0, uint256 min1)
        private
        view
        returns (uint256 r0, uint256 r1)
    {
        r0 = IERC20(pos.token0).balanceOf(address(this)) - b0;
        r1 = IERC20(pos.token1).balanceOf(address(this)) - b1;
        if (r0 < min0 || r1 < min1) revert BelowMinimum();
    }

    /// @dev Collects the position's owed fees and splits the balance change of that call.
    function _collectAndSplit(Position memory pos, IVenueModule m) private {
        (uint256 b0, uint256 b1) = _balances(pos);
        m.collect(pos);
        _split(pos.token0, IERC20(pos.token0).balanceOf(address(this)) - b0);
        _split(pos.token1, IERC20(pos.token1).balanceOf(address(this)) - b1);
    }

    /// @dev NOTSTOCK 100% to Burner; others 25% buyback, 25% project, 25% top-up, the rest free.
    function _split(address t, uint256 amount) private {
        if (amount == 0) return;
        emit FeesSplit(t, amount);
        if (t == token) {
            _send(t, burner, amount);
            return;
        }
        uint256 q = amount / 4;
        if (q == 0) return;
        if (t == IMD) {
            address fv = firmVault();
            _send(t, fv, q);
            IFirmVault(fv).creditFromDesk(q);
        } else {
            buybackBasket[t] += q;
        }
        _send(t, projectWallet, q);
        topUpBasket[t] += q;
    }

    function _send(address t, address to, uint256 amount) private {
        if (amount == 0) return;
        if (!IERC20(t).transfer(to, amount)) revert TransferFailed();
    }
}
