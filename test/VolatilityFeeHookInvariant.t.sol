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
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {VolatilityMath} from "../src/libraries/VolatilityMath.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// @title VolatilityFeeHookHandler
/// @notice Dedicated stateful fuzz handler for Uniswap v4 Dynamic Volatility Fee Hook
contract VolatilityFeeHookHandler is Test {
    using PoolIdLibrary for PoolKey;

    VolatilityFeeHook public immutable hook;
    IPoolManager public immutable manager;
    PoolSwapTest public immutable swapRouter;
    PoolKey public key;
    PoolId public poolId;

    uint256 public totalSwaps;
    uint256 public totalZeroForOne;
    uint256 public totalOneForZero;

    constructor(VolatilityFeeHook _hook, IPoolManager _manager, PoolSwapTest _swapRouter, PoolKey memory _key, PoolId _poolId) {
        hook = _hook;
        manager = _manager;
        swapRouter = _swapRouter;
        key = _key;
        poolId = _poolId;
    }

    function swapZeroForOne(uint256 amountRaw) external {
        int256 amount = -int256(bound(amountRaw, 100, 5000));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: amount,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        try swapRouter.swap(key, params, testSettings, "") {
            totalSwaps++;
            totalZeroForOne++;
        } catch {}
    }

    function swapOneForZero(uint256 amountRaw) external {
        int256 amount = -int256(bound(amountRaw, 100, 5000));

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: false,
            amountSpecified: amount,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        try swapRouter.swap(key, params, testSettings, "") {
            totalSwaps++;
            totalOneForZero++;
        } catch {}
    }

    function warpTime(uint256 secondsElapsed) external {
        secondsElapsed = bound(secondsElapsed, 1, 3600);
        vm.warp(block.timestamp + secondsElapsed);
    }
}

/// @title VolatilityFeeHookInvariantTest
/// @author Basant Pokhrel (@basantzp)
/// @notice Foundry Invariant Fuzzing Test Suite verifying fee bounds and solvency across randomized swaps
contract VolatilityFeeHookInvariantTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    VolatilityFeeHook hook;
    PoolId poolId;
    VolatilityFeeHookHandler handler;

    uint160 constant TARGET_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        bytes memory constructorArgs = abi.encode(manager);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(address(this), TARGET_FLAGS, type(VolatilityFeeHook).creationCode, constructorArgs);

        hook = new VolatilityFeeHook{salt: salt}(manager);
        require(address(hook) == hookAddress, "Hook address mismatch");

        (key, poolId) = initPoolAndAddLiquidity(
            currency0, currency1, IHooks(address(hook)), LPFeeLibrary.DYNAMIC_FEE_FLAG, SQRT_PRICE_1_1
        );

        handler = new VolatilityFeeHookHandler(hook, manager, swapRouter, key, poolId);

        targetContract(address(handler));
    }

    /// @notice Invariant 1: Dynamic fee strictly stays within minFee and maxFee bounds
    function invariant_DynamicFeeBounded() public view {
        (,,,, uint24 minFee, uint24 maxFee,,) = hook.poolStates(poolId);
        uint24 fee = hook.getEstimatedFee(poolId);

        assertGe(fee, minFee, "Fee collapsed below minFee floor");
        assertLe(fee, maxFee, "Fee exceeded maxFee ceiling");
        assertLe(fee, LPFeeLibrary.MAX_LP_FEE, "Fee exceeded protocol maximum LP fee");
    }

    /// @notice Invariant 2: Hook never traps or steals pool currency tokens
    function invariant_HookHoldsZeroTokens() public view {
        assertEq(currency0.balanceOf(address(hook)), 0, "Hook trapped currency0 tokens");
        assertEq(currency1.balanceOf(address(hook)), 0, "Hook trapped currency1 tokens");
    }

    /// @notice Invariant 3: Rolling EWMA volatility is strictly bounded
    function invariant_VolatilityWithinUpperLimits() public view {
        (,, uint32 vol,,,,,) = hook.poolStates(poolId);
        assertLe(vol, VolatilityMath.MAX_VOLATILITY, "Volatility exceeded MAX_VOLATILITY score");
    }
}
