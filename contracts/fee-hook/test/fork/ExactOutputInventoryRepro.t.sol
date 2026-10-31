// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SurplusFeeHook} from "../../src/SurplusFeeHook.sol";
import {ModifyLiquidityParams, PoolKey, SwapParams} from "../../src/V4Minimal.sol";
import {ForkHarness} from "./ForkHarness.sol";

interface InventoryReproVm {
    function snapshotState() external returns (uint256);
    function revertToState(uint256) external returns (bool);
}

/// Reproduction, NOT remediation: real reviewed hook + historical Base PoolManager.
/// Mock V2 isolates either currency ordering. Every swap settles through the existing Actor.
abstract contract ExactOutputInventoryRepro is ForkHarness {
    function test_ReproducesExactOutputInputFeeInventoryDependency() public {
        _wethOnly(official);
        _wethOnly(twin);
        assertEq(v2.balanceOf(address(MANAGER)), 0, "no prior global V2 inventory");
        SwapParams memory params = _exactOutSell(1 ether);
        InventoryReproVm cheat = InventoryReproVm(address(vm));
        uint256 snapshot = cheat.snapshotState();
        int256 control = actor.swap(twin, params);
        uint256 input = _abs(_unspecified(control, params));
        uint256 fee = input * 15_000 / 1_000_000;
        assertGt(fee, 0, "nonzero input-denominated hook fee");
        assertTrue(cheat.revertToState(snapshot), "control must not prefund the hook test");
        assertEq(v2.balanceOf(address(MANAGER)), 0, "control inventory was discarded");

        uint256 price = _sqrtPrice(official);
        uint256 traderV2 = v2.balanceOf(address(actor));
        uint256 traderWeth = IERC20(WETH).balanceOf(address(actor));
        _expectFeeInventoryRevert(params);
        assertEq(uint256(_sqrtPrice(official)), price, "price rollback");
        assertEq(v2.balanceOf(address(actor)), traderV2, "no input charged");
        assertEq(IERC20(WETH).balanceOf(address(actor)), traderWeth, "no output delivered");
        assertEq(hook.totalTaken(address(v2)), 0, "fee accounting rollback");

        // Fixture mint is equivalent to supplying this much prior token inventory to the manager.
        v2.mint(address(MANAGER), fee - 1);
        _expectFeeInventoryRevert(params);
        v2.mint(address(MANAGER), 1);
        int256 charged = actor.swap(official, params);
        assertEq(
            int256(_unspecified(charged, params)), int256(_unspecified(control, params)) - _int(fee), "input plus fee"
        );
        assertEq(int256(_specified(charged, params)), int256(_specified(control, params)), "requested output preserved");
        assertEq(v2.balanceOf(address(hook)), fee, "fee custody");
        assertEq(hook.totalTaken(address(v2)), fee, "fee ledger");
        emit log_named_decimal_uint("requested WETH output", 1 ether, 18);
        emit log_named_decimal_uint("pre-fee V2 input", input, 18);
        emit log_named_decimal_uint("minimum prior global V2 inventory", fee, 18);
    }

    function test_ExactInputSellControlNeedsNoPriorV2() public {
        _wethOnly(official);
        assertEq(v2.balanceOf(address(MANAGER)), 0, "zero prior V2");
        SwapParams memory params = _exactInSell(25_000 ether);
        int256 delta = actor.swap(official, params);
        assertEq(int256(_specified(delta, params)), -int256(25_000 ether), "exact input settled");
        assertGt(hook.totalTaken(WETH), 0, "output fee collected");
        assertEq(hook.totalTaken(address(v2)), 0, "no input fee prefunding");
    }

    function _expectFeeInventoryRevert(SwapParams memory params) internal {
        (bool ok, bytes memory reason) = address(actor).call(abi.encodeCall(actor.swap, (official, params)));
        assertFalse(ok, "insufficient prior input-fee inventory must reproduce the failure");
        bytes memory inner = abi.encodeWithSignature(
            "WrappedError(address,bytes4,bytes,bytes)",
            address(v2),
            IERC20.transfer.selector,
            abi.encodeWithSignature("Error(string)", "insufficient"),
            abi.encodeWithSignature("ERC20TransferFailed()")
        );
        bytes memory expected = abi.encodeWithSignature(
            "WrappedError(address,bytes4,bytes,bytes)",
            address(hook),
            SurplusFeeHook.afterSwap.selector,
            inner,
            abi.encodeWithSignature("HookCallFailed()")
        );
        assertEq(reason, expected, "specific take-before-input-settlement transfer failure");
    }

    function _wethOnly(PoolKey memory key) internal {
        vm.prank(INITIALIZER);
        int24 tick = MANAGER.initialize(key, _startPrice());
        int24 floor = tick / TICK_SPACING * TICK_SPACING;
        if (floor > tick) floor -= TICK_SPACING;
        int24 lower = _v2IsCurrency0() ? floor - HALF_RANGE : floor + TICK_SPACING;
        int24 upper = _v2IsCurrency0() ? floor : lower + HALF_RANGE;
        actor.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, LIQUIDITY, 0));
    }
}

contract ExactOutputInventoryCurrency0 is ExactOutputInventoryRepro {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

contract ExactOutputInventoryCurrency1 is ExactOutputInventoryRepro {
    function _v2IsCurrency0() internal pure override returns (bool) {
        return false;
    }
}
