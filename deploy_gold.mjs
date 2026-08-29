import { ethers } from "ethers";
import fs from "fs";

// =========================================================================
// 1. CONFIGURATION RÉSEAU & ADRESSES DE BASE
// =========================================================================
const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xe12f9b03327a875c2d5bf9b40a75cd2effeed46ea508ee595c6bc708c386da8c";
const USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const SUPRA_CONTRACT = "0x391Ab9ad5C4BFee04eA508b0a0Cf499198D015e3";
const GOLD_ASSET_ID = 5500n;

const RPC_URLS = [
  "https://api.developer.coinbase.com/rpc/v1/base-sepolia/h6Jh2uThY6yIgosEwH3eK7rm3yQWNV0h",
  "https://base-sepolia.drpc.org",
  "https://sepolia.base.org"
];

// =========================================================================
// 2. PARAMÈTRES DU MARCHÉ GOLD (XAU/USD)
// =========================================================================
// Échelle des pourcentages : 1e6 (ex: 1_000_000 = 100%, 120_000 = 12%, 80_000 = 8%)
const GOLD_CONFIG = {
  minLeverage: 5n,                                    // 5x
  maxLeverage: 20n,                                   // 20x
  minTradeSize: 10n * 10n ** 6n,                      // 10 USDC
  commissionRate: 1_000n,                             // 0.1% (1000 / 1e6)
  maxTraderOI: 2_500n * 10n ** 6n,                    // 2,500 USDC max par trader
  maxOpenInterest: 50_000n * 10n ** 6n,               // 50,000 USDC total market OI
  // Layer 1: MaxSkew (Hard Risk Control)
  maxSkew: 5_000n * 10n ** 6n,                        // 5,000 USDC max difference between Long and Short
  // Layer 2: Spread (Economic Pricing)
  minSpread: 300n,                                    // 0.03% (300 / 1e6)
  maxSpread: 1_500n,                                  // 0.15% (1500 / 1e6)
  spreadVirtualOI: 10_000n * 10n ** 6n,               // 10,000 USDC virtual OI for spread depth
  maxSpreadPenalty: 1_200n,                           // 0.12% max penalty on spread
  maxSpreadDiscount: 100n,                            // 0.01% discount on spread
  // Layer 2: Dynamic Borrow (Economic Pricing)
  baseBorrowRateHourly: 23n,                          // 20% annuel (~0.00228%/h -> 23 / 1e6)
  maxBorrowRateHourly: 114n,                          // 0.0114% / heure max (= 99.8% / an)
  borrowVirtualOI: 10_000n * 10n ** 6n,               // 10,000 USDC virtual OI for borrow smoothing
  recoveryTimeDays: 20n,                              // 20 days target recovery period
  maxProfitRate: 80_000n,                             // 8% (80_000 / 1e6) max profit rate per trade
  lockedCapitalRate: 120_000n,                        // 12% (120_000 / 1e6)
  liquidationThreshold: 950_000n                      // 95%
};

