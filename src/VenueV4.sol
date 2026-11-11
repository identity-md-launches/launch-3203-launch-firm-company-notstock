// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, IPoolManager, IPositionManagerV4, PoolKey, Position, KIND_V4} from "./Interfaces.sol";
import {DeskMath} from "./DeskMath.sol";

/// @notice LpDesk module for the Uniswap v4 venue kind (hookless pools). Callable only by LpDesk;
/// the position manager settles from its own balance (tokens sent to it in the same call) and
/// sweeps leftovers back to LpDesk; withdrawn and collected amounts are taken to LpDesk.
contract VenueV4 {
    uint8 private constant INCREASE_LIQUIDITY = 0x00;
    uint8 private constant DECREASE_LIQUIDITY = 0x01;
    uint8 private constant MINT_POSITION = 0x02;
    uint8 private constant SETTLE = 0x0b;
    uint8 private constant TAKE_PAIR = 0x11;
    uint8 private constant SWEEP = 0x14;

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

    function tickSpacingFor(address, uint8 kind, uint24 fee, int24 tickSpacing) external pure returns (int24) {
        if (kind != KIND_V4) revert BadKind();
        if (tickSpacing <= 0 || tickSpacing > 32767 || fee > 1_000_000) revert BadFeeTier();
        return tickSpacing;
    }

    function key(Position calldata p) public pure returns (PoolKey memory) {
        return PoolKey(p.token0, p.token1, p.fee, p.tickSpacing, address(0));
    }

    function poolPrice(Position calldata p) external view returns (uint160 sqrtPriceX96, bool exists) {
        IPoolManager pm = IPoolManager(IPositionManagerV4(p.venue).poolManager());
        bytes32 id = keccak256(abi.encode(key(p)));
        bytes32 slot0 = pm.extsload(keccak256(abi.encode(id, uint256(6))));
        sqrtPriceX96 = uint160(uint256(slot0));
        exists = sqrtPriceX96 != 0;
    }

    function createPool(Position calldata p, uint160 sqrtPriceX96) external onlyDesk {
        IPositionManagerV4(p.venue).initializePool(key(p), sqrtPriceX96);
    }

    function mint(Position calldata p, uint256 d0, uint256 d1, uint256, uint256)
        external
        onlyDesk
        returns (uint256 tokenId, uint128 liquidity)
    {
        liquidity = _liquidity(p, d0, d1);
        tokenId = IPositionManagerV4(p.venue).nextTokenId();
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE, SETTLE, SWEEP, SWEEP);
        bytes[] memory params = new bytes[](5);
        params[0] =
            abi.encode(key(p), p.tickLower, p.tickUpper, uint256(liquidity), uint128(d0), uint128(d1), lpDesk, "");
        params[1] = abi.encode(p.token0, uint256(0), false);
        params[2] = abi.encode(p.token1, uint256(0), false);
        params[3] = abi.encode(p.token0, lpDesk);
        params[4] = abi.encode(p.token1, lpDesk);
        _run(p, d0, d1, actions, params);
    }

    function increase(Position calldata p, uint256 d0, uint256 d1) external onlyDesk returns (uint128 liquidity) {
        liquidity = _liquidity(p, d0, d1);
        bytes memory actions = abi.encodePacked(INCREASE_LIQUIDITY, SETTLE, SETTLE, SWEEP, SWEEP);
        bytes[] memory params = new bytes[](5);
        params[0] = abi.encode(p.tokenId, uint256(liquidity), uint128(d0), uint128(d1), "");
        params[1] = abi.encode(p.token0, uint256(0), false);
        params[2] = abi.encode(p.token1, uint256(0), false);
        params[3] = abi.encode(p.token0, lpDesk);
        params[4] = abi.encode(p.token1, lpDesk);
        _run(p, d0, d1, actions, params);
    }

    function decrease(Position calldata p, uint128 liquidity, uint256 m0, uint256 m1) external onlyDesk {
        _decrease(p, liquidity, m0, m1);
    }

    function collect(Position calldata p) external onlyDesk {
        _decrease(p, 0, 0, 0);
    }

    function liquidityOf(Position calldata p) external view returns (uint128) {
        return IPositionManagerV4(p.venue).getPositionLiquidity(p.tokenId);
    }

    /// @dev v4 keeps no per-position owed amounts outside a liquidity change; collect() reports them.
    function pendingFees(Position calldata) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function _decrease(Position calldata p, uint128 liquidity, uint256 m0, uint256 m1) private {
        bytes memory actions = abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(p.tokenId, uint256(liquidity), uint128(m0), uint128(m1), "");
        params[1] = abi.encode(p.token0, p.token1, lpDesk);
        IPositionManagerV4(p.venue).modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _run(Position calldata p, uint256 d0, uint256 d1, bytes memory actions, bytes[] memory params) private {
        if (d0 > 0 && !IERC20(p.token0).transfer(p.venue, d0)) revert TransferFailed();
        if (d1 > 0 && !IERC20(p.token1).transfer(p.venue, d1)) revert TransferFailed();
        IPositionManagerV4(p.venue).modifyLiquidities(abi.encode(actions, params), block.timestamp);
        uint256 b0 = IERC20(p.token0).balanceOf(address(this));
        uint256 b1 = IERC20(p.token1).balanceOf(address(this));
        if (b0 > 0 && !IERC20(p.token0).transfer(lpDesk, b0)) revert TransferFailed();
        if (b1 > 0 && !IERC20(p.token1).transfer(lpDesk, b1)) revert TransferFailed();
    }

    /// @dev Liquidity the pool's current price gives for the desired amounts (the lesser side).
    function _liquidity(Position calldata p, uint256 d0, uint256 d1) private view returns (uint128) {
        IPoolManager pm = IPoolManager(IPositionManagerV4(p.venue).poolManager());
        bytes32 id = keccak256(abi.encode(key(p)));
        uint160 sp = uint160(uint256(pm.extsload(keccak256(abi.encode(id, uint256(6))))));
        uint160 sa = DeskMath.sqrtRatioAtTick(p.tickLower);
        uint160 sb = DeskMath.sqrtRatioAtTick(p.tickUpper);
        if (sp <= sa) return DeskMath.liquidityForAmount0(sa, sb, d0);
        if (sp >= sb) return DeskMath.liquidityForAmount1(sa, sb, d1);
        uint128 l0 = DeskMath.liquidityForAmount0(sp, sb, d0);
        uint128 l1 = DeskMath.liquidityForAmount1(sa, sp, d1);
        return l0 < l1 ? l0 : l1;
    }
}
