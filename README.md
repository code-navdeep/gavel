# Gavel

**Decision-making smart contracts for organisations.** Gavel records group decisions — yes/no votes, choices between options, ranked-choice votes and approvals that need a quorum — on a blockchain network your organisation runs, so that nobody, including the people running the process, can quietly change a result.

Gavel is a set of separate contracts. Use the ones you need.

| Contract | Use it for | Example |
|---|---|---|
| `GavelRegistry` | The list of people who can vote, and who runs the process | Every employee, each with an ID and a signing key |
| `GavelYesNo` | A question answered yes or no | "Approve the Q3 budget?" |
| `GavelChoice` | Picking one option from a list | "Which of these 4 vendors do we choose?" |
| `GavelRanked` | Ranking options in order of preference (instant runoff) | "Rank the three proposed office locations" |
| `GavelThreshold` | Approvals that need a minimum turnout or level of support | "At least 3 of these 5 managers must sign off" |

---

## Contents

1. [Why a blockchain](#1-why-a-blockchain)
2. [How a decision works](#2-how-a-decision-works)
3. [Who can do what](#3-who-can-do-what)
4. [People, IDs and keys](#4-people-ids-and-keys)
5. [The decision types](#5-the-decision-types)
6. [Using Gavel from your app](#6-using-gavel-from-your-app)
7. [Network requirements](#7-network-requirements)
8. [Deploying](#8-deploying)
9. [Getting the code and running the tests](#9-getting-the-code-and-running-the-tests)
10. [Limits and costs](#10-limits-and-costs)
11. [Licence](#11-licence)

---

## 1. Why a blockchain

- **Results can't be edited.** Every ballot is recorded permanently. There is no function that changes a ballot, a count or a result — not even for the owner.
- **The rules are enforced by code.** Who may vote, when voting opens and closes, and how the result is counted are fixed when a decision is locked.
- **Anyone with access can check.** Counts and results can be recomputed by anyone who can read the network.

Your users don't need to know any of this. Your app can hide the blockchain completely (see [section 6](#6-using-gavel-from-your-app)).

---

## 2. How a decision works

Every decision — whatever its type — goes through the same four states:

```
 Draft ──(owner locks)──▶ Scheduled ──(start time)──▶ Open ──(end time)──▶ Closed
```

| State | What happens |
|---|---|
| **Draft** | The owner creates the decision and builds its voter list. Voters can be added in batches and removed. |
| **Scheduled** | The owner has locked it. **Nothing about the decision can change any more** — not the question, the times or the voter list. |
| **Open** | From the start time (the start second counts as open). Each person on the voter list may cast **one** ballot. Ballots are final. |
| **Closed** | From the end time (the end second counts as closed). No more ballots. The result can be read. |

A decision opens and closes **on its own**, by the clock. There is no pause, no early close and no cancel.

**Example.** The owner creates "Approve the Q3 budget?", opening tomorrow at 09:00 for one day, adds the 5 board members, and locks it. Tomorrow 3 vote yes and 1 votes no; one never votes. After 09:00 the following day, anyone can read the result: **Yes, 3 to 1**.

---

## 3. Who can do what

The **owner** is a single address set when Gavel is deployed. It can be one person's key or a multi-signature wallet contract. The owner of `GavelRegistry` is automatically the owner of every decision contract.

| The owner can | The owner cannot |
|---|---|
| Register people and their keys | Change or delete anyone's ballot |
| Replace a person's key (e.g. after a lost device) | Change a count or a result |
| Mark a person inactive (they can't be added to new decisions) | Add or remove voters once a decision is locked |
| Create decisions, build their voter lists, and lock them | Cancel, pause or close a decision early |
| Hand ownership to a new owner (the new owner must accept) | Give up ownership entirely (disabled, so Gavel can never be left without an owner) |

**Everyone on a decision's voter list** can cast one ballot while it is open. **Anyone** can read ballots, counts and results.

### The one trust limit you should know about

Because the owner registers and replaces keys, the owner *could* replace the key of someone who has not voted yet and then vote in their place. Gavel doesn't block this, because blocking key replacement during a vote would also stop a person who genuinely lost their device from voting. Instead, **every key registration and replacement is permanently recorded** (`PersonRegistered` and `KeyReplaced` events, with the person's ID), so it can never happen invisibly. If this matters for your organisation, make the owner a multi-signature wallet so no single person can replace keys alone.

---

## 4. People, IDs and keys

- **Person ID** — a 32-byte value (`bytes32`) that identifies a person on the network. **Never use a name, email or other personal detail**: everything on a blockchain is permanent and visible to anyone who can read the network. Use a random ID and keep the mapping from ID to person in your own database. Note that votes are **named**: anyone who has your mapping can see how each person voted.
- **Key** — the address of the signing key on the person's browser or device. Each person has exactly one current key.
- **Lost device** — the owner calls `replaceKey(personId, newKey)`. The old key stops working immediately and can never be used again by anyone. **The person does not get a second vote**: ballots are counted per person ID, not per key.
- **Inactive people** — `setActive(personId, false)` stops a person being added to new decisions. It does **not** take away their vote in a decision that was already locked with them on it.

---

## 5. The decision types

All types share the rules in [section 2](#2-how-a-decision-works). Each type's `createDraft` returns the new decision's number (0, 1, 2 …). Then the owner calls `addVoters(decisionId, personIds)` (as many times as needed) and `lock(decisionId)`.

### `GavelYesNo`
- **Create:** `createDraft(title, startTime, endTime)` — times are Unix timestamps in seconds.
- **Vote:** `castBallot(decisionId, yes)` — `true` for yes, `false` for no.
- **Result:** `result(decisionId)` → outcome `NoBallots`, `Yes`, `No` or `Tied`, plus the yes and no counts.

### `GavelChoice`
- **Create:** `createDraft(title, options, startTime, endTime)` — 2 to 32 option labels. Options are numbered from 0 in the order given.
- **Vote:** `castBallot(decisionId, optionIndex)`.
- **Result:** outcome `NoBallots`, `Winner` or `Tied`; the winning option (or **every** option sharing the top count, if tied); and the count for each option.

### `GavelRanked`
- **Create:** `createDraft(title, options, startTime, endTime)` — 2 to 16 options; a voter list of at most 1,000 people.
- **Vote:** `castBallot(decisionId, ranking)` — option numbers from most to least preferred. Rank some or all options; no option twice.
- **How it's counted (instant runoff), round by round:**
  1. Every ballot counts for its highest-ranked option still in the race. A ballot whose ranked options have all been eliminated no longer counts.
  2. If one option has **more than half** of the ballots that still count, it wins.
  3. Otherwise, every option tied for the lowest count is eliminated together, and the next round starts.
  4. If that would eliminate every option still in the race, the result is a tie between them.
- **Worked example:** options 0 = Alpha, 1 = Beta, 2 = Gamma; five ballots `[0,1] [0,2] [1,0] [1,0] [2,1]`.
  - Round 1: Alpha 2, Beta 2, Gamma 1. Nobody has more than half of 5, so Gamma (lowest) is eliminated.
  - Round 2: the `[2,1]` ballot moves to Beta. Alpha 2, Beta 3. Beta has more than half and **wins**.
- **Result:** outcome `NoBallots`, `Winner` or `Tied`; the winner (or tied options); the number of rounds; and each option's count in the final round, so anyone can check the count.

### `GavelThreshold`
- **Create:** `createDraft(title, startTime, endTime, minBallots, minApprovals, minApprovalShareNumerator, minApprovalShareDenominator)`.
- **Vote:** `castBallot(decisionId, approve)` — `true` to approve, `false` to reject.
- **Result:** the decision is **Approved** only if all rules are met:
  1. **Quorum** — at least `minBallots` people voted. Otherwise the result is `QuorumNotMet`.
  2. **Minimum approvals** — at least `minApprovals` people approved (must be at least 1).
  3. **Minimum share** (optional) — at least `minApprovalShareNumerator` approvals for every `minApprovalShareDenominator` ballots. This is an exact fraction, checked as `approvals × minApprovalShareDenominator ≥ ballots × minApprovalShareNumerator`. Set both to `0` to not use a share.

  If rule 2 or 3 fails, the result is `ThresholdNotMet`.

| You want | Voter list | `minBallots` | `minApprovals` | `minApprovalShareNumerator`, `minApprovalShareDenominator` |
|---|---|---|---|---|
| "3 of these 5 managers must sign off" | the 5 managers | 0 | 3 | 0, 0 |
| "At least 120 of 200 members vote, and two-thirds of them approve" | the 200 members | 120 | 1 | 2, 3 |
| "Three-quarters of the ballots cast must approve" | everyone eligible | 0 | 1 | 3, 4 |

With a two-thirds share (2, 3), exactly 2 approvals out of 3 ballots **passes** (2 × 3 = 6 ≥ 3 × 2 = 6); 1 out of 3 does not.

**Results are only available after the end time**, even if the outcome is already certain (for example, 3 of 5 managers approved on the first day).

---

## 6. Using Gavel from your app

Gavel is contracts only — your app talks to them. A typical flow:

1. **First use:** your app quietly creates a signing key on the person's device and sends its address to your admin system.
2. **Registration:** your admin system (as the owner) calls `GavelRegistry.registerPerson(personId, address)`.
3. **Setting up a decision:** the owner calls `createDraft`, `addVoters` and `lock` on the right contract.
4. **Voting:** while the decision is open, your app sends `castBallot` signed with the person's device key. The person only sees a normal button like "Approve".
5. **Results:** after the end time, your app (or anyone) calls `result`.

The snippets below use the TypeScript library [viem](https://viem.sh) and are **illustrative** — adapt them to your app and check them against the library version you use. Contract interfaces (ABIs) are generated by `forge build` in `out/<Contract>.sol/<Contract>.json`.

**Create a device key (once per device):**
```ts
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";

const privateKey = generatePrivateKey(); // store it securely — see "Storing the key" below
const account = privateKeyToAccount(privateKey);
// Send account.address to your admin system, which calls:
//   GavelRegistry.registerPerson(personId, account.address)
```

**Describe your organisation's network (once):**
```ts
import { defineChain } from "viem";

export const companyNetwork = defineChain({
  id: 12345, // your network's chain ID
  name: "Company network",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://chain.example.internal"] } },
});
```

**Cast a ballot (yes/no decision):**
```ts
import { createWalletClient, createPublicClient, http } from "viem";
import yesNo from "./GavelYesNo.json"; // copied from out/GavelYesNo.sol/GavelYesNo.json

const wallet = createWalletClient({ account, chain: companyNetwork, transport: http() });
const reader = createPublicClient({ chain: companyNetwork, transport: http() });

const hash = await wallet.writeContract({
  address: GAVEL_YES_NO_ADDRESS,
  abi: yesNo.abi,
  functionName: "castBallot",
  args: [decisionId, true],
});
const receipt = await reader.waitForTransactionReceipt({ hash });
// Tell the person their vote is recorded ONLY when receipt.status === "success".
```

**Read a result (after the end time):**
```ts
const [outcome, yesCount, noCount] = await reader.readContract({
  address: GAVEL_YES_NO_ADDRESS,
  abi: yesNo.abi,
  functionName: "result",
  args: [decisionId],
});
// outcome: 0 = NoBallots, 1 = Yes, 2 = No, 3 = Tied
```

**Handling refusals.** Every refusal has a named error your app can show in plain words, for example `AlreadyVoted`, `NotOnVoterList`, `DecisionNotOpen`, `DecisionNotClosed`, `KeyNotRegistered`.

**Storing the key.** The device key is what lets a person vote, so treat it like a password:
- In a native mobile or desktop app, use the operating system's secure key storage.
- In a web app, never keep the raw key in plain `localStorage`. Keep it encrypted, for example with a browser-held key created through the Web Crypto API that cannot be exported.
- If a key is lost, the owner replaces it with `replaceKey` — the person keeps their single vote.

**Fees.** If your network charges no transaction fees, some libraries still try to estimate a fee price; check your library's options for sending with a zero gas price. If your network does charge fees, the owner must top up each voter's key with the network's currency before they vote ([section 7](#7-network-requirements)).

---

## 7. Network requirements

Gavel does not include a blockchain network. **You bring the network**; it must meet these requirements.

| Requirement | Why |
|---|---|
| **EVM-compatible** (runs Solidity smart contracts) | Gavel is written in Solidity |
| **Supports the `paris` EVM version or newer** | Gavel is compiled for `paris` so it runs on older networks too |
| **Standard contract size limit (24,576 bytes)** | The largest Gavel contract is 9,220 bytes |
| **Zero transaction fees, or pre-funded voter keys** | Every ballot is a transaction signed by the voter's own key. With fees, the owner must give each voter enough of the network's currency first: a ballot costs up to about 156,000 gas |
| **Block gas limit of at least 15,000,000** | Enough for adding voters in batches of 500 (about 29,000 gas per voter) and for the largest draft (about 2,400,000 gas) |
| **Read-call gas cap of at least 30,000,000** | Reading a ranked-choice result at the maximum size (1,000 voters, 16 options) takes about 23,100,000 gas. The name of this node setting differs between network software |
| **Regular block production, with accurate timestamps** | Decisions open and close by block time. If the network produces blocks only when there are transactions, a read may still report a decision as open after its end time until the next block is produced **— verify how your network software behaves** |
| **A network address (RPC endpoint) your users' devices can reach** | Apps send ballots and read results through it. Browser apps also need it to allow requests from your app's web address (CORS) |

---

## 8. Deploying

You need [Foundry](https://book.getfoundry.sh) installed (see [section 9](#9-getting-the-code-and-running-the-tests)). Foundry builds, tests and deploys the contracts; it does not provide the network.

```sh
forge build
GAVEL_OWNER=0xYourOwnerAddress \
  forge script script/DeployGavel.s.sol --rpc-url https://chain.example.internal --broadcast
```

- `GAVEL_OWNER` is the address that will run the registry and every decision contract.
- Provide the deploying key with one of Foundry's wallet options (for example an encrypted keystore). Don't put private keys in shell history or in the repository; `.env` files are git-ignored.
- The script deploys `GavelRegistry` and all four decision contracts, and prints their addresses.

---

## 9. Getting the code and running the tests

The third-party libraries in `lib/` (OpenZeppelin Contracts and forge-std) are git submodules, so clone with:

```sh
git clone --recurse-submodules <repository address>
# or, in an existing clone:
git submodule update --init --recursive
```

Install Foundry, then run the tests:

```sh
curl -L https://foundry.paradigm.xyz | bash
foundryup

forge build
forge test               # all tests
forge test --gas-report  # with gas costs per function
```

The test suite covers every rule and every refusal, including fuzz tests (random inputs) and an invariant test that performs thousands of random actions — voting, replacing keys, trying to change locked voter lists — and checks that no person ever gets two ballots.

---

## 10. Limits and costs

| Limit | Value |
|---|---|
| Options in a `GavelChoice` decision | 2–32 |
| Options in a `GavelRanked` decision | 2–16 |
| Voters in a `GavelRanked` decision | up to 1,000 |
| Voters in other decision types | no fixed limit; add them in batches |

Measured gas (the unit of computing work a network counts; free if your network charges no fees):

| Action | Gas (approx.) |
|---|---|
| Register a person | 93,200 |
| Replace a key | 76,500 |
| Add voters | 29,000 per voter |
| Lock a decision | 37,000–39,000 |
| Create a yes/no or threshold draft | 97,000–123,000 |
| Create a choice draft with 32 long option labels | 2,400,000 |
| Cast a ballot (yes/no, threshold, choice) | up to 111,000 |
| Cast a ranked ballot ranking all 16 options | up to 156,000 |
| Read a ranked-choice result at 1,000 voters × 16 options (worst case) | 23,100,000 |

---

## 11. Licence

MIT — see [`LICENSE`](LICENSE).
