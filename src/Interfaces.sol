// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
}

interface IERC721Approve {
    function setApprovalForAll(address operator, bool approved) external;
}

/// @dev Uniswap v3 style NonfungiblePositionManager (Uniswap, PancakeSwap, SushiSwap, BaseSwap).
interface INfpmV3 {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function factory() external view returns (address);
    function WETH9() external view returns (address);
    function createAndInitializePoolIfNecessary(address, address, uint24, uint160) external payable returns (address);
    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

/// @dev Aerodrome Slipstream NonfungiblePositionManager: tick spacing in place of the fee.
interface INfpmCL {
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    function mint(MintParams calldata) external payable returns (uint256, uint128, uint256, uint256);
}

/// @dev Shared by the V3 and CL position managers.
interface INfpmCommon {
    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function increaseLiquidity(IncreaseLiquidityParams calldata) external payable returns (uint128, uint256, uint256);
    function decreaseLiquidity(DecreaseLiquidityParams calldata) external payable returns (uint256, uint256);
    function collect(CollectParams calldata) external payable returns (uint256, uint256);
    /// @dev Same layout for V3 (uint24 fee) and CL (int24 tickSpacing) at word 4.
    function positions(uint256)
        external
        view
        returns (uint96, address, address, address, uint24, int24, int24, uint128, uint256, uint256, uint128, uint128);
}

interface IV3Factory {
    function getPool(address, address, uint24) external view returns (address);
    function feeAmountTickSpacing(uint24) external view returns (int24);
}

interface ICLFactory {
    function getPool(address, address, int24) external view returns (address);
    function tickSpacingToFee(int24) external view returns (uint24);
    function createPool(address, address, int24, uint160) external returns (address);
}

interface IPoolV3 {
    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96, bytes calldata)
        external
        returns (int256, int256);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

interface IPoolManager {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata) external returns (bytes memory);
    function swap(PoolKey memory, SwapParams memory, bytes calldata) external returns (int256);
    function sync(address) external;
    function settle() external payable returns (uint256);
    function take(address, address, uint256) external;
    function extsload(bytes32) external view returns (bytes32);
}

interface IPositionManagerV4 {
    function poolManager() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function initializePool(PoolKey calldata, uint160) external payable returns (int24);
    function modifyLiquidities(bytes calldata, uint256) external payable;
    function getPositionLiquidity(uint256) external view returns (uint128);
}

interface ILaunchFactory {
    function positionOf(uint64) external view returns (PoolKey memory, int24, int24, address);
    function registry() external view returns (address);
    function poolHook() external view returns (address);
    function poolManager() external view returns (address);
}

interface ILaunchRegistry {
    struct Artifact {
        bytes32 role;
        bytes32 name;
        address addr;
    }

    function artifactsOf(uint64) external view returns (Artifact[] memory);
}

interface IOFT {
    struct SendParam {
        uint32 dstEid;
        bytes32 to;
        uint256 amountLD;
        uint256 minAmountLD;
        bytes extraOptions;
        bytes composeMsg;
        bytes oftCmd;
    }

    struct MessagingFee {
        uint256 nativeFee;
        uint256 lzTokenFee;
    }

    function token() external view returns (address);
    function send(SendParam calldata, MessagingFee calldata, address)
        external
        payable
        returns (bytes memory, bytes memory);
}

/// @dev Venue kinds of SPEC 2b.
uint8 constant KIND_V4 = 0;
uint8 constant KIND_V3 = 1;
uint8 constant KIND_CL = 2;

/// @dev One LpDesk position; token0 < token1.
struct Position {
    address venue;
    uint8 kind;
    address asset;
    address token0;
    address token1;
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint256 tokenId;
    bool open;
}

/// @dev Open request of SPEC 2 (direct or by proposal).
struct OpenParams {
    address asset;
    address venue;
    uint24 fee;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint160 sqrtPriceX96;
    uint256 amount;
    uint256 amount0Min;
    uint256 amount1Min;
}

interface IVenueModule {
    function tickSpacingFor(address venue, uint8 kind, uint24 fee, int24 tickSpacing) external view returns (int24);
    function poolPrice(Position calldata p) external view returns (uint160 sqrtPriceX96, bool exists);
    function createPool(Position calldata p, uint160 sqrtPriceX96) external;
    function mint(Position calldata p, uint256 d0, uint256 d1, uint256 m0, uint256 m1)
        external
        returns (uint256 tokenId, uint128 liquidity);
    function increase(Position calldata p, uint256 d0, uint256 d1) external returns (uint128 liquidity);
    function decrease(Position calldata p, uint128 liquidity, uint256 m0, uint256 m1) external;
    function collect(Position calldata p) external;
    function liquidityOf(Position calldata p) external view returns (uint128);
    function pendingFees(Position calldata p) external view returns (uint256, uint256);
}

interface IDeskSwap {
    function swap(Position calldata p, address tokenIn, uint256 amountIn, address to) external returns (uint256 out);
}

interface IPriceGuard {
    function isAsset(address) external view returns (bool);
    function venueKind(address) external view returns (uint8 kind, bool listed);
    function registeredAt() external view returns (uint64);
    function firmVault() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
    function addAsset(address) external;
    function addVenue(address, uint8) external;
    function checkAsset(address) external view;
    function checkVenue(address, uint8) external view;
}

interface ILpDesk {
    function token() external view returns (address);
    function operator() external view returns (address);
    function burner() external view returns (address);
    function launchFactory() external view returns (address);
    function launchFactoryPoolManager() external view returns (address);
    function priceGuard() external view returns (address);
    function firmVault() external view returns (address);
    function registered() external view returns (bool);
    function poolKey() external view returns (PoolKey memory);
    function freeBalance(address) external view returns (uint256);
    function creditFromVault(uint256) external;
    function openByGovernor(OpenParams calldata) external returns (uint256);
    function addAssetByGovernor(address) external;
    function addVenueByGovernor(address, uint8) external;
    function bridgeOut(address adapter, uint32 dstEid, address dstLpDesk, uint256 amount, address refund)
        external
        payable;
    function checkOpenPrice(OpenParams calldata) external view;
}

interface IFirmVault {
    function lpDesk() external view returns (address);
    function creditFromDesk(uint256) external;
}
