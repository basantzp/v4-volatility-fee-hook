// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {VolatilityFeeHook} from "../src/VolatilityFeeHook.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

contract DeployVolatilityFeeHookScript is Script {
    uint160 constant TARGET_FLAGS = Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG;

    function run() external {
        address poolManagerAddress =
            vm.envOr("POOL_MANAGER_ADDRESS", address(0x000000000004444c5dc75cB358380D2e3dE08A90));
        IPoolManager poolManager = IPoolManager(poolManagerAddress);

        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        bytes memory constructorArgs = abi.encode(poolManager);

        console.log("Mining CREATE2 salt for deployer:", deployer);
        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployer, TARGET_FLAGS, type(VolatilityFeeHook).creationCode, constructorArgs);

        console.log("Mined Hook Address:", hookAddress);
        console.logBytes32(salt);

        vm.startBroadcast(deployerPrivateKey);
        VolatilityFeeHook hook = new VolatilityFeeHook{salt: salt}(poolManager);
        require(address(hook) == hookAddress, "Address mismatch");
        vm.stopBroadcast();

        console.log("VolatilityFeeHook deployed successfully at:", address(hook));
    }
}
