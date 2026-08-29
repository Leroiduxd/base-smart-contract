// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface Vm {
    function startBroadcast() external;
    function stopBroadcast() external;
}

import {BrokexCore} from "../BrokexCore.sol";
import {BrokexVault} from "../BrokexVault.sol";
import {BrokexLens} from "../BrokexLens.sol";

contract DeployMainnet {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address public constant USDC_MAINNET = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant SUPRA_MAINNET = 0x2FA6DbFe4291136Cf272E1A3294362b6651e8517; 
    uint256 public constant GOLD_ASSET_ID = 5500;

    function run() external returns (BrokexVault vault, BrokexCore core, BrokexLens lens) {
        vm.startBroadcast();

        // 1. Deploy Vault
        vault = new BrokexVault();

        // 2. Deploy Core
        core = new BrokexCore(USDC_MAINNET, SUPRA_MAINNET, address(vault));

        // 3. Link Vault to Core
        vault.setPrimaryCore(address(core));

        // 4. List Gold (5500)
        BrokexCore.AssetConfig memory goldConfig = BrokexCore.AssetConfig({
            minLeverage: 5,
            maxLeverage: 20,
            minTradeSize: 10 * 1e6,               // 10 USDC
            commissionRate: 1_000,                // 0.10%
            maxTraderOI: 2_500 * 1e6,             // 2,500 USDC max par trader
            maxOpenInterest: 50_000 * 1e6,        // 50,000 USDC max OI global
            maxSkew: 5_000 * 1e6,                 // 5,000 USDC max skew
            minSpread: 300,                       // 0.03%
            maxSpread: 1_500,                     // 0.15%
            spreadVirtualOI: 10_000 * 1e6,        // 10,000 USDC virtual OI
            maxSpreadPenalty: 1_200,              // 0.12% max penalty
            maxSpreadDiscount: 100,               // 0.01% max discount
            baseBorrowRateHourly: 23,             // ~20% / an base
            maxBorrowRateHourly: 114,             // ~99.8% / an max
            borrowVirtualOI: 10_000 * 1e6,        // 10,000 USDC borrow smoothing
            recoveryTimeDays: 20,                 // 20 jours
            maxProfitRate: 80_000,                // 8% max price move profit
            lockedCapitalRate: 120_000,           // 12% locked capital
            liquidationThreshold: 950_000         // 95% liquidation threshold
        });

        core.listAsset(GOLD_ASSET_ID, goldConfig);

        // 5. Deploy Lens
        lens = new BrokexLens(address(core));

        vm.stopBroadcast();
    }
}
