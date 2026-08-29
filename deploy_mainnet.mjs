import { ethers } from "ethers";
import fs from "fs";

// =========================================================================
// 1. CONFIGURATION RÉSEAU & ADRESSES BASE MAINNET
// =========================================================================
// ⚠️ Si vous utilisez une clé privée directe :
const PRIVATE_KEY = process.env.PRIVATE_KEY || "";

// USDC officiel natif sur Base Mainnet (Circle)
const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

// Contrat Oracle Supra DORA Pull sur Base Mainnet
const SUPRA_CONTRACT = process.env.SUPRA_CONTRACT || "0x2FA6DbFe4291136Cf272E1A3294362b6651e8517"; 

const GOLD_ASSET_ID = 5500n;

const RPC_URLS = [
  "https://mainnet.base.org",
  "https://base.drpc.org",
  "https://base-rpc.publicnode.com",
  "https://1rpc.io/base"
];

// =========================================================================
// 2. PARAMÈTRES DU MARCHÉ GOLD (XAU/USD - Asset ID: 5500)
// =========================================================================
// Échelle : 1e6 (ex: 1_000_000 = 100%, 10_000 = 1%, 1_000 = 0.1%, 100 = 0.01%)
const GOLD_CONFIG = {
  minLeverage: 5n,                                    // Levier min: 5x
  maxLeverage: 20n,                                   // Levier max: 20x
  minTradeSize: 10n * 10n ** 6n,                      // Collatéral min: 10 USDC
  commissionRate: 1_000n,                             // Commission: 0.10% du volume (1 000 / 1e6)
  maxTraderOI: 2_500n * 10n ** 6n,                    // Position max par trader: 2 500 USDC
  maxOpenInterest: 50_000n * 10n ** 6n,               // Capacité totale du marché: 50 000 USDC
  
  // Contrôle strict du déséquilibre (Skew)
  maxSkew: 5_000n * 10n ** 6n,                        // Déséquilibre max Long/Short: 5 000 USDC
  
  // Spreads dynamiques
  minSpread: 300n,                                    // Spread de base: 0.03% (300 / 1e6)
  maxSpread: 1_500n,                                  // Spread max en cas de gros déséquilibre: 0.15% (1500 / 1e6)
  spreadVirtualOI: 10_000n * 10n ** 6n,               // Profondeur virtuelle pour lissage: 10 000 USDC
  maxSpreadPenalty: 1_200n,                           // Pénalité max pour le côté dominant: 0.12%
  maxSpreadDiscount: 100n,                            // Réduction max pour le côté minoritaire: 0.01%
  
  // Taux d'emprunt dynamique (Borrow Fees)
  baseBorrowRateHourly: 23n,                          // ~20% / an de base (~0.0023% / heure -> 23 / 1e6)
  maxBorrowRateHourly: 114n,                          // ~99.8% / an max en cas de gros déséquilibre
  borrowVirtualOI: 10_000n * 10n ** 6n,               // Lissage de l'emprunt: 10 000 USDC
  recoveryTimeDays: 20n,                              // Période cible de rééquilibrage: 20 jours
  
  // Sécurité et Solvabilité
  maxProfitRate: 80_000n,                             // Plafond de profit par trade: 8% (80 000 / 1e6)
  lockedCapitalRate: 120_000n,                        // Réserve verrouillée dans le Vault: 12% (120 000 / 1e6)
  liquidationThreshold: 950_000n                      // Déclenchement de liquidation à 95% de perte du collatéral
};

// =========================================================================
// 3. CHARGEMENT DES ARTIFACTS
// =========================================================================
function loadArtifact(name) {
  const path = `./out/${name}.sol/${name}.json`;
  if (!fs.existsSync(path)) {
    throw new Error(`Artifact non trouvé: ${path}. Lancez d'abord 'forge build'.`);
  }
  return JSON.parse(fs.readFileSync(path, "utf8"));
}

async function getWorkingProvider() {
  for (const url of RPC_URLS) {
    try {
      const p = new ethers.JsonRpcProvider(url, 8453, { staticNetwork: ethers.Network.from(8453) });
      const block = await Promise.race([
        p.getBlockNumber(),
        new Promise((_, reject) => setTimeout(() => reject(new Error("Timeout")), 3500))
      ]);
      if (block > 0) {
        console.log(`📡 Connecté au RPC Base Mainnet: ${url} (Bloc #${block})`);
        return p;
      }
    } catch (e) {
      // essaye le RPC suivant
    }
  }
  return new ethers.JsonRpcProvider(RPC_URLS[0], 8453, { staticNetwork: ethers.Network.from(8453) });
}

