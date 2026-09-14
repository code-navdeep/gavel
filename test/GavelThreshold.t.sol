// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelThreshold} from "../src/GavelThreshold.sol";
import {GavelTestBase} from "./helpers/GavelTestBase.sol";

contract GavelThresholdTest is GavelTestBase {
    uint256 internal constant PEOPLE = 10;

    GavelThreshold internal threshold;

    function setUp() public override {
        super.setUp();
        threshold = new GavelThreshold(registry);
        _registerPeople(PEOPLE);
    }

    function _draft(uint32 minBallots, uint32 minApprovals, uint32 shareNumerator, uint32 shareDenominator)
        internal
        returns (uint256 decisionId)
    {
        vm.prank(owner);
        decisionId = threshold.createDraft(
            "Sign off the contract", VOTING_OPENS, VOTING_CLOSES, minBallots, minApprovals, shareNumerator, shareDenominator
        );
    }

    function _locked(
        uint256 voters,
        uint32 minBallots,
        uint32 minApprovals,
        uint32 shareNumerator,
        uint32 shareDenominator
    ) internal returns (uint256 decisionId) {
        decisionId = _draft(minBallots, minApprovals, shareNumerator, shareDenominator);
        vm.startPrank(owner);
        threshold.addVoters(decisionId, _firstPeople(voters));
        threshold.lock(decisionId);
        vm.stopPrank();
    }

    /// @dev Person 0..approvals-1 approve, the next rejections people reject.
    function _vote(uint256 decisionId, uint256 approvals, uint256 rejections) internal {
        for (uint256 i = 0; i < approvals + rejections; i++) {
            vm.prank(personKeys[i]);
            threshold.castBallot(decisionId, i < approvals);
        }
    }

    function _outcome(uint256 decisionId) internal view returns (GavelThreshold.Outcome outcome) {
        (outcome,,) = threshold.result(decisionId);
    }

    // ─────────────────────────────── drafts and locking ───────────────────────────────

    function test_CreateDraft_RefusesZeroMinApprovals() public {
        vm.prank(owner);
        vm.expectRevert(GavelThreshold.ZeroMinApprovals.selector);
        threshold.createDraft("x", VOTING_OPENS, VOTING_CLOSES, 0, 0, 0, 0);
    }

    function test_CreateDraft_RefusesInvalidShare() public {
        vm.startPrank(owner);

        // more approvals than ballots
        vm.expectRevert(abi.encodeWithSelector(GavelThreshold.InvalidShare.selector, 3, 2));
        threshold.createDraft("x", VOTING_OPENS, VOTING_CLOSES, 0, 1, 3, 2);

        // denominator of zero
        vm.expectRevert(abi.encodeWithSelector(GavelThreshold.InvalidShare.selector, 1, 0));
        threshold.createDraft("x", VOTING_OPENS, VOTING_CLOSES, 0, 1, 1, 0);

        // numerator of zero with a denominator (to not use a share, both must be 0)
        vm.expectRevert(abi.encodeWithSelector(GavelThreshold.InvalidShare.selector, 0, 3));
        threshold.createDraft("x", VOTING_OPENS, VOTING_CLOSES, 0, 1, 0, 3);

        vm.stopPrank();
    }

    function test_CreateDraft_StoresRules() public {
        vm.expectEmit(true, true, true, true, address(threshold));
        emit GavelThreshold.RulesSet(0, 4, 3, 3, 4);
        uint256 id = _draft(4, 3, 3, 4);

        GavelThreshold.Rules memory rules = threshold.rulesOf(id);
        assertEq(rules.minBallots, 4);
        assertEq(rules.minApprovals, 3);
        assertEq(rules.minApprovalShareNumerator, 3);
        assertEq(rules.minApprovalShareDenominator, 4);
    }

    function test_Lock_RefusesMinApprovalsAboveVoterCount() public {
        uint256 id = _draft(0, 6, 0, 0);
        vm.startPrank(owner);
        threshold.addVoters(id, _firstPeople(5));
        vm.expectRevert(abi.encodeWithSelector(GavelThreshold.MinApprovalsAboveVoterCount.selector, id, 6, 5));
        threshold.lock(id);
        vm.stopPrank();
    }

    function test_Lock_RefusesMinBallotsAboveVoterCount() public {
        uint256 id = _draft(6, 1, 0, 0);
        vm.startPrank(owner);
        threshold.addVoters(id, _firstPeople(5));
        vm.expectRevert(abi.encodeWithSelector(GavelThreshold.MinBallotsAboveVoterCount.selector, id, 6, 5));
        threshold.lock(id);
        vm.stopPrank();
    }

    // ─────────────────────────────── "3 of these 5 managers must sign off" ───────────────────────────────

    function test_ThreeOfFive_ThreeApprovalsIsApproved() public {
        uint256 id = _locked(5, 0, 3, 0, 0);
        _openVoting();
        _vote(id, 3, 2);
        _closeVoting();

        (GavelThreshold.Outcome outcome, uint32 approvals, uint32 rejections) = threshold.result(id);
        assertEq(uint8(outcome), uint8(GavelThreshold.Outcome.Approved));
        assertEq(approvals, 3);
        assertEq(rejections, 2);
    }

    function test_ThreeOfFive_TwoApprovalsIsNotApproved() public {
        uint256 id = _locked(5, 0, 3, 0, 0);
        _openVoting();
        _vote(id, 2, 3);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.ThresholdNotMet));
    }

    // ─────────────────────────────── quorum ───────────────────────────────

    function test_Quorum_OneBallotShortIsQuorumNotMet() public {
        uint256 id = _locked(5, 4, 1, 0, 0);
        _openVoting();
        _vote(id, 3, 0);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.QuorumNotMet));
    }

    function test_Quorum_ExactlyMetIsApproved() public {
        uint256 id = _locked(5, 4, 1, 0, 0);
        _openVoting();
        _vote(id, 3, 1);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.Approved));
    }

    function test_NoBallots_IsThresholdNotMet() public {
        uint256 id = _locked(5, 0, 1, 0, 0);
        _closeVoting();
        (GavelThreshold.Outcome outcome, uint32 approvals, uint32 rejections) = threshold.result(id);
        assertEq(uint8(outcome), uint8(GavelThreshold.Outcome.ThresholdNotMet));
        assertEq(approvals, 0);
        assertEq(rejections, 0);
    }

    // ─────────────────────────────── share of ballots ───────────────────────────────

    /// @dev Exactly two-thirds must pass: 2 approvals × 3 = 6 >= 3 ballots × 2 = 6.
    function test_Share_ExactlyTwoThirdsIsApproved() public {
        uint256 id = _locked(5, 0, 1, 2, 3);
        _openVoting();
        _vote(id, 2, 1);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.Approved));
    }

    /// @dev 1 approval × 3 = 3 < 3 ballots × 2 = 6.
    function test_Share_BelowTwoThirdsIsThresholdNotMet() public {
        uint256 id = _locked(5, 0, 1, 2, 3);
        _openVoting();
        _vote(id, 1, 2);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.ThresholdNotMet));
    }

    function test_Share_ExactlyThreeQuartersIsApproved() public {
        uint256 id = _locked(5, 0, 1, 3, 4);
        _openVoting();
        _vote(id, 3, 1);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.Approved));
    }

    function test_Share_BelowThreeQuartersIsThresholdNotMet() public {
        uint256 id = _locked(5, 0, 1, 3, 4);
        _openVoting();
        _vote(id, 2, 2);
        _closeVoting();
        assertEq(uint8(_outcome(id)), uint8(GavelThreshold.Outcome.ThresholdNotMet));
    }

    // ─────────────────────────────── ballots and counts ───────────────────────────────

    function test_BallotOfAndCounts() public {
        uint256 id = _locked(5, 0, 1, 0, 0);
        _openVoting();
        assertEq(uint8(threshold.ballotOf(id, personIds[0])), uint8(GavelThreshold.Ballot.None));

        _vote(id, 1, 1); // person 0 approves, person 1 rejects

        assertEq(uint8(threshold.ballotOf(id, personIds[0])), uint8(GavelThreshold.Ballot.Approve));
        assertEq(uint8(threshold.ballotOf(id, personIds[1])), uint8(GavelThreshold.Ballot.Reject));
        (uint32 approvals, uint32 rejections) = threshold.counts(id);
        assertEq(approvals, 1);
        assertEq(rejections, 1);
    }

    function test_BallotCast_EventIsNamed() public {
        uint256 id = _locked(5, 0, 1, 0, 0);
        _openVoting();
        vm.expectEmit(true, true, true, true, address(threshold));
        emit GavelThreshold.BallotCast(id, personIds[0], personKeys[0], true);
        vm.prank(personKeys[0]);
        threshold.castBallot(id, true);
    }

    // ─────────────────────────────── fuzz ───────────────────────────────

    /// @dev For any rules and votes, the outcome matches the stated formula exactly.
    function testFuzz_OutcomeMatchesTheRules(
        uint256 minBallots,
        uint256 minApprovals,
        uint256 shareDenominator,
        uint256 shareNumerator,
        uint256 approvals,
        uint256 rejections
    ) public {
        minBallots = bound(minBallots, 0, PEOPLE);
        minApprovals = bound(minApprovals, 1, PEOPLE);
        shareDenominator = bound(shareDenominator, 0, PEOPLE);
        // a share is either not used (0 and 0) or a numerator from 1 up to the denominator
        shareNumerator = shareDenominator == 0 ? 0 : bound(shareNumerator, 1, shareDenominator);
        approvals = bound(approvals, 0, PEOPLE);
        rejections = bound(rejections, 0, PEOPLE - approvals);

        // casting is safe because every value is bounded to 0-10 above
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 id = _locked(PEOPLE, uint32(minBallots), uint32(minApprovals), uint32(shareNumerator), uint32(shareDenominator));
        _openVoting();
        _vote(id, approvals, rejections);
        _closeVoting();

        uint256 ballots = approvals + rejections;
        GavelThreshold.Outcome expected;
        if (ballots < minBallots) {
            expected = GavelThreshold.Outcome.QuorumNotMet;
        } else if (approvals < minApprovals) {
            expected = GavelThreshold.Outcome.ThresholdNotMet;
        } else if (shareDenominator != 0 && approvals * shareDenominator < ballots * shareNumerator) {
            expected = GavelThreshold.Outcome.ThresholdNotMet;
        } else {
            expected = GavelThreshold.Outcome.Approved;
        }

        assertEq(uint8(_outcome(id)), uint8(expected));
    }
}
