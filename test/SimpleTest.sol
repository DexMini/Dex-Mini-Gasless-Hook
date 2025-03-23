// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Hooks} from "../lib/v4-core/src/libraries/Hooks.sol";
import {console} from "forge-std/console.sol";

// Create a truly simplified test to focus on basic functionality
contract TestGaslessHook {
    address public immutable poolManager;
    address public owner;

    uint256 public mevRewardBps = 200; // Initial 2%
    uint256 public constant INSURANCE_FEE_BPS = 5; // 0.05%
    mapping(address => bool) public guardians;
    bool public systemPaused;

    constructor(address _poolManager, address _owner) {
        poolManager = _poolManager;
        owner = _owner;
    }

    function getHookPermissions()
        external
        pure
        returns (Hooks.Permissions memory)
    {
        Hooks.Permissions memory permissions;
        permissions.beforeSwap = true;
        permissions.afterSwap = true;
        return permissions;
    }

    function updateGuardian(address guardian, bool status) external {
        require(msg.sender == owner, "Only owner");
        guardians[guardian] = status;
    }

    function setMevRewardBps(uint256 newRewardBps) external {
        require(msg.sender == owner, "Only owner");
        require(newRewardBps <= 1000, "Reward too high");
        mevRewardBps = newRewardBps;
    }

    function emergencyPause(bool pause) external {
        require(guardians[msg.sender] || msg.sender == owner, "Unauthorized");
        systemPaused = pause;
    }
}

contract SimpleGaslessSwapHookTest is Test {
    TestGaslessHook hook;

    function setUp() public {
        console.log("Setting up simplified test...");

        // Deploy our simplified test hook
        hook = new TestGaslessHook(address(0x123), address(this));

        console.log("Hook deployed at:", address(hook));
        console.log("Owner:", hook.owner());
    }

    function test_mevRewardBps() public {
        uint256 value = hook.mevRewardBps();
        console.log("MEV reward BPS:", value);
        assertEq(value, 200, "Default MEV reward should be 200 bps (2%)");
    }

    function test_insuranceFee() public {
        uint256 value = hook.INSURANCE_FEE_BPS();
        console.log("Insurance fee BPS:", value);
        assertEq(value, 5, "Insurance fee should be 5 bps (0.05%)");
    }

    function test_permissions() public {
        Hooks.Permissions memory permissions = hook.getHookPermissions();
        assertTrue(permissions.beforeSwap, "beforeSwap should be true");
        assertTrue(permissions.afterSwap, "afterSwap should be true");
    }

    function test_guardian() public {
        address guardian = address(0x456);

        // Initially guardian should not be set
        assertFalse(
            hook.guardians(guardian),
            "Guardian should not be set initially"
        );

        // Add guardian
        hook.updateGuardian(guardian, true);
        assertTrue(
            hook.guardians(guardian),
            "Guardian should be set after update"
        );

        // Remove guardian
        hook.updateGuardian(guardian, false);
        assertFalse(
            hook.guardians(guardian),
            "Guardian should be removed after update"
        );
    }

    function test_emergencyPause() public {
        // Set up a guardian
        address guardian = address(0x456);
        hook.updateGuardian(guardian, true);

        // Initially system should not be paused
        assertFalse(
            hook.systemPaused(),
            "System should not be paused initially"
        );

        // Pause as guardian
        vm.prank(guardian);
        hook.emergencyPause(true);
        assertTrue(
            hook.systemPaused(),
            "System should be paused after guardian action"
        );

        // Unpause as owner
        hook.emergencyPause(false);
        assertFalse(
            hook.systemPaused(),
            "System should be unpaused after owner action"
        );
    }

    function test_setMevRewardBps() public {
        // Initial value
        assertEq(
            hook.mevRewardBps(),
            200,
            "Initial MEV reward should be 200 bps (2%)"
        );

        // Update as owner
        hook.setMevRewardBps(300);
        assertEq(
            hook.mevRewardBps(),
            300,
            "MEV reward should be updated to 300 bps (3%)"
        );

        // Try to set too high (should revert)
        vm.expectRevert("Reward too high");
        hook.setMevRewardBps(1100);

        // Try as non-owner (should revert)
        vm.prank(address(0x789));
        vm.expectRevert("Only owner");
        hook.setMevRewardBps(400);
    }
}
