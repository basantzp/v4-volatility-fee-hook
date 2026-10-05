// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {VolatilityMath} from "./libraries/VolatilityMath.sol";

/// @title VolatilityFeeHook
/// @notice Uniswap v4 Hook that dynamically adjusts pool LP fees in response to realized tick volatility (Anti-LVR Protection)
/// @dev Implements afterInitialize, beforeSwap, and afterSwap hooks. Address must possess corresponding flag bits.
contract VolatilityFeeHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using Hooks for IHooks;

    /// @notice Thrown when caller is not the PoolManager
    error NotPoolManager();

    /// @notice Thrown when attempting to initialize a pool without dynamic fee flag
    error NotDynamicFeePool();

    /// @notice Thrown when fee parameters are invalid
    error InvalidFeeConfiguration();

    /// @notice Thrown for unimplemented hook methods
    error HookNotImplemented();

    /// @notice Emitted when a new pool is registered with volatility fee tracking
    event PoolVolatilityInitialized(PoolId indexed poolId, int24 initialTick, uint24 baseFee);

    /// @notice Emitted when volatility and dynamic fee are updated after a swap
    event VolatilityUpdated(PoolId indexed poolId, uint32 newVolatility, uint24 dynamicFee, int24 newTick);

    /// @notice Emitted when fee parameters are updated for a pool
    event FeeConfigUpdated(PoolId indexed poolId, uint24 baseFee, uint24 minFee, uint24 maxFee);

    /// @notice Packed storage struct for tracking pool volatility and fee parameters (fits in 1 slot: 27 bytes)
    struct VolatilityState {
        int24 lastTick; // 3 bytes: Last observed pool tick
        uint40 lastTimestamp; // 5 bytes: Timestamp of last observation
        uint32 volatility; // 4 bytes: Current rolling EWMA volatility score
        uint24 baseFee; // 3 bytes: Baseline swap fee (hundredths of a bip)
        uint24 minFee; // 3 bytes: Minimum fee floor
        uint24 maxFee; // 3 bytes: Maximum fee cap
        uint16 feeSensitivity; // 2 bytes: Sensitivity multiplier
        uint32 halfLife; // 4 bytes: Volatility decay half-life in seconds
    }

    /// @notice Reference to the canonical Uniswap v4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice Volatility state mapped by pool ID
    mapping(PoolId => VolatilityState) public poolStates;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    /// @notice Returns the required Uniswap v4 hook permissions
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert NotDynamicFeePool();

        PoolId poolId = key.toId();

        // Default fee configuration: 0.30% base, 0.05% min, 5.00% max, 60s half-life
        poolStates[poolId] = VolatilityState({
            lastTick: tick,
            lastTimestamp: uint40(block.timestamp),
            volatility: 0,
            baseFee: 3000,
            minFee: 500,
            maxFee: 50000,
            feeSensitivity: 100,
            halfLife: 60
        });

        emit PoolVolatilityInitialized(poolId, tick, 3000);
        return IHooks.afterInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        VolatilityState memory state = poolStates[poolId];

        uint32 timeElapsed = block.timestamp > state.lastTimestamp ? uint32(block.timestamp - state.lastTimestamp) : 0;

        uint32 decayedVol = VolatilityMath.decayVolatility(state.volatility, timeElapsed, state.halfLife);

        uint24 dynamicFee = VolatilityMath.calculateDynamicFee(
            decayedVol, state.baseFee, state.minFee, state.maxFee, state.feeSensitivity
        );

        // Return selector, zero delta, and fee with override flag
        return
            (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, dynamicFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        VolatilityState storage state = poolStates[poolId];

        (, int24 currentTick,,) = poolManager.getSlot0(poolId);

        uint32 timeElapsed = block.timestamp > state.lastTimestamp ? uint32(block.timestamp - state.lastTimestamp) : 0;

        uint24 tickDelta = VolatilityMath.absTickDelta(currentTick, state.lastTick);

        uint32 newVolatility = VolatilityMath.computeUpdatedVolatility(
            state.volatility,
            timeElapsed,
            tickDelta,
            state.halfLife,
            10 // Weight factor per tick displacement
        );

        state.volatility = newVolatility;
        state.lastTick = currentTick;
        state.lastTimestamp = uint40(block.timestamp);

        uint24 dynamicFee = VolatilityMath.calculateDynamicFee(
            newVolatility, state.baseFee, state.minFee, state.maxFee, state.feeSensitivity
        );

        emit VolatilityUpdated(poolId, newVolatility, dynamicFee, currentTick);
        return (IHooks.afterSwap.selector, 0);
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @notice Read current dynamic fee for a pool without executing a swap
    /// @param poolId Identifier of the pool
    /// @return currentFee Dynamic fee that would be applied currently
    function getEstimatedFee(PoolId poolId) external view returns (uint24 currentFee) {
        VolatilityState memory state = poolStates[poolId];
        uint32 timeElapsed = block.timestamp > state.lastTimestamp ? uint32(block.timestamp - state.lastTimestamp) : 0;
        uint32 decayedVol = VolatilityMath.decayVolatility(state.volatility, timeElapsed, state.halfLife);
        return
            VolatilityMath.calculateDynamicFee(
                decayedVol, state.baseFee, state.minFee, state.maxFee, state.feeSensitivity
            );
    }
}
