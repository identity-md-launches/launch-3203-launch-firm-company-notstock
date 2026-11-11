// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IPoolV3, IPoolManager, PoolKey} from "../src/Interfaces.sol";
import {DeskMath} from "../src/DeskMath.sol";

/// @dev Test-only trader: swaps on a V3/CL pool or a v4 pool to generate fees and move prices.
contract Swapper {
    address private _pool;

    function swapV3(address pool, address tokenIn, bool zeroForOne, uint256 amountIn) external {
        _pool = pool;
        IPoolV3(pool)
            .swap(
                address(this),
                zeroForOne,
                int256(amountIn),
                zeroForOne ? DeskMath.MIN_SQRT_RATIO + 1 : DeskMath.MAX_SQRT_RATIO - 1,
                abi.encode(tokenIn)
            );
        _pool = address(0);
    }

    function uniswapV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _pay(a0, a1, data);
    }

    function pancakeV3SwapCallback(int256 a0, int256 a1, bytes calldata data) external {
        _pay(a0, a1, data);
    }

    function _pay(int256 a0, int256 a1, bytes calldata data) private {
        require(msg.sender == _pool, "pool");
        IERC20(abi.decode(data, (address))).transfer(msg.sender, uint256(a0 > 0 ? a0 : a1));
    }

    function swapV4(address pm, PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256 out) {
        _pool = pm;
        out = abi.decode(IPoolManager(pm).unlock(abi.encode(key, zeroForOne, amountIn)), (uint256));
        _pool = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _pool, "pm");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        IPoolManager pm = IPoolManager(msg.sender);
        int256 delta = pm.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, -int256(amountIn), zeroForOne ? DeskMath.MIN_SQRT_RATIO + 1 : DeskMath.MAX_SQRT_RATIO - 1
            ),
            ""
        );
        int128 d0 = int128(delta >> 128);
        int128 d1 = int128(delta);
        address tokenIn = zeroForOne ? key.currency0 : key.currency1;
        uint256 paid = uint256(uint128(-(zeroForOne ? d0 : d1)));
        uint256 out = uint256(uint128(zeroForOne ? d1 : d0));
        pm.sync(tokenIn);
        IERC20(tokenIn).transfer(address(pm), paid);
        pm.settle();
        pm.take(zeroForOne ? key.currency1 : key.currency0, address(this), out);
        return abi.encode(out);
    }
}
