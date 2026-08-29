const axios = require('axios');
const { Web3 } = require('web3');

const web3 = new Web3();
const OracleProofABI = require('../supra-pull-client/rest/resources/oracleProof.json');

const REST_URL = 'https://rpc-testnet-dora-2.supra.com';
const ASSET_INDEX = 5500;

async function fetchAndDecodeProof() {
    try {
        console.log(`📡 Interrogation de Supra DORA pour l'asset ${ASSET_INDEX}...`);
        
        // 1. Récupération de la proof brute depuis le serveur Supra
        const response = await axios.post(`${REST_URL}/get_proof`, {
            pair_indexes: [ASSET_INDEX],
            chain_type: 'evm'
        });

        const rawProof = response.data.proof_bytes;
        const hexProof = rawProof.startsWith('0x') ? rawProof : `0x${rawProof}`;

        // 2. Décodage local du payload de proof via l'ABI interne de Supra
        const decoded = web3.eth.abi.decodeParameters(OracleProofABI, hexProof);
        const committeeFeed = decoded[0].data[0].committee_data.committee_feed[0];

        const pairId = committeeFeed.pair.toString();
        const price = committeeFeed.price.toString();
        const decimals = committeeFeed.decimals.toString();
        const rawTimestamp = Number(committeeFeed.timestamp.toString());
        // Supra renvoie le timestamp en millisecondes
        const timestampMs = rawTimestamp > 1e12 ? rawTimestamp : rawTimestamp * 1000;
        const formattedPrice = (Number(price) / Math.pow(10, decimals)).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 4 });

        console.log('\n================ RÉSULTAT SUPRA ================');
        console.log(`🔹 Asset ID     : ${pairId} (BTC/USDT)`);
        console.log(`🔹 Prix Décodé  : $${formattedPrice}`);
        console.log(`🔹 Décimales    : ${decimals}`);
        console.log(`🔹 Date Oracle  : ${new Date(timestampMs).toLocaleString()}`);
        console.log(`🔹 Âge Proof    : ${Math.max(0, Math.floor((Date.now() - timestampMs) / 1000))}s`);
        console.log(`🔹 Proof Bytes  : ${hexProof.slice(0, 50)}... (${hexProof.length} chars)`);
        console.log('=================================================\n');

    } catch (error) {
        console.error('❌ Erreur :', error.message);
    }
}

// Récupération en boucle toutes les 500 ms (2 fois par seconde)
fetchAndDecodeProof();
setInterval(fetchAndDecodeProof, 500);
