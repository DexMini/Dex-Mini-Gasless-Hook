// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GaslessSwapHook} from "../src/GaslessSwapHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock interfaces for Uniswap
interface IPoolManager {
    struct ModifyLiquidityParams {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }
}

// Simplified mock for testing
contract MockPoolManager {
    function getProtocolFeesAccrued() external pure returns (uint256) {
        return 0;
    }
}

// Simple test to verify contract compiles and basic functionality
contract GaslessSwapHookSimpleTest is Test {
    GaslessSwapHook public hook;
    MockPoolManager public poolManager;
    MockERC20 public token;

    address public owner;
    address public guardian;
    address public user;

    function setUp() public {
        owner = address(this);
        guardian = makeAddr("guardian");
        user = makeAddr("user");

        poolManager = new MockPoolManager();
        hook = new GaslessSwapHook(IPoolManager(address(poolManager)), owner);

        token = new MockERC20("Test Token", "TEST", 18);
        token.mint(user, 1000 ether);
    }

    function testConstruction() public {
        // Test contract constants
        assertEq(
            hook.MAX_MEV_REWARD_BPS(),
            1000,
            "MAX_MEV_REWARD_BPS should be 1000"
        );
        assertEq(hook.INSURANCE_FEE_BPS(), 5, "INSURANCE_FEE_BPS should be 5");

        // Test initial values
        assertEq(hook.mevRewardBps(), 200, "mevRewardBps should be 200");
        assertEq(hook.systemPaused(), false, "System should not be paused");
    }

    function testGuardianManagement() public {
        // Set guardian
        hook.updateGuardian(guardian, true);
        assertTrue(hook.guardians(guardian), "Guardian should be set");

        // Guardian should be able to pause the system
        vm.prank(guardian);
        hook.emergencyPause(true);
        assertTrue(hook.systemPaused(), "System should be paused");

        // Guardian should be able to unpause
        vm.prank(guardian);
        hook.emergencyPause(false);
        assertFalse(hook.systemPaused(), "System should be unpaused");
    }

    function testMevRewardUpdates() public {
        uint256 newRewardBps = 500;

        // Queue reward update
        hook.setMevRewardBps(newRewardBps);
        assertEq(
            hook.pendingMevRewardBps(),
            newRewardBps,
            "Pending reward should be set"
        );

        // Time travel to bypass timelock
        vm.warp(block.timestamp + 2 days + 1);

        // Apply the update
        hook.applyMevRewardBps();
        assertEq(hook.mevRewardBps(), newRewardBps, "Reward should be updated");
    }

    function testRewardClaiming() public {
        // Add some pending rewards for user
        uint256 rewardAmount = 100 ether;
        vm.startPrank(owner);
        token.mint(address(hook), rewardAmount);
        vm.stopPrank();

        // Simulate setting pending rewards (normally done in distributeFunds)
        vm.store(
            address(hook),
            keccak256(
                abi.encode(
                    user,
                    keccak256(abi.encode(address(token), uint256(1)))
                )
            ),
            bytes32(rewardAmount)
        );

        // Check pending rewards
        assertEq(
            hook.pendingRewards(user, address(token)),
            rewardAmount,
            "Pending rewards should be set"
        );

        // Claim rewards
        uint256 userBalanceBefore = token.balanceOf(user);

        vm.prank(user);
        hook.claimRewards(address(token));

        uint256 userBalanceAfter = token.balanceOf(user);
        assertEq(
            userBalanceAfter - userBalanceBefore,
            rewardAmount,
            "User should receive reward"
        );
        assertEq(
            hook.pendingRewards(user, address(token)),
            0,
            "Pending rewards should be reset"
        );
    }

    function testInsuranceWithdrawal() public {
        // Add to insurance reserve
        uint256 insuranceAmount = 10 ether;
        vm.startPrank(owner);
        token.mint(address(hook), insuranceAmount);
        vm.stopPrank();

        // Simulate adding to insurance reserve
        vm.store(
            address(hook),
            keccak256(abi.encode(address(token), uint256(3))),
            bytes32(insuranceAmount)
        );

        // Check insurance reserve
        assertEq(
            hook.insuranceReserve(address(token)),
            insuranceAmount,
            "Insurance should be set"
        );

        // Withdraw insurance
        uint256 ownerBalanceBefore = token.balanceOf(owner);

        hook.withdrawInsurance(address(token), insuranceAmount / 2);

        uint256 ownerBalanceAfter = token.balanceOf(owner);
        assertEq(
            ownerBalanceAfter - ownerBalanceBefore,
            insuranceAmount / 2,
            "Owner should receive half of insurance"
        );
        assertEq(
            hook.insuranceReserve(address(token)),
            insuranceAmount / 2,
            "Half of insurance should remain"
        );
    }
}
