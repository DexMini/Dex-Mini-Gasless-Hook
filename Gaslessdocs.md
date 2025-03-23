# Secure, MEV-Resistant Swaps with Profit Sharing

## The Gasless Swap Hook

The Gasless Swap Hook revolutionizes Uniswap V4 trading by enabling gasless, MEV-resistant swaps that reward users instead of extractors. This innovation leverages off-chain signature authorization with on-chain execution, eliminating gas fees while incorporating powerful safeguards against exploitation.

### Key Security Features
- **Zero Gas Fees:** Users can execute swaps without incurring any transaction costs, making DeFi more accessible.
- **Zero Slippage:** Trades are executed precisely at the target price, eliminating the risk of unfavorable price changes.
- **Zero MEV Exploitation:** Competitive bidding mechanisms redistribute value to traders, effectively preventing Miner Extractable Value (MEV) exploitation and ensuring fairer trades.

The Dex Mini Gasless Swap Hook reimagines order execution as a competitive auction designed to benefit users. Instead of relying on traditional transaction processing, Gasless Swap broadcasts swap orders to a decentralized network of specialized searchers (automated market makers). These searchers then engage in a competitive bidding process to fulfill the swap request.

## How It Works

### 1. User Order Submission
- Users initiate swaps by submitting orders with signed parameters, including the desired price, amount, and order expiration. This process is entirely gas-free.

### 2. Searcher Competition
- A network of automated market makers (searchers) actively monitors the order broadcast. They compete to execute the swap in the most efficient manner.

### 3. Winning Execution
- The searcher who offers the best execution fulfills the swap on-chain. This includes forwarding any ETH tips and importantly, any surplus value generated from the competitive bidding process directly to the user.

## Robust Security and Risk Mitigation

- **BalanceDelta Validation:** Enforces strict asset flow constraints, effectively preventing manipulation and ensuring the integrity of the swap.
- **Governance Timelock (48-Hour Delay):** All protocol updates are subject to a 48-hour timelock, providing the community with ample opportunity for review and ensuring transparent governance.
- **Signature Protection (EIP-712, Nonce Enforcement):** Utilizes industry-standard signature protocols to prevent order duplication, front-running, and unauthorized execution, safeguarding user funds and intent.

## User Protection & Profit Mechanisms

- **Price Warning System:** Alerts users if orders deviate significantly from market rates, reducing accidental losses.
- **Guaranteed ETH Tips:** Searchers *must* attach an ETH tip to execute orders, ensuring traders always gain value.
- **Surplus Redistribution:** In high-competition auctions, searchers may bid beyond the required tip to prioritize order fulfillment. This results in a "surplus" – additional ETH earned by users – creating scenarios where traders profit from the swap process itself.

By decentralizing MEV redistribution and removing friction costs, the Gasless Swap Hook shifts DeFi toward a fairer, more efficient trading model where users—not bots—capture the value of their trades.

## Key Components

### 1. User Configuration: Setting Your Swap Parameters

- **Token Selection:** Users specify the input token they wish to sell and the output token they intend to buy.
- **Price Strategy:**
  - **Market Orders:** Execute instantly at the best available rate in the market.
  - **Limit Orders:** Execute only when the market price reaches the user's specified price:
    - **Competitive Auction:** Limit orders placed above the current market price for buying, or below for selling, trigger a competitive auction among MEV searchers.
    - **MEV Searcher Bidding:** These searchers bid to fill the order precisely at the user-defined limit price.
    - **Interface Warnings:** The user interface provides alerts if the chosen limit price might lead to unfavorable execution.

### 2. Auction Mechanism: Competitive Bidding for Optimal Execution

- **Order Broadcast:** The swap order is broadcast to a decentralized network of MEV searchers.
- **Real-Time Competitive Bidding:** Searchers compete in real time, optimizing for:
  - **Best Execution Price:** Ensuring the user receives the most favorable rate for their swap.
  - **ETH Tip Size:** A priority bid paid to the user as a reward for using the Gasless Swap Hook.
- **Winning Execution:** The searcher offering the highest combined value of the optimal execution price and the ETH tip wins the right to execute the swap.

### 3. Order Execution & Rewards: Ensuring Accuracy and User Benefits

- **Swap Finalization:** The winning searcher executes the swap on-chain, guaranteeing:
  - The exact requested amount of the output token.
  - A guaranteed ETH tip, which is the minimum reward offered by the searcher.
  - Any surplus ETH, representing additional value generated from the competitive bidding process.

### 4. Technical Parameters & Events: Governance and System Management

- **System Constants:**
  - `MAX_MEV_REWARD_BPS`: Caps MEV rewards at 10% (1,000 basis points).
  - `INSURANCE_FEE_BPS`: Allocates 0.05% of each swap to protocol reserves.
  - `TIMELOCK_DELAY`: Introduces a 2-day delay for critical parameter changes, enhancing security and transparency.
- **State Variables:**
  - `mevRewardBps`: The currently active MEV reward rate.
  - `pendingMevRewardBps`: A proposed MEV reward rate awaiting the timelock period.
  - `orderNonces`: Used to prevent the reuse of signatures, protecting against replay attacks.
  - `insuranceReserve`: Token-specific funds dedicated to mitigating risks.
- **Contract Events:**
  - `GaslessSwapExecuted`: Emitted upon the successful completion of a gasless swap.
  - `RewardsClaimed`: Emitted when users withdraw their earned tips and surplus ETH.
  - `ParameterChangeQueued`: Signals that a governance proposal to change a parameter is pending and awaiting the timelock.

## Illustrative Scenarios

### 1. Regular User Swap Walkthrough (Alice)

#### Scenario: Alice wants to swap 1 ETH for USDC without paying gas fees.

#### Step-by-Step Process:

1. **Order Creation (Off-Chain):**
   - Alice creates an Order specifying:
     - `tokenIn: WETH` (ETH wrapper)
     - `tokenOut: USDC`
     - `amount: 1 ETH`
     - `minAmountOut: 1800 USDC`
     - `deadline: 20 minutes`
     - `exactInput: true`
   - Signs the order with her private key using EIP-712.
2. **Relayer Submission:** Alice sends the signed order to a relayer. The relayer pays gas fees.
3. **Order Execution:** The relayer calls `GaslessSwapHook.executeOrder(Order)` to execute the swap.
4. **AfterSwap Hook Processing:**
   - Calculates output: 1850 USDC (example).
   - Deducts fees:
     - **Insurance**: 0.925 USDC
     - **MEV Reward**: 37 USDC
   - Transfers 1812.075 USDC to Alice.

### 2. Liquidity Provider Adding Liquidity Perspective (Bob)

Bob adds liquidity to the ETH/USDC pool with Gasless Swap Hook, earning fees from swaps.

### 3. Liquidity Provider Reward Claim Process (Bob)

Bob claims accumulated USDC rewards from MEV sharing.

### 4. MEV Searcher/Relayer Perspective

Relayers optimize order execution for profit, ensuring high efficiency and fair trade execution.

---

The Gasless Swap Hook transforms DeFi by ensuring fairer, more efficient, and gasless transactions, where users benefit from MEV instead of being exploited by it.

