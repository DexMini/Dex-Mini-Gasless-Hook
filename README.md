# Dex-Mini-Gasless-Hook

A gasless swap hook implementation for Uniswap v4, allowing users to execute swaps without holding ETH for gas.

## Features

- Gasless swaps using ERC-2612 permit
- MEV reward sharing
- Insurance fee mechanism
- Guardian system for emergency pauses
- TWAP protection (to be implemented)

## Installation
ash
forge install
bash
forge build
bash
forge test
bash
git init
git add .
git commit -m "feat: implement GaslessSwapHook for Uniswap v4"
git branch -M main
git remote add origin https://github.com/DexMini/Dex-Mini-Gasless-Hook.git
git push -u origin main