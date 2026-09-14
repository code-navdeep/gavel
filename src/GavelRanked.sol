// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelDecisionBase} from "./GavelDecisionBase.sol";
import {GavelRegistry} from "./GavelRegistry.sol";

/// @title GavelRanked — ranked-choice decisions, counted by instant runoff
/// @notice Each person on the voter list ranks the options in order of preference, once.
///         They may rank all options or only some. Options are numbered from 0 in the order
///         they were given to `createDraft`.
///
///         How the result is counted (after the end time), round by round:
///         1. Every ballot counts for its highest-ranked option that is still in the race.
///            A ballot whose ranked options have all been eliminated no longer counts.
///         2. If one option has MORE THAN HALF of the ballots that still count, it wins.
///         3. Otherwise, every option tied for the lowest count is eliminated together, and
///            the next round starts.
///         4. If that would eliminate every option still in the race, the result is Tied
///            between those options.
///
///         Worked example with options 0 = Alpha, 1 = Beta, 2 = Gamma and 5 ballots:
///         [0,1] [0,2] [1,0] [1,0] [2,1].
///         Round 1: Alpha 2, Beta 2, Gamma 1 — nobody has more than half of 5, so Gamma
///         (lowest) is eliminated. Round 2: the [2,1] ballot moves to Beta: Alpha 2, Beta 3.
///         Beta has more than half of 5 and wins.
/// @dev All lifecycle rules (draft, lock, open, closed, one ballot per person) come from
///      GavelDecisionBase. The result is computed when it is read, so there is nothing to
///      finalise. MAX_OPTIONS and MAX_VOTERS keep that computation within a predictable
///      amount of gas.
contract GavelRanked is GavelDecisionBase {
    /// @notice The largest number of options a decision can have.
    uint256 public constant MAX_OPTIONS = 16;
    /// @notice The largest voter list a decision can be locked with.
    uint256 public constant MAX_VOTERS = 1_000;

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
    /// @notice A decision cannot be locked with more than MAX_VOTERS people on its voter list.
    error TooManyVoters(uint256 decisionId, uint32 voterCount, uint256 max);
    /// @notice A ballot must rank at least one option.
    error EmptyRanking();
    /// @notice A ballot cannot rank more options than the decision has.
    error RankingTooLong(uint256 given, uint256 optionCount);
    /// @notice There is no option with this number in the decision.
    error InvalidOption(uint256 decisionId, uint8 optionIndex);
    /// @notice A ballot cannot rank the same option twice.
    error DuplicateOption(uint256 decisionId, uint8 optionIndex);

    /// @notice The options of a new draft decision, in order (option 0 first).
    event OptionsSet(uint256 indexed decisionId, string[] options);
    /// @notice A ballot was cast. Votes are named: the person ID and key are recorded.
    ///         `ranking` lists option numbers from most preferred to least preferred.
    event BallotCast(uint256 indexed decisionId, bytes32 indexed personId, address indexed key, uint8[] ranking);

    mapping(uint256 decisionId => string[]) private _options;
    mapping(uint256 decisionId => uint8[][]) private _rankings;
    mapping(uint256 decisionId => mapping(bytes32 personId => uint256)) private _rankingIndex;

    /// @param registry_ The deployed GavelRegistry this module uses.
    constructor(GavelRegistry registry_) GavelDecisionBase(registry_) {}

    /// @notice Create a draft ranked-choice decision. Add voters with `addVoters`, then `lock` it.
    /// @dev Only the owner. Needs 2 to MAX_OPTIONS options. The end time must be after the start
    ///      time. When the decision is locked, its voter list must not exceed MAX_VOTERS.
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

        emit OptionsSet(decisionId, options);
    }

    /// @notice Cast your ballot: option numbers from most preferred to least preferred. Final once cast.
    /// @dev Refused unless the ranking is valid (1 to all options, each option at most once, every
    ///      number an existing option), the decision is open, the sender's key belongs to a
    ///      registered person on the voter list, and that person has not voted yet.
    function castBallot(uint256 decisionId, uint8[] calldata ranking) external {
        _requireExists(decisionId);
        uint256 optionCount = _options[decisionId].length;
        if (ranking.length == 0) revert EmptyRanking();
        if (ranking.length > optionCount) revert RankingTooLong(ranking.length, optionCount);

        bool[] memory alreadyRanked = new bool[](optionCount);
        for (uint256 i = 0; i < ranking.length; i++) {
            uint8 option = ranking[i];
            if (option >= optionCount) revert InvalidOption(decisionId, option);
            if (alreadyRanked[option]) revert DuplicateOption(decisionId, option);
            alreadyRanked[option] = true;
        }

        bytes32 personId = _admitVoter(decisionId);

        _rankingIndex[decisionId][personId] = _rankings[decisionId].length;
        _rankings[decisionId].push(ranking);

        emit BallotCast(decisionId, personId, msg.sender, ranking);
    }

    /// @notice The options of a decision, in order (option 0 first).
    function optionsOf(uint256 decisionId) external view returns (string[] memory) {
        _requireExists(decisionId);
        return _options[decisionId];
    }

    /// @notice What a person voted in a decision.
    /// @return voted False if the person has not voted (then `ranking` is empty).
    /// @return ranking Their option numbers from most preferred to least preferred.
    function ballotOf(uint256 decisionId, bytes32 personId) external view returns (bool voted, uint8[] memory ranking) {
        voted = hasVoted(decisionId, personId);
        if (voted) {
            ranking = _rankings[decisionId][_rankingIndex[decisionId][personId]];
        }
    }

    /// @notice The final result, counted by instant runoff. Only available once the decision is closed.
    /// @return outcome NoBallots, Winner or Tied.
    /// @return winners The winning option (one entry), the tied options (several entries), or
    ///         nothing (NoBallots).
    /// @return rounds How many counting rounds were needed (0 for NoBallots).
    /// @return finalRoundCounts How many ballots counted for each option in the last round, in
    ///         option order (eliminated options show 0).
    function result(uint256 decisionId)
        external
        view
        returns (Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalRoundCounts)
    {
        _requireClosed(decisionId);

        uint256 optionCount = _options[decisionId].length;
        uint8[][] memory ballots = _rankings[decisionId];

        if (ballots.length == 0) {
            return (Outcome.NoBallots, new uint8[](0), 0, new uint32[](optionCount));
        }

        bool[] memory eliminated = new bool[](optionCount);
        uint256 optionsInRace = optionCount;
        // For each ballot: which position in its ranking it currently counts for.
        uint256[] memory currentPosition = new uint256[](ballots.length);

        while (true) {
            rounds += 1;
            uint32[] memory roundCounts = new uint32[](optionCount);
            uint256 ballotsInPlay = 0;

            // Step 1: count every ballot for its highest-ranked option still in the race.
            for (uint256 b = 0; b < ballots.length; b++) {
                uint8[] memory ranking = ballots[b];
                uint256 position = currentPosition[b];
                while (position < ranking.length && eliminated[ranking[position]]) {
                    position += 1;
                }
                currentPosition[b] = position;

                if (position < ranking.length) {
                    roundCounts[ranking[position]] += 1;
                    ballotsInPlay += 1;
                }
            }

            // Step 2: an option with more than half of the ballots still in play wins.
            for (uint256 option = 0; option < optionCount; option++) {
                if (!eliminated[option] && uint256(roundCounts[option]) * 2 > ballotsInPlay) {
                    winners = new uint8[](1);
                    // casting to 'uint8' is safe because option is an option number below MAX_OPTIONS (16)
                    // forge-lint: disable-next-line(unsafe-typecast)
                    winners[0] = uint8(option);
                    return (Outcome.Winner, winners, rounds, roundCounts);
                }
            }

            // Step 3: find the lowest count among options still in the race, and how many share it.
            uint32 lowest = type(uint32).max;
            for (uint256 option = 0; option < optionCount; option++) {
                if (!eliminated[option] && roundCounts[option] < lowest) {
                    lowest = roundCounts[option];
                }
            }
            uint256 sharingLowest = 0;
            for (uint256 option = 0; option < optionCount; option++) {
                if (!eliminated[option] && roundCounts[option] == lowest) {
                    sharingLowest += 1;
                }
            }

            // Step 4: if every option still in the race shares the lowest count, it is a tie.
            if (sharingLowest == optionsInRace) {
                winners = new uint8[](optionsInRace);
                uint256 next = 0;
                for (uint256 option = 0; option < optionCount; option++) {
                    if (!eliminated[option]) {
                        // casting to 'uint8' is safe because option is an option number below MAX_OPTIONS (16)
                        // forge-lint: disable-next-line(unsafe-typecast)
                        winners[next] = uint8(option);
                        next += 1;
                    }
                }
                return (Outcome.Tied, winners, rounds, roundCounts);
            }

            // Otherwise eliminate every option with the lowest count together, and count again.
            for (uint256 option = 0; option < optionCount; option++) {
                if (!eliminated[option] && roundCounts[option] == lowest) {
                    eliminated[option] = true;
                }
            }
            optionsInRace -= sharingLowest;
        }
    }

    /// @dev When locking, the voter list must not exceed MAX_VOTERS.
    function _checkBeforeLock(uint256 decisionId, uint32 voterCount) internal pure override {
        if (voterCount > MAX_VOTERS) revert TooManyVoters(decisionId, voterCount, MAX_VOTERS);
    }
}
