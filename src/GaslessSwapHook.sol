// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title GaslessSwapHook
 * @notice A Uniswap V4 Hook enabling gasless swaps with MEV profit sharing
 * @dev This contract implements:
 * - EIP-712 for order signing
 * - ERC-2612 for gasless token approvals
 * - MEV reward distribution system
 * - Insurance mechanism for trade protection
 *
 * Architecture Overview:
 * 1. Trader signs an order (off-chain)
 * 2. MEV searcher executes the order through this hook
 * 3. Hook validates signatures and executes swap
 * 4. Profits are distributed between trader, searcher, and insurance fund
 */

/*////////////////////////////////////////////////////////////////////////////
//                                                                          //
//     ██████╗ ███████╗██╗  ██╗    ███╗   ███╗██╗███╗   ██╗██╗           //
//     ██╔══██╗██╔════╝╚██╗██╔╝    ████╗ ████║██║████╗  ██║██║           //
//     ██║  ██║█████╗   ╚███╔╝     ██╔████╔██║██║██╔██╗ ██║██║           //
//     ██║  ██║██╔══╝   ██╔██╗     ██║╚██╔╝██║██║██║╚██╗██║██║           //
//     ██████╔╝███████╗██╔╝ ██╗    ██║ ╚═╝ ██║██║██║ ╚████║██║           //
//     ╚═════╝ ╚══════╝╚═╝  ╚═╝    ╚═╝     ╚═╝╚═╝╚═╝  ╚═══╝╚═╝           //
//                                                                          //
//     Uniswap V4 Hook - Version 1.0                                       //
//     https://dexmini.com                                                 //
//                                                                          //
////////////////////////////////////////////////////////////////////////////*/

