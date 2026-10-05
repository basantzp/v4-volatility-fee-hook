// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title VolatilityMath
/// @notice Pure mathematical library for calculating exponentially decayed tick volatility and dynamic LP fees
library VolatilityMath {
    /// @dev Half-life for volatility decay in seconds (e.g., 60 seconds)
    uint32 internal constant DEFAULT_HALF_LIFE = 60;

    /// @dev Maximum volatility score to prevent integer overflows
    uint32 internal constant MAX_VOLATILITY = 1_000_000;

    /// @notice Calculates absolute difference between two ticks
    /// @param tickA First tick
    /// @param tickB Second tick
    /// @return delta Absolute tick difference
    function absTickDelta(int24 tickA, int24 tickB) internal pure returns (uint24 delta) {
        int256 diff = int256(tickA) - int256(tickB);
        return diff >= 0 ? uint24(uint256(diff)) : uint24(uint256(-diff));
    }

    /// @notice Applies time-based exponential decay to volatility score
    /// @param currentVol Previous volatility score
    /// @param timeElapsed Number of seconds elapsed since last update
    /// @param halfLife Duration in seconds for volatility to halve
    /// @return decayedVol Decayed volatility score
    function decayVolatility(uint32 currentVol, uint32 timeElapsed, uint32 halfLife)
        internal
        pure
        returns (uint32 decayedVol)
    {
        if (currentVol == 0 || timeElapsed == 0) return currentVol;
        if (halfLife == 0) halfLife = DEFAULT_HALF_LIFE;

        uint32 halfLifePeriods = timeElapsed / halfLife;
        if (halfLifePeriods >= 30) {
            return 0;
        }

        // Halve for each full half-life period
        decayedVol = currentVol >> halfLifePeriods;

        // Linear interpolation for remainder of current period
        uint32 remainder = timeElapsed % halfLife;
        if (remainder > 0 && decayedVol > 0) {
            uint32 reduction = uint32((uint256(decayedVol) * remainder) / (uint256(halfLife) * 2));
            decayedVol = decayedVol > reduction ? decayedVol - reduction : 0;
        }
    }

    /// @notice Computes updated volatility after observing tick movement
    /// @param priorVol Previous volatility score
    /// @param timeElapsed Seconds since last swap
    /// @param tickDelta Absolute tick movement
    /// @param halfLife Volatility decay half-life
    /// @param weight Weight given to new tick delta
    /// @return updatedVol Updated volatility metric
    function computeUpdatedVolatility(
        uint32 priorVol,
        uint32 timeElapsed,
        uint24 tickDelta,
        uint32 halfLife,
        uint16 weight
    ) internal pure returns (uint32 updatedVol) {
        uint32 decayed = decayVolatility(priorVol, timeElapsed, halfLife);
        uint256 added = uint256(tickDelta) * uint256(weight);
        uint256 total = uint256(decayed) + added;

        if (total > MAX_VOLATILITY) {
            return MAX_VOLATILITY;
        }
        return uint32(total);
    }

    /// @notice Calculates dynamic fee based on volatility and fee bounds
    /// @param volatility Observed volatility score
    /// @param baseFee Baseline fee in hundredths of a bip (e.g., 3000 = 0.3%)
    /// @param minFee Lower bound fee
    /// @param maxFee Upper bound fee (must be <= 1,000,000)
    /// @param feeSensitivity Multiplier converting volatility to fee bips
    /// @return fee Resulting LP fee clamped within [minFee, maxFee]
    function calculateDynamicFee(uint32 volatility, uint24 baseFee, uint24 minFee, uint24 maxFee, uint16 feeSensitivity)
        internal
        pure
        returns (uint24 fee)
    {
        uint256 feeAddition = (uint256(volatility) * uint256(feeSensitivity)) / 1000;
        uint256 calculatedFee = uint256(baseFee) + feeAddition;

        if (calculatedFee < minFee) {
            fee = minFee;
        } else if (calculatedFee > maxFee) {
            fee = maxFee;
        } else {
            fee = uint24(calculatedFee);
        }
    }
}
