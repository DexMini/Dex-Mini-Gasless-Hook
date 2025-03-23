// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {GaslessSwapHook} from "../src/GaslessSwapHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

contract GaslessSwapHookTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Test setup variables
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");
    address public guardian = makeAddr("guardian");
    uint256 public alicePrivateKey = 0x1;
    uint256 public bobPrivateKey = 0x2;
    uint256 public charliePrivateKey = 0x3;

    // Uniswap V4 contracts
    PoolManager public poolManager;
    PoolSwapTest public swapRouter;
    GaslessSwapHook public gaslessHook;

    // Token contracts
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    // Pool constants
    uint24 constant FEE = 3000; // 0.3%
    int24 constant TICK_SPACING = 60;
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e18;

    // Pool details
    PoolKey poolKey;
    PoolId poolId;

    // EIP-712 constants
    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(address trader,PoolKey poolKey,address tokenIn,address tokenOut,uint256 amount,uint256 minAmountOut,uint256 deadline,uint256 nonce,bool exactInput)PoolKey(Currency currency0,Currency currency1,uint24 fee,int24 tickSpacing,IHooks hooks)"
        );

    bytes32 public constant POOLKEY_TYPEHASH =
        keccak256(
            "PoolKey(Currency currency0,Currency currency1,uint24 fee,int24 tickSpacing,IHooks hooks)"
        );

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("Token A", "TKNA", 18);
        tokenB = new MockERC20("Token B", "TKNB", 18);

        // Ensure tokenA address is less than tokenB for correct pool ordering
        if (address(tokenA) > address(tokenB)) {
            (tokenA, tokenB) = (tokenB, tokenA);
        }

        // Deploy PoolManager
        poolManager = new PoolManager(address(500_000));

        // Deploy SwapRouter for testing
        swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));

        // Mine a hook address
        (address payable hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            type(GaslessSwapHook).creationCode,
            abi.encode(address(poolManager), address(this)),
            uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
        );

        // Deploy the hook to the computed address
        vm.record();
        address deployed = address(
            new GaslessSwapHook{salt: salt}(
                IPoolManager(address(poolManager)),
                address(this)
            )
        );
        require(deployed == hookAddress, "Hook deployment failed");
        gaslessHook = GaslessSwapHook(hookAddress);

        // Create the pool key
        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });

        poolId = poolKey.toId();

        // Mint tokens to test addresses
        tokenA.mint(alice, INITIAL_LIQUIDITY);
        tokenB.mint(alice, INITIAL_LIQUIDITY);
        tokenA.mint(bob, INITIAL_LIQUIDITY);
        tokenB.mint(bob, INITIAL_LIQUIDITY);

        // Initialize pool
        vm.startPrank(alice);
        tokenA.approve(address(poolManager), type(uint256).max);
        tokenB.approve(address(poolManager), type(uint256).max);

        uint160 sqrtPriceX96 = uint160(1 << 96); // 1.0 as Q64.96
        poolManager.initialize(poolKey, sqrtPriceX96, "");

        // Add initial liquidity
        int256 liquidityDelta = 1_000_000e18;
        poolManager.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -TICK_SPACING,
                tickUpper: TICK_SPACING,
                liquidityDelta: int256(liquidityDelta)
            }),
            ""
        );
        vm.stopPrank();

        // Set up guardian
        gaslessHook.updateGuardian(guardian, true);
    }

    // The following tests will be implemented
    function testInitialSetup() public {
        // Test that the hook has the correct permissions
        assertEq(
            uint256(gaslessHook.getHookPermissions()),
            uint256(Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG)
        );

        // Test that pool was initialized correctly
        (bool initialized, , , ) = poolManager.getSlot0(poolId);
        assertTrue(initialized);
    }

    function testGaslessSwapExecution() public {
        uint256 amount = 1e18;
        uint256 minAmountOut = 0.98e18; // 2% slippage
        uint256 deadline = block.timestamp + 3600;

        // Create and sign an order
        bytes memory orderSignature = _createAndSignOrder(
            alicePrivateKey,
            address(tokenA),
            address(tokenB),
            amount,
            minAmountOut,
            deadline,
            0, // nonce
            true // exactInput
        );

        // Initial balances for verification later
        uint256 aliceTokenABefore = tokenA.balanceOf(alice);
        uint256 aliceTokenBBefore = tokenB.balanceOf(alice);

        // Approve the hook to spend Alice's tokens
        vm.startPrank(alice);
        tokenA.approve(address(gaslessHook), amount);
        vm.stopPrank();

        // Setup bob as the MEV searcher/relayer
        vm.startPrank(bob);

        // Create the order struct
        GaslessSwapHook.Order memory order = GaslessSwapHook.Order({
            trader: alice,
            poolKey: poolKey,
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amount: amount,
            minAmountOut: minAmountOut,
            deadline: deadline,
            nonce: 0,
            exactInput: true,
            orderSignature: orderSignature,
            permitSignature: new bytes(0) // No permit in this test
        });

        // Encode the order for the callback
        bytes memory callbackData = abi.encode(order);

        // Execute the swap through the hook
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true, // tokenA to tokenB
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0 // No price limit
        });

        // First call beforeSwap manually to simulate the hook
        gaslessHook.beforeSwap(
            address(gaslessHook),
            poolKey,
            params,
            callbackData
        );

        // Execute the swap through PoolManager
        BalanceDelta delta = poolManager.swap(poolKey, params, callbackData);

        // Call afterSwap manually to distribute funds
        gaslessHook.afterSwap(
            address(gaslessHook),
            poolKey,
            params,
            delta,
            callbackData
        );

        vm.stopPrank();

        // Verify balances after swap
        uint256 aliceTokenAAfter = tokenA.balanceOf(alice);
        uint256 aliceTokenBAfter = tokenB.balanceOf(alice);

        // Calculate the actual token amount received
        uint256 tokenASpent = aliceTokenABefore - aliceTokenAAfter;
        uint256 tokenBReceived = aliceTokenBAfter - aliceTokenBBefore;

        // Verify token A spent
        assertEq(
            tokenASpent,
            amount,
            "Alice should have spent the correct amount of token A"
        );

        // Verify minimum amount out requirement
        assertTrue(
            tokenBReceived >= minAmountOut,
            "Alice should have received at least the minimum amount"
        );

        // Verify that MEV reward was calculated correctly
        uint256 expectedInsuranceFee = (tokenBReceived *
            gaslessHook.INSURANCE_FEE_BPS()) / 10000;
        uint256 expectedMevReward = ((tokenBReceived - expectedInsuranceFee) *
            gaslessHook.mevRewardBps()) / 10000;

        // Check insurance reserve
        assertEq(
            gaslessHook.insuranceReserve(address(tokenB)),
            expectedInsuranceFee,
            "Insurance reserve should be increased correctly"
        );

        // Check pending rewards
        assertEq(
            gaslessHook.pendingRewards(alice, address(tokenB)),
            expectedMevReward,
            "Pending rewards should be calculated correctly"
        );

        // Check that Alice can claim her rewards
        vm.startPrank(alice);

        // Get initial token balance before claiming rewards
        uint256 balanceBeforeClaim = tokenB.balanceOf(alice);

        // Claim rewards
        gaslessHook.claimRewards(address(tokenB));

        // Verify that rewards were transferred
        uint256 balanceAfterClaim = tokenB.balanceOf(alice);
        assertEq(
            balanceAfterClaim - balanceBeforeClaim,
            expectedMevReward,
            "Alice should have received her rewards"
        );

        // Verify that pending rewards are reset
        assertEq(
            gaslessHook.pendingRewards(alice, address(tokenB)),
            0,
            "Pending rewards should be reset to zero"
        );

        vm.stopPrank();
    }

    function _createAndSignOrder(
        uint256 privateKey,
        address tokenIn,
        address tokenOut,
        uint256 amount,
        uint256 minAmountOut,
        uint256 deadline,
        uint256 nonce,
        bool exactInput
    ) internal view returns (bytes memory) {
        // Prepare the domain separator data
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("GaslessSwapHook")),
                keccak256(bytes("1")),
                block.chainid,
                address(gaslessHook)
            )
        );

        // Compute the hash of the poolKey
        bytes32 poolKeyHash = keccak256(
            abi.encode(
                POOLKEY_TYPEHASH,
                poolKey.currency0,
                poolKey.currency1,
                poolKey.fee,
                poolKey.tickSpacing,
                poolKey.hooks
            )
        );

        // Compute the hash of the order data
        bytes32 orderHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                vm.addr(privateKey), // trader address
                poolKeyHash,
                tokenIn,
                tokenOut,
                amount,
                minAmountOut,
                deadline,
                nonce,
                exactInput
            )
        );

        // Compute the digest
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domainSeparator, orderHash)
        );

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function testOrderExpiryAndNonce() public {
        uint256 amount = 1e18;
        uint256 minAmountOut = 0.98e18;
        uint256 deadline = block.timestamp + 3600;

        // Create and sign an order
        bytes memory orderSignature = _createAndSignOrder(
            alicePrivateKey,
            address(tokenA),
            address(tokenB),
            amount,
            minAmountOut,
            deadline,
            0, // nonce
            true // exactInput
        );

        // Approve tokens
        vm.startPrank(alice);
        tokenA.approve(address(gaslessHook), amount);
        vm.stopPrank();

        // Create the order
        GaslessSwapHook.Order memory order = GaslessSwapHook.Order({
            trader: alice,
            poolKey: poolKey,
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amount: amount,
            minAmountOut: minAmountOut,
            deadline: deadline,
            nonce: 0,
            exactInput: true,
            orderSignature: orderSignature,
            permitSignature: new bytes(0)
        });

        // Setup swap parameters
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0
        });

        bytes memory callbackData = abi.encode(order);

        // Test 1: First execution should succeed
        vm.startPrank(bob);
        gaslessHook.beforeSwap(
            address(gaslessHook),
            poolKey,
            params,
            callbackData
        );
        BalanceDelta delta = poolManager.swap(poolKey, params, callbackData);
        gaslessHook.afterSwap(
            address(gaslessHook),
            poolKey,
            params,
            delta,
            callbackData
        );
        vm.stopPrank();

        // Test 2: Nonce replay protection
        // Try to execute the same order again, it should fail due to nonce
        vm.startPrank(charlie);
        vm.expectRevert("Invalid nonce");
        gaslessHook.beforeSwap(
            address(gaslessHook),
            poolKey,
            params,
            callbackData
        );
        vm.stopPrank();

        // Test 3: Order expiry
        // Create a new order with expired deadline
        bytes memory expiredSignature = _createAndSignOrder(
            alicePrivateKey,
            address(tokenA),
            address(tokenB),
            amount,
            minAmountOut,
            block.timestamp - 1, // already expired
            1, // new nonce
            true
        );

        GaslessSwapHook.Order memory expiredOrder = GaslessSwapHook.Order({
            trader: alice,
            poolKey: poolKey,
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amount: amount,
            minAmountOut: minAmountOut,
            deadline: block.timestamp - 1, // expired
            nonce: 1,
            exactInput: true,
            orderSignature: expiredSignature,
            permitSignature: new bytes(0)
        });

        bytes memory expiredCallbackData = abi.encode(expiredOrder);

        // Should fail due to expiration
        vm.startPrank(bob);
        vm.expectRevert("Order expired");
        gaslessHook.beforeSwap(
            address(gaslessHook),
            poolKey,
            params,
            expiredCallbackData
        );
        vm.stopPrank();
    }

    function testAdminFunctions() public {
        // Test changing the MEV reward rate
        uint256 newMevRewardBps = 500; // 5%

        // Only owner should be able to change parameters
        vm.startPrank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        gaslessHook.setMevRewardBps(newMevRewardBps);
        vm.stopPrank();

        // Owner changes the MEV reward rate
        vm.startPrank(address(this)); // Test contract is the owner
        gaslessHook.setMevRewardBps(newMevRewardBps);
        vm.stopPrank();

        // Check that the change is queued
        assertEq(
            gaslessHook.pendingMevRewardBps(),
            newMevRewardBps,
            "MEV reward rate should be queued"
        );
        assertTrue(
            gaslessHook.pendingMevRewardBpsTime() > block.timestamp,
            "Timelock should be active"
        );

        // Fast forward time to bypass timelock
        vm.warp(block.timestamp + 2 days + 1 seconds);

        // Apply the change
        vm.startPrank(address(this));
        gaslessHook.applyMevRewardBps();
        vm.stopPrank();

        // Verify the change was applied
        assertEq(
            gaslessHook.mevRewardBps(),
            newMevRewardBps,
            "MEV reward rate should be updated"
        );

        // Test MEV reward distribution with new rate
        uint256 amount = 1e18;
        uint256 minAmountOut = 0.98e18;
        uint256 deadline = block.timestamp + 3600;

        // Create and sign an order with Alice
        bytes memory orderSignature = _createAndSignOrder(
            alicePrivateKey,
            address(tokenA),
            address(tokenB),
            amount,
            minAmountOut,
            deadline,
            0, // nonce
            true // exactInput
        );

        // Approve tokens
        vm.startPrank(alice);
        tokenA.approve(address(gaslessHook), amount);
        vm.stopPrank();

        // Create and execute the order
        GaslessSwapHook.Order memory order = GaslessSwapHook.Order({
            trader: alice,
            poolKey: poolKey,
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amount: amount,
            minAmountOut: minAmountOut,
            deadline: deadline,
            nonce: 0,
            exactInput: true,
            orderSignature: orderSignature,
            permitSignature: new bytes(0)
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0
        });

        bytes memory callbackData = abi.encode(order);

        // Initial balances
        uint256 aliceTokenBBefore = tokenB.balanceOf(alice);

        // Execute the swap
        vm.startPrank(bob);
        gaslessHook.beforeSwap(
            address(gaslessHook),
            poolKey,
            params,
            callbackData
        );
        BalanceDelta delta = poolManager.swap(poolKey, params, callbackData);
        gaslessHook.afterSwap(
            address(gaslessHook),
            poolKey,
            params,
            delta,
            callbackData
        );
        vm.stopPrank();

        // Calculate the output amount
        uint256 aliceTokenBAfter = tokenB.balanceOf(alice);
        uint256 tokenBReceived = aliceTokenBAfter - aliceTokenBBefore;

        // Verify MEV reward with new rate
        uint256 expectedInsuranceFee = (tokenBReceived *
            gaslessHook.INSURANCE_FEE_BPS()) / 10000;
        uint256 expectedMevReward = ((tokenBReceived - expectedInsuranceFee) *
            newMevRewardBps) / 10000;

        // Check pending rewards
        assertEq(
            gaslessHook.pendingRewards(alice, address(tokenB)),
            expectedMevReward,
            "Pending rewards should use new rate"
        );
    }

    function testEmergencyFunctions() public {
        // Test emergency pause
        vm.startPrank(bob);
        vm.expectRevert("Unauthorized");
        gaslessHook.emergencyPause(true);
        vm.stopPrank();

        // Guardian should be able to pause
        vm.startPrank(guardian);
        gaslessHook.emergencyPause(true);
        vm.stopPrank();

        // Verify system is paused
        assertTrue(gaslessHook.systemPaused(), "System should be paused");

        // Attempting a swap while paused should fail
        uint256 amount = 1e18;
        uint256 minAmountOut = 0.98e18;
        uint256 deadline = block.timestamp + 3600;

        bytes memory orderSignature = _createAndSignOrder(
            alicePrivateKey,
            address(tokenA),
            address(tokenB),
            amount,
            minAmountOut,
            deadline,
            0, // nonce
            true // exactInput
        );

        GaslessSwapHook.Order memory order = GaslessSwapHook.Order({
            trader: alice,
            poolKey: poolKey,
            tokenIn: address(tokenA),
            tokenOut: address(tokenB),
            amount: amount,
            minAmountOut: minAmountOut,
            deadline: deadline,
            nonce: 0,
            exactInput: true,
            orderSignature: orderSignature,
            permitSignature: new bytes(0)
        });

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: int256(amount),
            sqrtPriceLimitX96: 0
        });

        bytes memory callbackData = abi.encode(order);

        // Attempt swap while paused
        vm.startPrank(bob);
        vm.expectRevert("System paused");
        gaslessHook.beforeSwap(
            address(gaslessHook),
            poolKey,
            params,
            callbackData
        );
        vm.stopPrank();

        // Unpause the system
        vm.startPrank(guardian);
        gaslessHook.emergencyPause(false);
        vm.stopPrank();

        // Verify system is unpaused
        assertFalse(gaslessHook.systemPaused(), "System should be unpaused");
    }

    // Additional tests to be implemented:
    // 1. testPoolSwapWithHook() - Test regular swaps going through the pool with hook
    // 2. testOrderExpiryAndNonce() - Test order expiry and nonce validation
    // 3. testInvalidSignatures() - Test signature validation
    // 4. testMEVRewardDistribution() - Test the reward calculation and distribution
    // 5. testInsuranceFundContribution() - Test contributions to insurance fund
    // 6. testRewardClaiming() - Test claiming of rewards by traders
    // 7. testAdminFunctions() - Test admin functions like parameter changes
    // 8. testEmergencyFunctions() - Test emergency pause and withdrawals
    // 9. testLiquidityProviderPerformance() - Test impact on liquidity provider returns
}
