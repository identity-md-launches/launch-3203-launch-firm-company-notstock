// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ILpDesk} from "./Interfaces.sol";

/// @notice SPEC 2c: anyone may send NOTSTOCK here; burn() moves its whole NOTSTOCK balance to dead.
contract Burner {
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    ILpDesk public immutable lpDesk;

    event Burned(uint256 amount);

    error NothingToBurn();
    error TransferFailed();

    constructor(address lpDesk_) {
        lpDesk = ILpDesk(lpDesk_);
    }

    function burn() external {
        IERC20 token = IERC20(lpDesk.token());
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert NothingToBurn();
        if (!token.transfer(DEAD, bal)) revert TransferFailed();
        emit Burned(bal);
    }
}
