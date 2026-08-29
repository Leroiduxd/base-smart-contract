import { ethers } from "ethers";

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0xe12f9b03327a875c2d5bf9b40a75cd2effeed46ea508ee595c6bc708c386da8c";
const USDC_ADDRESS = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";
const CORE_ADDRESS = "0xF9Dcf0925ea569579C235205597F6AD7f6EA8769";
const LENS_ADDRESS = "0x26C4C4c36232FC61f4a06D9Dd9DA8b5921e4C0eB";
const PYTH_GOLD_FEED_ID = "0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2";
const PYTH_CONTRACT_ADDRESS = "0xA2aa501b19aff244D90cc15a4Cf739D2725B5729";
const RPC_URL = "https://sepolia.base.org";

async function main() {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const signer = new ethers.Wallet(PRIVATE_KEY, provider);

  console.log(`Test Trader: ${signer.address}`);

  const usdcAbi = [
    "function balanceOf(address account) view returns (uint256)",
    "function allowance(address owner, address spender) view returns (uint256)",
    "function approve(address spender, uint256 amount) returns (bool)"
  ];
  const coreAbi = [
    "function nextTradeId() view returns (uint256)",
    "function openMarket((bytes32 feedId, uint8 direction, uint256 collateral, uint256 leverage, uint256 stopLoss, uint256 takeProfit, address referrer) request, bytes[] priceUpdateData) payable returns (uint256)",
    "function closeMarket(uint256 tradeId, bytes[] priceUpdateData) payable"
  ];
  const pythAbi = [
    "function getUpdateFee(bytes[] updateData) view returns (uint256)"
  ];

  const usdc = new ethers.Contract(USDC_ADDRESS, usdcAbi, signer);
  const core = new ethers.Contract(CORE_ADDRESS, coreAbi, signer);
  const pyth = new ethers.Contract(PYTH_CONTRACT_ADDRESS, pythAbi, signer);

  const collat = 10n * 10n ** 6n; // 10 USDC

  // Check allowance
  const allow = await usdc.allowance(signer.address, CORE_ADDRESS);
  if (allow < collat) {
    console.log("Approbation USDC pour le Core...");
    const appTx = await usdc.approve(CORE_ADDRESS, ethers.MaxUint256);
    await appTx.wait(2);
  }

  // Get Pyth proof
  const pythRes = await fetch(`https://hermes.pyth.network/v2/updates/price/latest?ids[]=${PYTH_GOLD_FEED_ID}`);
  const pythJson = await pythRes.json();
  const pythProof = `0x${pythJson.binary.data[0]}`;
  const pythFee = await pyth.getUpdateFee([pythProof]);

  console.log("Envoi openMarket LONG 10 USDC @ 5x...");
  const marketOrder = {
    feedId: PYTH_GOLD_FEED_ID,
    direction: 1, // LONG
    collateral: collat,
    leverage: 5n,
    stopLoss: 0n,
    takeProfit: 0n,
    referrer: ethers.ZeroAddress
  };

  const tx = await core.openMarket(marketOrder, [pythProof], { value: pythFee, gasLimit: 1000000 });
  console.log(`Tx envoyée: ${tx.hash}`);
  const receipt = await tx.wait(1);
  console.log(`✅ Trade #1 ouvert avec succès sur l'Or dans le bloc ${receipt.blockNumber} !`);
}

main().catch(console.error);
