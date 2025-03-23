// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/**
 * @title MockERC20
 * @dev Implementation of the ERC20 standard token with permit functionality for testing.
 */
contract MockERC20 is ERC20, ERC20Permit {
    uint8 private _decimals;

    constructor(
        string memory name,
        string memory symbol,
        uint8 decimalsArg
    ) ERC20(name, symbol) ERC20Permit(name) {
        _decimals = decimalsArg;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) public {
        _burn(from, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
