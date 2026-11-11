// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20, ILpDesk, IPriceGuard, IOFT, OpenParams} from "./Interfaces.sol";

/// @notice SPEC 2a: staking with block checkpoints, one open proposal per kind per side (stakers /
/// operator), 3-day vote, 3% quorum and for-majority, 2-day operator veto, 3-day execute window.
contract LpGovernor {
    enum Kind {
        OpenPosition,
        AddAsset,
        AddVenue,
        AddBridge,
        BridgeOut
    }

    enum State {
        Active,
        Failed,
        Passed,
        Executable,
        Vetoed,
        Executed,
        Expired
    }

    struct Checkpoint {
        uint64 blockNumber;
        uint192 value;
    }

    struct Bridge {
        address adapter;
        uint32 dstChainId;
        address dstLpDesk;
    }

    struct Proposal {
        Kind kind;
        address author;
        bool byOperator;
        bool executed;
        bool vetoed;
        uint64 checkpointBlock;
        uint64 voteEnd;
        uint256 totalAtCheckpoint;
        uint256 forVotes;
        uint256 againstVotes;
        OpenParams open;
        address addr;
        uint8 venueKind;
        uint32 dstChainId;
        address dstLpDesk;
        uint256 bridgeId;
        uint256 amount;
    }

    uint256 public constant VOTE_SECONDS = 3 days;
    uint256 public constant VETO_SECONDS = 2 days;
    uint256 public constant EXECUTE_SECONDS = 259_200;
    uint256 public constant THRESHOLD_BPS_1000 = 1; // 0.1% = 1/1000
    uint256 public constant QUORUM_PERCENT = 3;

    ILpDesk public immutable lpDesk;

    mapping(address => uint256) public stakedOf;
    uint256 public totalStaked;
    mapping(address => Checkpoint[]) private _accountCps;
    Checkpoint[] private _totalCps;

    Proposal[] private _proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    /// @dev open proposal id + 1 per kind, [0] stakers' slot, [1] operator's slot.
    mapping(uint8 => uint256[2]) private _slot;

    Bridge[] private _bridges;
    mapping(uint256 => uint256) public bridgedOut;

    event Staked(address indexed who, uint256 amount);
    event Unstaked(address indexed who, uint256 amount);
    event ProposalCreated(uint256 indexed id, Kind kind, address author, bool byOperator);
    event Voted(uint256 indexed id, address indexed voter, bool support, uint256 weight);
    event Vetoed(uint256 indexed id);
    event Executed(uint256 indexed id);
    event BridgeAdded(uint256 indexed bridgeId, address adapter, uint32 dstChainId, address dstLpDesk);

    error TransferFailed();
    error AboveStake();
    error BelowThreshold();
    error SlotTaken();
    error BadProposal();
    error NotActive();
    error AlreadyVoted();
    error NoWeight();
    error NotOperator();
    error NotInVetoWindow();
    error NotExecutable();
    error BadBridge();
    error ValueNotAllowed();

    constructor() {
        lpDesk = ILpDesk(msg.sender);
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external {
        if (!IERC20(lpDesk.token()).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        stakedOf[msg.sender] += amount;
        totalStaked += amount;
        _push(_accountCps[msg.sender], stakedOf[msg.sender]);
        _push(_totalCps, totalStaked);
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external {
        if (amount > stakedOf[msg.sender]) revert AboveStake();
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        _push(_accountCps[msg.sender], stakedOf[msg.sender]);
        _push(_totalCps, totalStaked);
        if (!IERC20(lpDesk.token()).transfer(msg.sender, amount)) revert TransferFailed();
        emit Unstaked(msg.sender, amount);
    }

    function stakedAt(address who, uint256 blockNumber) public view returns (uint256) {
        return _lookup(_accountCps[who], blockNumber);
    }

    function totalStakedAt(uint256 blockNumber) public view returns (uint256) {
        return _lookup(_totalCps, blockNumber);
    }

    function _push(Checkpoint[] storage cps, uint256 value) private {
        uint256 n = cps.length;
        if (n > 0 && cps[n - 1].blockNumber == block.number) {
            cps[n - 1].value = uint192(value);
        } else {
            cps.push(Checkpoint(uint64(block.number), uint192(value)));
        }
    }

    function _lookup(Checkpoint[] storage cps, uint256 blockNumber) private view returns (uint256) {
        uint256 lo;
        uint256 hi = cps.length;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (cps[mid].blockNumber <= blockNumber) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : cps[lo - 1].value;
    }

    // ---------------------------------------------------------------- proposals

    function proposalCount() external view returns (uint256) {
        return _proposals.length;
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return _proposals[id];
    }

    function bridgeCount() external view returns (uint256) {
        return _bridges.length;
    }

    function bridge(uint256 id) external view returns (Bridge memory) {
        return _bridges[id];
    }

    function state(uint256 id) public view returns (State) {
        Proposal storage p = _proposals[id];
        if (p.executed) return State.Executed;
        if (p.vetoed) return State.Vetoed;
        if (block.timestamp < p.voteEnd) return State.Active;
        uint256 quorum = p.totalAtCheckpoint * QUORUM_PERCENT / 100;
        bool passed = p.forVotes + p.againstVotes >= quorum && p.forVotes > p.againstVotes;
        if (!passed) return State.Failed;
        if (block.timestamp < p.voteEnd + VETO_SECONDS) return State.Passed;
        if (block.timestamp < p.voteEnd + VETO_SECONDS + EXECUTE_SECONDS) return State.Executable;
        return State.Expired;
    }

    /// @notice Vote end, veto end and expiry of a proposal.
    function deadlines(uint256 id) external view returns (uint256 voteEnd, uint256 vetoEnd, uint256 expiry) {
        voteEnd = _proposals[id].voteEnd;
        vetoEnd = voteEnd + VETO_SECONDS;
        expiry = vetoEnd + EXECUTE_SECONDS;
    }

    function isOpen(uint256 id) public view returns (bool) {
        State s = state(id);
        return s == State.Active || s == State.Passed || s == State.Executable;
    }

    function proposeOpenPosition(OpenParams calldata open) external returns (uint256 id) {
        if (open.amount > lpDesk.freeBalance(lpDesk.token())) revert BadProposal();
        lpDesk.checkOpenPrice(open);
        id = _create(Kind.OpenPosition);
        _proposals[id].open = open;
    }

    function proposeAddAsset(address asset) external returns (uint256 id) {
        IPriceGuard(lpDesk.priceGuard()).checkAsset(asset);
        id = _create(Kind.AddAsset);
        _proposals[id].addr = asset;
    }

    function proposeAddVenue(address positionManager, uint8 kind) external returns (uint256 id) {
        IPriceGuard(lpDesk.priceGuard()).checkVenue(positionManager, kind);
        id = _create(Kind.AddVenue);
        _proposals[id].addr = positionManager;
        _proposals[id].venueKind = kind;
    }

    function proposeAddBridge(address adapter, uint32 dstChainId, address dstLpDesk) external returns (uint256 id) {
        _checkAdapter(adapter);
        if (dstLpDesk == address(0)) revert BadBridge();
        id = _create(Kind.AddBridge);
        _proposals[id].addr = adapter;
        _proposals[id].dstChainId = dstChainId;
        _proposals[id].dstLpDesk = dstLpDesk;
    }

    function proposeBridgeOut(uint256 bridgeId, uint256 amount) external returns (uint256 id) {
        if (bridgeId >= _bridges.length) revert BadBridge();
        if (amount == 0 || amount > lpDesk.freeBalance(lpDesk.token())) revert BadProposal();
        id = _create(Kind.BridgeOut);
        _proposals[id].bridgeId = bridgeId;
        _proposals[id].amount = amount;
    }

    function _create(Kind kind) private returns (uint256 id) {
        bool byOperator = msg.sender == lpDesk.operator();
        if (!byOperator) {
            uint256 s = stakedOf[msg.sender];
            if (s == 0 || s * 1000 < totalStaked) revert BelowThreshold();
        }
        uint256[2] storage slot = _slot[uint8(kind)];
        uint256 taken = slot[byOperator ? 1 : 0];
        if (taken != 0 && isOpen(taken - 1)) revert SlotTaken();
        id = _proposals.length;
        Proposal storage p = _proposals.push();
        p.kind = kind;
        p.author = msg.sender;
        p.byOperator = byOperator;
        p.checkpointBlock = uint64(block.number - 1);
        p.voteEnd = uint64(block.timestamp + VOTE_SECONDS);
        p.totalAtCheckpoint = totalStakedAt(block.number - 1);
        slot[byOperator ? 1 : 0] = id + 1;
        emit ProposalCreated(id, kind, msg.sender, byOperator);
    }

    function vote(uint256 id, bool support) external {
        if (state(id) != State.Active) revert NotActive();
        if (hasVoted[id][msg.sender]) revert AlreadyVoted();
        uint256 w = stakedAt(msg.sender, _proposals[id].checkpointBlock);
        if (w == 0) revert NoWeight();
        hasVoted[id][msg.sender] = true;
        if (support) _proposals[id].forVotes += w;
        else _proposals[id].againstVotes += w;
        emit Voted(id, msg.sender, support, w);
    }

    function veto(uint256 id) external {
        if (msg.sender != lpDesk.operator()) revert NotOperator();
        if (state(id) != State.Passed) revert NotInVetoWindow();
        _proposals[id].vetoed = true;
        emit Vetoed(id);
    }

    /// @notice Performs the passed, unvetoed proposal's action once. msg.value only for BridgeOut.
    function execute(uint256 id) external payable {
        if (state(id) != State.Executable) revert NotExecutable();
        Proposal storage p = _proposals[id];
        p.executed = true;
        if (p.kind != Kind.BridgeOut && msg.value != 0) revert ValueNotAllowed();
        if (p.kind == Kind.OpenPosition) {
            lpDesk.openByGovernor(p.open);
        } else if (p.kind == Kind.AddAsset) {
            lpDesk.addAssetByGovernor(p.addr);
        } else if (p.kind == Kind.AddVenue) {
            lpDesk.addVenueByGovernor(p.addr, p.venueKind);
        } else if (p.kind == Kind.AddBridge) {
            _checkAdapter(p.addr);
            _bridges.push(Bridge(p.addr, p.dstChainId, p.dstLpDesk));
            emit BridgeAdded(_bridges.length - 1, p.addr, p.dstChainId, p.dstLpDesk);
        } else {
            Bridge memory b = _bridges[p.bridgeId];
            bridgedOut[p.bridgeId] += p.amount;
            lpDesk.bridgeOut{value: msg.value}(b.adapter, b.dstChainId, b.dstLpDesk, p.amount, msg.sender);
        }
        emit Executed(id);
    }

    function _checkAdapter(address adapter) private view {
        if (adapter.code.length == 0) revert BadBridge();
        (bool ok, bytes memory ret) = adapter.staticcall(abi.encodeWithSelector(IOFT.token.selector));
        if (!ok || ret.length < 32 || abi.decode(ret, (address)) != lpDesk.token()) revert BadBridge();
    }
}
