// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {GavelRanked} from "../src/GavelRanked.sol";
import {GavelTestBase} from "./helpers/GavelTestBase.sol";

contract GavelRankedTest is GavelTestBase {
    uint256 internal constant PEOPLE = 12;
    /// @dev The largest amount of gas reading a ranked result may use at the size limits.
    uint256 internal constant RESULT_GAS_BUDGET = 30_000_000;

    GavelRanked internal ranked;

    function setUp() public override {
        super.setUp();
        ranked = new GavelRanked(registry);
        _registerPeople(PEOPLE);
    }

    function _options(uint256 count) internal pure returns (string[] memory options) {
        options = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            options[i] = string.concat("Option ", vm.toString(i));
        }
    }

    function _lockedDecision(uint256 optionCount, uint256 voters) internal returns (uint256 decisionId) {
        vm.startPrank(owner);
        decisionId = ranked.createDraft("Choose the office location", _options(optionCount), VOTING_OPENS, VOTING_CLOSES);
        ranked.addVoters(decisionId, _firstPeople(voters));
        ranked.lock(decisionId);
        vm.stopPrank();
    }

    function _vote(uint256 decisionId, uint256 person, uint8[] memory ranking) internal {
        vm.prank(personKeys[person]);
        ranked.castBallot(decisionId, ranking);
    }

    function _r1(uint8 a) internal pure returns (uint8[] memory r) {
        r = new uint8[](1);
        r[0] = a;
    }

    function _r2(uint8 a, uint8 b) internal pure returns (uint8[] memory r) {
        r = new uint8[](2);
        r[0] = a;
        r[1] = b;
    }

    function _result(uint256 decisionId)
        internal
        view
        returns (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts)
    {
        return ranked.result(decisionId);
    }

    // ─────────────────────────────── drafts ───────────────────────────────

    function test_CreateDraft_RefusesTooFewOptions() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRanked.TooFewOptions.selector, 1));
        ranked.createDraft("x", _options(1), VOTING_OPENS, VOTING_CLOSES);
    }

    function test_CreateDraft_RefusesTooManyOptions() public {
        uint256 maxOptions = ranked.MAX_OPTIONS();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRanked.TooManyOptions.selector, maxOptions + 1, maxOptions));
        ranked.createDraft("x", _options(maxOptions + 1), VOTING_OPENS, VOTING_CLOSES);
    }

    function test_CreateDraft_StoresOptionsInOrder() public {
        vm.expectEmit(true, true, true, true, address(ranked));
        emit GavelRanked.OptionsSet(0, _options(3));
        uint256 id = _lockedDecision(3, PEOPLE);

        string[] memory stored = ranked.optionsOf(id);
        assertEq(stored.length, 3);
        assertEq(stored[1], "Option 1");
    }

    function test_Lock_RefusesMoreThanMaxVoters() public {
        uint256 maxVoters = ranked.MAX_VOTERS();
        _registerPeople(maxVoters + 1 - PEOPLE);

        vm.startPrank(owner);
        uint256 id = ranked.createDraft("x", _options(2), VOTING_OPENS, VOTING_CLOSES);
        ranked.addVoters(id, _firstPeople(maxVoters + 1));
        vm.expectRevert(abi.encodeWithSelector(GavelRanked.TooManyVoters.selector, id, maxVoters + 1, maxVoters));
        ranked.lock(id);
        vm.stopPrank();
    }

    // ─────────────────────────────── ballots ───────────────────────────────

    function test_Ballot_RefusesEmptyRanking() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        vm.prank(personKeys[0]);
        vm.expectRevert(GavelRanked.EmptyRanking.selector);
        ranked.castBallot(id, new uint8[](0));
    }

    function test_Ballot_RefusesRankingLongerThanOptions() public {
        uint256 id = _lockedDecision(2, PEOPLE);
        _openVoting();
        uint8[] memory tooLong = new uint8[](3);
        tooLong[0] = 0;
        tooLong[1] = 1;
        tooLong[2] = 0;
        vm.prank(personKeys[0]);
        vm.expectRevert(abi.encodeWithSelector(GavelRanked.RankingTooLong.selector, 3, 2));
        ranked.castBallot(id, tooLong);
    }

    function test_Ballot_RefusesMissingOption() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        vm.prank(personKeys[0]);
        vm.expectRevert(abi.encodeWithSelector(GavelRanked.InvalidOption.selector, id, 3));
        ranked.castBallot(id, _r2(0, 3));
    }

    function test_Ballot_RefusesSameOptionTwice() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        vm.prank(personKeys[0]);
        vm.expectRevert(abi.encodeWithSelector(GavelRanked.DuplicateOption.selector, id, 1));
        ranked.castBallot(id, _r2(1, 1));
    }

    function test_BallotOf_BeforeAndAfter() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();

        (bool voted, uint8[] memory ranking) = ranked.ballotOf(id, personIds[0]);
        assertFalse(voted);
        assertEq(ranking.length, 0);

        _vote(id, 0, _r2(2, 0));
        (voted, ranking) = ranked.ballotOf(id, personIds[0]);
        assertTrue(voted);
        assertEq(ranking.length, 2);
        assertEq(ranking[0], 2);
        assertEq(ranking[1], 0);
    }

    function test_BallotCast_EventIsNamed() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        vm.expectEmit(true, true, true, true, address(ranked));
        emit GavelRanked.BallotCast(id, personIds[0], personKeys[0], _r2(1, 0));
        _vote(id, 0, _r2(1, 0));
    }

    // ─────────────────────────────── outcomes ───────────────────────────────

    function test_Result_NoBallots() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _closeVoting();
        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts) =
            _result(id);
        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.NoBallots));
        assertEq(winners.length, 0);
        assertEq(rounds, 0);
        assertEq(finalCounts.length, 3);
    }

    function test_Result_FirstRoundMajority() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        _vote(id, 0, _r2(2, 0));
        _vote(id, 1, _r2(2, 1));
        _vote(id, 2, _r1(0));
        _closeVoting();

        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts) =
            _result(id);
        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Winner));
        assertEq(winners[0], 2);
        assertEq(rounds, 1);
        assertEq(finalCounts[2], 2);
        assertEq(finalCounts[0], 1);
    }

    /// @dev The worked example in GavelRanked's description: [0,1] [0,2] [1,0] [1,0] [2,1].
    function test_Result_WorkedExampleFromTheContract() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        _vote(id, 0, _r2(0, 1));
        _vote(id, 1, _r2(0, 2));
        _vote(id, 2, _r2(1, 0));
        _vote(id, 3, _r2(1, 0));
        _vote(id, 4, _r2(2, 1));
        _closeVoting();

        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts) =
            _result(id);
        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Winner));
        assertEq(winners[0], 1); // Beta
        assertEq(rounds, 2);
        assertEq(finalCounts[0], 2);
        assertEq(finalCounts[1], 3);
        assertEq(finalCounts[2], 0);
    }

    /// @dev Round 1: A 3, B 2, C 2 of 7 — no majority; B and C share the lowest count and are
    ///      eliminated together. Their single-choice ballots drop out. Round 2: A has 3 of the 3
    ///      ballots still in play and wins, although 3 is not a majority of all 7 ballots.
    function test_Result_ExhaustedBallotsDropOut() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        _vote(id, 0, _r1(0));
        _vote(id, 1, _r1(0));
        _vote(id, 2, _r1(0));
        _vote(id, 3, _r1(1));
        _vote(id, 4, _r1(1));
        _vote(id, 5, _r1(2));
        _vote(id, 6, _r1(2));
        _closeVoting();

        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts) =
            _result(id);
        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Winner));
        assertEq(winners[0], 0);
        assertEq(rounds, 2);
        assertEq(finalCounts[0], 3);
        assertEq(finalCounts[1], 0);
        assertEq(finalCounts[2], 0);
    }

    /// @dev Round 1: A 4, B 3, C 1, D 1 of 9 — C and D are eliminated together and both their
    ///      ballots move to B. Round 2: B 5 of 9 wins.
    function test_Result_TiedLowestEliminatedTogetherAndTransfer() public {
        uint256 id = _lockedDecision(4, PEOPLE);
        _openVoting();
        for (uint256 p = 0; p < 4; p++) {
            _vote(id, p, _r1(0));
        }
        for (uint256 p = 4; p < 7; p++) {
            _vote(id, p, _r1(1));
        }
        _vote(id, 7, _r2(2, 1));
        _vote(id, 8, _r2(3, 1));
        _closeVoting();

        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts) =
            _result(id);
        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Winner));
        assertEq(winners[0], 1);
        assertEq(rounds, 2);
        assertEq(finalCounts[0], 4);
        assertEq(finalCounts[1], 5);
    }

    function test_Result_FinalTie() public {
        uint256 id = _lockedDecision(3, PEOPLE);
        _openVoting();
        _vote(id, 0, _r1(0));
        _vote(id, 1, _r1(1));
        _closeVoting();

        // Round 1: A 1, B 1, C 0 — C eliminated. Round 2: A 1, B 1 — every option left shares the
        // lowest count, so it is a tie between A and B.
        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds,) = _result(id);
        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Tied));
        assertEq(winners.length, 2);
        assertEq(winners[0], 0);
        assertEq(winners[1], 1);
        assertEq(rounds, 2);
    }

    // ─────────────────────────────── fuzz ───────────────────────────────

    /// @dev A pseudo-random valid ranking: a shuffled list of the options, cut to a random length.
    function _randomRanking(uint256 seed, uint256 optionCount) internal pure returns (uint8[] memory ranking) {
        uint8[] memory order = new uint8[](optionCount);
        for (uint8 i = 0; i < optionCount; i++) {
            order[i] = i;
        }
        for (uint256 i = optionCount - 1; i > 0; i--) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % (i + 1);
            (order[i], order[j]) = (order[j], order[i]);
        }
        uint256 length = 1 + (uint256(keccak256(abi.encode(seed, "length"))) % optionCount);
        ranking = new uint8[](length);
        for (uint256 i = 0; i < length; i++) {
            ranking[i] = order[i];
        }
    }

    /// @dev For any ballots: a winner holds more than half of the final round; a tie lists every
    ///      option still in the race, all with the same count; and an option that is the first
    ///      choice of more than half of all voters wins in round 1.
    function testFuzz_ResultFollowsInstantRunoff(uint256 seed, uint256 optionCount, uint256 voters) public {
        optionCount = bound(optionCount, 2, 6);
        voters = bound(voters, 1, PEOPLE);

        uint256 id = _lockedDecision(optionCount, PEOPLE);
        _openVoting();
        uint256[] memory firstChoiceCounts = new uint256[](optionCount);
        for (uint256 v = 0; v < voters; v++) {
            uint8[] memory ranking = _randomRanking(uint256(keccak256(abi.encode(seed, v))), optionCount);
            firstChoiceCounts[ranking[0]] += 1;
            _vote(id, v, ranking);
        }
        _closeVoting();

        (GavelRanked.Outcome outcome, uint8[] memory winners, uint256 rounds, uint32[] memory finalCounts) =
            _result(id);
        assertTrue(outcome != GavelRanked.Outcome.NoBallots);
        assertGe(rounds, 1);
        assertLe(rounds, optionCount);

        uint256 inPlay = 0;
        for (uint256 o = 0; o < optionCount; o++) {
            inPlay += finalCounts[o];
        }

        if (outcome == GavelRanked.Outcome.Winner) {
            assertEq(winners.length, 1);
            assertGt(uint256(finalCounts[winners[0]]) * 2, inPlay);
        } else {
            assertGe(winners.length, 2);
            uint256 tiedSum = 0;
            for (uint256 w = 0; w < winners.length; w++) {
                assertEq(finalCounts[winners[w]], finalCounts[winners[0]]);
                tiedSum += finalCounts[winners[w]];
            }
            assertEq(tiedSum, inPlay); // options not in the tie were eliminated and hold nothing
        }

        for (uint256 o = 0; o < optionCount; o++) {
            if (firstChoiceCounts[o] * 2 > voters) {
                assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Winner));
                assertEq(winners[0], o);
                assertEq(rounds, 1);
            }
        }
    }

    // ─────────────────────────────── gas at the limits ───────────────────────────────

    /// @dev Builds the most expensive result to count at MAX_OPTIONS and MAX_VOTERS:
    ///      - first choices are spread so every option has a different count (option o is the
    ///        first choice on o+1 of every 136 ballots), so options are eliminated one per round;
    ///      - each ballot ranks its first choice, then every lower-numbered option in descending
    ///        order. Lower-numbered options have lower counts and are eliminated first, so when a
    ///        ballot's first choice is eliminated it scans through all its other preferences
    ///        before dropping out.
    ///      This forces the largest number of rounds and the most scanning.
    function test_Gas_ResultAtMaxOptionsAndMaxVoters() public {
        uint256 optionCount = ranked.MAX_OPTIONS();
        uint256 voters = ranked.MAX_VOTERS();
        _registerPeople(voters - PEOPLE);

        vm.prank(owner);
        uint256 id = ranked.createDraft("Largest allowed ranked decision", _options(optionCount), VOTING_OPENS, VOTING_CLOSES);

        uint256 batchSize = 200;
        uint256 addVotersGas = 0;
        for (uint256 start = 0; start < voters; start += batchSize) {
            bytes32[] memory batch = new bytes32[](batchSize);
            for (uint256 i = 0; i < batchSize; i++) {
                batch[i] = personIds[start + i];
            }
            vm.prank(owner);
            uint256 before = gasleft();
            ranked.addVoters(id, batch);
            addVotersGas = before - gasleft();
        }
        vm.prank(owner);
        ranked.lock(id);
        _openVoting();

        uint8[] memory firstChoiceSequence = new uint8[](136);
        uint256 next = 0;
        for (uint8 o = 0; o < optionCount; o++) {
            for (uint256 k = 0; k <= o; k++) {
                firstChoiceSequence[next] = o;
                next += 1;
            }
        }

        uint256 fullBallotGas = 0;
        for (uint256 v = 0; v < voters; v++) {
            uint8 first = firstChoiceSequence[v % 136];
            uint8[] memory ranking = new uint8[](uint256(first) + 1);
            for (uint8 p = 0; p <= first; p++) {
                ranking[p] = first - p;
            }
            vm.prank(personKeys[v]);
            uint256 before = gasleft();
            ranked.castBallot(id, ranking);
            if (ranking.length == optionCount) fullBallotGas = before - gasleft();
        }
        _closeVoting();

        uint256 gasBefore = gasleft();
        (GavelRanked.Outcome outcome,, uint256 rounds,) = ranked.result(id);
        uint256 resultGas = gasBefore - gasleft();

        console.log("GavelRanked result gas at MAX_OPTIONS and MAX_VOTERS:", resultGas);
        console.log("  rounds:", rounds);
        console.log("GavelRanked castBallot gas, full 16-option ranking:", fullBallotGas);
        console.log("addVoters gas for a batch of 200:", addVotersGas);

        assertEq(uint8(outcome), uint8(GavelRanked.Outcome.Winner));
        assertLt(resultGas, RESULT_GAS_BUDGET);
    }
}
