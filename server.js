const http = require('http');
const fs = require('fs');
const path = require('path');
const axios = require('axios');
const { Web3 } = require('web3');

const web3 = new Web3();
const OracleProofABI = require('./supra-pull-client/rest/resources/oracleProof.json');

const PORT = 3333;
const REST_URL = 'https://rpc-mainnet-dora-2.supra.com';

async function fetchSupraProof(assetId) {
    const response = await axios.post(`${REST_URL}/get_proof`, {
        pair_indexes: [Number(assetId)],
        chain_type: 'evm'
    }, { timeout: 5000 });

    const rawProof = response.data.proof_bytes;
    const hexProof = rawProof.startsWith('0x') ? rawProof : `0x${rawProof}`;

    const decoded = web3.eth.abi.decodeParameters(OracleProofABI, hexProof);
    const committeeFeed = decoded[0].data[0].committee_data.committee_feed[0];

    const pairId = Number(committeeFeed.pair.toString());
    const rawPrice = committeeFeed.price.toString();
    const decimals = Number(committeeFeed.decimals.toString());
    const rawTimestamp = Number(committeeFeed.timestamp.toString());
    const timestampMs = rawTimestamp > 1e12 ? rawTimestamp : rawTimestamp * 1000;
    const priceNumber = Number(rawPrice) / Math.pow(10, decimals);

    return {
        pairId,
        rawPrice,
        decimals,
        price: priceNumber,
        timestamp: Math.floor(timestampMs / 1000),
        proofBytes: hexProof
    };
}

const server = http.createServer(async (req, res) => {
    // Enable CORS for all requests
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

    if (req.method === 'OPTIONS') {
        res.writeHead(204);
        res.end();
        return;
    }

    const parsedUrl = new URL(req.url, `http://localhost:${PORT}`);

    // API Endpoint: /api/proof?assetId=5500
    if (parsedUrl.pathname === '/api/proof' || parsedUrl.pathname === '/api/price') {
        const assetId = parsedUrl.searchParams.get('assetId') || 5500;
        try {
            const data = await fetchSupraProof(assetId);
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true, ...data }));
        } catch (err) {
            console.error(`Erreur Supra fetch pour asset ${assetId}:`, err.message);
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: false, error: err.message }));
        }
        return;
    }

    // Serve index.html or static files
    let filePath = path.join(__dirname, parsedUrl.pathname === '/' ? 'index.html' : parsedUrl.pathname);
    
    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
        const ext = path.extname(filePath);
        const contentType = ext === '.html' ? 'text/html'
            : ext === '.js' ? 'text/javascript'
            : ext === '.css' ? 'text/css'
            : ext === '.json' ? 'application/json'
            : 'text/plain';

        res.writeHead(200, { 'Content-Type': contentType });
        fs.createReadStream(filePath).pipe(res);
    } else {
        // Fallback to index.html for SPA
        res.writeHead(200, { 'Content-Type': 'text/html' });
        fs.createReadStream(path.join(__dirname, 'index.html')).pipe(res);
    }
});

server.listen(PORT, () => {
    console.log(`🚀 Serveur Brokex & Proxy Supra démarré sur http://localhost:${PORT}`);
    console.log(`📡 API Supra Proof disponible sur http://localhost:${PORT}/api/proof?assetId=5500`);
});
