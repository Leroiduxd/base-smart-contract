import { ethers } from "ethers";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xe12f9b03327a875c2d5bf9b40a75cd2effeed46ea508ee595c6bc708c386da8c";
const CORE_ADDRESS = "0x9B567d3758b6CD78b83d137F43F6A42725158Dcf";
const NEW_RISK_MANAGER = "0x8E221f2eaF11eba2CA1fF2DEDd38432673Ee4938";

const RPC_URL = "https://api.developer.coinbase.com/rpc/v1/base-sepolia/h6Jh2uThY6yIgosEwH3eK7rm3yQWNV0h";

const CORE_ABI = [
  "function owner() view returns (address)",
  "function riskManager() view returns (address)",
  "function setRiskManager(address newRiskManager) external"
];

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL, 84532, { staticNetwork: ethers.Network.from(84532) });
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log(`👤 Wallet: ${wallet.address}`);
  console.log(`🏛️ Core:   ${CORE_ADDRESS}`);

  const core = new ethers.Contract(CORE_ADDRESS, CORE_ABI, wallet);

  const currentOwner = await core.owner();
  const currentRiskManager = await core.riskManager();

  console.log(`👑 Owner actuel:        ${currentOwner}`);
  console.log(`🛡️ Risk Manager actuel: ${currentRiskManager}`);

  if (currentOwner.toLowerCase() !== wallet.address.toLowerCase()) {
    console.error(`❌ Erreur: Vous n'êtes pas le owner du contrat Core !`);
    process.exit(1);
  }

  if (currentRiskManager.toLowerCase() === NEW_RISK_MANAGER.toLowerCase()) {
    console.log(`ℹ️ Le Risk Manager est déjà défini sur ${NEW_RISK_MANAGER}.`);
    return;
  }

  console.log(`\n🚀 Mise à jour du Risk Manager vers ${NEW_RISK_MANAGER}...`);
  const tx = await core.setRiskManager(NEW_RISK_MANAGER, { gasLimit: 150000 });
  console.log(`📤 Tx envoyée: ${tx.hash}`);

  console.log("⏳ En attente de confirmation...");
  const receipt = await tx.wait(1);

  if (receipt.status === 1) {
    const updatedRiskManager = await core.riskManager();
    console.log(`✅ Succès ! Nouveau Risk Manager configuré: ${updatedRiskManager}`);
  } else {
    console.error("❌ La transaction a échoué.");
  }
}

main().catch(err => {
  console.error("❌ Erreur:", err);
  process.exit(1);
});
