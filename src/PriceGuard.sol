// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IERC20,
    ILpDesk,
    IFirmVault,
    ILaunchFactory,
    ILaunchRegistry,
    INfpmV3,
    IPositionManagerV4,
    PoolKey,
    KIND_V4,
    KIND_V3,
    KIND_CL
} from "./Interfaces.sol";

/// @notice SPEC 2b: the fixed venue and asset lists (extended only by executed AddVenue / AddAsset
/// through LpDesk) and the one-time NOTSTOCK registration against the launch factory's record.
contract PriceGuard {
    struct Venue {
        address positionManager;
        uint8 kind;
        address factory;
    }

    struct Asset {
        address token;
        uint8 decimals;
    }

    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant WETH = 0x4200000000000000000000000000000000000006;
    uint24 public constant POOL_FEE = 12500;
    uint256 public constant REQUIRED_SUPPLY = 1_000_000_000e18;

    ILpDesk public immutable lpDesk;

    Venue[] private _venues;
    mapping(address => uint256) private _venueIndex; // index + 1
    Asset[] private _assets;
    mapping(address => bool) public isAsset;

    uint64 public registeredAt;
    uint64 public launchNumber;
    address public firmVault;
    address public genesisSplitter;
    PoolKey private _poolKey;

    event Registered(uint64 launchNumber, address firmVault, uint64 at);
    event AssetAdded(address asset);
    event VenueAdded(address positionManager, uint8 kind, address factory);

    error NotLpDesk();
    error AlreadyRegistered();
    error BadRecord();
    error BadAsset();
    error BadVenue();

    constructor() {
        lpDesk = ILpDesk(msg.sender);
        _addVenue(0x7C5f5A4bBd8fD63184577525326123B519429bDc, KIND_V4, 0x498581fF718922c3f8e6A244956aF099B2652b2b);
        _addVenue(0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1, KIND_V3, 0x33128a8fC17869897dcE68Ed026d694621f6FDfD);
        _addVenue(0x46A15B0b27311cedF172AB29E4f4766fbE7F4364, KIND_V3, 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865);
        _addVenue(0x80C7DD17B01855a6D2347444a0FCC36136a314de, KIND_V3, 0xc35DADB65012eC5796536bD9864eD8773aBc74C4);
        _addVenue(0x827922686190790b37229fd06084350E74485b72, KIND_CL, 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);
        _addVenue(0x4857DB576eE0e45F10525eC59527BfD10beeC60b, KIND_CL, 0x9CB220581b91b0C83223012FE69688b92aD07a76);
        _addAsset(IMD, 18);
        _addAsset(WETH, 18);
        _addAsset(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913, 6);
        _addAsset(0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf, 8);
        _addAsset(0xb2000000000000000000002D0BA3164cc74f58B7, 8);
        _addAsset(0xb200000000000000000000397293Cb8cda9a10c5, 8);
        _addAsset(0xb20000000000000000000078ee7ce2fE4908108C, 8);
        _addAsset(0xb2000000000000000000008bC8786B856E61707C, 8);
        _addAsset(0xb2000000000000000000007b9fcbd005511aCBd5, 8);
        _addAsset(0xB200000000000000000000Ab99cFa739E253872B, 8);
        _addAsset(0xb200000000000000000000C2e324d24d7eEcd1fb, 8);
        _addAsset(0xB2000000000000000000000d8Ce462E99ee7A47B, 8);
        _addAsset(0xb2000000000000000000007d16372840dF4dAbbe, 8);
    }

    // ---------------------------------------------------------------- views

    function venues() external view returns (Venue[] memory) {
        return _venues;
    }

    function assets() external view returns (Asset[] memory) {
        return _assets;
    }

    function venueKind(address positionManager) external view returns (uint8 kind, bool listed) {
        uint256 i = _venueIndex[positionManager];
        if (i == 0) return (0, false);
        return (_venues[i - 1].kind, true);
    }

    function venueFactory(address positionManager) external view returns (address) {
        uint256 i = _venueIndex[positionManager];
        if (i == 0) revert BadVenue();
        return _venues[i - 1].factory;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    /// @notice AddAsset gate: zero, NOTSTOCK or already listed reverts.
    function checkAsset(address asset) public view {
        if (asset == address(0) || asset == lpDesk.token() || isAsset[asset]) revert BadAsset();
    }

    /// @notice AddVenue gate: zero, listed, no code, or not answering as its kind reverts.
    function checkVenue(address positionManager, uint8 kind) public view returns (address factory) {
        if (positionManager == address(0) || _venueIndex[positionManager] != 0 || positionManager.code.length == 0) {
            revert BadVenue();
        }
        if (kind == KIND_V4) {
            (bool ok, bytes memory ret) =
                positionManager.staticcall(abi.encodeWithSelector(IPositionManagerV4.poolManager.selector));
            if (!ok || ret.length < 32) revert BadVenue();
            factory = abi.decode(ret, (address));
            if (factory.code.length == 0) revert BadVenue();
        } else if (kind == KIND_V3 || kind == KIND_CL) {
            (bool ok, bytes memory ret) = positionManager.staticcall(abi.encodeWithSelector(INfpmV3.factory.selector));
            if (!ok || ret.length < 32) revert BadVenue();
            factory = abi.decode(ret, (address));
            if (factory.code.length == 0) revert BadVenue();
            (ok, ret) = positionManager.staticcall(abi.encodeWithSelector(INfpmV3.WETH9.selector));
            if (!ok || ret.length < 32 || abi.decode(ret, (address)) != WETH) revert BadVenue();
        } else {
            revert BadVenue();
        }
    }

    // ---------------------------------------------------------------- LpDesk only

    function addAsset(address asset) external {
        if (msg.sender != address(lpDesk)) revert NotLpDesk();
        checkAsset(asset);
        _addAsset(asset, 0);
    }

    function addVenue(address positionManager, uint8 kind) external {
        if (msg.sender != address(lpDesk)) revert NotLpDesk();
        address factory = checkVenue(positionManager, kind);
        _addVenue(positionManager, kind, factory);
    }

    // ---------------------------------------------------------------- registration

    /// @notice Once, by anyone: checks the launch factory's record of `launchNumber_` is this launch
    /// and stores the pool key, the fee recipient (FirmVault) and the block time (bootstrap start).
    function registerNotStock(uint64 launchNumber_) external {
        if (registeredAt != 0) revert AlreadyRegistered();
        ILaunchFactory factory = ILaunchFactory(lpDesk.launchFactory());
        address token = lpDesk.token();
        (PoolKey memory key,,, address requester) = factory.positionOf(launchNumber_);
        (address c0, address c1) = token < IMD ? (token, IMD) : (IMD, token);
        if (key.currency0 != c0 || key.currency1 != c1 || key.fee != POOL_FEE || key.hooks != factory.poolHook()) {
            revert BadRecord();
        }
        if (
            keccak256(bytes(IERC20(token).name())) != keccak256("notSTOCK")
                || keccak256(bytes(IERC20(token).symbol())) != keccak256("NOTSTOCK")
                || IERC20(token).totalSupply() != REQUIRED_SUPPLY
        ) revert BadRecord();
        ILaunchRegistry.Artifact[] memory arts = ILaunchRegistry(factory.registry()).artifactsOf(launchNumber_);
        address splitter;
        bool deskFound;
        bool tokenFound;
        for (uint256 i; i < arts.length; ++i) {
            if (arts[i].role == bytes32("token") && arts[i].addr == token) tokenFound = true;
            if (arts[i].name == bytes32("LpDesk") && arts[i].addr == address(lpDesk)) deskFound = true;
            if (arts[i].name == bytes32("GenesisSplitter")) splitter = arts[i].addr;
        }
        if (!tokenFound || !deskFound || splitter == address(0)) revert BadRecord();
        if (IERC20(token).balanceOf(splitter) < REQUIRED_SUPPLY * 60 / 100) revert BadRecord();
        if (requester.code.length == 0) revert BadRecord();
        (bool ok, bytes memory ret) = requester.staticcall(abi.encodeWithSelector(IFirmVault.lpDesk.selector));
        if (!ok || ret.length < 32 || abi.decode(ret, (address)) != address(lpDesk)) revert BadRecord();
        _poolKey = key;
        firmVault = requester;
        genesisSplitter = splitter;
        launchNumber = launchNumber_;
        registeredAt = uint64(block.timestamp);
        emit Registered(launchNumber_, requester, uint64(block.timestamp));
    }

    function _addVenue(address pm, uint8 kind, address factory) private {
        _venues.push(Venue(pm, kind, factory));
        _venueIndex[pm] = _venues.length;
        emit VenueAdded(pm, kind, factory);
    }

    function _addAsset(address asset, uint8 dec) private {
        isAsset[asset] = true;
        _assets.push(Asset(asset, dec));
        emit AssetAdded(asset);
    }
}
