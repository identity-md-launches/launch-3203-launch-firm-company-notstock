// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Concentrated-liquidity math written without the assembly shifts of the vendored
/// Uniswap libraries (SPEC 0): only Solidity operators, plus mulmod/div assembly for mulDiv.
library DeskMath {
    uint256 internal constant Q96 = 0x1000000000000000000000000;
    uint160 internal constant MIN_SQRT_RATIO = 4295128739;
    uint160 internal constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;

    error TickOutOfRange();
    error MulDivOverflow();
    error PriceOff();

    /// @dev Uniswap v3 TickMath.getSqrtRatioAtTick with Solidity shifts.
    function sqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > 887272) revert TickOutOfRange();
        unchecked {
            uint256 ratio =
                absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
            if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) ratio = type(uint256).max / ratio;
            sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
        }
    }

    /// @dev floor(x * y / d) with 512-bit intermediate (OpenZeppelin Math.mulDiv, no shifts).
    function mulDiv(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 prod0;
            uint256 prod1;
            assembly ("memory-safe") {
                let mm := mulmod(x, y, not(0))
                prod0 := mul(x, y)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }
            if (prod1 == 0) return prod0 / d;
            if (d <= prod1) revert MulDivOverflow();
            uint256 remainder;
            assembly ("memory-safe") {
                remainder := mulmod(x, y, d)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }
            uint256 twos = d & (0 - d);
            assembly ("memory-safe") {
                d := div(d, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;
            // Newton seed, correct to 4 bits: 3*d with bit 1 flipped (d is odd here), written
            // without the xor operator that static analysis reads as a mistyped exponent.
            uint256 inverse = d % 4 == 3 ? 3 * d + 2 : 3 * d - 2;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            inverse *= 2 - d * inverse;
            result = prod0 * inverse;
        }
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 r) {
        r = mulDiv(x, y, d);
        if (mulmod(x, y, d) > 0) r += 1;
    }

    function sort(uint160 a, uint160 b) internal pure returns (uint160, uint160) {
        return a < b ? (a, b) : (b, a);
    }

    function liquidityForAmount0(uint160 sa, uint160 sb, uint256 amount0) internal pure returns (uint128) {
        (sa, sb) = sort(sa, sb);
        uint256 intermediate = mulDiv(sa, sb, Q96);
        return toU128(mulDiv(amount0, intermediate, sb - sa));
    }

    function liquidityForAmount1(uint160 sa, uint160 sb, uint256 amount1) internal pure returns (uint128) {
        (sa, sb) = sort(sa, sb);
        return toU128(mulDiv(amount1, Q96, sb - sa));
    }

    /// @dev Amounts a position of `liquidity` over [sa, sb] takes at price `sp`, rounded up as a deposit.
    function amountsForLiquidity(uint160 sp, uint160 sa, uint160 sb, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        (sa, sb) = sort(sa, sb);
        if (sp <= sa) {
            amount0 = amount0For(sa, sb, liquidity);
        } else if (sp < sb) {
            amount0 = amount0For(sp, sb, liquidity);
            amount1 = amount1For(sa, sp, liquidity);
        } else {
            amount1 = amount1For(sa, sb, liquidity);
        }
    }

    function amount0For(uint160 sa, uint160 sb, uint128 liquidity) internal pure returns (uint256) {
        (sa, sb) = sort(sa, sb);
        uint256 num = uint256(liquidity) * Q96;
        return mulDivUp(mulDivUp(num, sb - sa, sb), 1, sa);
    }

    function amount1For(uint160 sa, uint160 sb, uint128 liquidity) internal pure returns (uint256) {
        (sa, sb) = sort(sa, sb);
        return mulDivUp(liquidity, sb - sa, Q96);
    }

    /// @dev Liquidity the range gives for `amount` of token0 (driver0) or token1 at price `sp`.
    function liquidityForDriver(uint160 sp, uint160 sa, uint160 sb, uint256 amount, bool driver0)
        internal
        pure
        returns (uint128)
    {
        (sa, sb) = sort(sa, sb);
        if (driver0) {
            if (sp >= sb) return 0;
            return liquidityForAmount0(sp > sa ? sp : sa, sb, amount);
        }
        if (sp <= sa) return 0;
        return liquidityForAmount1(sa, sp < sb ? sp : sb, amount);
    }

    /// @dev True when price(a) is within 0.5% of price(b), prices being sqrt values squared.
    function within(uint160 a, uint160 b) internal pure returns (bool) {
        if (a == 0 || b == 0) return false;
        uint256 r = mulDiv(a, 1e9, b);
        if (r < 5e8 || r > 2e9) return false;
        uint256 p = r * r; // price ratio * 1e18
        return p >= 995e15 && p <= 1005e15;
    }

    function toU128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert MulDivOverflow();
        return uint128(x);
    }
}
