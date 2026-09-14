// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {GavelRegistry} from "../src/GavelRegistry.sol";
import {GavelDecisionBase} from "../src/GavelDecisionBase.sol";
import {GavelYesNo} from "../src/GavelYesNo.sol";
import {GavelTestBase} from "./helpers/GavelTestBase.sol";

/// @notice Tests the rules every decision type shares (GavelDecisionBase), using the yes/no module.
contract DecisionLifecycleTest is GavelTestBase {
    GavelYesNo internal yesNo;

    function setUp() public override {
        super.setUp();
        yesNo = new GavelYesNo(registry);
        _registerPeople(5);
    }

    function _createDraft() internal returns (uint256 decisionId) {
        vm.prank(owner);
        decisionId = yesNo.createDraft("Approve the Q3 budget?", VOTING_OPENS, VOTING_CLOSES);
    }

    function _createLocked(uint256 voterCount) internal returns (uint256 decisionId) {
        decisionId = _createDraft();
        vm.startPrank(owner);
        yesNo.addVoters(decisionId, _firstPeople(voterCount));
        yesNo.lock(decisionId);
        vm.stopPrank();
    }

    function _assertState(uint256 decisionId, GavelDecisionBase.State expected) internal view {
        assertEq(uint8(yesNo.stateOf(decisionId)), uint8(expected));
    }

    // ─────────────────────────────── deploying and drafts ───────────────────────────────

    function test_Constructor_RefusesZeroRegistry() public {
        vm.expectRevert(GavelDecisionBase.ZeroRegistry.selector);
        new GavelYesNo(GavelRegistry(address(0)));
    }

    function test_CreateDraft_OnlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOwner.selector, outsider));
        yesNo.createDraft("x", VOTING_OPENS, VOTING_CLOSES);
    }

    function test_CreateDraft_RefusesEndNotAfterStart() public {
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(GavelDecisionBase.EndNotAfterStart.selector, VOTING_OPENS, VOTING_OPENS)
        );
        yesNo.createDraft("x", VOTING_OPENS, VOTING_OPENS);
    }

    function test_CreateDraft_NumbersFromZeroAndStartsAsDraft() public {
        vm.expectEmit(true, true, true, true, address(yesNo));
        emit GavelDecisionBase.DraftCreated(0, "Approve the Q3 budget?", VOTING_OPENS, VOTING_CLOSES);
        uint256 first = _createDraft();
        uint256 second = _createDraft();

        assertEq(first, 0);
        assertEq(second, 1);
        assertEq(yesNo.decisionCount(), 2);
        _assertState(first, GavelDecisionBase.State.Draft);

        GavelDecisionBase.DecisionInfo memory info = yesNo.getDecision(first);
        assertEq(info.title, "Approve the Q3 budget?");
        assertEq(info.startTime, VOTING_OPENS);
        assertEq(info.endTime, VOTING_CLOSES);
        assertFalse(info.locked);
        assertEq(info.voterCount, 0);
        assertEq(info.ballotCount, 0);
    }

    function test_UnknownDecision_IsRefused() public {
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.DecisionNotFound.selector, 0));
        yesNo.stateOf(0);

        _createDraft();
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.DecisionNotFound.selector, 1));
        yesNo.getDecision(1);
    }

    // ─────────────────────────────── voter lists ───────────────────────────────

    function test_AddVoters_InBatches() public {
        uint256 id = _createDraft();
        bytes32[] memory firstBatch = new bytes32[](2);
        firstBatch[0] = personIds[0];
        firstBatch[1] = personIds[1];
        bytes32[] memory secondBatch = new bytes32[](3);
        secondBatch[0] = personIds[2];
        secondBatch[1] = personIds[3];
        secondBatch[2] = personIds[4];

        vm.startPrank(owner);
        vm.expectEmit(true, true, true, true, address(yesNo));
        emit GavelDecisionBase.VoterAdded(id, personIds[0]);
        yesNo.addVoters(id, firstBatch);
        yesNo.addVoters(id, secondBatch);
        vm.stopPrank();

        assertEq(yesNo.getDecision(id).voterCount, 5);
        for (uint256 i = 0; i < 5; i++) {
            assertTrue(yesNo.isVoter(id, personIds[i]));
        }
    }

    function test_AddVoters_OnlyOwner() public {
        uint256 id = _createDraft();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOwner.selector, outsider));
        yesNo.addVoters(id, _firstPeople(1));
    }

    function test_AddVoters_RefusesUnregisteredPerson() public {
        uint256 id = _createDraft();
        bytes32 stranger = _idFor(999);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.PersonNotRegistered.selector, stranger));
        yesNo.addVoters(id, _only(stranger));
    }

    function test_AddVoters_RefusesInactivePerson() public {
        uint256 id = _createDraft();
        vm.startPrank(owner);
        registry.setActive(personIds[0], false);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.PersonNotActive.selector, personIds[0]));
        yesNo.addVoters(id, _only(personIds[0]));
        vm.stopPrank();
    }

    function test_AddVoters_RefusesDuplicates_AndRefusedBatchChangesNothing() public {
        uint256 id = _createDraft();
        bytes32[] memory twice = new bytes32[](2);
        twice[0] = personIds[0];
        twice[1] = personIds[0];

        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.AlreadyOnVoterList.selector, id, personIds[0]));
        yesNo.addVoters(id, twice);
        assertEq(yesNo.getDecision(id).voterCount, 0);
        assertFalse(yesNo.isVoter(id, personIds[0]));

        yesNo.addVoters(id, _only(personIds[0]));
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.AlreadyOnVoterList.selector, id, personIds[0]));
        yesNo.addVoters(id, _only(personIds[0]));
        vm.stopPrank();
    }

    function test_RemoveVoter_UpdatesList() public {
        uint256 id = _createDraft();
        vm.startPrank(owner);
        yesNo.addVoters(id, _firstPeople(3));
        vm.expectEmit(true, true, true, true, address(yesNo));
        emit GavelDecisionBase.VoterRemoved(id, personIds[1]);
        yesNo.removeVoter(id, personIds[1]);
        vm.stopPrank();

        assertEq(yesNo.getDecision(id).voterCount, 2);
        assertFalse(yesNo.isVoter(id, personIds[1]));
        assertTrue(yesNo.isVoter(id, personIds[0]));
    }

    function test_RemoveVoter_RefusesPersonNotOnList() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOnVoterList.selector, id, personIds[0]));
        yesNo.removeVoter(id, personIds[0]);
    }

    function test_RemoveVoter_OnlyOwner() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        yesNo.addVoters(id, _firstPeople(1));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOwner.selector, outsider));
        yesNo.removeVoter(id, personIds[0]);
    }

    // ─────────────────────────────── locking ───────────────────────────────

    function test_Lock_SchedulesTheDecision() public {
        uint256 id = _createDraft();
        vm.startPrank(owner);
        yesNo.addVoters(id, _firstPeople(3));
        vm.expectEmit(true, true, true, true, address(yesNo));
        emit GavelDecisionBase.DecisionLocked(id, 3, VOTING_OPENS, VOTING_CLOSES);
        yesNo.lock(id);
        vm.stopPrank();

        assertTrue(yesNo.getDecision(id).locked);
        _assertState(id, GavelDecisionBase.State.Scheduled);
    }

    function test_Lock_OnlyOwner() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        yesNo.addVoters(id, _firstPeople(1));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOwner.selector, outsider));
        yesNo.lock(id);
    }

    function test_Lock_RefusesEmptyVoterList() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.EmptyVoterList.selector, id));
        yesNo.lock(id);
    }

    function test_Lock_RefusesEndTimeInPast() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        yesNo.addVoters(id, _firstPeople(1));
        vm.warp(VOTING_CLOSES);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.EndTimeInPast.selector, VOTING_CLOSES));
        yesNo.lock(id);
    }

    function test_Lock_WithStartInPast_OpensImmediately() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        yesNo.addVoters(id, _firstPeople(1));
        vm.warp(VOTING_OPENS + 1 hours);
        vm.prank(owner);
        yesNo.lock(id);
        _assertState(id, GavelDecisionBase.State.Open);
    }

    function test_NothingCanBeEditedAfterLock() public {
        uint256 id = _createLocked(3);
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotDraft.selector, id));
        yesNo.addVoters(id, _only(personIds[4]));

        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotDraft.selector, id));
        yesNo.removeVoter(id, personIds[0]);

        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotDraft.selector, id));
        yesNo.lock(id);

        vm.stopPrank();
        assertEq(yesNo.getDecision(id).voterCount, 3);
    }

    // ─────────────────────────────── the clock ───────────────────────────────

    function test_State_FollowsTheClockAtExactBoundaries() public {
        uint256 id = _createLocked(3);

        _assertState(id, GavelDecisionBase.State.Scheduled);
        vm.warp(VOTING_OPENS - 1);
        _assertState(id, GavelDecisionBase.State.Scheduled);
        vm.warp(VOTING_OPENS); // the start second counts as open
        _assertState(id, GavelDecisionBase.State.Open);
        vm.warp(VOTING_CLOSES - 1);
        _assertState(id, GavelDecisionBase.State.Open);
        vm.warp(VOTING_CLOSES); // the end second counts as closed
        _assertState(id, GavelDecisionBase.State.Closed);
    }

    // ─────────────────────────────── ballots ───────────────────────────────

    function test_Ballot_RefusedWhileDraft() public {
        uint256 id = _createDraft();
        vm.prank(owner);
        yesNo.addVoters(id, _firstPeople(1));
        _openVoting();

        vm.prank(personKeys[0]);
        vm.expectRevert(
            abi.encodeWithSelector(GavelDecisionBase.DecisionNotOpen.selector, id, GavelDecisionBase.State.Draft)
        );
        yesNo.castBallot(id, true);
    }

    function test_Ballot_RefusedBeforeOpenAndAfterClose() public {
        uint256 id = _createLocked(1);

        vm.warp(VOTING_OPENS - 1);
        vm.prank(personKeys[0]);
        vm.expectRevert(
            abi.encodeWithSelector(GavelDecisionBase.DecisionNotOpen.selector, id, GavelDecisionBase.State.Scheduled)
        );
        yesNo.castBallot(id, true);

        vm.warp(VOTING_CLOSES);
        vm.prank(personKeys[0]);
        vm.expectRevert(
            abi.encodeWithSelector(GavelDecisionBase.DecisionNotOpen.selector, id, GavelDecisionBase.State.Closed)
        );
        yesNo.castBallot(id, true);
    }

    function test_Ballot_RefusedForUnregisteredKey() public {
        uint256 id = _createLocked(3);
        _openVoting();
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.KeyNotRegistered.selector, outsider));
        yesNo.castBallot(id, true);
    }

    function test_Ballot_RefusedForPersonNotOnList() public {
        uint256 id = _createLocked(3);
        _openVoting();
        vm.prank(personKeys[4]);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOnVoterList.selector, id, personIds[4]));
        yesNo.castBallot(id, true);
    }

    function test_Ballot_SecondBallotRefused() public {
        uint256 id = _createLocked(3);
        _openVoting();

        vm.prank(personKeys[0]);
        yesNo.castBallot(id, true);
        assertTrue(yesNo.hasVoted(id, personIds[0]));

        vm.prank(personKeys[0]);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.AlreadyVoted.selector, id, personIds[0]));
        yesNo.castBallot(id, false);

        assertEq(yesNo.getDecision(id).ballotCount, 1);
    }

    function test_Ballot_ReplacedKeyCannotVoteAgain() public {
        uint256 id = _createLocked(3);
        _openVoting();

        vm.prank(personKeys[0]);
        yesNo.castBallot(id, true);

        address newKey = _keyFor(0, 1);
        vm.prank(owner);
        registry.replaceKey(personIds[0], newKey);

        // the new key belongs to the same person, who has already voted
        vm.prank(newKey);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.AlreadyVoted.selector, id, personIds[0]));
        yesNo.castBallot(id, false);

        // the old key no longer belongs to anyone
        vm.prank(personKeys[0]);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.KeyNotRegistered.selector, personKeys[0]));
        yesNo.castBallot(id, false);

        assertEq(yesNo.getDecision(id).ballotCount, 1);
    }

    function test_Ballot_KeyReplacedBeforeVoting_NewKeyVotes() public {
        uint256 id = _createLocked(3);
        address newKey = _keyFor(0, 1);
        vm.prank(owner);
        registry.replaceKey(personIds[0], newKey);
        _openVoting();

        vm.prank(newKey);
        yesNo.castBallot(id, true);
        assertTrue(yesNo.hasVoted(id, personIds[0]));
    }

    function test_DeactivatedPerson_StillVotesInAlreadyLockedDecision() public {
        uint256 id = _createLocked(3);
        vm.prank(owner);
        registry.setActive(personIds[0], false);
        _openVoting();

        vm.prank(personKeys[0]);
        yesNo.castBallot(id, true);
        assertTrue(yesNo.hasVoted(id, personIds[0]));
    }

    function test_Result_RefusedBeforeClose() public {
        uint256 id = _createLocked(3);
        _openVoting();
        vm.expectRevert(
            abi.encodeWithSelector(GavelDecisionBase.DecisionNotClosed.selector, id, GavelDecisionBase.State.Open)
        );
        yesNo.result(id);
    }

    // ─────────────────────────────── ownership ───────────────────────────────

    function test_OwnershipTransfer_MovesControlOfModules() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        registry.transferOwnership(newOwner);
        vm.prank(newOwner);
        registry.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelDecisionBase.NotOwner.selector, owner));
        yesNo.createDraft("x", VOTING_OPENS, VOTING_CLOSES);

        vm.prank(newOwner);
        uint256 id = yesNo.createDraft("x", VOTING_OPENS, VOTING_CLOSES);
        assertEq(id, 0);
    }
}
