// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Computes CREATE2 salt that produces a contract address satisfying target hook flag bits
library HookMiner {
    /// @notice Find a salt that produces a hook address matching targetFlags
    /// @param deployer The address that will call CREATE2
    /// @param targetFlags Mask of required hook flags
    /// @param creationCode Creation bytecode of the hook contract
    /// @param constructorArgs ABI encoded constructor parameters
    /// @return hookAddress The calculated CREATE2 hook address
    /// @return salt The mined salt
    function find(address deployer, uint160 targetFlags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        for (uint256 i = 0; i < 200_000; i++) {
            bytes32 candidateSalt = bytes32(i);
            address predicted = computeAddress(deployer, candidateSalt, initCodeHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == targetFlags) {
                return (predicted, candidateSalt);
            }
        }
        revert("HookMiner: could not find salt");
    }

    /// @notice Computes CREATE2 address
    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
