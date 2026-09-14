// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelYesNo} from "../src/GavelYesNo.sol";
import {GavelTestBase} from "./helpers/GavelTestBase.sol";

contract GavelYesNoTest is GavelTestBase {
    uint256 internal constant VOTERS = 7;

    GavelYesNo internal yesNo;

    function setUp() public override {
        super.setUp();
        yesNo = new GavelYesNo(registry);
        _registerPeople(VOTERS);
    }

    function _lockedDecision() internal returns (uint256 decisionId) {
        vm.startPrank(owner);
        decisionId = yesNo.createDraft("Approve the Q3 budget?", VOTING_OPENS, VOTING_CLOSES);
        yesNo.addVoters(decisionId, _firstPeople(VOTERS));
        yesNo.lock(decisionId);
        vm.stopPrank();
    }

    /// @dev Person 0..yesVotes-1 vote yes, the next noVotes people vote no.
    function _vote(uint256 decisionId, uint256 yesVotes, uint256 noVotes) internal {
        for (uint256 i = 0; i < yesVotes + noVotes; i++) {
            vm.prank(personKeys[i]);
            yesNo.castBallot(decisionId, i < yesVotes);
        }
    }

    function _assertResult(uint256 decisionId, GavelYesNo.Outcome expected, uint32 expectedYes, uint32 expectedNo)
        internal
        view
    {
        (GavelYesNo.Outcome outcome, uint32 yes, uint32 no) = yesNo.result(decisionId);
        assertEq(uint8(outcome), uint8(expected));
        assertEq(yes, expectedYes);
        assertEq(no, expectedNo);
    }

    // ─────────────────────────────── outcomes ───────────────────────────────

    function test_Result_NoBallots() public {
        uint256 id = _lockedDecision();
        _closeVoting();
        _assertResult(id, GavelYesNo.Outcome.NoBallots, 0, 0);
    }

    function test_Result_Yes() public {
        uint256 id = _lockedDecision();
        _openVoting();
        _vote(id, 3, 1);
        _closeVoting();
        _assertResult(id, GavelYesNo.Outcome.Yes, 3, 1);
    }

    function test_Result_No() public {
        uint256 id = _lockedDecision();
        _openVoting();
        _vote(id, 1, 3);
        _closeVoting();
        _assertResult(id, GavelYesNo.Outcome.No, 1, 3);
    }

    function test_Result_Tied() public {
        uint256 id = _lockedDecision();
        _openVoting();
        _vote(id, 2, 2);
        _closeVoting();
        _assertResult(id, GavelYesNo.Outcome.Tied, 2, 2);
    }

    // ─────────────────────────────── ballots and counts ───────────────────────────────

    function test_BallotOfAndCounts() public {
        uint256 id = _lockedDecision();
        _openVoting();

        assertEq(uint8(yesNo.ballotOf(id, personIds[0])), uint8(GavelYesNo.Ballot.None));

        _vote(id, 1, 1); // person 0 yes, person 1 no

        assertEq(uint8(yesNo.ballotOf(id, personIds[0])), uint8(GavelYesNo.Ballot.Yes));
        assertEq(uint8(yesNo.ballotOf(id, personIds[1])), uint8(GavelYesNo.Ballot.No));
        (uint32 yes, uint32 no) = yesNo.counts(id);
        assertEq(yes, 1);
        assertEq(no, 1);
    }

    function test_BallotCast_EventIsNamed() public {
        uint256 id = _lockedDecision();
        _openVoting();

        vm.expectEmit(true, true, true, true, address(yesNo));
        emit GavelYesNo.BallotCast(id, personIds[0], personKeys[0], true);
        vm.prank(personKeys[0]);
        yesNo.castBallot(id, true);
    }

    // ─────────────────────────────── fuzz ───────────────────────────────

    /// @dev For any split of voters, counts add up to ballots cast and the outcome follows the rule.
    function testFuzz_CountsAndOutcome(uint256 yesVotes, uint256 noVotes) public {
        yesVotes = bound(yesVotes, 0, VOTERS);
        noVotes = bound(noVotes, 0, VOTERS - yesVotes);

        uint256 id = _lockedDecision();
        _openVoting();
        _vote(id, yesVotes, noVotes);
        _closeVoting();

        (GavelYesNo.Outcome outcome, uint32 yes, uint32 no) = yesNo.result(id);
        assertEq(uint256(yes) + uint256(no), yesNo.getDecision(id).ballotCount);
        assertEq(yes, yesVotes);
        assertEq(no, noVotes);

        if (yesVotes == 0 && noVotes == 0) assertEq(uint8(outcome), uint8(GavelYesNo.Outcome.NoBallots));
        else if (yesVotes > noVotes) assertEq(uint8(outcome), uint8(GavelYesNo.Outcome.Yes));
        else if (noVotes > yesVotes) assertEq(uint8(outcome), uint8(GavelYesNo.Outcome.No));
        else assertEq(uint8(outcome), uint8(GavelYesNo.Outcome.Tied));
    }
}
