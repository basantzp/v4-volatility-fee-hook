# ⚡ Uniswap v4 Volatility Fee Hook Telemetry

> **Repository**: [`basantzp/v4-volatility-fee-hook`](https://github.com/basantzp/v4-volatility-fee-hook)  
> **Compiler**: Solc `0.8.26` (Cancun EVM)  
> **Last Verification Run**: `2026-10-27 05:55:21 +0545`  
> **Dynamic Fee Status**: 🟢 **Operational & Bounds Verified**  
> **Author**: `basantzp <basantpok90@gmail.com>`

---

## 🧪 Verified Hook Properties
- **EWMA Volatility Decay**: Monotonically decays towards 0 over elapsed half-lives.
- **Dynamic Fee Strict Bounds**: Fee strictly clamped between `minFee` and `maxFee` under extreme tick displacement.
- **Admin Configuration**: Runtime dynamic reconfiguration of fee floors, caps, and sensitivities verified.

### Verification Summary
```text
[PASS] testFuzz_AbsTickDelta(int24,int24) (runs: 256, μ: 1171, ~: 1172)
[PASS] testFuzz_CalculateDynamicFee_StrictBounds(uint32,uint16) (runs: 256, μ: 1073, ~: 1070)
[PASS] testFuzz_VolatilityDecay_Monotonic(uint32,uint32) (runs: 256, μ: 1026, ~: 919)
[PASS] test_FeeConfig_UpdateAndValidation() (gas: 75220)
[PASS] test_InitialPoolState() (gas: 11344)
[PASS] test_InitialSwapAppliesBaseFee() (gas: 197931)
[PASS] test_RevertIf_NotDynamicFeePool() (gas: 73216)
[PASS] test_RevertIf_NotPoolManager() (gas: 83050)
[PASS] test_TimeDecay_ReducesVolatilityToFloor() (gas: 188148)
Suite result: ok. 9 passed; 0 failed; 0 skipped; finished in 57.29ms (19.65ms CPU time)
```
