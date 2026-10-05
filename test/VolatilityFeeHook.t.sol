// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Deployers} from "v4-core-test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {VolatilityMath} from "../src/libraries/VolatilityMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

contract VolatilityFeeHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    VolatilityFeeHook hook;
    PoolId poolId;

    uint160 constant TARGET_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    function setUp() public {
        // Deploy fresh Uniswap v4 Manager and peripheral routers
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Mine salt matching hook flag bits
        bytes memory constructorArgs = abi.encode(manager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), TARGET_FLAGS, type(VolatilityFeeHook).creationCode, constructorArgs);

        // Deploy hook to the mined address
        hook = new VolatilityFeeHook{salt: salt}(manager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        // Initialize a pool with dynamic fee flag
        (key, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );
    }

    /* -------------------------------------------------------------------------- */
    /*                                 UNIT TESTS                                 */
    /* -------------------------------------------------------------------------- */

    function test_InitialPoolState() public view {
        (int24 lastTick, uint40 lastTimestamp, uint32 volatility, uint24 baseFee, uint24 minFee, uint24 maxFee,,) =
            hook.poolStates(poolId);

        assertEq(lastTick, 0);
        assertEq(lastTimestamp, uint40(block.timestamp));
        assertEq(volatility, 0);
        assertEq(baseFee, 3000);
        assertEq(minFee, 500);
        assertEq(maxFee, 50000);
    }

    function test_RevertIf_NotPoolManager() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -100, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        vm.expectRevert(VolatilityFeeHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");

        vm.expectRevert(VolatilityFeeHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");

        vm.expectRevert(VolatilityFeeHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
    }

    function test_RevertIf_NotDynamicFeePool() public {
        PoolKey memory staticKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 3000, // static 0.30% fee
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        // Initialize should revert when fee is not DYNAMIC_FEE_FLAG
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.afterInitialize.selector,
                abi.encodeWithSelector(VolatilityFeeHook.NotDynamicFeePool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(staticKey, SQRT_PRICE_1_1);
    }

    function test_InitialSwapAppliesBaseFee() public {
        uint24 estimatedFee = hook.getEstimatedFee(poolId);
        assertEq(estimatedFee, 3000); // 0.30% base fee

        // Perform swap
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1000, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, "");

        // Volatility is still low on small trade
        uint24 newFee = hook.getEstimatedFee(poolId);
        assertGe(newFee, 3000);
    }

    function test_TimeDecay_ReducesVolatilityToFloor() public {
        // Perform a swap
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -10000, sqrtPriceLimitX96: SQRT_PRICE_1_2});

        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(key, params, testSettings, "");

        // Warp time forward by 300 seconds (5 half-lives)
        vm.warp(block.timestamp + 300);

        uint24 decayedFee = hook.getEstimatedFee(poolId);
        assertEq(decayedFee, 3000); // Decayed back to base fee
    }

    /* -------------------------------------------------------------------------- */
    /*                                 FUZZ TESTS                                 */
    /* -------------------------------------------------------------------------- */

    function testFuzz_AbsTickDelta(int24 a, int24 b) public pure {
        uint24 delta = VolatilityMath.absTickDelta(a, b);
        uint24 deltaRev = VolatilityMath.absTickDelta(b, a);
        assertEq(delta, deltaRev);

        if (a == b) {
            assertEq(delta, 0);
        } else {
            assertGt(delta, 0);
        }
    }

    function testFuzz_VolatilityDecay_Monotonic(uint32 vol, uint32 timeElapsed) public pure {
        uint32 decayed = VolatilityMath.decayVolatility(vol, timeElapsed, 60);
        assertLe(decayed, vol);

        if (timeElapsed >= 1800) {
            // >= 30 half-lives
            assertEq(decayed, 0);
        }
    }

    function testFuzz_CalculateDynamicFee_StrictBounds(uint32 vol, uint16 sensitivity) public pure {
        uint24 base = 3000;
        uint24 min = 500;
        uint24 max = 50000;

        uint24 fee = VolatilityMath.calculateDynamicFee(vol, base, min, max, sensitivity);
        assertGe(fee, min);
        assertLe(fee, max);
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE);
    }
}
