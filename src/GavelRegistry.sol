// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title GavelRegistry — the list of people who can take part in decisions
/// @notice Every person is identified by a PERSON ID that your organisation chooses
///         (for example a random ID, or an encoded employee number). Never put names
///         or other personal details here: everything written to a blockchain is
///         permanent and visible to everyone who can read the network.
///
///         Each person has exactly one KEY at a time: the address of the signing key
///         on their browser or device. When someone loses a device, the owner replaces
///         their key. Decisions count ballots by person ID, so a replaced key never
///         gives anyone a second vote.
///
///         Only the owner can change this registry. Every change is recorded as an
///         event, so there is a permanent history of who was registered and which keys
///         they used.
/// @dev Ownership moves in two steps (the new owner must accept), and giving up
///      ownership is disabled. The owner of this registry is also the owner of every
///      decision module that uses it.
contract GavelRegistry is Ownable2Step {
    /// @notice What the registry stores about one person.
    /// @param key The address of the person's current signing key.
    /// @param active Whether the person can be added to NEW decisions.
    struct Person {
        address key;
        bool active;
    }

    /// @notice A person ID of all zeros is not allowed.
    error ZeroPersonId();
    /// @notice The zero address is not a valid key.
    error ZeroKey();
    /// @notice This person ID is already registered.
    error PersonAlreadyRegistered(bytes32 personId);
    /// @notice This person ID has never been registered.
    error PersonNotRegistered(bytes32 personId);
    /// @notice This key has already been used by someone (now or in the past).
    error KeyAlreadyUsed(address key);
    /// @notice Giving up ownership is disabled, so the toolkit can never be left without an owner.
    error RenounceDisabled();

    /// @notice A new person was added with their first key.
    event PersonRegistered(bytes32 indexed personId, address indexed key);
    /// @notice A person's key was replaced (for example after a lost device).
    event KeyReplaced(bytes32 indexed personId, address indexed oldKey, address indexed newKey);
    /// @notice A person was marked active or inactive.
    event ActiveSet(bytes32 indexed personId, bool active);

    mapping(bytes32 personId => Person) private _people;
    mapping(address key => bytes32 personId) private _personIdOfKey;
    mapping(address key => bool) private _keyEverUsed;

    /// @param initialOwner The address that will run the registry and every decision module.
    constructor(address initialOwner) Ownable(initialOwner) {}

    // ──────────────────────────────── owner actions ────────────────────────────────

    /// @notice Add a person with their first key. The person starts as active.
    /// @dev Only the owner. Refuses a zero ID, a zero key, an ID that is already
    ///      registered, and a key that anyone has ever used before.
    function registerPerson(bytes32 personId, address key) external onlyOwner {
        if (personId == bytes32(0)) revert ZeroPersonId();
        if (key == address(0)) revert ZeroKey();
        if (_people[personId].key != address(0)) revert PersonAlreadyRegistered(personId);
        if (_keyEverUsed[key]) revert KeyAlreadyUsed(key);

        _people[personId] = Person({key: key, active: true});
        _personIdOfKey[key] = personId;
        _keyEverUsed[key] = true;

        emit PersonRegistered(personId, key);
    }

    /// @notice Give a person a new key. The old key stops working immediately and can never be used again.
    /// @dev Only the owner. Refuses a zero key, an unregistered person, and a key that
    ///      anyone has ever used before.
    ///
    ///      Trust note: because the owner can replace keys, the owner could replace the
    ///      key of someone who has not voted yet and vote in their place. This event makes
    ///      every replacement permanently visible.
    function replaceKey(bytes32 personId, address newKey) external onlyOwner {
        if (newKey == address(0)) revert ZeroKey();
        Person storage person = _people[personId];
        if (person.key == address(0)) revert PersonNotRegistered(personId);
        if (_keyEverUsed[newKey]) revert KeyAlreadyUsed(newKey);

        address oldKey = person.key;
        delete _personIdOfKey[oldKey];
        person.key = newKey;
        _personIdOfKey[newKey] = personId;
        _keyEverUsed[newKey] = true;

        emit KeyReplaced(personId, oldKey, newKey);
    }

    /// @notice Mark a person as active or inactive.
    /// @dev Only the owner. An inactive person cannot be added to new decisions, but keeps
    ///      their vote in any decision that was already locked with them on its voter list.
    function setActive(bytes32 personId, bool active) external onlyOwner {
        Person storage person = _people[personId];
        if (person.key == address(0)) revert PersonNotRegistered(personId);

        person.active = active;

        emit ActiveSet(personId, active);
    }

    /// @notice Disabled. Always fails, so the toolkit can never be left without an owner.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ──────────────────────────────── lookups ────────────────────────────────

    /// @notice The current key of a person, or the zero address if the ID is not registered.
    function keyOf(bytes32 personId) external view returns (address) {
        return _people[personId].key;
    }

    /// @notice The person ID a key currently belongs to, or zero if the key is not a current key.
    function personIdOf(address key) external view returns (bytes32) {
        return _personIdOfKey[key];
    }

    /// @notice Whether this person ID has been registered.
    function isRegistered(bytes32 personId) external view returns (bool) {
        return _people[personId].key != address(0);
    }

    /// @notice Whether this person can be added to new decisions. False for unregistered IDs.
    function isActive(bytes32 personId) external view returns (bool) {
        return _people[personId].active;
    }

    /// @notice Whether a key has ever been registered or used as a replacement.
    function wasKeyEverUsed(address key) external view returns (bool) {
        return _keyEverUsed[key];
    }
}
