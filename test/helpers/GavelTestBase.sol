// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {GavelRegistry} from "../../src/GavelRegistry.sol";

/// @notice Shared setup for every Gavel test: a fixed clock, an owner, a registry, and helpers
///         to register people and move time.
abstract contract GavelTestBase is Test {
    /// @dev A fixed starting time so every test run behaves identically.
    uint64 internal constant TEST_START = 1_760_000_000;
    /// @dev Standard timeline used by most tests: voting opens 1 hour in, lasts 1 day.
    uint64 internal constant VOTING_OPENS = TEST_START + 1 hours;
    uint64 internal constant VOTING_CLOSES = VOTING_OPENS + 1 days;

    address internal owner = makeAddr("owner");
    address internal outsider = makeAddr("outsider");

    GavelRegistry internal registry;

    /// @dev Registered people, in registration order. personKeys[i] is the first key of personIds[i].
    bytes32[] internal personIds;
    address[] internal personKeys;

    function setUp() public virtual {
        vm.warp(TEST_START);
        registry = new GavelRegistry(owner);
    }

    /// @dev A predictable person ID for person number `n`.
    function _idFor(uint256 n) internal pure returns (bytes32) {
        return keccak256(abi.encode("gavel-test-person", n));
    }

    /// @dev A predictable key for person number `n`. `generation` gives replacement keys.
    function _keyFor(uint256 n, uint256 generation) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("gavel-test-key", n, generation)))));
    }

    /// @dev Registers `count` more people (as the owner) and remembers their IDs and keys.
    function _registerPeople(uint256 count) internal {
        uint256 first = personIds.length;
        for (uint256 n = first; n < first + count; n++) {
            bytes32 personId = _idFor(n);
            address key = _keyFor(n, 0);
            vm.prank(owner);
            registry.registerPerson(personId, key);
            personIds.push(personId);
            personKeys.push(key);
        }
    }

    /// @dev The IDs of the first `count` registered people.
    function _firstPeople(uint256 count) internal view returns (bytes32[] memory ids) {
        ids = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            ids[i] = personIds[i];
        }
    }

    /// @dev A one-person list.
    function _only(bytes32 personId) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = personId;
    }

    function _openVoting() internal {
        vm.warp(VOTING_OPENS);
    }

    function _closeVoting() internal {
        vm.warp(VOTING_CLOSES);
    }
}