import {BaseHook} from "@uniswap/v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract GaslessSwapHook is BaseHook, EIP712, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using ECDSA for bytes32;

    // --- Constants ---
    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(address trader,PoolKey poolKey,address tokenIn,address tokenOut,uint256 amount,uint256 minAmountOut,uint256 deadline,uint256 nonce,bool exactInput)PoolKey(Currency currency0,Currency currency1,uint24 fee,int24 tickSpacing,IHooks hooks)"
        );

    bytes32 public constant POOLKEY_TYPEHASH =
        keccak256(
            "PoolKey(Currency currency0,Currency currency1,uint24 fee,int24 tickSpacing,IHooks hooks)"
        );

    uint256 public constant MAX_MEV_REWARD_BPS = 1000; // 10%
    uint256 public constant INSURANCE_FEE_BPS = 5; // 0.05%
    uint256 private constant TIMELOCK_DELAY = 2 days;

    // --- State Variables ---
    uint256 public mevRewardBps = 200; // Initial 2%
    uint256 public pendingMevRewardBps;
    uint256 public pendingMevRewardBpsTime;

    mapping(address => uint256) public orderNonces;
    mapping(address => mapping(address => uint256)) public pendingRewards;
    mapping(address => uint256) public insuranceReserve;
    mapping(address => bool) public guardians;
    bool public systemPaused;

    // --- Events ---
    event GaslessSwapExecuted(
        address indexed trader,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 reward
    );

    event RewardsClaimed(
        address indexed trader,
        address indexed token,
        uint256 amount
    );
    event ParameterChangeQueued(
        string indexed paramName,
        uint256 newValue,
        uint256 activationTime
    );
    event ParameterChangeApplied(string indexed paramName, uint256 newValue);
    event GuardianUpdated(address indexed guardian, bool status);

    // --- Structs ---
    struct Order {
        address trader;
        PoolKey poolKey;
        address tokenIn;
        address tokenOut;
        uint256 amount;
        uint256 minAmountOut;
        uint256 deadline;
        uint256 nonce;
        bool exactInput;
        bytes orderSignature;
        bytes permitSignature;
    }

    // --- Modifiers ---
    modifier whenNotPaused() {
        require(!systemPaused, "System paused");
        _;
    }

    constructor(
        IPoolManager _poolManager,
        address initialOwner
    )
        BaseHook(_poolManager)
        EIP712("GaslessSwapHook", "1")
        Ownable(initialOwner)
    {}

    // --- Hook Implementation ---
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
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

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata callbackData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(!systemPaused, "System paused");
        require(sender == address(this), "Unauthorized");

        Order memory order = abi.decode(callbackData, (Order));
        validateOrder(order, key);
        processPreSwap(order);

        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta delta,
        bytes calldata callbackData
    ) external override nonReentrant whenNotPaused returns (bytes4, int128) {
        Order memory order = abi.decode(callbackData, (Order));
        uint256 actualAmount = calculateSwapAmount(order, delta);

        distributeFunds(order, actualAmount);
        return (BaseHook.afterSwap.selector, 0);
    }

    // --- Core Logic ---
    function calculateSwapAmount(
        Order memory order,
        BalanceDelta delta
    ) internal pure returns (uint256) {
        bool isTokenInCurrency0 = order.tokenIn ==
            Currency.unwrap(order.poolKey.currency0);
        int128 relevantDelta;
        bool isOutputNegative;

        if (order.exactInput) {
            relevantDelta = isTokenInCurrency0
                ? delta.amount1()
                : delta.amount0();
            isOutputNegative = true;
        } else {
            relevantDelta = isTokenInCurrency0
                ? delta.amount0()
                : delta.amount1();
            isOutputNegative = false;
        }

        require(
            (isOutputNegative && relevantDelta < 0) ||
                (!isOutputNegative && relevantDelta > 0),
            "Invalid delta direction"
        );

        return
            isOutputNegative
                ? uint256(uint128(-relevantDelta))
                : uint256(uint128(relevantDelta));
    }

    function distributeFunds(
        Order memory order,
        uint256 actualAmount
    ) internal {
        require(actualAmount >= order.minAmountOut, "Slippage exceeded");

        uint256 insuranceFee = (actualAmount * INSURANCE_FEE_BPS) / 10000;
        uint256 reward = calculateMevReward(order, actualAmount - insuranceFee);
        uint256 traderAmount = actualAmount - insuranceFee - reward;

        insuranceReserve[order.tokenOut] += insuranceFee;
        pendingRewards[order.trader][order.tokenOut] += reward;

        IERC20(order.tokenOut).safeTransfer(order.trader, traderAmount);
        emit GaslessSwapExecuted(
            order.trader,
            order.tokenIn,
            order.tokenOut,
            order.amount,
            actualAmount,
            reward
        );
    }

    // Calculate MEV reward based on the current reward percentage
    function calculateMevReward(
        Order memory order,
        uint256 amount
    ) internal view returns (uint256) {
        return (amount * mevRewardBps) / 10000;
    }

    // --- Order Validation ---
    function validateOrder(Order memory order, PoolKey calldata key) internal {
        require(order.deadline >= block.timestamp, "Order expired");
        require(order.nonce == orderNonces[order.trader]++, "Invalid nonce");
        require(
            keccak256(abi.encode(key)) == keccak256(abi.encode(order.poolKey)),
            "Pool mismatch"
        );

        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    ORDER_TYPEHASH,
                    order.trader,
                    hashPoolKey(order.poolKey),
                    order.tokenIn,
                    order.tokenOut,
                    order.amount,
                    order.minAmountOut,
                    order.deadline,
                    order.nonce,
                    order.exactInput
                )
            )
        );
        require(
            digest.recover(order.orderSignature) == order.trader,
            "Invalid signature"
        );
    }

    // Process pre-swap operations like permit and token transfers
    function processPreSwap(Order memory order) internal {
        if (order.permitSignature.length > 0) {
            (uint8 v, bytes32 r, bytes32 s) = splitSignature(
                order.permitSignature
            );
            IERC20Permit(order.tokenIn).permit(
                order.trader,
                address(this),
                order.amount,
                order.deadline,
                v,
                r,
                s
            );
        }

        IERC20 tokenIn = IERC20(order.tokenIn);
        tokenIn.safeTransferFrom(order.trader, address(this), order.amount);

        // Reset allowance to 0 first to handle non-standard ERC20 tokens
        if (tokenIn.allowance(address(this), address(poolManager)) > 0) {
            tokenIn.approve(address(poolManager), 0);
        }
        tokenIn.approve(address(poolManager), order.amount);
    }

    // --- Admin Functions ---
    function setMevRewardBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_MEV_REWARD_BPS, "Exceeds max");
        pendingMevRewardBps = newBps;
        pendingMevRewardBpsTime = block.timestamp + TIMELOCK_DELAY;
        emit ParameterChangeQueued(
            "mevRewardBps",
            newBps,
            pendingMevRewardBpsTime
        );
    }

    function applyMevRewardBps() external onlyOwner {
        require(block.timestamp >= pendingMevRewardBpsTime, "Timelocked");
        mevRewardBps = pendingMevRewardBps;
        emit ParameterChangeApplied("mevRewardBps", mevRewardBps);
    }

    function updateGuardian(address guardian, bool status) external onlyOwner {
        guardians[guardian] = status;
        emit GuardianUpdated(guardian, status);
    }

    // --- User Functions ---
    function claimRewards(address token) external nonReentrant {
        uint256 amount = pendingRewards[msg.sender][token];
        require(amount > 0, "No rewards");

        pendingRewards[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, token, amount);
    }

    // --- Emergency Functions ---
    function emergencyPause(bool pause) external {
        require(guardians[msg.sender], "Unauthorized");
        systemPaused = pause;
    }

    function withdrawInsurance(
        address token,
        uint256 amount
    ) external onlyOwner {
        require(insuranceReserve[token] >= amount, "Insufficient reserve");
        insuranceReserve[token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // --- Utility Functions ---
    function hashPoolKey(PoolKey memory key) internal pure returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    POOLKEY_TYPEHASH,
                    key.currency0,
                    key.currency1,
                    key.fee,
                    key.tickSpacing,
                    key.hooks
                )
            );
    }

    function splitSignature(
        bytes memory sig
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        require(sig.length == 65, "Invalid signature length");
        assembly {
            r := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
    }

    // --- Fallback ---
    receive() external payable {} // Explicitly handle native ETH
}
