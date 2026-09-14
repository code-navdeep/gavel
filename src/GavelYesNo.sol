// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelDecisionBase} from "./GavelDecisionBase.sol";
import {GavelRegistry} from "./GavelRegistry.sol";

/// @title GavelYesNo — decisions answered with yes or no
/// @notice Example: "Approve the Q3 budget?" Each person on the voter list answers yes or
///         no, once. After the end time, the result is Yes if more people said yes, No if
///         more said no, Tied if the numbers are equal, and NoBallots if nobody voted.
/// @dev All lifecycle rules (draft, lock, open, closed, one ballot per person) come from
///      GavelDecisionBase.
contract GavelYesNo is GavelDecisionBase {
    /// @notice What a person voted. None means they have not voted.
    enum Ballot {
        None,
        Yes,
        No
    }

    /// @notice The result of a closed decision.
    enum Outcome {
        NoBallots,
        Yes,
        No,
        Tied
    }

    /// @notice A ballot was cast. Votes are named: the person ID and key are recorded.
    event BallotCast(uint256 indexed decisionId, bytes32 indexed personId, address indexed key, bool yes);

    mapping(uint256 decisionId => uint32) private _yesCount;
    mapping(uint256 decisionId => uint32) private _noCount;
    mapping(uint256 decisionId => mapping(bytes32 personId => Ballot)) private _ballots;

    /// @param registry_ The deployed GavelRegistry this module uses.
    constructor(GavelRegistry registry_) GavelDecisionBase(registry_) {}

    /// @notice Create a draft yes/no decision. Add voters with `addVoters`, then `lock` it.
    /// @dev Only the owner. The end time must be after the start time.
    /// @return decisionId The number of the new decision.
    function createDraft(string calldata title, uint64 startTime, uint64 endTime)
        external
        onlyOwner
        returns (uint256 decisionId)
    {
        decisionId = _createDraft(title, startTime, endTime);
    }

    /// @notice Cast your ballot: true for yes, false for no. Final once cast.
    /// @dev Refused unless the decision is open, the sender's key belongs to a registered
    ///      person on the voter list, and that person has not voted yet.
    function castBallot(uint256 decisionId, bool yes) external {
        bytes32 personId = _admitVoter(decisionId);

        if (yes) {
            _yesCount[decisionId] += 1;
            _ballots[decisionId][personId] = Ballot.Yes;
        } else {
            _noCount[decisionId] += 1;
            _ballots[decisionId][personId] = Ballot.No;
        }

        emit BallotCast(decisionId, personId, msg.sender, yes);
    }

    /// @notice What a person voted in a decision (None if they have not voted).
    function ballotOf(uint256 decisionId, bytes32 personId) external view returns (Ballot) {
        _requireExists(decisionId);
        return _ballots[decisionId][personId];
    }

    /// @notice The current yes and no counts. Available at any time, because votes are named and public.
    function counts(uint256 decisionId) external view returns (uint32 yes, uint32 no) {
        _requireExists(decisionId);
        return (_yesCount[decisionId], _noCount[decisionId]);
    }

    /// @notice The final result. Only available once the decision is closed.
    /// @return outcome NoBallots, Yes, No or Tied.
    /// @return yes How many people voted yes.
    /// @return no How many people voted no.
    function result(uint256 decisionId) external view returns (Outcome outcome, uint32 yes, uint32 no) {
        _requireClosed(decisionId);

        yes = _yesCount[decisionId];
        no = _noCount[decisionId];

        if (yes == 0 && no == 0) {
            outcome = Outcome.NoBallots;
        } else if (yes > no) {
            outcome = Outcome.Yes;
        } else if (no > yes) {
            outcome = Outcome.No;
        } else {
            outcome = Outcome.Tied;
        }
    }
}
