// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GavelRegistry} from "../src/GavelRegistry.sol";
import {GavelTestBase} from "./helpers/GavelTestBase.sol";

contract GavelRegistryTest is GavelTestBase {
    bytes32 internal alice = _idFor(1);
    bytes32 internal bob = _idFor(2);
    address internal aliceKey = _keyFor(1, 0);
    address internal bobKey = _keyFor(2, 0);

    function _register(bytes32 personId, address key) internal {
        vm.prank(owner);
        registry.registerPerson(personId, key);
    }

    // ─────────────────────────────── registering ───────────────────────────────

    function test_RegisterPerson_StoresKeyAndActive() public {
        vm.expectEmit(true, true, true, true, address(registry));
        emit GavelRegistry.PersonRegistered(alice, aliceKey);
        _register(alice, aliceKey);

        assertTrue(registry.isRegistered(alice));
        assertTrue(registry.isActive(alice));
        assertEq(registry.keyOf(alice), aliceKey);
        assertEq(registry.personIdOf(aliceKey), alice);
        assertTrue(registry.wasKeyEverUsed(aliceKey));
    }

    function test_Lookups_ForUnknownPersonAndKey() public view {
        assertFalse(registry.isRegistered(alice));
        assertFalse(registry.isActive(alice));
        assertEq(registry.keyOf(alice), address(0));
        assertEq(registry.personIdOf(aliceKey), bytes32(0));
        assertFalse(registry.wasKeyEverUsed(aliceKey));
    }

    function test_RegisterPerson_RefusesZeroId() public {
        vm.prank(owner);
        vm.expectRevert(GavelRegistry.ZeroPersonId.selector);
        registry.registerPerson(bytes32(0), aliceKey);
    }

    function test_RegisterPerson_RefusesZeroKey() public {
        vm.prank(owner);
        vm.expectRevert(GavelRegistry.ZeroKey.selector);
        registry.registerPerson(alice, address(0));
    }

    function test_RegisterPerson_RefusesSameIdTwice() public {
        _register(alice, aliceKey);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.PersonAlreadyRegistered.selector, alice));
        registry.registerPerson(alice, bobKey);
    }

    function test_RegisterPerson_RefusesKeyOfAnotherPerson() public {
        _register(alice, aliceKey);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.KeyAlreadyUsed.selector, aliceKey));
        registry.registerPerson(bob, aliceKey);
    }

    // ─────────────────────────────── replacing keys ───────────────────────────────

    function test_ReplaceKey_OldKeyStopsNewKeyWorks() public {
        _register(alice, aliceKey);
        address newKey = _keyFor(1, 1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit GavelRegistry.KeyReplaced(alice, aliceKey, newKey);
        vm.prank(owner);
        registry.replaceKey(alice, newKey);

        assertEq(registry.keyOf(alice), newKey);
        assertEq(registry.personIdOf(newKey), alice);
        assertEq(registry.personIdOf(aliceKey), bytes32(0));
        assertTrue(registry.wasKeyEverUsed(aliceKey));
    }

    function test_ReplaceKey_RetiredKeyCanNeverBeReused() public {
        _register(alice, aliceKey);
        vm.prank(owner);
        registry.replaceKey(alice, _keyFor(1, 1));

        // not for someone else...
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.KeyAlreadyUsed.selector, aliceKey));
        registry.registerPerson(bob, aliceKey);

        // ...and not for the same person either
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.KeyAlreadyUsed.selector, aliceKey));
        registry.replaceKey(alice, aliceKey);
    }

    function test_ReplaceKey_RefusesZeroKey() public {
        _register(alice, aliceKey);
        vm.prank(owner);
        vm.expectRevert(GavelRegistry.ZeroKey.selector);
        registry.replaceKey(alice, address(0));
    }

    function test_ReplaceKey_RefusesUnregisteredPerson() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.PersonNotRegistered.selector, alice));
        registry.replaceKey(alice, aliceKey);
    }

    function test_ReplaceKey_RefusesKeyOfAnotherPerson() public {
        _register(alice, aliceKey);
        _register(bob, bobKey);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.KeyAlreadyUsed.selector, bobKey));
        registry.replaceKey(alice, bobKey);
    }

    // ─────────────────────────────── active flag ───────────────────────────────

    function test_SetActive_TogglesAndEmits() public {
        _register(alice, aliceKey);

        vm.expectEmit(true, true, true, true, address(registry));
        emit GavelRegistry.ActiveSet(alice, false);
        vm.prank(owner);
        registry.setActive(alice, false);
        assertFalse(registry.isActive(alice));
        assertTrue(registry.isRegistered(alice));

        vm.prank(owner);
        registry.setActive(alice, true);
        assertTrue(registry.isActive(alice));
    }

    function test_SetActive_RefusesUnregisteredPerson() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(GavelRegistry.PersonNotRegistered.selector, alice));
        registry.setActive(alice, false);
    }

    // ─────────────────────────────── owner only ───────────────────────────────

    function test_OwnerActions_RefuseEveryoneElse() public {
        _register(alice, aliceKey);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.registerPerson(bob, bobKey);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.replaceKey(alice, bobKey);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.setActive(alice, false);
    }

    // ─────────────────────────────── ownership ───────────────────────────────

    function test_OwnershipTransfer_NeedsAcceptance() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        registry.transferOwnership(newOwner);
        assertEq(registry.owner(), owner); // nothing changes until accepted
        assertEq(registry.pendingOwner(), newOwner);

        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider));
        registry.acceptOwnership();

        vm.prank(newOwner);
        registry.acceptOwnership();
        assertEq(registry.owner(), newOwner);
        assertEq(registry.pendingOwner(), address(0));
    }

    function test_RenounceOwnership_IsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(GavelRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), owner);
    }
}
