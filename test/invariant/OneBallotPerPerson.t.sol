// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GavelRegistry} from "../../src/GavelRegistry.sol";
import {GavelYesNo} from "../../src/GavelYesNo.sol";
import {GavelTestBase} from "../helpers/GavelTestBase.sol";

/// @notice Performs random actions against one open decision: casting ballots, replacing keys, and
///         trying to change the voter list. It records every ballot that was accepted.
contract OneBallotHandler is Test {
    GavelYesNo public immutable yesNo;
    GavelRegistry public immutable registry;
    address public immutable owner;
    uint256 public immutable decisionId;

    bytes32[] public people;
    uint256 public keyGeneration;

    mapping(uint256 personIndex => uint256) public acceptedBallots;
    uint256 public totalAccepted;

    constructor(GavelYesNo yesNo_, GavelRegistry registry_, address owner_, uint256 decisionId_, bytes32[] memory people_) {
        yesNo = yesNo_;
        registry = registry_;
        owner = owner_;
        decisionId = decisionId_;
        people = people_;
    }

    function peopleCount() external view returns (uint256) {
        return people.length;
    }

    /// @dev A person tries to vote with their current key. Refusals are expected and ignored.
    function castBallot(uint256 personSeed, bool yes) external {
        uint256 index = bound(personSeed, 0, people.length - 1);
        address key = registry.keyOf(people[index]);
        vm.prank(key);
        try yesNo.castBallot(decisionId, yes) {
            acceptedBallots[index] += 1;
            totalAccepted += 1;
        } catch {}
    }

    /// @dev The owner gives a person a brand-new key.
    function replaceKey(uint256 personSeed) external {
        uint256 index = bound(personSeed, 0, people.length - 1);
        keyGeneration += 1;
        address newKey = address(uint160(uint256(keccak256(abi.encode("invariant-key", index, keyGeneration)))));
        vm.prank(owner);
        registry.replaceKey(people[index], newKey);
    }

    /// @dev The owner tries to add someone to the locked decision. Must always be refused.
    function tryAddVoter(uint256 personSeed) external {
        uint256 index = bound(personSeed, 0, people.length - 1);
        bytes32[] memory list = new bytes32[](1);
        list[0] = people[index];
        vm.prank(owner);
        try yesNo.addVoters(decisionId, list) {} catch {}
    }

    /// @dev The owner tries to remove someone from the locked decision. Must always be refused.
    function tryRemoveVoter(uint256 personSeed) external {
        uint256 index = bound(personSeed, 0, people.length - 1);
        vm.prank(owner);
        try yesNo.removeVoter(decisionId, people[index]) {} catch {}
    }
}

/// @notice Whatever sequence of actions happens, one person never gets two ballots, and a locked
///         decision's voter list never changes.
contract OneBallotPerPersonInvariantTest is GavelTestBase {
    uint256 internal constant ON_LIST = 5;
    uint256 internal constant NOT_ON_LIST_INDEX = 5;

    GavelYesNo internal yesNo;
    OneBallotHandler internal handler;
    uint256 internal decisionId;

    function setUp() public override {
        super.setUp();
        yesNo = new GavelYesNo(registry);
        _registerPeople(ON_LIST + 1); // person 5 is registered but not on the voter list

        vm.startPrank(owner);
        decisionId = yesNo.createDraft("Invariant decision", VOTING_OPENS, VOTING_CLOSES);
        yesNo.addVoters(decisionId, _firstPeople(ON_LIST));
        yesNo.lock(decisionId);
        vm.stopPrank();
        _openVoting();

        handler = new OneBallotHandler(yesNo, registry, owner, decisionId, _firstPeople(ON_LIST + 1));
        targetContract(address(handler));
    }

    /// @dev Runs at the end of every random sequence: proves ballots really were accepted, so the
    ///      invariants below were checked against actual voting rather than an empty run.
    function afterInvariant() public view {
        assertGt(handler.totalAccepted(), 0);
    }

    function invariant_NoPersonEverHasTwoBallots() public view {
        for (uint256 i = 0; i < handler.peopleCount(); i++) {
            assertLe(handler.acceptedBallots(i), 1);
        }
    }

    function invariant_PersonNotOnListNeverVotes() public view {
        assertEq(handler.acceptedBallots(NOT_ON_LIST_INDEX), 0);
    }

    function invariant_CountsMatchAcceptedBallots() public view {
        (uint32 yes, uint32 no) = yesNo.counts(decisionId);
        assertEq(uint256(yes) + uint256(no), handler.totalAccepted());
        assertEq(yesNo.getDecision(decisionId).ballotCount, handler.totalAccepted());
    }

    function invariant_LockedVoterListNeverChanges() public view {
        assertEq(yesNo.getDecision(decisionId).voterCount, ON_LIST);
        for (uint256 i = 0; i < ON_LIST; i++) {
            assertTrue(yesNo.isVoter(decisionId, personIds[i]));
        }
        assertFalse(yesNo.isVoter(decisionId, personIds[NOT_ON_LIST_INDEX]));
    }
}