async function main() {
  if (!PRIVATE_KEY) {
    console.error("❌ Veuillez fournir votre PRIVATE_KEY via la variable d'environnement :");
    console.error("👉 Exemple : PRIVATE_KEY=0x... node deploy_mainnet.mjs\n");
    console.error("💡 Si vous préférez utiliser votre LEDGER directement, utilisez la commande Foundry :");
    console.error("👉 forge script scripts/DeployMainnet.s.sol:DeployMainnet --rpc-url https://mainnet.base.org --ledger --broadcast\n");
    process.exit(1);
  }

  const provider = await getWorkingProvider();
  const deployer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log("\n==================================================");
  console.log("   🚀 DÉPLOIEMENT DU PROTOCOLE BROKEX - BASE MAINNET");
  console.log("==================================================");
  console.log(`👤 Déployeur:       ${deployer.address}`);
  const ethBal = await provider.getBalance(deployer.address);
  console.log(`⛽ Solde ETH:       ${ethers.formatEther(ethBal)} ETH`);
  console.log(`💵 USDC Mainnet:    ${USDC_ADDRESS}`);
  console.log(`🔮 Supra Oracle:    ${SUPRA_CONTRACT}`);
  console.log(`🥇 Actif Initial:   Gold XAU/USD (Asset ID: ${GOLD_ASSET_ID})\n`);

  if (ethBal === 0n) {
    console.error("❌ Solde ETH insuffisant pour payer le gaz de déploiement !");
    process.exit(1);
  }

  const vaultArtifact = loadArtifact("BrokexVault");
  const coreArtifact = loadArtifact("BrokexCore");
  const lensArtifact = loadArtifact("BrokexLens");

  // 1. Déploiement de BrokexVault
  console.log("1️⃣ Déploiement de BrokexVault...");
  const VaultFactory = new ethers.ContractFactory(vaultArtifact.abi, vaultArtifact.bytecode.object, deployer);
  const vault = await VaultFactory.deploy();
  await vault.waitForDeployment();
  const vaultAddress = await vault.getAddress();
  console.log(`✅ BrokexVault déployé à : ${vaultAddress}`);

  // 2. Déploiement de BrokexCore
  console.log("\n2️⃣ Déploiement de BrokexCore...");
  const CoreFactory = new ethers.ContractFactory(coreArtifact.abi, coreArtifact.bytecode.object, deployer);
  const core = await CoreFactory.deploy(
    USDC_ADDRESS,
    SUPRA_CONTRACT,
    vaultAddress
  );
  await core.waitForDeployment();
  const coreAddress = await core.getAddress();
  console.log(`✅ BrokexCore déployé à : ${coreAddress}`);

  // 3. Liaison du Vault au Core
  console.log("\n3️⃣ Configuration de la Vault (setPrimaryCore)...");
  const linkTx = await vault.setPrimaryCore(coreAddress);
  await linkTx.wait(1);
  console.log(`✅ BrokexVault lié à BrokexCore !`);

  // 4. Listing de l'Or (5500)
  console.log("\n4️⃣ Listing du marché Gold (XAU/USD)...");
  const listTx = await core.listAsset(GOLD_ASSET_ID, GOLD_CONFIG);
  await listTx.wait(1);
  console.log(`✅ Marché Gold (5500) listé avec succès !`);

  // 5. Déploiement de BrokexLens
  console.log("\n5️⃣ Déploiement de BrokexLens...");
  const LensFactory = new ethers.ContractFactory(lensArtifact.abi, lensArtifact.bytecode.object, deployer);
  const lens = await LensFactory.deploy(coreAddress);
  await lens.waitForDeployment();
  const lensAddress = await lens.getAddress();
  console.log(`✅ BrokexLens déployé à : ${lensAddress}`);

  // Récapitulatif
  console.log("\n==================================================");
  console.log("   🎉 DÉPLOIEMENT MAINNET TERMINÉ AVEC SUCCÈS !");
  console.log("==================================================");
  console.log(`VAULT_ADDRESS = "${vaultAddress}";`);
  console.log(`CORE_ADDRESS  = "${coreAddress}";`);
  console.log(`LENS_ADDRESS  = "${lensAddress}";`);
  console.log("==================================================\n");
}

main().catch((err) => {
  console.error("\n❌ Erreur de déploiement :", err);
  process.exit(1);
});
