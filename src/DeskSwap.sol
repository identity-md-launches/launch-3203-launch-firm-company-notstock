// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IERC20,
    INfpmV3,
    IV3Factory,
    ICLFactory,
    IPoolV3,
    IPoolManager,
    IPositionManagerV4,
    PoolKey,
    Position,
    KIND_V4,
    KIND_CL
} from "./Interfaces.sol";
import {DeskMath} from "./DeskMath.sol";

/// @notice LpDesk module holding only the swap code of buyback(): exact-input swap of the asset for
/// NOTSTOCK in the position's own pool, output sent to the destination LpDesk names (dead).
contract DeskSwap {
    address public immutable lpDesk;

    address private _expectedPool;
    bytes32 private _unlockHash;

    error NotLpDesk();
    error BadPool();
    error UnexpectedCallback();
    error TransferFailed();

    constructor() {
        lpDesk = msg.sender;
    }

    /// @notice Swaps `amountIn` of `tokenIn` (already transferred here) for the pair's other token, to `to`.
    function swap(Position calldata p, address tokenIn, uint256 amountIn, address to) external returns (uint256 out) {
        if (msg.sender != lpDesk) revert NotLpDesk();
        bool zeroForOne = tokenIn == p.token0;
        if (p.kind == KIND_V4) {
            IPoolManager pm = IPoolManager(IPositionManagerV4(p.venue).poolManager());
            bytes memory data = abi.encode(p.token0, p.token1, p.fee, p.tickSpacing, zeroForOne, amountIn, to);
            _expectedPool = address(pm);
            _unlockHash = keccak256(data);
            out = abi.decode(pm.unlock(data), (uint256));
            _expectedPool = address(0);
            _unlockHash = bytes32(0);
        } else {
            address factory = INfpmV3(p.venue).factory();
            address pool = p.kind == KIND_CL
                ? ICLFactory(factory).getPool(p.token0, p.token1, p.tickSpacing)
                : IV3Factory(factory).getPool(p.token0, p.token1, p.fee);
            if (pool == address(0)) revert BadPool();
            _expectedPool = pool;
            (int256 a0, int256 a1) = IPoolV3(pool)
                .swap(
                    to,
                    zeroForOne,
                    int256(amountIn),
                    zeroForOne ? DeskMath.MIN_SQRT_RATIO + 1 : DeskMath.MAX_SQRT_RATIO - 1,
                    abi.encode(tokenIn)
                );
            _expectedPool = address(0);
            out = uint256(-(zeroForOne ? a1 : a0));
        }
        uint256 left = IERC20(tokenIn).balanceOf(address(this));
        if (left > 0 && !IERC20(tokenIn).transfer(lpDesk, left)) revert TransferFailed();
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _pay(a0, a1, data);
    }

    function pancakeV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _pay(a0, a1, data);
    }

    function _pay(int256 a0, int256 a1, bytes calldata data) private {
        if (msg.sender != _expectedPool || _expectedPool == address(0)) revert UnexpectedCallback();
        address tokenIn = abi.decode(data, (address));
        uint256 owed = uint256(a0 > 0 ? a0 : a1);
        if (!IERC20(tokenIn).transfer(msg.sender, owed)) revert TransferFailed();
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != _expectedPool || _expectedPool == address(0)) revert UnexpectedCallback();
        if (keccak256(data) != _unlockHash) revert UnexpectedCallback();
        (address t0, address t1, uint24 fee, int24 ts, bool zeroForOne, uint256 amountIn, address to) =
            abi.decode(data, (address, address, uint24, int24, bool, uint256, address));
        IPoolManager pm = IPoolManager(msg.sender);
        int256 delta = pm.swap(
            PoolKey(t0, t1, fee, ts, address(0)),
            IPoolManager.SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? DeskMath.MIN_SQRT_RATIO + 1 : DeskMath.MAX_SQRT_RATIO - 1
            ),
            ""
        );
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        address tokenIn = zeroForOne ? t0 : t1;
        uint256 paid = uint256(uint128(-(zeroForOne ? d0 : d1)));
        uint256 out = uint256(uint128(zeroForOne ? d1 : d0));
        pm.sync(tokenIn);
        if (!IERC20(tokenIn).transfer(address(pm), paid)) revert TransferFailed();
        pm.settle();
        pm.take(zeroForOne ? t1 : t0, to, out);
        return abi.encode(out);
    }
}
