// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {console} from "forge-std/Test.sol";
import {GavelChoice} from "../src/GavelChoice.sol";
import {GavelTestBase} from "./helpers/GavelTestBase.sol";

contract GavelChoiceTest is GavelTestBase {
    uint256 internal constant VOTERS = 12;

    GavelChoice internal choice;

    function setUp() public override {
        super.setUp();
        choice = new GavelChoice(registry);
        _registerPeople(VOTERS);
    }

    function _options(uint256 count) internal pure returns (string[] memory options) {
        options = new string[](count);
        for (uint256 i = 0; i < count; i++) {
            options[i] = string.concat("Vendor ", vm.toString(i));
        }
    }

    function _lockedDecision(uint256 optionCount) internal returns (uint256 decisionId) {
        vm.startPrank(owner);
        decisionId = choice.createDraft("Which vendor?", _options(optionCount), VOTING_OPENS, VOTING_CLOSES);
        choice.addVoters(decisionId, _firstPeople(VOTERS));
        choice.lock(decisionId);
        vm.stopPrank();
    }

    function _vote(uint256 decisionId, uint256 person, uint8 option) internal {
        vm.prank(personKeys[person]);
        choice.castBallot(decisionId, option);
    }

    // ─────────────────────────────── drafts ───────────────────────────────

    function test_CreateDraft_RefusesTooFewOptions() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelChoice.TooFewOptions.selector, 1));
        choice.createDraft("x", _options(1), VOTING_OPENS, VOTING_CLOSES);
    }

    function test_CreateDraft_RefusesTooManyOptions() public {
        uint256 maxOptions = choice.MAX_OPTIONS();
        uint256 tooMany = maxOptions + 1;
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelChoice.TooManyOptions.selector, tooMany, maxOptions));
        choice.createDraft("x", _options(tooMany), VOTING_OPENS, VOTING_CLOSES);
    }

    function test_CreateDraft_StoresOptionsInOrder() public {
        vm.expectEmit(true, true, true, true, address(choice));
        emit GavelChoice.OptionsSet(0, _options(3));
        uint256 id = _lockedDecision(3);

        string[] memory stored = choice.optionsOf(id);
        assertEq(stored.length, 3);
        assertEq(stored[0], "Vendor 0");
        assertEq(stored[2], "Vendor 2");

        uint32[] memory counts = choice.counts(id);
        assertEq(counts.length, 3);
        assertEq(counts[0], 0);
    }

    // ─────────────────────────────── ballots ───────────────────────────────

    function test_Ballot_RefusesMissingOption() public {
        uint256 id = _lockedDecision(3);
        _openVoting();
        vm.prank(personKeys[0]);
        vm.expectRevert(abi.encodeWithSelector(GavelChoice.InvalidOption.selector, id, 3));
        choice.castBallot(id, 3);
    }

    function test_BallotOf_BeforeAndAfter() public {
        uint256 id = _lockedDecision(3);
        _openVoting();

        (bool voted,) = choice.ballotOf(id, personIds[0]);
        assertFalse(voted);

        _vote(id, 0, 2);
        uint8 option;
        (voted, option) = choice.ballotOf(id, personIds[0]);
        assertTrue(voted);
        assertEq(option, 2);
    }

    function test_BallotCast_EventIsNamed() public {
        uint256 id = _lockedDecision(3);
        _openVoting();
        vm.expectEmit(true, true, true, true, address(choice));
        emit GavelChoice.BallotCast(id, personIds[0], personKeys[0], 1);
        _vote(id, 0, 1);
    }

    // ─────────────────────────────── outcomes ───────────────────────────────

    function test_Result_NoBallots() public {
        uint256 id = _lockedDecision(3);
        _closeVoting();
        (GavelChoice.Outcome outcome, uint8[] memory winners, uint32[] memory counts) = choice.result(id);
        assertEq(uint8(outcome), uint8(GavelChoice.Outcome.NoBallots));
        assertEq(winners.length, 0);
        assertEq(counts.length, 3);
    }

    function test_Result_Winner() public {
        uint256 id = _lockedDecision(3);
        _openVoting();
        _vote(id, 0, 1);
        _vote(id, 1, 1);
        _vote(id, 2, 0);
        _closeVoting();

        (GavelChoice.Outcome outcome, uint8[] memory winners, uint32[] memory counts) = choice.result(id);
        assertEq(uint8(outcome), uint8(GavelChoice.Outcome.Winner));
        assertEq(winners.length, 1);
        assertEq(winners[0], 1);
        assertEq(counts[0], 1);
        assertEq(counts[1], 2);
        assertEq(counts[2], 0);
    }

    function test_Result_TiedListsEveryTiedOption() public {
        uint256 id = _lockedDecision(4);
        _openVoting();
        _vote(id, 0, 0);
        _vote(id, 1, 3);
        _vote(id, 2, 0);
        _vote(id, 3, 3);
        _vote(id, 4, 2);
        _closeVoting();

        (GavelChoice.Outcome outcome, uint8[] memory winners,) = choice.result(id);
        assertEq(uint8(outcome), uint8(GavelChoice.Outcome.Tied));
        assertEq(winners.length, 2);
        assertEq(winners[0], 0);
        assertEq(winners[1], 3);
    }

    // ─────────────────────────────── fuzz ───────────────────────────────

    /// @dev For any spread of ballots, counts add up, every winner holds the top count, and every
    ///      other option has less.
    function testFuzz_WinnersHoldTheTopCount(uint256 optionCount, uint8[VOTERS] memory picks, uint256 voters) public {
        optionCount = bound(optionCount, 2, 6);
        voters = bound(voters, 0, VOTERS);

        uint256 id = _lockedDecision(optionCount);
        _openVoting();
        for (uint256 i = 0; i < voters; i++) {
            // casting to 'uint8' is safe because the remainder is below optionCount, which is at most 6
            // forge-lint: disable-next-line(unsafe-typecast)
            _vote(id, i, uint8(picks[i] % optionCount));
        }
        _closeVoting();

        (GavelChoice.Outcome outcome, uint8[] memory winners, uint32[] memory counts) = choice.result(id);

        uint256 total = 0;
        uint32 highest = 0;
        for (uint256 o = 0; o < counts.length; o++) {
            total += counts[o];
            if (counts[o] > highest) highest = counts[o];
        }
        assertEq(total, voters);
        assertEq(total, choice.getDecision(id).ballotCount);

        if (voters == 0) {
            assertEq(uint8(outcome), uint8(GavelChoice.Outcome.NoBallots));
            return;
        }

        bool[] memory isWinner = new bool[](optionCount);
        for (uint256 w = 0; w < winners.length; w++) {
            assertEq(counts[winners[w]], highest);
            isWinner[winners[w]] = true;
        }
        for (uint256 o = 0; o < optionCount; o++) {
            if (!isWinner[o]) assertLt(counts[o], highest);
        }
        assertEq(uint8(outcome), uint8(winners.length == 1 ? GavelChoice.Outcome.Winner : GavelChoice.Outcome.Tied));
    }

    // ─────────────────────────────── gas at the limits ───────────────────────────────

    /// @dev Records the cost of the largest allowed draft (MAX_OPTIONS options with 64-character
    ///      labels) and of reading its result.
    function test_Gas_AtMaxOptions() public {
        uint256 optionCount = choice.MAX_OPTIONS();
        string[] memory options = new string[](optionCount);
        for (uint256 i = 0; i < optionCount; i++) {
            options[i] = "Option label that is sixty-four characters long, for measuring..";
        }

        vm.prank(owner);
        uint256 gasBefore = gasleft();
        uint256 id = choice.createDraft("Largest allowed choice decision", options, VOTING_OPENS, VOTING_CLOSES);
        uint256 createGas = gasBefore - gasleft();

        vm.startPrank(owner);
        choice.addVoters(id, _firstPeople(VOTERS));
        choice.lock(id);
        vm.stopPrank();
        _openVoting();
        for (uint256 i = 0; i < VOTERS; i++) {
            // casting to 'uint8' is safe because the remainder is below optionCount, which is MAX_OPTIONS (32)
            // forge-lint: disable-next-line(unsafe-typecast)
            _vote(id, i, uint8((i * 7) % optionCount));
        }
        _closeVoting();

        gasBefore = gasleft();
        choice.result(id);
        uint256 resultGas = gasBefore - gasleft();

        console.log("GavelChoice createDraft gas at MAX_OPTIONS:", createGas);
        console.log("GavelChoice result gas at MAX_OPTIONS:", resultGas);
    }
}
