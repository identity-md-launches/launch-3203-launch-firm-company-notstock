// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ILpDesk, IPoolManager, PoolKey} from "./Interfaces.sol";
import {DeskMath} from "./DeskMath.sol";

/// @notice SPEC 2.2 and 5: pool fee recipient. distribute(IMD) splits the undistributed IMD
/// 25% buyback bucket, 25% project wallet, 25% LpDesk top-up basket, 25% LpDesk free IMD;
/// distribute(NOTSTOCK) sends 100% to Burner. The buyback bucket is spent only by the operator's
/// buyback(amount, minOut) in the registered NOTSTOCK/IMD pool, all output to dead.
contract FirmVault {
    address public constant IMD = 0xFF0C532FDB8Cd566Ae169C1CB157ff2Bdc83E105;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable projectWallet;
    ILpDesk public immutable lpDeskContract;

    /// @notice IMD reserved for buybacks (SPEC 5).
    uint256 public buybackBucket;
    /// @dev Swap in flight: pool manager and hash of the expected callback data.
    address private _poolManager;
    bytes32 private _swapHash;

    event Distributed(address indexed token, uint256 amount);
    event DeskCredit(uint256 amount);
    event Buyback(uint256 amountIn, uint256 amountOut);

    error NotRegistered();
    error NotLpDesk();
    error NotOperator();
    error UnsupportedToken();
    error AboveBucket();
    error BelowMinOut();
    error NotPoolManager();
    error UnexpectedCallback();
    error TransferFailed();

    constructor(address projectWallet_, address lpDesk_) {
        projectWallet = projectWallet_;
        lpDeskContract = ILpDesk(lpDesk_);
    }

    function lpDesk() external view returns (address) {
        return address(lpDeskContract);
    }

    /// @notice Undistributed IMD = balance minus the buyback bucket.
    function undistributed() public view returns (uint256) {
        return IERC20(IMD).balanceOf(address(this)) - buybackBucket;
    }

    /// @notice LpDesk's 25% IMD buyback share (SPEC 2): transferred first, then credited here, 100% to the bucket.
    function creditFromDesk(uint256 amount) external {
        if (msg.sender != address(lpDeskContract)) revert NotLpDesk();
        buybackBucket += amount;
        if (buybackBucket > IERC20(IMD).balanceOf(address(this))) revert AboveBucket();
        emit DeskCredit(amount);
    }

    /// @notice Splits the whole undistributed balance of `token`. Integer policy: each quarter is
    /// floor(undistributed / 4); the remainder (at most 3 wei) stays undistributed for the next call.
    function distribute(address token) external {
        if (!lpDeskContract.registered()) revert NotRegistered();
        address notStock = lpDeskContract.token();
        if (token == notStock) {
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) _send(token, lpDeskContract.burner(), bal);
            emit Distributed(token, bal);
        } else if (token == IMD) {
            uint256 q = undistributed() / 4;
            if (q > 0) {
                buybackBucket += q;
                _send(IMD, projectWallet, q);
                _send(IMD, address(lpDeskContract), 2 * q);
                lpDeskContract.creditFromVault(2 * q);
            }
            emit Distributed(token, 4 * q);
        } else {
            revert UnsupportedToken();
        }
    }

    /// @notice Operator-only buyback: swaps up to `amount` IMD of the bucket for NOTSTOCK in the
    /// registered pool at its price, output below `minOut` reverts, all NOTSTOCK to dead. The bucket
    /// drops only by the IMD the pool actually took: on a partial fill the rest stays in the bucket.
    function buyback(uint256 amount, uint256 minOut) external returns (uint256 out) {
        if (msg.sender != lpDeskContract.operator()) revert NotOperator();
        if (amount > buybackBucket) revert AboveBucket();
        buybackBucket -= amount;
        PoolKey memory key = lpDeskContract.poolKey();
        address pm = ILpDesk(address(lpDeskContract)).launchFactoryPoolManager();
        bytes memory data = abi.encode(key, amount);
        _poolManager = pm;
        _swapHash = keccak256(data);
        bytes memory ret = IPoolManager(pm).unlock(data);
        _poolManager = address(0);
        _swapHash = bytes32(0);
        uint256 paid;
        (out, paid) = abi.decode(ret, (uint256, uint256));
        if (paid > amount) revert AboveBucket();
        buybackBucket += amount - paid;
        if (out < minOut) revert BelowMinOut();
        emit Buyback(paid, out);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != _poolManager || _poolManager == address(0)) revert NotPoolManager();
        if (keccak256(data) != _swapHash) revert UnexpectedCallback();
        (PoolKey memory key, uint256 amount) = abi.decode(data, (PoolKey, uint256));
        bool zeroForOne = key.currency0 == IMD;
        IPoolManager pm = IPoolManager(msg.sender);
        int256 delta = pm.swap(
            key,
            IPoolManager.SwapParams(
                zeroForOne, -int256(amount), zeroForOne ? DeskMath.MIN_SQRT_RATIO + 1 : DeskMath.MAX_SQRT_RATIO - 1
            ),
            ""
        );
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        uint256 out = uint256(uint128(zeroForOne ? a1 : a0));
        uint256 paid = uint256(uint128(-(zeroForOne ? a0 : a1)));
        pm.sync(IMD);
        _send(IMD, address(pm), paid);
        pm.settle();
        pm.take(zeroForOne ? key.currency1 : key.currency0, DEAD, out);
        return abi.encode(out, paid);
    }

    function _send(address token, address to, uint256 amount) private {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }
}
