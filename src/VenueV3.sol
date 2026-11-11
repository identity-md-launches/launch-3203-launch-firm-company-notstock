// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {
    IERC20,
    INfpmV3,
    INfpmCL,
    INfpmCommon,
    IV3Factory,
    ICLFactory,
    Position,
    KIND_V3,
    KIND_CL
} from "./Interfaces.sol";

/// @notice LpDesk module for the V3 and CL venue kinds (one code path, SPEC 2). Callable only by
/// LpDesk; receives exactly what LpDesk sends, mints to LpDesk, returns every unused, withdrawn or
/// collected amount to LpDesk in the same call, and holds nothing afterwards.
contract VenueV3 {
    address public immutable lpDesk;

    error NotLpDesk();
    error BadFeeTier();
    error BadKind();
    error TransferFailed();

    modifier onlyDesk() {
        if (msg.sender != lpDesk) revert NotLpDesk();
        _;
    }

    constructor() {
        lpDesk = msg.sender;
    }

    function tickSpacingFor(address venue, uint8 kind, uint24 fee, int24 tickSpacing) external view returns (int24) {
        address factory = INfpmV3(venue).factory();
        if (kind == KIND_V3) {
            int24 ts = IV3Factory(factory).feeAmountTickSpacing(fee);
            if (ts == 0) revert BadFeeTier();
            return ts;
        }
        if (kind == KIND_CL) {
            if (tickSpacing == 0 || ICLFactory(factory).tickSpacingToFee(tickSpacing) == 0) revert BadFeeTier();
            return tickSpacing;
        }
        revert BadKind();
    }

    function pool(Position calldata p) public view returns (address) {
        address factory = INfpmV3(p.venue).factory();
        if (p.kind == KIND_CL) return ICLFactory(factory).getPool(p.token0, p.token1, p.tickSpacing);
        return IV3Factory(factory).getPool(p.token0, p.token1, p.fee);
    }

    function poolPrice(Position calldata p) external view returns (uint160 sqrtPriceX96, bool exists) {
        address pl = pool(p);
        if (pl == address(0)) return (0, false);
        (bool ok, bytes memory ret) = pl.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || ret.length < 32) return (0, false);
        sqrtPriceX96 = uint160(uint256(bytes32(ret)));
        exists = sqrtPriceX96 != 0;
    }

    function createPool(Position calldata p, uint160 sqrtPriceX96) external onlyDesk {
        if (p.kind == KIND_CL) {
            ICLFactory(INfpmV3(p.venue).factory()).createPool(p.token0, p.token1, p.tickSpacing, sqrtPriceX96);
        } else {
            INfpmV3(p.venue).createAndInitializePoolIfNecessary(p.token0, p.token1, p.fee, sqrtPriceX96);
        }
    }

    function mint(Position calldata p, uint256 d0, uint256 d1, uint256 m0, uint256 m1)
        external
        onlyDesk
        returns (uint256 tokenId, uint128 liquidity)
    {
        _approve(p, d0, d1);
        if (p.kind == KIND_CL) {
            (tokenId, liquidity,,) = INfpmCL(p.venue)
                .mint(
                    INfpmCL.MintParams(
                        p.token0,
                        p.token1,
                        p.tickSpacing,
                        p.tickLower,
                        p.tickUpper,
                        d0,
                        d1,
                        m0,
                        m1,
                        lpDesk,
                        block.timestamp,
                        0
                    )
                );
        } else {
            (tokenId, liquidity,,) = INfpmV3(p.venue)
                .mint(
                    INfpmV3.MintParams(
                        p.token0, p.token1, p.fee, p.tickLower, p.tickUpper, d0, d1, m0, m1, lpDesk, block.timestamp
                    )
                );
        }
        _flush(p);
    }

    function increase(Position calldata p, uint256 d0, uint256 d1) external onlyDesk returns (uint128 liquidity) {
        _approve(p, d0, d1);
        (liquidity,,) = INfpmCommon(p.venue)
            .increaseLiquidity(INfpmCommon.IncreaseLiquidityParams(p.tokenId, d0, d1, 0, 0, block.timestamp));
        _flush(p);
    }

    function decrease(Position calldata p, uint128 liquidity, uint256 m0, uint256 m1) external onlyDesk {
        INfpmCommon(p.venue)
            .decreaseLiquidity(INfpmCommon.DecreaseLiquidityParams(p.tokenId, liquidity, m0, m1, block.timestamp));
        _collect(p);
    }

    function collect(Position calldata p) external onlyDesk {
        _collect(p);
    }

    function liquidityOf(Position calldata p) external view returns (uint128 liquidity) {
        (,,,,,,, liquidity,,,,) = INfpmCommon(p.venue).positions(p.tokenId);
    }

    /// @dev Tokens owed as recorded by the manager (updated at each collect, which pokes the pool).
    function pendingFees(Position calldata p) external view returns (uint256 f0, uint256 f1) {
        (,,,,,,,,,, uint128 o0, uint128 o1) = INfpmCommon(p.venue).positions(p.tokenId);
        return (o0, o1);
    }

    function _collect(Position calldata p) private {
        INfpmCommon(p.venue).collect(INfpmCommon.CollectParams(p.tokenId, lpDesk, type(uint128).max, type(uint128).max));
    }

    function _approve(Position calldata p, uint256 d0, uint256 d1) private {
        if (!IERC20(p.token0).approve(p.venue, d0)) revert TransferFailed();
        if (!IERC20(p.token1).approve(p.venue, d1)) revert TransferFailed();
    }

    /// @dev Returns every token left here to LpDesk and clears approvals.
    function _flush(Position calldata p) private {
        if (!IERC20(p.token0).approve(p.venue, 0)) revert TransferFailed();
        if (!IERC20(p.token1).approve(p.venue, 0)) revert TransferFailed();
        uint256 b0 = IERC20(p.token0).balanceOf(address(this));
        uint256 b1 = IERC20(p.token1).balanceOf(address(this));
        if (b0 > 0 && !IERC20(p.token0).transfer(lpDesk, b0)) revert TransferFailed();
        if (b1 > 0 && !IERC20(p.token1).transfer(lpDesk, b1)) revert TransferFailed();
    }
}
