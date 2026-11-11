// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey, ILaunchRegistry, IOFT, IERC20, IPoolManager} from "../src/Interfaces.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {LpDesk} from "../src/LpDesk.sol";
import {FirmVault} from "../src/FirmVault.sol";
import {GenesisSplitter} from "../src/GenesisSplitter.sol";

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
        return true;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
        return true;
    }
}

/// @dev Stands in for the launch factory off the fork: deploys the launch (so LpDesk's factory is
/// this contract), keeps a mutable record for the registration tests, and answers registry().
contract MockFactory {
    address public poolHook = address(0xA00C);
    address public poolManager = address(0xBEEF);
    PoolKey public key;
    address public requester;
    ILaunchRegistry.Artifact[] private _arts;

    LaunchToken public token;
    LpDesk public desk;
    FirmVault public vault;
    GenesisSplitter public splitter;

    constructor(address operator, address projectWallet, address devWallet, address imd) {
        token = new LaunchToken();
        desk = new LpDesk(address(token), operator, projectWallet);
        vault = new FirmVault(projectWallet, address(desk));
        splitter = new GenesisSplitter(address(desk), devWallet);
        (address c0, address c1) = address(token) < imd ? (address(token), imd) : (imd, address(token));
        key = PoolKey(c0, c1, 12500, 60, poolHook);
        requester = address(vault);
        _arts.push(ILaunchRegistry.Artifact("token", "LaunchToken", address(token)));
        _arts.push(ILaunchRegistry.Artifact("other", "LpDesk", address(desk)));
        _arts.push(ILaunchRegistry.Artifact("other", "FirmVault", address(vault)));
        _arts.push(ILaunchRegistry.Artifact("other", "GenesisSplitter", address(splitter)));
        token.transfer(projectWallet, token.totalSupply());
    }

    function positionOf(uint64) external view returns (PoolKey memory, int24, int24, address) {
        return (key, 0, 0, requester);
    }

    function registry() external view returns (address) {
        return address(this);
    }

    function artifactsOf(uint64) external view returns (ILaunchRegistry.Artifact[] memory) {
        return _arts;
    }

    function setFee(uint24 fee) external {
        key.fee = fee;
    }

    function setHooks(address h) external {
        key.hooks = h;
    }

    function setRequester(address r) external {
        requester = r;
    }

    function setArtifact(uint256 i, bytes32 name, address a) external {
        _arts[i].name = name;
        _arts[i].addr = a;
    }
}

contract OtherVault {
    address public lpDesk = address(0x1234);
}

contract MockOFT is IOFT {
    address public immutable token;
    uint256 public sent;
    bytes32 public lastTo;
    uint32 public lastEid;

    constructor(address t) {
        token = t;
    }

    function send(SendParam calldata p, MessagingFee calldata, address)
        external
        payable
        returns (bytes memory, bytes memory)
    {
        IERC20(token).transferFrom(msg.sender, address(this), p.amountLD);
        sent += p.amountLD;
        lastTo = p.to;
        lastEid = p.dstEid;
        return ("", "");
    }
}

contract BadOFT {
    address public token = address(0x5555);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata) external returns (bytes memory);
}

/// @dev A pool manager whose pool runs out of liquidity half way: an exact-input swap of X consumes
/// only X/2 (the price limit is reached) and pays 1:1 on what it consumed, from its own balance.
contract HalfDepthPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory) {
        return IUnlockCallback(msg.sender).unlockCallback(data);
    }

    function swap(PoolKey memory, IPoolManager.SwapParams memory p, bytes calldata) external pure returns (int256) {
        int256 consumed = -p.amountSpecified / 2;
        (int256 a0, int256 a1) = p.zeroForOne ? (-consumed, consumed) : (consumed, -consumed);
        return (a0 << 128) | int256(uint256(uint128(int128(a1))));
    }

    function sync(address) external {}

    function settle() external payable returns (uint256) {
        return 0;
    }

    function take(address currency, address to, uint256 amount) external {
        IERC20(currency).transfer(to, amount);
    }
}
