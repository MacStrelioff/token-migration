# Exact-output fee-inventory reproduction (M-02)

This is a **reproduction, not a fix**. Base source is upstream commit `259dec9b0b313ff018f28a9e0b948ee0116a51c5`.

## Why the swap can fail

For exact-output swaps the unspecified currency is the input currency. The reviewed hook physically calls `PoolManager.take()` for its fee from inside `afterSwap`, before the ordinary swap actor pays its input at settlement. A manager with less prior input-token inventory than that fee cannot make the transfer, although the trader has enough tokens to pay the complete swap.

[Executable reproduction](ExactOutputInventoryRepro.t.sol) reuses the upstream `ForkHarness` and `Actor`. It uses the **actual reviewed SurplusFeeHook and real historical Base PoolManager**, with an explicitly mocked V2 token to isolate both currency orderings. The WETH-only liquidity ranges are built through real manager calls; no manager storage or ERC20 balance override makes the failing state.

## Run

Install Foundry **v1.7.1** and Node/npm. Check out this source commit on `MacStrelioff/token-migration` (or the `test/m02-exact-output-inventory` branch), then:

```sh
npm ci --ignore-scripts
cd contracts/fee-hook
forge test --match-path test/fork/ExactOutputInventoryRepro.t.sol \
  --fork-url https://mainnet.base.org --fork-block-number 51935583 -vv
```

The public RPC is used only for historical reads. All state changes are local Foundry fork execution. No key, signature or public broadcast is needed. The two suites run both V2 currency orderings.

## Expected result

**Four methods pass**: two assertions reproducing bad behavior and two exact-input controls. A passing reproduction wrapper does **not** mean the dependency is fixed.

For each token ordering, requesting 1 WETH exact output:

1. A hookless twin succeeds. Its state is snapshotted and discarded, so its input payment cannot accidentally prefund the hooked case.
2. Zero prior global manager V2 inventory: hooked trade reverts with the specific nested fee-token transfer error.
3. Prior inventory `fee - 1`: the same failure.
4. Prior inventory exactly `376512504622295293301` raw V2 (`376.512504622295293301` tokens): trade settles and the requested output and fee accounting match the hookless control plus fee.
5. Failed swaps restore pool price, trader V2/WETH balances and the hook fee ledger.
6. Exact-input sell succeeds with zero prior manager V2 inventory, because its fee is taken from the output currency instead.

The threshold is specific to the sampled fixture, price, fee and requested size—not a universal inventory buffer. The fixture supplies mock V2 inventory by minting; that represents a prior transfer/donation to the shared manager, not a proposed production remedy.

## Severity boundary

This is **conditional exact-output routing/liveness**, not theft. The manager's balance is global across its pools; it is not merely this pool's reserves. The isolated one-sided fixture does not prove that the actual split-seed launch starts deficient. A separate actual-launch/UUPS-V2/real-hook matrix completed 32 finite-funded, snapshot-isolated normal trades across both directions, exactness modes and token orderings.

The existing extreme-size seeded probes measure hook-take success using intentionally reverted callbacks. They are not proof of a completed affordable production trade failing, and their thresholds must not be generalized to every later liquidity state or router.

## Suggested acceptance criteria

Either remove the pre-settlement input-inventory dependency through a reviewed fee-settlement design, or explicitly document and enforce the supported router/shape/prefunding policy. Preserve zero, fee-minus-one, exact-fee, rollback and exact-input regressions in both currency orders. This reproduction does not endorse a particular redesign.
