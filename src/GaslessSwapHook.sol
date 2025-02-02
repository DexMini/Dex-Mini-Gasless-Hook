// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Uniswap imports with correct paths
import {BaseHook} from "@uniswap/v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

// OpenZeppelin imports
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

    // Events
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

    bytes32 public constant ORDER_TYPEHASH =
        keccak256(
            "Order(address trader,PoolKey poolKey,address tokenIn,address tokenOut,uint256 amount,uint256 minAmountOut,uint256 deadline,uint256 nonce,bool exactInput)PoolKey(Currency currency0,Currency currency1,uint24 fee,int24 tickSpacing,IHooks hooks,int24 minTick,int24 maxTick)"
        );
    bytes32 public constant POOLKEY_TYPEHASH =
        keccak256(
            "PoolKey(Currency currency0,Currency currency1,uint24 fee,int24 tickSpacing,IHooks hooks,int24 minTick,int24 maxTick)"
        );

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

    uint256 public mevRewardBps = 200;
    uint256 public constant MAX_MEV_REWARD_BPS = 1000;
    uint256 public constant INSURANCE_FEE_BPS = 5;

    mapping(address => uint256) public orderNonces;
    mapping(address => mapping(address => uint256)) public pendingRewards; // token => trader => amount
    mapping(address => bool) public guardians;
    uint256 public insuranceReserve;

    bool public systemPaused;
    uint256 private constant TIMELOCK_DELAY = 2 days;
    mapping(bytes32 => uint256) public parameterChanges;

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

    // Add hook permissions
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

    // Fix beforeSwap signature - remove unused params
    function beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata /* params */, // unused
        bytes calldata callbackData
    ) external override returns (bytes4, BeforeSwapDelta, uint24) {
        require(!systemPaused, "System paused");
        require(sender == address(this), "Unauthorized");

        Order memory order = abi.decode(callbackData, (Order));
        validateOrder(order, key);
        processPreSwap(order);

        return (BaseHook.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    // Fix afterSwap signature - remove unused params
    function afterSwap(
        address /* sender */, // unused
        PoolKey calldata /* key */, // unused
        IPoolManager.SwapParams calldata /* params */, // unused
        BalanceDelta delta,
        bytes calldata callbackData
    ) external override nonReentrant whenNotPaused returns (bytes4, int128) {
        Order memory order = abi.decode(callbackData, (Order));

        // Handle negative values properly
        uint256 actualAmount;
        if (order.exactInput) {
            int128 amount = -delta.amount0(); // Negative because tokens are leaving
            require(amount > 0, "Invalid amount");
            actualAmount = uint256(uint128(amount));
        } else {
            int128 amount = delta.amount1();
            require(amount > 0, "Invalid amount");
            actualAmount = uint256(uint128(amount));
        }

        distributeFunds(order, actualAmount);
        return (BaseHook.afterSwap.selector, 0);
    }

    // --- Order Validation --- //
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

    // --- Funds Handling --- //
    function processPreSwap(Order memory order) internal {
        // Split permit signature for ERC-2612
        (uint8 v, bytes32 r, bytes32 s) = splitSignature(order.permitSignature);

        // Process ERC-2612 permit with correct parameters
        IERC20Permit(order.tokenIn).permit(
            order.trader,
            address(this),
            order.amount,
            order.deadline,
            v,
            r,
            s
        );

        // Transfer tokens
        IERC20(order.tokenIn).safeTransferFrom(
            order.trader,
            address(this),
            order.amount
        );

        // Approve and settle
        IERC20(order.tokenIn).approve(address(poolManager), order.amount);
        poolManager.settle();
    }

    function distributeFunds(
        Order memory order,
        uint256 actualAmount
    ) internal {
        require(actualAmount >= order.minAmountOut, "Slippage exceeded");

        uint256 insuranceFee = (actualAmount * INSURANCE_FEE_BPS) / 10000;
        uint256 reward = calculateMevReward(order, actualAmount - insuranceFee);
        uint256 traderAmount = actualAmount - insuranceFee - reward;

        insuranceReserve += insuranceFee;
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

    function calculateMevReward(
        Order memory order,
        uint256 amount
    ) internal view returns (uint256) {
        uint256 minOut = order.minAmountOut;
        if (amount <= minOut) return 0;
        return ((amount - minOut) * mevRewardBps) / 10000;
    }

    // --- User Functions --- //
    function claimRewards(address token) external nonReentrant {
        uint256 amount = pendingRewards[msg.sender][token];
        require(amount > 0, "No rewards");

        pendingRewards[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit RewardsClaimed(msg.sender, token, amount);
    }

    // --- Admin Functions --- //
    function setMevRewardBps(uint256 newBps) external onlyOwner {
        require(newBps <= MAX_MEV_REWARD_BPS, "Exceeds max");
        require(
            block.timestamp >= parameterChanges[keccak256("mevRewardBps")],
            "Timelocked"
        );

        mevRewardBps = newBps;
        parameterChanges[keccak256("mevRewardBps")] =
            block.timestamp +
            TIMELOCK_DELAY;
    }

    function addGuardian(address guardian) external onlyOwner {
        guardians[guardian] = true;
    }

    function emergencyPause(bool pause) external {
        require(guardians[msg.sender], "Unauthorized");
        systemPaused = pause;
    }

    function withdrawInsurance(
        address token,
        uint256 amount
    ) external onlyOwner {
        insuranceReserve -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    // Fix validateTwap - change to pure and remove unused params
    function validateTwap(
        PoolKey memory /* key */, // unused
        uint32 /* twapWindow */, // unused
        uint256 /* maxDeviationBps */ // unused
    ) internal pure {
        revert("TWAP validation not implemented in v4");
    }

    // Add helper function for signature splitting
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

    // --- Fallbacks --- //
    receive() external payable {} // For native token handling
}
