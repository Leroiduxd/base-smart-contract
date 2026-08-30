import fs from "fs";

const API_KEY = process.env.BASESCAN_API_KEY || "59HHZN9T5IIQ4P4HK4WYFTBQPWTJYXHEVS";
const COMPILER_VERSION = "v0.8.24+commit.e11b9ed9";

function createStandardJson(contractFile, extraFiles = []) {
  const sources = {};
  sources[contractFile] = { content: fs.readFileSync(`./${contractFile}`, "utf8") };
  for (const f of extraFiles) {
    sources[f] = { content: fs.readFileSync(`./${f}`, "utf8") };
  }

  return JSON.stringify({
    language: "Solidity",
    sources,
    settings: {
      optimizer: {
        enabled: true,
        runs: 200
      },
      viaIR: true,
      evmVersion: "cancun",
      outputSelection: {
        "*": {
          "*": ["*"]
        }
      }
    }
  });
}

const CONTRACTS = [
  {
    name: "BrokexVault",
    file: "BrokexVault.sol",
    extra: ["IERC20.sol"],
    address: "0xB36e1eDF743352D67E8B24C0A8BD8fc2c229EB4e",
    constructorArgs: ""
  },
  {
    name: "BrokexCore",
    file: "BrokexCore.sol",
    extra: ["IERC20.sol"],
    address: "0x252487bE9867eF47A194402d178Ee8E555466dd9",
    constructorArgs: "000000000000000000000000833589fcd6edb6e08f4c7c32d4f71b54bda029130000000000000000000000002fa6dbfe4291136cf272e1a3294362b6651e8517000000000000000000000000b36e1edf743352d67e8b24c0a8bd8fc2c229eb4e"
  },
  {
    name: "BrokexLens",
    file: "BrokexLens.sol",
    extra: ["IERC20.sol"],
    address: "0x631C66fE969Ca48840b7CF85CE0f06aF93EFf3ff",
    constructorArgs: "000000000000000000000000252487be9867ef47a194402d178ee8e555466dd9"
  }
];

async function verifyContract(contract) {
  console.log(`\n⏳ Soumission standard JSON pour ${contract.name} (${contract.address})...`);
  const standardJson = createStandardJson(contract.file, contract.extra);

  const params = new URLSearchParams();
  params.append("apikey", API_KEY);
  params.append("module", "contract");
  params.append("action", "verifysourcecode");
  params.append("contractaddress", contract.address);
  params.append("sourceCode", standardJson);
  params.append("codeformat", "solidity-standard-json-input");
  params.append("contractname", `${contract.file}:${contract.name}`);
  params.append("compilerversion", COMPILER_VERSION);
  params.append("optimizationUsed", "1");
  params.append("runs", "200");
  if (contract.constructorArgs) {
    params.append("constructorArguements", contract.constructorArgs);
  }

  const url = "https://api.etherscan.io/v2/api?chainid=8453";
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: params.toString()
  });

  const data = await res.json();
  console.log(`Réponse soumission:`, data);

  if (data.status !== "1") {
    console.error(`❌ Échec soumission pour ${contract.name}:`, data.result);
    return;
  }

  const guid = data.result;
  console.log(`GUID reçu: ${guid}. En attente de vérification...`);

  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 4000));
    const checkUrl = `https://api.etherscan.io/v2/api?chainid=8453&apikey=${API_KEY}&module=contract&action=checkverifystatus&guid=${guid}`;
    const checkRes = await fetch(checkUrl);
    const checkData = await checkRes.json();
    console.log(`Statut (${i + 1}/20): ${checkData.result}`);
    if (checkData.result === "Pass - Verified" || (checkData.status === "1" && checkData.result.toLowerCase().includes("verified"))) {
      console.log(`🎉 ${contract.name} VÉRIFIÉ AVEC SUCCÈS SUR BASESCAN !`);
      return;
    }
    if (checkData.result && checkData.result.toLowerCase().includes("fail")) {
      console.error(`❌ Échec pour ${contract.name}:`, checkData.result);
      return;
    }
  }
}

async function main() {
  for (const c of CONTRACTS) {
    await verifyContract(c);
  }
}

main().catch(console.error);
