// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SurplusFeeHook} from "../src/SurplusFeeHook.sol";
import {PoolKey, SwapParams} from "../src/V4Minimal.sol";
import {HookTest} from "./utils/HookTest.sol";
import {MockPoolManager} from "./utils/MockPoolManager.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @dev Spec §3.5 oracle review of the fee-hook diff, round 2 finding 2 (triage:
 *      contracts/migration-launch/kit/evidence/review/fee-hook-oracle.md). FAILS on b62393184: tokens sent to the
 *      hook outside afterSwap have no way out, because fee withdrawals stop at owed − paid. It targets the
 *      recovery ABI of 1ed281150, `recoverExcess(currency, to)`, spelled from its signature so this file compiles
 *      before the fix. It complements test/HookOracleReview.t.sol from that commit with the cases that decide
 *      what "the balance above the unpaid fees" is: a currency the hook never charged, fees already partly
 *      withdrawn, and the fees staying withdrawable after a recovery.
 */
contract HookStrayTokenRecoveryTest is HookTest {
    uint24 internal constant LP_FEE = 3000; // pips: 0.30%
    int24 internal constant TICK_SPACING = 60;
    address internal constant TREASURY = address(0x7EA5);
    address internal constant INITIALIZER = address(0x1417);
    address internal constant STRANGER = address(0xBAD);
    address internal constant SWAPPER = address(0x5A1);
    address internal constant SENDER = address(0x5E4D); // pastes the hook's address by mistake
    address internal constant SINK = address(0x7EA7); // where the Safe returns tokens and fees
    uint256 internal constant STRAY = 5 ether;

    MockPoolManager internal manager;
    MockERC20 internal token0;
    MockERC20 internal token1;
    SurplusFeeHook internal hook;

    function setUp() public {
        manager = new MockPoolManager();
        MockERC20 a = new MockERC20("Token A", "A");
        MockERC20 b = new MockERC20("Token B", "B");
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        hook = _deployHook(
            "oracle.stray.hook",
            HookArgs(address(manager), TREASURY, INITIALIZER, address(token0), address(token1), LP_FEE, TICK_SPACING)
        );
        token1.mint(address(manager), 1e30);
    }

    function test_ORACLE_hook_StrayTokensAreRecoverable() public {
        // A real fee: an exact-input swap paying 2e18 token1 out; the hook takes 1.5% = 3e16 token1.
        PoolKey memory key = PoolKey(address(token0), address(token1), LP_FEE, TICK_SPACING, address(hook));
        vm.prank(address(manager));
        hook.afterSwap(SWAPPER, key, SwapParams(true, -1e18, 0), _delta(-1e18, 2e18), "");
        uint256 fee = hook.teamOwed(address(token1));
        assertEq(fee, 3e16, "the full fee accrued to the treasury");
        uint256 paidFirst = fee / 3;

        // A partial withdrawal makes `paid` non-zero, so owed alone overstates what is unpaid.
        vm.prank(TREASURY);
        hook.withdrawTeam(address(token1), SINK, paidFirst);

        // Plain transfers: in the fee currency, and in a currency the hook never charged.
        _strayTransfer(token1);
        _strayTransfer(token0);

        assertFalse(_recover(STRANGER, address(token1)), "a stranger recovered tokens");
        assertTrue(_recover(TREASURY, address(token1)), "stray token1 is stranded: nothing returns it");
        assertTrue(_recover(TREASURY, address(token0)), "stray token0 is stranded: nothing returns it");
        assertEq(token1.balanceOf(SINK), paidFirst + STRAY, "exactly the stray token1 came back");
        assertEq(token0.balanceOf(SINK), STRAY, "exactly the stray token0 came back");
        assertEq(token1.balanceOf(address(hook)), fee - paidFirst, "all unpaid treasury fees stayed in the hook");
        assertEq(hook.teamOwed(address(token1)), fee, "recovery preserves accrued fees");
        assertEq(hook.teamPaid(address(token1)), paidFirst, "recovery preserves paid fees");
        assertFalse(_recover(TREASURY, address(token1)), "a second recovery reached into the unpaid fees");

        // All unpaid treasury fees are still withdrawable, and nothing is left behind.
        vm.prank(TREASURY);
        hook.withdrawTeam(address(token1), SINK, fee - paidFirst);
        assertEq(hook.teamPaid(address(token1)), fee, "all fees paid");
        assertEq(token1.balanceOf(address(hook)), 0, "token1 left in the hook");
        assertEq(token0.balanceOf(address(hook)), 0, "token0 left in the hook");
    }

    function _strayTransfer(MockERC20 token) internal {
        token.mint(SENDER, STRAY);
        vm.prank(SENDER);
        assertTrue(token.transfer(address(hook), STRAY), "stray transfer");
    }

    function _recover(address caller, address currency) internal returns (bool ok) {
        vm.prank(caller);
        (ok,) = address(hook).call(abi.encodeWithSignature("recoverExcess(address,address)", currency, SINK));
    }
}
