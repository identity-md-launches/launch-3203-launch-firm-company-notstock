// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ILpDesk} from "./Interfaces.sol";

/// @notice SPEC 2.3: once it holds NOTSTOCK and registration succeeded, anyone may split() once:
/// 10/60 of the balance to the dev wallet, 50/60 (the rest, so no wei is left) to LpDesk.
contract GenesisSplitter {
    ILpDesk public immutable lpDesk;
    address public immutable devWallet;

    event Split(uint256 toLpDesk, uint256 toDev);

    error NotRegistered();
    error NothingToSplit();
    error TransferFailed();

    constructor(address lpDesk_, address devWallet_) {
        lpDesk = ILpDesk(lpDesk_);
        devWallet = devWallet_;
    }

    function split() external {
        if (!lpDesk.registered()) revert NotRegistered();
        IERC20 token = IERC20(lpDesk.token());
        uint256 bal = token.balanceOf(address(this));
        if (bal == 0) revert NothingToSplit();
        uint256 dev = bal * 10 / 60;
        uint256 desk = bal - dev;
        if (!token.transfer(devWallet, dev)) revert TransferFailed();
        if (!token.transfer(address(lpDesk), desk)) revert TransferFailed();
        emit Split(desk, dev);
    }
}