// =========================================================================
// 3. CHARGEMENT DES ARTIFACTS FOUNDRY (OUT)
// =========================================================================
function loadArtifact(name) {
  const path = `./out/${name}.sol/${name}.json`;
  if (!fs.existsSync(path)) {
    throw new Error(`Artifact non trouvé: ${path}. Lancez 'forge build' d'abord.`);
  }
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

async function getWorkingProvider() {
  for (const url of RPC_URLS) {
    try {
      const p = new ethers.JsonRpcProvider(url, 84532, { staticNetwork: ethers.Network.from(84532) });
      const block = await Promise.race([
        p.getBlockNumber(),
        new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout")), 3000))
      ]);
      if (block > 0) {
        console.log(`📡 RPC connecté: ${url}`);
        return p;
      }
    } catch (e) {
      // try next
    }
  }
  return new ethers.JsonRpcProvider(RPC_URLS[0], 84532, { staticNetwork: ethers.Network.from(84532) });
}

async function main() {
  if (PRIVATE_KEY === "YOUR_PRIVATE_KEY_HERE") {
    console.error("❌ Veuillez fournir votre PRIVATE_KEY (ex: PRIVATE_KEY=0x... node deploy_gold.mjs)");
    process.exit(1);
  }

  const provider = await getWorkingProvider();
  const deployer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("\n==================================================");
  console.log("   DÉPLOIEMENT DU PROTOCOLE BROKEX MULTI-ACTIFS");
  console.log("==================================================");
  console.log(`👤 Deployer:     ${deployer.address}`);
  const ethBal = await provider.getBalance(deployer.address);
  console.log(`⛽ Solde ETH:    ${ethers.formatEther(ethBal)} ETH`);
  console.log(`💵 USDC:         ${USDC_ADDRESS}`);
  console.log(`🔮 Supra Oracle: ${SUPRA_CONTRACT}`);
  console.log(`🥇 Asset ID Or:  ${GOLD_ASSET_ID}\n`);

  const vaultArtifact = loadArtifact("BrokexVault");
  const coreArtifact = loadArtifact("BrokexCore");
  const lensArtifact = loadArtifact("BrokexLens");

  // 1. Déploiement du Vault
  console.log("1️⃣ Déploiement de BrokexVault...");
  const VaultFactory = new ethers.ContractFactory(vaultArtifact.abi, vaultArtifact.bytecode.object, deployer);
  const vault = await VaultFactory.deploy({ gasLimit: 2500000 });
  const vaultReceipt = await vault.deploymentTransaction().wait(1);
  const vaultAddress = await vault.getAddress();
  console.log(`✅ BrokexVault déployé à: ${vaultAddress} (Bloc: ${vaultReceipt.blockNumber})`);

  // 2. Déploiement du Core (Constructor minimaliste)
  console.log("\n2️⃣ Déploiement de BrokexCore (Multi-Actifs)...");
  const CoreFactory = new ethers.ContractFactory(coreArtifact.abi, coreArtifact.bytecode.object, deployer);
  const core = await CoreFactory.deploy(
    USDC_ADDRESS,
    SUPRA_CONTRACT,
    vaultAddress,
    { gasLimit: 7000000 }
  );
  const coreReceipt = await core.deploymentTransaction().wait(1);
  const coreAddress = await core.getAddress();
  console.log(`✅ BrokexCore déployé à: ${coreAddress} (Bloc: ${coreReceipt.blockNumber})`);

  // 3. Liaison Vault -> Core
  console.log("\n3️⃣ Liaison du Vault avec le Core (setPrimaryCore)...");
  const linkTx = await vault.setPrimaryCore(coreAddress, { gasLimit: 500000 });
  await linkTx.wait(1);
  console.log(`✅ Vault lié au Core avec succès !`);

  // 4. Listing du marché Or (XAU/USD)
  console.log("\n4️⃣ Listing du marché Gold (XAU/USD)...");
  const listTx = await core.listAsset(GOLD_ASSET_ID, GOLD_CONFIG, { gasLimit: 1500000 });
  await listTx.wait(1);
  console.log(`✅ Marché Gold (XAU/USD) listé avec succès (Asset ID: ${GOLD_ASSET_ID}) !`);

  // 5. Déploiement du Lens
  console.log("\n5️⃣ Déploiement de BrokexLens...");
  const LensFactory = new ethers.ContractFactory(lensArtifact.abi, lensArtifact.bytecode.object, deployer);
  const lens = await LensFactory.deploy(coreAddress, { gasLimit: 4000000 });
  const lensReceipt = await lens.deploymentTransaction().wait(1);
  const lensAddress = await lens.getAddress();
  console.log(`✅ BrokexLens déployé à: ${lensAddress} (Bloc: ${lensReceipt.blockNumber})`);

  // 6. Dépôt initial de 30 USDC dans le Vault
  console.log("\n6️⃣ Dépôt initial de 30 USDC dans le Vault...");
  const usdcAbi = [
    "function balanceOf(address account) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)"
  ];
  const usdcContract = new ethers.Contract(USDC_ADDRESS, usdcAbi, deployer);
  const depositAmount = 30n * 10n ** 6n; // 30 USDC

  const userBalance = await usdcContract.balanceOf(deployer.address);
  console.log(`💰 Solde USDC disponible: ${ethers.formatUnits(userBalance, 6)} USDC`);

  if (userBalance < depositAmount) {
    console.warn(`⚠️ Attention: Solde USDC insuffisant pour déposer 30 USDC (Solde: ${ethers.formatUnits(userBalance, 6)} USDC). Dépôt ignoré.`);
  } else {
    console.log("Approbation USDC pour le Vault...");
    const approveTx = await usdcContract.approve(vaultAddress, ethers.MaxUint256, { gasLimit: 100000 });
    await approveTx.wait(1);
    console.log("✅ Approbation confirmée.");

    console.log("Dépôt de 30 USDC dans le Vault...");
    const depositTx = await vault.deposit(depositAmount, { gasLimit: 200000 });
    await depositTx.wait(1);
    console.log(`✅ 30 USDC déposés avec succès dans le Vault !`);
  }

  // Résumé
  console.log("\n==================================================");
  console.log("   🎉 DÉPLOIEMENT TERMINÉ AVEC SUCCÈS !");
  console.log("==================================================");
  console.log(`VAULT_ADDRESS = "${vaultAddress}"; // Bloc ${vaultReceipt.blockNumber}`);
  console.log(`CORE_ADDRESS  = "${coreAddress}";  // Bloc ${coreReceipt.blockNumber}`);
  console.log(`LENS_ADDRESS  = "${lensAddress}";  // Bloc ${lensReceipt.blockNumber}`);
  console.log(`DEPLOYMENT_BLOCK = ${coreReceipt.blockNumber};`);
  console.log("==================================================\n");
}

main().catch((err) => {
  console.error("\n❌ Erreur de déploiement:", err);
  process.exit(1);
});
