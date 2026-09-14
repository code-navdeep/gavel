// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelRegistry} from "./GavelRegistry.sol";

/// @title GavelDecisionBase — the rules every Gavel decision type shares
/// @notice A DECISION is one question put to one fixed list of people, with a start
///         time and an end time. Every decision moves through four states, driven by
///         the owner's lock and then by the clock:
///
///         Draft      The owner is still setting it up: adding and removing voters.
///         Scheduled  The owner has locked it. Nothing about it can change any more.
///                    Voting has not started yet.
///         Open       Start time reached (the start second counts as open).
///                    People on the voter list can cast one ballot each.
///         Closed     End time reached (the end second counts as closed).
///                    No more ballots. The result can be read.
///
///         What the owner CAN do: create drafts, add and remove voters while a decision
///         is a draft, and lock it.
///         What the owner CANNOT do: cancel, pause or close a decision early, change a
///         decision after locking it, or change anyone's ballot. There are no functions
///         for any of these.
///
///         One person, one vote: ballots are counted per PERSON ID from the registry,
///         not per key. If someone's key is replaced, their new key cannot vote again.
///         Ballots are final once cast.
/// @dev Each concrete module (yes/no, choice, ranked, threshold) inherits this contract,
///      adds its own draft settings and ballot type, and calls `_admitVoter` at the start
///      of its ballot function.
abstract contract GavelDecisionBase {
    /// @notice The four states a decision moves through. See the contract description.
    enum State {
        Draft,
        Scheduled,
        Open,
        Closed
    }

    /// @notice What every decision stores, whatever its type.
    /// @param title A short description of the question.
    /// @param startTime When voting opens (Unix time, in seconds).
    /// @param endTime When voting closes (Unix time, in seconds).
    /// @param locked True once the owner has locked the decision.
    /// @param voterCount How many people are on the voter list.
    /// @param ballotCount How many of them have voted so far.
    struct DecisionInfo {
        string title;
        uint64 startTime;
        uint64 endTime;
        bool locked;
        uint32 voterCount;
        uint32 ballotCount;
    }

    /// @notice The registry address given at deployment was zero.
    error ZeroRegistry();
    /// @notice Only the registry's owner can do this.
    error NotOwner(address caller);
    /// @notice No decision exists with this number.
    error DecisionNotFound(uint256 decisionId);
    /// @notice This can only be done while the decision is a draft.
    error NotDraft(uint256 decisionId);
    /// @notice The end time must be after the start time.
    error EndNotAfterStart(uint64 startTime, uint64 endTime);
    /// @notice A decision cannot be locked once its end time has passed.
    error EndTimeInPast(uint64 endTime);
    /// @notice A decision cannot be locked with nobody on its voter list.
    error EmptyVoterList(uint256 decisionId);
    /// @notice This person ID is not in the registry.
    error PersonNotRegistered(bytes32 personId);
    /// @notice This person is marked inactive in the registry and cannot be added to new decisions.
    error PersonNotActive(bytes32 personId);
    /// @notice This person is already on the decision's voter list.
    error AlreadyOnVoterList(uint256 decisionId, bytes32 personId);
    /// @notice This person is not on the decision's voter list.
    error NotOnVoterList(uint256 decisionId, bytes32 personId);
    /// @notice Ballots can only be cast while the decision is open.
    error DecisionNotOpen(uint256 decisionId, State state);
    /// @notice Results can only be read once the decision is closed.
    error DecisionNotClosed(uint256 decisionId, State state);
    /// @notice The key sending this ballot does not belong to any registered person.
    error KeyNotRegistered(address key);
    /// @notice This person has already voted in this decision. Ballots are final.
    error AlreadyVoted(uint256 decisionId, bytes32 personId);

    /// @notice A new draft decision was created.
    event DraftCreated(uint256 indexed decisionId, string title, uint64 startTime, uint64 endTime);
    /// @notice A person was added to a draft decision's voter list.
    event VoterAdded(uint256 indexed decisionId, bytes32 indexed personId);
    /// @notice A person was removed from a draft decision's voter list.
    event VoterRemoved(uint256 indexed decisionId, bytes32 indexed personId);
    /// @notice The owner locked a decision. From now on nothing about it can change.
    event DecisionLocked(uint256 indexed decisionId, uint32 voterCount, uint64 startTime, uint64 endTime);

    /// @notice The registry that says who people are and who the owner is.
    GavelRegistry public immutable registry;

    /// @notice How many decisions have been created. Decision numbers run from 0 to decisionCount - 1.
    uint256 public decisionCount;

    mapping(uint256 decisionId => DecisionInfo) private _decisions;
    mapping(uint256 decisionId => mapping(bytes32 personId => bool)) private _isVoter;
    mapping(uint256 decisionId => mapping(bytes32 personId => bool)) private _hasVoted;

    /// @notice Allows the call only if the sender is the registry's current owner.
    modifier onlyOwner() {
        if (msg.sender != registry.owner()) revert NotOwner(msg.sender);
        _;
    }

    /// @param registry_ The deployed GavelRegistry this module uses.
    constructor(GavelRegistry registry_) {
        if (address(registry_) == address(0)) revert ZeroRegistry();
        registry = registry_;
    }

    // ──────────────────────────────── owner actions (drafts only) ────────────────────────────────

    /// @notice Add people to a draft decision's voter list. Can be called several times to add people in batches.
    /// @dev Only the owner, only while the decision is a draft. Every person must be registered
    ///      and active, and not already on the list; otherwise the whole call is refused.
    function addVoters(uint256 decisionId, bytes32[] calldata personIds) external onlyOwner {
        DecisionInfo storage decision = _draft(decisionId);

        for (uint256 i = 0; i < personIds.length; i++) {
            bytes32 personId = personIds[i];
            if (!registry.isRegistered(personId)) revert PersonNotRegistered(personId);
            if (!registry.isActive(personId)) revert PersonNotActive(personId);
            if (_isVoter[decisionId][personId]) revert AlreadyOnVoterList(decisionId, personId);

            _isVoter[decisionId][personId] = true;
            decision.voterCount += 1;

            emit VoterAdded(decisionId, personId);
        }
    }

    /// @notice Remove a person from a draft decision's voter list.
    /// @dev Only the owner, only while the decision is a draft.
    function removeVoter(uint256 decisionId, bytes32 personId) external onlyOwner {
        DecisionInfo storage decision = _draft(decisionId);
        if (!_isVoter[decisionId][personId]) revert NotOnVoterList(decisionId, personId);

        _isVoter[decisionId][personId] = false;
        decision.voterCount -= 1;

        emit VoterRemoved(decisionId, personId);
    }

    /// @notice Lock a draft decision. After this, nothing about it can change: it opens at its
    ///         start time and closes at its end time on its own.
    /// @dev Only the owner, only while the decision is a draft. Refuses an empty voter list and
    ///      an end time that has already passed. A start time in the past is allowed: the
    ///      decision is then open immediately. Each module can add its own checks.
    function lock(uint256 decisionId) external onlyOwner {
        DecisionInfo storage decision = _draft(decisionId);
        if (decision.voterCount == 0) revert EmptyVoterList(decisionId);
        // Decisions are timed by the block clock on purpose. Block producers can shift it by a few
        // seconds at most, which does not matter for decisions that last hours or days.
        // forge-lint: disable-next-line(block-timestamp)
        if (decision.endTime <= block.timestamp) revert EndTimeInPast(decision.endTime);

        _checkBeforeLock(decisionId, decision.voterCount);

        decision.locked = true;

        emit DecisionLocked(decisionId, decision.voterCount, decision.startTime, decision.endTime);
    }

    // ──────────────────────────────── lookups ────────────────────────────────

    /// @notice The current state of a decision: Draft, Scheduled, Open or Closed.
    function stateOf(uint256 decisionId) public view returns (State) {
        DecisionInfo storage decision = _existing(decisionId);
        if (!decision.locked) return State.Draft;
        // The state is driven by the block clock on purpose (see `lock`).
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < decision.startTime) return State.Scheduled;
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < decision.endTime) return State.Open;
        return State.Closed;
    }

    /// @notice Everything stored about a decision that is common to all types.
    function getDecision(uint256 decisionId) external view returns (DecisionInfo memory) {
        return _existing(decisionId);
    }

    /// @notice Whether a person is on a decision's voter list.
    function isVoter(uint256 decisionId, bytes32 personId) external view returns (bool) {
        _existing(decisionId);
        return _isVoter[decisionId][personId];
    }

    /// @notice Whether a person has already voted in a decision.
    function hasVoted(uint256 decisionId, bytes32 personId) public view returns (bool) {
        _existing(decisionId);
        return _hasVoted[decisionId][personId];
    }

    // ──────────────────────────────── for modules ────────────────────────────────

    /// @dev Creates a new draft decision and returns its number. Modules call this from their
    ///      own `createDraft`, which must be `onlyOwner`.
    function _createDraft(string calldata title, uint64 startTime, uint64 endTime)
        internal
        returns (uint256 decisionId)
    {
        if (endTime <= startTime) revert EndNotAfterStart(startTime, endTime);

        decisionId = decisionCount;
        decisionCount += 1;

        DecisionInfo storage decision = _decisions[decisionId];
        decision.title = title;
        decision.startTime = startTime;
        decision.endTime = endTime;

        emit DraftCreated(decisionId, title, startTime, endTime);
    }

    /// @dev Runs every shared check before a ballot is accepted, marks the sender's person as
    ///      having voted, and returns their person ID. Modules call this first in their ballot
    ///      function, then record the ballot itself.
    function _admitVoter(uint256 decisionId) internal returns (bytes32 personId) {
        State state = stateOf(decisionId);
        if (state != State.Open) revert DecisionNotOpen(decisionId, state);

        personId = registry.personIdOf(msg.sender);
        if (personId == bytes32(0)) revert KeyNotRegistered(msg.sender);
        if (!_isVoter[decisionId][personId]) revert NotOnVoterList(decisionId, personId);
        if (_hasVoted[decisionId][personId]) revert AlreadyVoted(decisionId, personId);

        _hasVoted[decisionId][personId] = true;
        _decisions[decisionId].ballotCount += 1;
    }

    /// @dev Refuses the call unless the decision is closed. Modules call this first in `result`.
    function _requireClosed(uint256 decisionId) internal view {
        State state = stateOf(decisionId);
        if (state != State.Closed) revert DecisionNotClosed(decisionId, state);
    }

    /// @dev Refuses the call unless the decision exists.
    function _requireExists(uint256 decisionId) internal view {
        _existing(decisionId);
    }

    /// @dev Extra checks a module wants to run when a decision is locked. Does nothing by default.
    function _checkBeforeLock(uint256 decisionId, uint32 voterCount) internal view virtual {}

    function _existing(uint256 decisionId) private view returns (DecisionInfo storage) {
        if (decisionId >= decisionCount) revert DecisionNotFound(decisionId);
        return _decisions[decisionId];
    }

    function _draft(uint256 decisionId) private view returns (DecisionInfo storage decision) {
        decision = _existing(decisionId);
        if (decision.locked) revert NotDraft(decisionId);
    }
}
