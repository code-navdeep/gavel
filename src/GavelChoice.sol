// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelDecisionBase} from "./GavelDecisionBase.sol";
import {GavelRegistry} from "./GavelRegistry.sol";

/// @title GavelChoice — decisions where each person picks one option from a list
/// @notice Example: "Which of these 4 vendors do we choose?" Each person on the voter list
///         picks exactly one option, once. After the end time, the option with the most
///         votes wins. If several options share the highest count, the result is Tied and
///         lists all of them. If nobody voted, the result is NoBallots.
///
///         Options are numbered from 0 in the order they were given to `createDraft`.
/// @dev All lifecycle rules (draft, lock, open, closed, one ballot per person) come from
///      GavelDecisionBase.
contract GavelChoice is GavelDecisionBase {
    /// @notice The largest number of options a decision can have.
    uint256 public constant MAX_OPTIONS = 32;

    /// @notice The result of a closed decision.
    enum Outcome {
        NoBallots,
        Winner,
        Tied
    }

    /// @notice A decision needs at least 2 options.
    error TooFewOptions(uint256 given);
    /// @notice A decision can have at most MAX_OPTIONS options.
    error TooManyOptions(uint256 given, uint256 max);
    /// @notice There is no option with this number in the decision.
    error InvalidOption(uint256 decisionId, uint8 optionIndex);

    /// @notice The options of a new draft decision, in order (option 0 first).
    event OptionsSet(uint256 indexed decisionId, string[] options);
    /// @notice A ballot was cast. Votes are named: the person ID and key are recorded.
    event BallotCast(uint256 indexed decisionId, bytes32 indexed personId, address indexed key, uint8 optionIndex);

    mapping(uint256 decisionId => string[]) private _options;
    mapping(uint256 decisionId => uint32[]) private _counts;
    mapping(uint256 decisionId => mapping(bytes32 personId => uint8)) private _ballots;

    /// @param registry_ The deployed GavelRegistry this module uses.
    constructor(GavelRegistry registry_) GavelDecisionBase(registry_) {}

    /// @notice Create a draft decision with a list of options. Add voters with `addVoters`, then `lock` it.
    /// @dev Only the owner. Needs 2 to MAX_OPTIONS options. The end time must be after the start time.
    /// @return decisionId The number of the new decision.
    function createDraft(string calldata title, string[] calldata options, uint64 startTime, uint64 endTime)
        external
        onlyOwner
        returns (uint256 decisionId)
    {
        if (options.length < 2) revert TooFewOptions(options.length);
        if (options.length > MAX_OPTIONS) revert TooManyOptions(options.length, MAX_OPTIONS);

        decisionId = _createDraft(title, startTime, endTime);

        for (uint256 i = 0; i < options.length; i++) {
            _options[decisionId].push(options[i]);
        }
        _counts[decisionId] = new uint32[](options.length);

        emit OptionsSet(decisionId, options);
    }

    /// @notice Cast your ballot for one option (numbered from 0). Final once cast.
    /// @dev Refused unless the option exists, the decision is open, the sender's key belongs to
    ///      a registered person on the voter list, and that person has not voted yet.
    function castBallot(uint256 decisionId, uint8 optionIndex) external {
        _requireExists(decisionId);
        if (optionIndex >= _options[decisionId].length) revert InvalidOption(decisionId, optionIndex);

        bytes32 personId = _admitVoter(decisionId);

        _counts[decisionId][optionIndex] += 1;
        _ballots[decisionId][personId] = optionIndex;

        emit BallotCast(decisionId, personId, msg.sender, optionIndex);
    }

    /// @notice The options of a decision, in order (option 0 first).
    function optionsOf(uint256 decisionId) external view returns (string[] memory) {
        _requireExists(decisionId);
        return _options[decisionId];
    }

    /// @notice What a person voted in a decision.
    /// @return voted False if the person has not voted (then `optionIndex` means nothing).
    /// @return optionIndex The option they picked.
    function ballotOf(uint256 decisionId, bytes32 personId) external view returns (bool voted, uint8 optionIndex) {
        voted = hasVoted(decisionId, personId);
        optionIndex = _ballots[decisionId][personId];
    }

    /// @notice The current vote count of every option, in option order. Available at any time,
    ///         because votes are named and public.
    function counts(uint256 decisionId) external view returns (uint32[] memory) {
        _requireExists(decisionId);
        return _counts[decisionId];
    }

    /// @notice The final result. Only available once the decision is closed.
    /// @return outcome NoBallots, Winner or Tied.
    /// @return winners The winning option (one entry), the tied options (several entries), or
    ///         nothing (NoBallots).
    /// @return optionCounts The final vote count of every option, in option order.
    function result(uint256 decisionId)
        external
        view
        returns (Outcome outcome, uint8[] memory winners, uint32[] memory optionCounts)
    {
        _requireClosed(decisionId);
        optionCounts = _counts[decisionId];

        // Find the highest count, then how many options share it.
        uint32 highest = 0;
        for (uint256 i = 0; i < optionCounts.length; i++) {
            if (optionCounts[i] > highest) highest = optionCounts[i];
        }

        if (highest == 0) {
            return (Outcome.NoBallots, new uint8[](0), optionCounts);
        }

        uint256 sharingHighest = 0;
        for (uint256 i = 0; i < optionCounts.length; i++) {
            if (optionCounts[i] == highest) sharingHighest += 1;
        }

        winners = new uint8[](sharingHighest);
        uint256 next = 0;
        for (uint256 i = 0; i < optionCounts.length; i++) {
            if (optionCounts[i] == highest) {
                // casting to 'uint8' is safe because i is an option number below MAX_OPTIONS (32)
                // forge-lint: disable-next-line(unsafe-typecast)
                winners[next] = uint8(i);
                next += 1;
            }
        }

        outcome = sharingHighest == 1 ? Outcome.Winner : Outcome.Tied;
    }
}
