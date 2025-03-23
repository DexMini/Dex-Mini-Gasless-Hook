// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Hooks} from "../../lib/v4-core/src/libraries/Hooks.sol";

/// @title HookMiner
/// @notice Utility for mining hook addresses for Uniswap V4
library HookMiner {
    /// @notice Find an address that has the desired hooks flag set when cast to a hooks interface
    /// @param deployer The address that will deploy the hook
    /// @param hookFlag The desired hook flag
    /// @return hook The address of the hook
    function find(
        address deployer,
        uint160 hookFlag
    ) internal pure returns (address hook) {
        // Start with a random nonce that fulfills the CREATE2 constraint of having 0s in the first byte
        uint256 salt = 0x1;

        while (true) {
            hook = computeAddress(deployer, salt);
            if (uint160(hook) & hookFlag == hookFlag) {
                break;
            }
            salt++;
        }

        return hook;
    }

    /// @notice Compute the address of a contract deployed via CREATE2 with given parameters
    /// @param deployer The address that will deploy the hook
    /// @param salt The salt for the CREATE2 deployment
    /// @return hook The address of the deployed contract
    function computeAddress(
        address deployer,
        uint256 salt
    ) internal pure returns (address hook) {
        // The CREATE2 prefix from EIP-1014
        bytes memory prefix = hex"ff";

        // The contract code to be deployed
        bytes memory initCode = hex"6080604052";

        // The formula is: keccak256(0xff + deployer + salt + keccak256(init_code))[12:]
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 hash = keccak256(
            abi.encodePacked(prefix, deployer, salt, initCodeHash)
        );

        // The result is the last 20 bytes of the hash (the address)
        return address(uint160(uint256(hash)));
    }
}
