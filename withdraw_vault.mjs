import { ethers } from "ethers";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xe12f9b03327a875c2d5bf9b40a75cd2effeed46ea508ee595c6bc708c386da8c";
const VAULT_ADDRESS = "0xBdf140e2F48fF00CdAf9B4CA02351149b8488DFe";
const RPC_URL = "https://sepolia.base.org";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  const vault = new ethers.Contract(VAULT_ADDRESS, ["function withdraw(uint256 amount) external"], signer);
  console.log("Retrait de 10 USDC du Vault vers le wallet deployer...");
  const tx = await vault.withdraw(10n * 10n ** 6n, { gasLimit: 200000 });
  await tx.wait(1);
  console.log("✅ 10 USDC retirés du Vault avec succès !");
}

main().catch(console.error);
