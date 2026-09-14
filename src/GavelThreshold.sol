// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelDecisionBase} from "./GavelDecisionBase.sol";
import {GavelRegistry} from "./GavelRegistry.sol";

/// @title GavelThreshold — approvals that need a minimum turnout and a minimum level of support
/// @notice Each person on the voter list either approves or rejects, once. After the end time,
///         the decision is Approved only if ALL of its rules are met:
///
///         1. Quorum — at least `minBallots` people voted.
///         2. Minimum approvals — at least `minApprovals` people approved.
///         3. Minimum share (optional) — at least `minApprovalShareNumerator` approvals for every
///            `minApprovalShareDenominator` ballots cast. The share is an exact fraction, so
///            "two-thirds" is 2 and 3, and exactly 2 approvals out of 3 ballots passes.
///            Set both numbers to 0 to not use a share.
///
///         Otherwise the result says which rule failed: QuorumNotMet (rule 1) or
///         ThresholdNotMet (rule 2 or 3).
///
///         Example "3 of these 5 managers must sign off": voter list of 5 managers,
///         minBallots 0, minApprovals 3, share 0 and 0.
///         Example "at least 120 of 200 members vote, and two-thirds of them approve":
///         voter list of 200, minBallots 120, minApprovals 1, share 2 and 3.
/// @dev All lifecycle rules (draft, lock, open, closed, one ballot per person) come from
///      GavelDecisionBase.
contract GavelThreshold is GavelDecisionBase {
    /// @notice What a person voted. None means they have not voted.
    enum Ballot {
        None,
        Approve,
        Reject
    }

    /// @notice The result of a closed decision.
    enum Outcome {
        Approved,
        QuorumNotMet,
        ThresholdNotMet
    }

    /// @notice The rules a decision must meet to be approved.
    /// @param minBallots At least this many people must vote.
    /// @param minApprovals At least this many people must approve.
    /// @param minApprovalShareNumerator With the denominator: at least this many approvals for
    ///        every `minApprovalShareDenominator` ballots. 0 when no share is used.
    /// @param minApprovalShareDenominator 0 when no share is used.
    struct Rules {
        uint32 minBallots;
        uint32 minApprovals;
        uint32 minApprovalShareNumerator;
        uint32 minApprovalShareDenominator;
    }

    /// @notice minApprovals must be at least 1; otherwise a decision could pass with no support.
    error ZeroMinApprovals();
    /// @notice A share must be both numbers 0 (not used), or a numerator from 1 up to the denominator.
    error InvalidShare(uint32 numerator, uint32 denominator);
    /// @notice minApprovals cannot be more than the number of people on the voter list.
    error MinApprovalsAboveVoterCount(uint256 decisionId, uint32 minApprovals, uint32 voterCount);
    /// @notice minBallots cannot be more than the number of people on the voter list.
    error MinBallotsAboveVoterCount(uint256 decisionId, uint32 minBallots, uint32 voterCount);

    /// @notice The rules of a new draft decision.
    event RulesSet(
        uint256 indexed decisionId,
        uint32 minBallots,
        uint32 minApprovals,
        uint32 minApprovalShareNumerator,
        uint32 minApprovalShareDenominator
    );
    /// @notice A ballot was cast. Votes are named: the person ID and key are recorded.
    event BallotCast(uint256 indexed decisionId, bytes32 indexed personId, address indexed key, bool approve);

    mapping(uint256 decisionId => Rules) private _rules;
    mapping(uint256 decisionId => uint32) private _approvals;
    mapping(uint256 decisionId => uint32) private _rejections;
    mapping(uint256 decisionId => mapping(bytes32 personId => Ballot)) private _ballots;

    /// @param registry_ The deployed GavelRegistry this module uses.
    constructor(GavelRegistry registry_) GavelDecisionBase(registry_) {}

    /// @notice Create a draft approval decision with its rules. Add voters with `addVoters`, then `lock` it.
    /// @dev Only the owner. Refuses minApprovals of 0 and an invalid share (see `InvalidShare`). The
    ///      end time must be after the start time. When the decision is locked, minBallots and
    ///      minApprovals must not exceed the number of people on the voter list.
    /// @return decisionId The number of the new decision.
    function createDraft(
        string calldata title,
        uint64 startTime,
        uint64 endTime,
        uint32 minBallots,
        uint32 minApprovals,
        uint32 minApprovalShareNumerator,
        uint32 minApprovalShareDenominator
    ) external onlyOwner returns (uint256 decisionId) {
        if (minApprovals == 0) revert ZeroMinApprovals();

        bool shareUnused = minApprovalShareNumerator == 0 && minApprovalShareDenominator == 0;
        bool shareValid = minApprovalShareNumerator >= 1 && minApprovalShareNumerator <= minApprovalShareDenominator;
        if (!shareUnused && !shareValid) {
            revert InvalidShare(minApprovalShareNumerator, minApprovalShareDenominator);
        }

        decisionId = _createDraft(title, startTime, endTime);

        _rules[decisionId] = Rules({
            minBallots: minBallots,
            minApprovals: minApprovals,
            minApprovalShareNumerator: minApprovalShareNumerator,
            minApprovalShareDenominator: minApprovalShareDenominator
        });

        emit RulesSet(decisionId, minBallots, minApprovals, minApprovalShareNumerator, minApprovalShareDenominator);
    }

    /// @notice Cast your ballot: true to approve, false to reject. Final once cast.
    /// @dev Refused unless the decision is open, the sender's key belongs to a registered
    ///      person on the voter list, and that person has not voted yet.
    function castBallot(uint256 decisionId, bool approve) external {
        bytes32 personId = _admitVoter(decisionId);

        if (approve) {
            _approvals[decisionId] += 1;
            _ballots[decisionId][personId] = Ballot.Approve;
        } else {
            _rejections[decisionId] += 1;
            _ballots[decisionId][personId] = Ballot.Reject;
        }

        emit BallotCast(decisionId, personId, msg.sender, approve);
    }

    /// @notice The rules of a decision.
    function rulesOf(uint256 decisionId) external view returns (Rules memory) {
        _requireExists(decisionId);
        return _rules[decisionId];
    }

    /// @notice What a person voted in a decision (None if they have not voted).
    function ballotOf(uint256 decisionId, bytes32 personId) external view returns (Ballot) {
        _requireExists(decisionId);
        return _ballots[decisionId][personId];
    }

    /// @notice The current approval and rejection counts. Available at any time, because votes are named and public.
    function counts(uint256 decisionId) external view returns (uint32 approvals, uint32 rejections) {
        _requireExists(decisionId);
        return (_approvals[decisionId], _rejections[decisionId]);
    }

    /// @notice The final result. Only available once the decision is closed.
    /// @return outcome Approved, QuorumNotMet or ThresholdNotMet.
    /// @return approvals How many people approved.
    /// @return rejections How many people rejected.
    function result(uint256 decisionId) external view returns (Outcome outcome, uint32 approvals, uint32 rejections) {
        _requireClosed(decisionId);

        Rules memory rules = _rules[decisionId];
        approvals = _approvals[decisionId];
        rejections = _rejections[decisionId];
        uint256 ballots = uint256(approvals) + uint256(rejections);

        // Share rule: approvals / ballots >= numerator / denominator, compared without division
        // as approvals × denominator >= ballots × numerator, so no rounding is involved.
        bool shareUsed = rules.minApprovalShareDenominator != 0;
        bool shareMet = uint256(approvals) * uint256(rules.minApprovalShareDenominator)
            >= ballots * uint256(rules.minApprovalShareNumerator);

        if (ballots < rules.minBallots) {
            outcome = Outcome.QuorumNotMet;
        } else if (approvals < rules.minApprovals) {
            outcome = Outcome.ThresholdNotMet;
        } else if (shareUsed && !shareMet) {
            outcome = Outcome.ThresholdNotMet;
        } else {
            outcome = Outcome.Approved;
        }
    }

    /// @dev When locking, the rules must be achievable with the voter list as it stands.
    function _checkBeforeLock(uint256 decisionId, uint32 voterCount) internal view override {
        Rules memory rules = _rules[decisionId];
        if (rules.minApprovals > voterCount) {
            revert MinApprovalsAboveVoterCount(decisionId, rules.minApprovals, voterCount);
        }
        if (rules.minBallots > voterCount) {
            revert MinBallotsAboveVoterCount(decisionId, rules.minBallots, voterCount);
        }
    }
}
