import { ethers } from "ethers";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xe12f9b03327a875c2d5bf9b40a75cd2effeed46ea508ee595c6bc708c386da8c";
const USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const VAULT_ADDRESS = "0xa35af336059Db7659b5f1565d9F9309323961067";
const RPC_URL = "https://sepolia.base.org";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  const usdc = new ethers.Contract(USDC_ADDRESS, [
    "function balanceOf(address) view returns (uint256)",
    "function approve(address, uint256) returns (bool)"
  ], signer);
  const vault = new ethers.Contract(VAULT_ADDRESS, ["function deposit(uint256) external"], signer);

  const depositAmount = 5n * 10n ** 6n; // 5 USDC
  console.log("Approbation USDC pour le Vault...");
  const appTx = await usdc.approve(VAULT_ADDRESS, depositAmount);
  await appTx.wait(1);
  console.log("Dépôt de 5 USDC dans le Vault...");
  const depTx = await vault.deposit(depositAmount, { gasLimit: 200000 });
  await depTx.wait(1);
  console.log("✅ 5 USDC déposés dans le Vault avec succès !");
}

main().catch(console.error);
