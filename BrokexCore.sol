// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

interface ISupraOraclePull {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }

    function verifyOracleProofV2(bytes calldata _bytesProof) external returns (PriceInfo memory);
}

interface IChainlinkAggregator {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

interface IBrokexVault {
    function payTrader(address trader, uint256 amount) external;
    function lockedCapital() external view returns (uint256);
}

contract BrokexCore {
    uint256 internal constant PRECISION = 1e6;
    uint256 public constant BORROW_INDEX_PRECISION = 1e18;
    uint256 internal constant BORROW_INDEX_RATE_SCALE = BORROW_INDEX_PRECISION / PRECISION;
    uint256 public constant MAX_LEVERAGE = 100;
    uint256 internal constant MAX_COMMISSION = 10_000;
    uint256 internal constant MAX_BORROW_RATE_HOURLY = 114;
    uint256 public constant MAX_OPENING_SPREAD = 10_000;
    uint256 internal constant MAX_PROOF_AGE = 7 seconds;
    uint256 internal constant MAX_FUTURE_ORACLE_DRIFT = 5 seconds;
    uint256 public constant MAX_ASSETS = 20;

    uint8 internal constant STATE_ORDER = 0;
    uint8 internal constant STATE_OPEN = 1;
    uint8 internal constant STATE_CLOSED = 2;
    uint8 internal constant STATE_CANCELLED = 3;
    uint8 internal constant STATE_LIQUIDATED = 4;
    uint8 internal constant STATE_RECOVERED = 5;

    uint8 internal constant DIR_SHORT = 0;
    uint8 internal constant DIR_LONG = 1;

    uint8 internal constant ORDER_MARKET = 0;
    uint8 internal constant ORDER_LIMIT = 1;
    uint8 internal constant ORDER_STOP = 2;

    uint8 internal constant REASON_EXECUTION = 0;
    uint8 internal constant REASON_SL = 1;
    uint8 internal constant REASON_TP = 2;
    uint8 internal constant REASON_LIQ = 3;

    uint8 internal constant MODE_NORMAL = 0;
    uint8 internal constant MODE_CLOSE_ONLY = 1;
    uint8 internal constant MODE_PAUSED = 2;
    uint8 internal constant MODE_RECOVERY = 3;

    uint8 public constant CLOSE_MARKET = 0;
    uint8 public constant CLOSE_STOP_LOSS = 1;
    uint8 public constant CLOSE_TAKE_PROFIT = 2;
    uint8 public constant CLOSE_LIQUIDATION = 3;

    struct Trade {
        address trader;
        uint40 openTimestamp;
        uint8 state;
        uint8 direction;
        uint8 orderType;
        uint8 leverage;
        uint64 margin;
        uint64 price;
        uint64 stopLoss;
        uint64 takeProfit;
        uint128 borrowIndexAtOpen;
        uint256 assetId;
    }

    struct AssetConfig {
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 minTradeSize;
        uint256 commissionRate;
        uint256 maxTraderOI;
        uint256 maxOpenInterest;
        uint256 maxSkew;
        // Spreads
        uint256 minSpread;
        uint256 maxSpread;
        uint256 spreadVirtualOI;
        uint256 maxSpreadPenalty;
        uint256 maxSpreadDiscount;
        // Borrow & Risk
        uint256 baseBorrowRateHourly;
        uint256 maxBorrowRateHourly;
        uint256 borrowVirtualOI;
        uint256 recoveryTimeDays;
        uint256 maxProfitRate;
        uint256 lockedCapitalRate;
        uint256 liquidationThreshold;
    }

    struct AssetState {
        bool listed;
        uint8 securityMode;
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 longBorrowIndex;
        uint256 shortBorrowIndex;
        uint256 lastBorrowUpdate;
    }

    struct MarketOrder {
        uint256 assetId;
        uint8 direction;
        uint256 collateral;
        uint256 leverage;
        uint256 stopLoss;
        uint256 takeProfit;
        address referrer;
    }

    struct PendingOrder {
        uint256 assetId;
        uint8 direction;
        uint8 orderType;
        uint256 targetPrice;
        uint256 collateral;
        uint256 leverage;
        uint256 stopLoss;
        uint256 takeProfit;
        address referrer;
    }

    address public owner;
    address public pendingOwner;

    IERC20 public immutable USDC;
    ISupraOraclePull public immutable supra;
    IBrokexVault public immutable vault;

    uint256[] public activeAssets;
    mapping(uint256 assetId => AssetConfig) public assetConfigs;
    mapping(uint256 assetId => AssetState) public assetStates;
    mapping(uint256 assetId => mapping(address trader => uint256 openInterest)) public traderAssetOI;

    uint256 public referralRewardRate = 200_000; // 20% (scale: 1e6)
    mapping(address trader => address referrer) public referrers;
    mapping(address trader => uint256 rate) public referralRates;
    mapping(address referrer => uint256 reward) public referralRewards;
    mapping(address trader => bool hasTraded) public hasOpenedPosition;

    struct ChainlinkGuard {
        address feed;
        uint32 maxDeviation; // scale 1e6 (ex: 11_250 for 1.125%, 15_000 for 1.5%)
    }

    mapping(uint256 assetId => ChainlinkGuard) public chainlinkGuards;
    mapping(uint256 assetId => bool) public marketClosed;

    mapping(uint256 tradeId => Trade trade) public trades;
    uint256 public nextTradeId = 1;
    uint8 public securityMode;

    uint256 private _reentrancyLock = 1;

    event AssetListed(uint256 indexed assetId, uint40 timestamp);
    event AssetDelisted(uint256 indexed assetId, uint40 timestamp);
    event AssetConfigUpdated(uint256 indexed assetId, uint40 timestamp);
    event AssetSecurityModeUpdated(uint256 indexed assetId, uint8 newMode, uint40 timestamp);
    event ChainlinkGuardUpdated(uint256 indexed assetId, address indexed feed, uint32 maxDeviation, uint40 timestamp);
    event MarketStatusUpdated(uint256 indexed assetId, bool isClosed, uint40 timestamp);

    event TradeCreated(
        uint256 indexed tradeId,
        address indexed trader,
        uint256 indexed assetId,
        uint8 direction,
        uint8 orderType,
        uint8 leverage,
        uint256 collateral,
        uint256 targetPrice,
        uint256 stopLoss,
        uint256 takeProfit,
        uint40 createdAt
    );
    event TradeOpened(
        uint256 indexed tradeId,
        uint256 indexed assetId,
        uint256 oraclePrice,
        uint256 executionPrice,
        uint256 openingSpread,
        uint256 commissionPaid,
        uint256 margin,
        uint256 openInterest,
        uint256 borrowIndexAtOpen,
        uint40 openedAt
    );
    event TradeClosed(
        uint256 indexed tradeId,
        uint256 indexed assetId,
        uint8 indexed closeMethod,
        uint256 oraclePrice,
        uint256 executionPrice,
        uint256 closingSpread,
        int256 grossPnl,
        uint256 borrowFeePaid,
        int256 finalPnl,
        uint256 traderPayout,
        uint40 closedAt
    );
    event StopsChanged(uint256 indexed tradeId, uint64 stopLoss, uint64 takeProfit, uint40 timestamp);
    event OrderCancelled(uint256 indexed tradeId, uint256 refundedCollateral, uint40 cancelledAt);
    event TradeRecovered(uint256 indexed tradeId, uint256 refundedMargin, uint40 recoveredAt);
    event ReferrerSet(address indexed trader, address indexed referrer, uint256 referralRate, uint40 timestamp);
    event ReferralRewardAccrued(
        address indexed referrer, address indexed trader, uint256 indexed tradeId, uint256 amount, uint40 timestamp
    );
    event ReferralRewardsClaimed(address indexed referrer, uint256 amount, uint40 timestamp);

    error Unauthorized();
    error InvalidInput();
    error InvalidState();
    error TransferFailed();
    error OracleUncertain();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 1) revert InvalidState();
        _reentrancyLock = 2;
        _;
        _reentrancyLock = 1;
    }

    constructor(address usdc, address supraContract, address vaultAddress) {
        if (
            usdc == address(0) || supraContract == address(0) || vaultAddress == address(0) || usdc.code.length == 0
                || supraContract.code.length == 0 || vaultAddress.code.length == 0
        ) {
            revert InvalidInput();
        }

        owner = msg.sender;
        USDC = IERC20(usdc);
        supra = ISupraOraclePull(supraContract);
        vault = IBrokexVault(vaultAddress);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (securityMode >= MODE_PAUSED) revert InvalidState();
        if (newOwner == address(0)) revert InvalidInput();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert Unauthorized();
        owner = pendingOwner;
        pendingOwner = address(0);
    }

    function setSecurityMode(uint8 newMode) external onlyOwner {
        if (newMode > MODE_RECOVERY || securityMode == MODE_RECOVERY) revert InvalidState();
        securityMode = newMode;
    }

    function getActiveAssets() external view returns (uint256[] memory) {
        return activeAssets;
    }

    function getAssetCount() external view returns (uint256) {
        return activeAssets.length;
    }

    function _validateAssetConfig(AssetConfig calldata config) internal pure {
        if (
            config.minLeverage == 0 || config.maxLeverage < config.minLeverage || config.maxLeverage > MAX_LEVERAGE
                || config.minTradeSize == 0 || config.minTradeSize > type(uint64).max
                || config.commissionRate > MAX_COMMISSION || config.commissionRate * config.maxLeverage >= PRECISION
                || config.lockedCapitalRate < 50_000 || config.lockedCapitalRate > 500_000
                || config.lockedCapitalRate <= config.maxProfitRate
                || config.liquidationThreshold < 850_000 || config.liquidationThreshold > PRECISION
                || config.maxTraderOI == 0 || config.maxOpenInterest == 0 || config.maxSkew == 0
                || config.baseBorrowRateHourly > config.maxBorrowRateHourly
                || config.maxBorrowRateHourly > MAX_BORROW_RATE_HOURLY
                || config.borrowVirtualOI == 0
                || config.minSpread > config.maxSpread || config.maxSpread > MAX_OPENING_SPREAD
                || config.spreadVirtualOI == 0 || config.maxSpreadPenalty > MAX_OPENING_SPREAD
                || config.maxSpreadDiscount > config.minSpread || config.maxProfitRate < 20_000
                || config.maxProfitRate > 500_000 || config.recoveryTimeDays == 0 || config.recoveryTimeDays > 365
        ) revert InvalidInput();
    }

    function listAsset(uint256 assetId, AssetConfig calldata config) external onlyOwner {
        if (securityMode >= MODE_PAUSED) revert InvalidState();
        if (assetId == 0 || assetStates[assetId].listed) revert InvalidInput();
        if (activeAssets.length >= MAX_ASSETS) revert InvalidState();

        _validateAssetConfig(config);

        assetConfigs[assetId] = config;
        assetStates[assetId] = AssetState({
            listed: true,
            securityMode: MODE_NORMAL,
            openInterestLong: 0,
            openInterestShort: 0,
            longBorrowIndex: 0,
            shortBorrowIndex: 0,
            lastBorrowUpdate: block.timestamp
        });

        activeAssets.push(assetId);
        emit AssetListed(assetId, uint40(block.timestamp));
    }

    function setAssetConfig(uint256 assetId, AssetConfig calldata newConfig) external onlyOwner {
        if (securityMode >= MODE_PAUSED) revert InvalidState();
        if (!assetStates[assetId].listed) revert InvalidInput();

        _validateAssetConfig(newConfig);
        _updateBorrowIndexes(assetId);

        assetConfigs[assetId] = newConfig;
        emit AssetConfigUpdated(assetId, uint40(block.timestamp));
    }

    function setAssetSecurityMode(uint256 assetId, uint8 newMode) external onlyOwner {
        AssetState storage state = assetStates[assetId];
        if (!state.listed) revert InvalidInput();
        if (newMode > MODE_RECOVERY || state.securityMode == MODE_RECOVERY) revert InvalidState();
        state.securityMode = newMode;
        emit AssetSecurityModeUpdated(assetId, newMode, uint40(block.timestamp));
    }

    function delistAsset(uint256 assetId) external onlyOwner {
        if (securityMode >= MODE_PAUSED) revert InvalidState();
        AssetState storage state = assetStates[assetId];
        if (!state.listed) revert InvalidInput();
        if (state.openInterestLong != 0 || state.openInterestShort != 0) revert InvalidState();

        state.listed = false;

        uint256 len = activeAssets.length;
        for (uint256 i = 0; i < len; ++i) {
            if (activeAssets[i] == assetId) {
                activeAssets[i] = activeAssets[len - 1];
                activeAssets.pop();
                break;
            }
        }

        emit AssetDelisted(assetId, uint40(block.timestamp));
    }

    function setChainlinkGuard(uint256 assetId, address feed, uint32 maxDeviation) external onlyOwner {
        if (securityMode >= MODE_PAUSED) revert InvalidState();
        if (maxDeviation > 100_000) revert InvalidInput(); // max 10%
        chainlinkGuards[assetId] = ChainlinkGuard({
            feed: feed,
            maxDeviation: maxDeviation
        });
        emit ChainlinkGuardUpdated(assetId, feed, maxDeviation, uint40(block.timestamp));
    }

    function setMarketClosed(uint256 assetId, bool closed) external onlyOwner {
        marketClosed[assetId] = closed;
        emit MarketStatusUpdated(assetId, closed, uint40(block.timestamp));
    }

    function setReferralRewardRate(uint256 newRate) external onlyOwner {
        if (securityMode >= MODE_PAUSED) revert InvalidState();
        if (newRate > PRECISION) revert InvalidInput();
        referralRewardRate = newRate;
    }

    function _trySetReferrer(address trader, address referrer) internal {
        if (
            referrer != address(0) && referrer != trader && !hasOpenedPosition[trader]
                && referrers[trader] == address(0)
        ) {
            referrers[trader] = referrer;
            referralRates[trader] = referralRewardRate;
            emit ReferrerSet(trader, referrer, referralRewardRate, uint40(block.timestamp));
        }
    }

    function claimReferralRewards() external nonReentrant {
        uint256 amount = referralRewards[msg.sender];
        if (amount == 0) revert InvalidState();

        referralRewards[msg.sender] = 0;
        if (!USDC.transfer(msg.sender, amount)) revert TransferFailed();
        emit ReferralRewardsClaimed(msg.sender, amount, uint40(block.timestamp));
    }

    function openMarket(MarketOrder calldata request, bytes[] calldata priceUpdateData)
        external
        nonReentrant
        returns (uint256 tradeId)
    {
        AssetState storage state = assetStates[request.assetId];
        if (!state.listed || securityMode != MODE_NORMAL || state.securityMode != MODE_NORMAL || marketClosed[request.assetId]) {
            revert InvalidState();
        }

        _validateOpeningInput(request.assetId, request.direction, request.collateral, request.leverage);
        _trySetReferrer(msg.sender, request.referrer);

        uint256 oraclePrice = _price(request.assetId, priceUpdateData);
        _updateBorrowIndexes(request.assetId);

        tradeId = nextTradeId++;
        trades[tradeId].orderType = ORDER_MARKET;

        (bool success, uint256 vaultCommission) = _initOpenPosition(
            tradeId,
            msg.sender,
            request.assetId,
            request.direction,
            uint8(request.leverage),
            request.collateral,
            oraclePrice,
            request.stopLoss,
            request.takeProfit
        );
        if (!success) revert InvalidState();

        emit TradeCreated(
            tradeId,
            msg.sender,
            request.assetId,
            request.direction,
            ORDER_MARKET,
            uint8(request.leverage),
            request.collateral,
            0,
            trades[tradeId].stopLoss,
            trades[tradeId].takeProfit,
            uint40(block.timestamp)
        );

        if (!USDC.transferFrom(msg.sender, address(this), request.collateral)) revert TransferFailed();
        if (vaultCommission != 0 && !USDC.transfer(address(vault), vaultCommission)) revert TransferFailed();
    }

    function openOrder(PendingOrder calldata request) external nonReentrant returns (uint256 tradeId) {
        AssetState storage state = assetStates[request.assetId];
        if (!state.listed || securityMode != MODE_NORMAL || state.securityMode != MODE_NORMAL || marketClosed[request.assetId]) {
            revert InvalidState();
        }

        _validateOpeningInput(request.assetId, request.direction, request.collateral, request.leverage);
        if (request.orderType != ORDER_LIMIT && request.orderType != ORDER_STOP) revert InvalidInput();
        if (request.targetPrice == 0 || request.targetPrice > type(uint64).max) revert InvalidInput();

        _trySetReferrer(msg.sender, request.referrer);

        uint256 liqPrice = _liquidationPrice(request.assetId, request.targetPrice, request.leverage, request.direction);
        (uint64 safeSL, uint64 safeTP) =
            _sanitizeStops(request.direction, request.targetPrice, liqPrice, request.stopLoss, request.takeProfit);

        tradeId = nextTradeId++;
        trades[tradeId] = Trade({
            trader: msg.sender,
            openTimestamp: _toUint40(block.timestamp),
            state: STATE_ORDER,
            direction: request.direction,
            orderType: request.orderType,
            leverage: _toUint8(request.leverage),
            margin: _toUint64(request.collateral),
            price: _toUint64(request.targetPrice),
            stopLoss: safeSL,
            takeProfit: safeTP,
            borrowIndexAtOpen: 0,
            assetId: request.assetId
        });

        emit TradeCreated(
            tradeId,
            msg.sender,
            request.assetId,
            request.direction,
            request.orderType,
            _toUint8(request.leverage),
            request.collateral,
            request.targetPrice,
            safeSL,
            safeTP,
            _toUint40(block.timestamp)
        );

        if (!USDC.transferFrom(msg.sender, address(this), request.collateral)) revert TransferFailed();
    }

    function cancel(uint256 tradeId) external nonReentrant {
        Trade storage trade = trades[tradeId];
        if (securityMode > MODE_CLOSE_ONLY || assetStates[trade.assetId].securityMode > MODE_CLOSE_ONLY) {
            revert InvalidState();
        }
        if (trade.trader != msg.sender) revert Unauthorized();
        if (trade.state != STATE_ORDER) revert InvalidState();
        if (block.timestamp < uint256(trade.openTimestamp) + 1 minutes) revert InvalidState();

        trade.state = STATE_CANCELLED;
        if (!USDC.transfer(trade.trader, trade.margin)) revert TransferFailed();
        emit OrderCancelled(tradeId, trade.margin, uint40(block.timestamp));
    }

    function setStops(uint256 tradeId, uint256 newSL, uint256 newTP) external {
        Trade storage trade = trades[tradeId];
        if (securityMode > MODE_CLOSE_ONLY || assetStates[trade.assetId].securityMode > MODE_CLOSE_ONLY) {
            revert InvalidState();
        }
        if (trade.trader != msg.sender) revert Unauthorized();
        if (trade.state != STATE_OPEN && trade.state != STATE_ORDER) revert InvalidState();

        uint256 liqPrice = _liquidationPrice(trade.assetId, trade.price, trade.leverage, trade.direction);
        (uint64 safeSL, uint64 safeTP) = _sanitizeStops(trade.direction, trade.price, liqPrice, newSL, newTP);

        trade.stopLoss = safeSL;
        trade.takeProfit = safeTP;
        emit StopsChanged(tradeId, safeSL, safeTP, uint40(block.timestamp));
    }

    function closeMarket(uint256 tradeId, bytes[] calldata priceUpdateData) external nonReentrant {
        Trade storage trade = trades[tradeId];
        if (securityMode > MODE_CLOSE_ONLY || assetStates[trade.assetId].securityMode > MODE_CLOSE_ONLY) {
            revert InvalidState();
        }
        if (trade.trader != msg.sender) revert Unauthorized();
        if (trade.state != STATE_OPEN) revert InvalidState();
        if (block.timestamp < uint256(trade.openTimestamp) + 1 minutes) revert InvalidState();

        uint256 oraclePrice = _price(trade.assetId, priceUpdateData);
        _closeTrade(tradeId, oraclePrice, CLOSE_MARKET);
    }

    function execute(bytes[] calldata priceUpdateData, uint256[] calldata tradeIds, uint8[] calldata reasons)
        external
        nonReentrant
    {
        if (securityMode > MODE_CLOSE_ONLY) revert InvalidState();
        if (tradeIds.length != reasons.length || tradeIds.length == 0) revert InvalidInput();

        if (priceUpdateData.length == 0) revert InvalidInput();

        uint256 firstTradeId = tradeIds[0];
        Trade storage firstTrade = trades[firstTradeId];
        if (firstTrade.trader == address(0)) revert InvalidInput();
        uint256 batchAssetId = firstTrade.assetId;

        if (assetStates[batchAssetId].securityMode > MODE_CLOSE_ONLY) revert InvalidState();

        ISupraOraclePull.PriceInfo memory info = supra.verifyOracleProofV2(priceUpdateData[0]);
        (uint256 oraclePrice, uint256 oracleTime) = _getPriceAndTimestampFromInfo(info, batchAssetId);
        _updateBorrowIndexes(batchAssetId);

        bool executed;
        for (uint256 i; i < tradeIds.length; ++i) {
            uint256 tradeId = tradeIds[i];
            Trade storage trade = trades[tradeId];
            if (trade.trader == address(0) || trade.assetId != batchAssetId) revert InvalidInput();

            if (_executeTriggered(tradeId, oraclePrice, oracleTime, reasons[i])) executed = true;
        }
        if (!executed) revert InvalidState();
    }

    function recover(uint256 tradeId) external nonReentrant {
        Trade storage trade = trades[tradeId];
        uint256 assetId = trade.assetId;
        if (securityMode != MODE_RECOVERY && assetStates[assetId].securityMode != MODE_RECOVERY) {
            revert InvalidState();
        }

        if (trade.trader != msg.sender) revert Unauthorized();
        if (trade.margin == 0 || (trade.state != STATE_ORDER && trade.state != STATE_OPEN)) revert InvalidState();

        if (trade.state == STATE_OPEN) {
            uint256 oi = uint256(trade.margin) * trade.leverage;
            _changeExposure(trade.trader, assetId, trade.direction, oi, false);
        }

        uint256 refundedMargin = trade.margin;
        trade.state = STATE_RECOVERED;
        if (!USDC.transfer(trade.trader, refundedMargin)) revert TransferFailed();
        emit TradeRecovered(tradeId, refundedMargin, uint40(block.timestamp));
    }

    function _executeTriggered(uint256 tradeId, uint256 oraclePrice, uint256 oracleTime, uint8 reason) internal returns (bool) {
        Trade storage trade = trades[tradeId];
        uint256 assetId = trade.assetId;

        if (trade.state == STATE_ORDER) {
            if (
                !assetStates[assetId].listed
                    || securityMode != MODE_NORMAL
                    || assetStates[assetId].securityMode != MODE_NORMAL
                    || reason != REASON_EXECUTION
                    || oracleTime < uint256(trade.openTimestamp)
            ) {
                return false;
            }

            bool orderTriggered;
            if (trade.orderType == ORDER_LIMIT) {
                orderTriggered = trade.direction == DIR_LONG ? oraclePrice <= trade.price : oraclePrice >= trade.price;
            } else if (trade.orderType == ORDER_STOP) {
                orderTriggered = trade.direction == DIR_LONG ? oraclePrice >= trade.price : oraclePrice <= trade.price;
            }
            return orderTriggered && _executeOrder(tradeId, oraclePrice);
        }

        if (trade.state != STATE_OPEN) return false;

        if (block.timestamp < uint256(trade.openTimestamp) + 1 minutes) {
            return false;
        }

        if (reason == REASON_LIQ) {
            if (!_isLiquidatable(trade, oraclePrice)) return false;
            _closeTrade(tradeId, oraclePrice, CLOSE_LIQUIDATION);
            return true;
        }

        if (reason == REASON_SL) {
            bool triggered = trade.stopLoss != 0
                && (trade.direction == DIR_LONG ? oraclePrice <= trade.stopLoss : oraclePrice >= trade.stopLoss);
            if (!triggered) return false;
            _closeTrade(tradeId, oraclePrice, CLOSE_STOP_LOSS);
            return true;
        }

        if (reason == REASON_TP) {
            bool triggered = trade.takeProfit != 0
                && (trade.direction == DIR_LONG ? oraclePrice >= trade.takeProfit : oraclePrice <= trade.takeProfit);
            if (!triggered) return false;
            _closeTrade(tradeId, oraclePrice, CLOSE_TAKE_PROFIT);
            return true;
        }

        return false;
    }

    function _initOpenPosition(
        uint256 tradeId,
        address trader,
        uint256 assetId,
        uint8 direction,
        uint8 leverage,
        uint256 collateral,
        uint256 oraclePrice,
        uint256 stopLoss,
        uint256 takeProfit
    ) internal returns (bool success, uint256 vaultCommission) {
        (uint256 margin, uint256 commission, uint256 oi) = _openingAmounts(assetId, collateral, leverage);
        if (margin > type(uint64).max || !_canOpen(trader, assetId, direction, oi)) return (false, 0);

        (uint256 entryPrice, uint256 openingSpread) = _entryPrice(assetId, oraclePrice, direction, oi);
        if (entryPrice > type(uint64).max) return (false, 0);

        uint256 liqPrice = _liquidationPrice(assetId, entryPrice, leverage, direction);
        (uint64 safeSL, uint64 safeTP) = _sanitizeStops(direction, entryPrice, liqPrice, stopLoss, takeProfit);

        vaultCommission = _handleCommission(trader, commission, tradeId);
        hasOpenedPosition[trader] = true;

        uint128 borrowSnapshot = _borrowIndexSnapshot(assetId, direction);
        Trade storage trade = trades[tradeId];
        trade.trader = trader;
        trade.openTimestamp = _toUint40(block.timestamp);
        trade.state = STATE_OPEN;
        trade.direction = direction;
        trade.leverage = leverage;
        trade.margin = _toUint64(margin);
        trade.price = _toUint64(entryPrice);
        trade.stopLoss = safeSL;
        trade.takeProfit = safeTP;
        trade.borrowIndexAtOpen = borrowSnapshot;
        trade.assetId = assetId;

        _changeExposure(trader, assetId, direction, oi, true);

        emit TradeOpened(
            tradeId,
            assetId,
            oraclePrice,
            entryPrice,
            openingSpread,
            commission,
            margin,
            oi,
            borrowSnapshot,
            uint40(block.timestamp)
        );
        return (true, vaultCommission);
    }

    function _executeOrder(uint256 tradeId, uint256 oraclePrice) internal returns (bool) {
        Trade storage trade = trades[tradeId];
        (bool success, uint256 vaultCommission) = _initOpenPosition(
            tradeId,
            trade.trader,
            trade.assetId,
            trade.direction,
            trade.leverage,
            trade.margin,
            oraclePrice,
            trade.stopLoss,
            trade.takeProfit
        );
        if (!success) return false;
        if (vaultCommission != 0 && !USDC.transfer(address(vault), vaultCommission)) revert TransferFailed();
        return true;
    }

    function lockedCapital() public view returns (uint256 totalLocked) {
        uint256 len = activeAssets.length;
        for (uint256 i = 0; i < len; ++i) {
            uint256 assetId = activeAssets[i];
            AssetState storage state = assetStates[assetId];
            if (state.listed && state.securityMode != MODE_RECOVERY) {
                uint256 dominantOI = state.openInterestLong > state.openInterestShort
                    ? state.openInterestLong
                    : state.openInterestShort;
                totalLocked += (dominantOI * assetConfigs[assetId].lockedCapitalRate) / PRECISION;
            }
        }
    }

    function assetLockedCapital(uint256 assetId) external view returns (uint256) {
        AssetState storage state = assetStates[assetId];
        uint256 dominantOI =
            state.openInterestLong > state.openInterestShort ? state.openInterestLong : state.openInterestShort;
        return (dominantOI * assetConfigs[assetId].lockedCapitalRate) / PRECISION;
    }

    function currentBorrowRates(uint256 assetId) external view returns (uint256 longRate, uint256 shortRate) {
        AssetState storage state = assetStates[assetId];
        return calculateBorrowRates(assetId, state.openInterestLong, state.openInterestShort);
    }

    function currentSpreads(uint256 assetId) external view returns (uint256 longSpread, uint256 shortSpread) {
        AssetState storage state = assetStates[assetId];
        return calculateSpreads(assetId, state.openInterestLong, state.openInterestShort);
    }

    function previewBorrowFee(uint256 tradeId) external view returns (uint256) {
        Trade storage trade = trades[tradeId];
        if (trade.state != STATE_OPEN) revert InvalidState();

        uint256 assetId = trade.assetId;
        (uint256 previewLongIndex, uint256 previewShortIndex) = _previewBorrowIndexes(assetId);
        uint256 currentIndex = trade.direction == DIR_LONG ? previewLongIndex : previewShortIndex;
        uint256 oi = uint256(trade.margin) * trade.leverage;
        return _borrowFee(trade.borrowIndexAtOpen, currentIndex, oi);
    }

    function dynamicMaxOI(uint256 assetId) public view returns (uint256 maxOILong, uint256 maxOIShort) {
        AssetState storage state = assetStates[assetId];
        AssetConfig storage config = assetConfigs[assetId];

        maxOILong = state.openInterestShort + config.maxSkew;
        if (maxOILong > config.maxOpenInterest) maxOILong = config.maxOpenInterest;

        maxOIShort = state.openInterestLong + config.maxSkew;
        if (maxOIShort > config.maxOpenInterest) maxOIShort = config.maxOpenInterest;
    }

    function _canOpen(address trader, uint256 assetId, uint8 direction, uint256 oi) internal view returns (bool) {
        AssetState storage state = assetStates[assetId];
        if (!state.listed) return false;
        AssetConfig storage config = assetConfigs[assetId];

        uint256 newLong = state.openInterestLong + (direction == DIR_LONG ? oi : 0);
        uint256 newShort = state.openInterestShort + (direction == DIR_SHORT ? oi : 0);

        (uint256 maxOILong, uint256 maxOIShort) = dynamicMaxOI(assetId);

        if (direction == DIR_LONG && newLong > maxOILong) return false;
        if (direction == DIR_SHORT && newShort > maxOIShort) return false;
        if (traderAssetOI[assetId][trader] + oi > config.maxTraderOI) return false;

        uint256 currentDominant =
            state.openInterestLong > state.openInterestShort ? state.openInterestLong : state.openInterestShort;
        uint256 newDominant = newLong > newShort ? newLong : newShort;
        uint256 currentAssetLocked = (currentDominant * config.lockedCapitalRate) / PRECISION;
        uint256 newAssetLocked = (newDominant * config.lockedCapitalRate) / PRECISION;
        uint256 additionalLocked = newAssetLocked > currentAssetLocked ? newAssetLocked - currentAssetLocked : 0;

        if (lockedCapital() + additionalLocked > USDC.balanceOf(address(vault))) return false;

        return true;
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function calculateSpreads(uint256 assetId, uint256 longOI, uint256 shortOI)
        public
        view
        returns (uint256 longSpread, uint256 shortSpread)
    {
        AssetConfig storage config = assetConfigs[assetId];
        if (longOI == shortOI) {
            return (config.minSpread, config.minSpread);
        }

        uint256 skew = longOI > shortOI ? longOI - shortOI : shortOI - longOI;
        uint256 vaultLiquidity = USDC.balanceOf(address(vault));
        uint256 depth = vaultLiquidity + longOI + shortOI + config.spreadVirtualOI;
        if (depth == 0) return (config.minSpread, config.minSpread);

        uint256 skewRatio = (skew * PRECISION) / depth;
        if (skewRatio > PRECISION) skewRatio = PRECISION;

        uint256 riskFactor = _sqrt(skewRatio * PRECISION);

        uint256 penalty = (config.maxSpreadPenalty * riskFactor) / PRECISION;
        uint256 discount = (config.maxSpreadDiscount * riskFactor) / PRECISION;

        uint256 dominantSpread = config.minSpread + penalty;
        if (dominantSpread > config.maxSpread) dominantSpread = config.maxSpread;

        uint256 minoritySpread = config.minSpread > discount ? config.minSpread - discount : 0;

        if (longOI > shortOI) {
            longSpread = dominantSpread;
            shortSpread = minoritySpread;
        } else {
            longSpread = minoritySpread;
            shortSpread = dominantSpread;
        }
    }

    function calculateBorrowRates(uint256 assetId, uint256 longOI, uint256 shortOI)
        public
        view
        returns (uint256 longRate, uint256 shortRate)
    {
        AssetConfig storage config = assetConfigs[assetId];
        if (longOI == shortOI) {
            return (config.baseBorrowRateHourly, config.baseBorrowRateHourly);
        }

        uint256 dominantOI = longOI > shortOI ? longOI : shortOI;
        uint256 minorityOI = longOI > shortOI ? shortOI : longOI;
        uint256 skew = dominantOI - minorityOI;

        uint256 risk = (skew * config.maxProfitRate) / PRECISION;

        uint256 totalRecoveryHours = config.recoveryTimeDays * 24;
        if (totalRecoveryHours == 0) totalRecoveryHours = 168;

        uint256 hourlyTarget = risk / totalRecoveryHours;
        uint256 effectiveOI = dominantOI + config.borrowVirtualOI;
        uint256 dominantBorrow = effectiveOI != 0 ? (hourlyTarget * PRECISION) / effectiveOI : 0;

        uint256 dominantRate = config.baseBorrowRateHourly + dominantBorrow;
        if (dominantRate > config.maxBorrowRateHourly) dominantRate = config.maxBorrowRateHourly;

        if (longOI > shortOI) {
            longRate = dominantRate;
            shortRate = config.baseBorrowRateHourly;
        } else {
            longRate = config.baseBorrowRateHourly;
            shortRate = dominantRate;
        }
    }

    function _changeExposure(address trader, uint256 assetId, uint8 direction, uint256 oi, bool increase) internal {
        AssetState storage state = assetStates[assetId];
        if (increase) {
            if (direction == DIR_LONG) {
                state.openInterestLong += oi;
            } else {
                state.openInterestShort += oi;
            }
            traderAssetOI[assetId][trader] += oi;
            return;
        }

        if (direction == DIR_LONG) {
            state.openInterestLong -= oi;
        } else {
            state.openInterestShort -= oi;
        }
        traderAssetOI[assetId][trader] -= oi;
    }

    function _closeTrade(uint256 tradeId, uint256 oraclePrice, uint8 closeMethod) internal {
        Trade storage trade = trades[tradeId];
        if (trade.state != STATE_OPEN) revert InvalidState();

        uint256 assetId = trade.assetId;
        _updateBorrowIndexes(assetId);

        uint256 margin = trade.margin;
        uint256 oi = margin * trade.leverage;

        AssetState storage state = assetStates[assetId];
        AssetConfig storage config = assetConfigs[assetId];

        uint256 postLong = state.openInterestLong >= (trade.direction == DIR_LONG ? oi : 0)
            ? state.openInterestLong - (trade.direction == DIR_LONG ? oi : 0)
            : 0;
        uint256 postShort = state.openInterestShort >= (trade.direction == DIR_SHORT ? oi : 0)
            ? state.openInterestShort - (trade.direction == DIR_SHORT ? oi : 0)
            : 0;
        (uint256 longSpread, uint256 shortSpread) =
            calculateSpreads(assetId, postLong, postShort);
        uint256 closingSpread = trade.direction == DIR_LONG ? shortSpread : longSpread;
        uint256 spreadAmount = (oraclePrice * closingSpread) / PRECISION;
        uint256 closePrice = trade.direction == DIR_LONG ? oraclePrice - spreadAmount : oraclePrice + spreadAmount;

        int256 grossPnl = _pnl(oi, trade.price, closePrice, trade.direction);
        uint256 currentIndex = trade.direction == DIR_LONG ? state.longBorrowIndex : state.shortBorrowIndex;
        uint256 borrowFee = _borrowFee(trade.borrowIndexAtOpen, currentIndex, oi);
        int256 netPnl = grossPnl - int256(borrowFee);

        bool liquidated = closeMethod == CLOSE_LIQUIDATION;
        int256 realizedPnl = liquidated ? -int256(margin) : netPnl;
        if (realizedPnl < -int256(margin)) realizedPnl = -int256(margin);
        uint256 maxProfit = (oi * config.maxProfitRate) / PRECISION;
        if (realizedPnl > int256(maxProfit)) realizedPnl = int256(maxProfit);
        uint256 traderPayout = realizedPnl >= 0 ? margin + uint256(realizedPnl) : margin - uint256(-realizedPnl);

        trade.state = liquidated ? STATE_LIQUIDATED : STATE_CLOSED;
        _changeExposure(trade.trader, assetId, trade.direction, oi, false);
        _settle(trade.trader, margin, realizedPnl);

        emit TradeClosed(
            tradeId,
            assetId,
            closeMethod,
            oraclePrice,
            closePrice,
            closingSpread,
            grossPnl,
            borrowFee,
            realizedPnl,
            traderPayout,
            uint40(block.timestamp)
        );
    }

    function _updateBorrowIndexes(uint256 assetId) internal {
        AssetState storage state = assetStates[assetId];
        uint256 elapsed = block.timestamp - state.lastBorrowUpdate;
        if (elapsed == 0) return;

        (uint256 longRate, uint256 shortRate) =
            calculateBorrowRates(assetId, state.openInterestLong, state.openInterestShort);
        state.longBorrowIndex += (longRate * elapsed * BORROW_INDEX_RATE_SCALE) / 1 hours;
        state.shortBorrowIndex += (shortRate * elapsed * BORROW_INDEX_RATE_SCALE) / 1 hours;
        state.lastBorrowUpdate = block.timestamp;
    }

    function _previewBorrowIndexes(uint256 assetId)
        internal
        view
        returns (uint256 previewLongIndex, uint256 previewShortIndex)
    {
        AssetState storage state = assetStates[assetId];
        previewLongIndex = state.longBorrowIndex;
        previewShortIndex = state.shortBorrowIndex;
        uint256 elapsed = block.timestamp - state.lastBorrowUpdate;
        if (elapsed == 0) return (previewLongIndex, previewShortIndex);

        (uint256 longRate, uint256 shortRate) =
            calculateBorrowRates(assetId, state.openInterestLong, state.openInterestShort);
        previewLongIndex += (longRate * elapsed * BORROW_INDEX_RATE_SCALE) / 1 hours;
        previewShortIndex += (shortRate * elapsed * BORROW_INDEX_RATE_SCALE) / 1 hours;
    }

    function _borrowIndexSnapshot(uint256 assetId, uint8 direction) internal view returns (uint128 snapshot) {
        AssetState storage state = assetStates[assetId];
        uint256 index = direction == DIR_LONG ? state.longBorrowIndex : state.shortBorrowIndex;
        if (index > type(uint128).max) revert InvalidState();
        snapshot = uint128(index);
    }

    function _borrowFee(uint128 borrowIndexAtOpen, uint256 currentIndex, uint256 oi) internal pure returns (uint256) {
        uint256 indexDelta = currentIndex - uint256(borrowIndexAtOpen);
        return (oi * indexDelta) / BORROW_INDEX_PRECISION;
    }

    function _settle(address trader, uint256 margin, int256 pnl) internal {
        if (pnl >= 0) {
            if (!USDC.transfer(trader, margin)) revert TransferFailed();
            uint256 profit = uint256(pnl);
            if (profit != 0) vault.payTrader(trader, profit);
            return;
        }

        uint256 loss = uint256(-pnl);
        if (!USDC.transfer(address(vault), loss)) revert TransferFailed();
        uint256 traderPayout = margin - loss;
        if (traderPayout != 0 && !USDC.transfer(trader, traderPayout)) revert TransferFailed();
    }

    function _entryPrice(uint256 assetId, uint256 oraclePrice, uint8 direction, uint256 oi)
        internal
        view
        returns (uint256 entryPrice, uint256 openingSpread)
    {
        AssetState storage state = assetStates[assetId];
        uint256 postLong = state.openInterestLong + (direction == DIR_LONG ? oi : 0);
        uint256 postShort = state.openInterestShort + (direction == DIR_SHORT ? oi : 0);
        (uint256 longSpread, uint256 shortSpread) =
            calculateSpreads(assetId, postLong, postShort);
        openingSpread = direction == DIR_LONG ? longSpread : shortSpread;
        uint256 amount = (oraclePrice * openingSpread) / PRECISION;
        entryPrice = direction == DIR_LONG ? oraclePrice + amount : oraclePrice - amount;
    }

    function _liquidationPrice(uint256 assetId, uint256 openPrice, uint256 leverage, uint8 direction)
        internal
        view
        returns (uint256)
    {
        uint256 move = (openPrice * assetConfigs[assetId].liquidationThreshold) / (leverage * PRECISION);
        return direction == DIR_LONG ? openPrice - move : openPrice + move;
    }

    function _isLiquidatable(Trade storage trade, uint256 oraclePrice) internal view returns (bool) {
        uint256 assetId = trade.assetId;
        AssetState storage state = assetStates[assetId];
        AssetConfig storage config = assetConfigs[assetId];

        uint256 margin = trade.margin;
        uint256 oi = margin * trade.leverage;
        int256 pricePnl = _pnl(oi, trade.price, oraclePrice, trade.direction);
        uint256 currentIndex = trade.direction == DIR_LONG ? state.longBorrowIndex : state.shortBorrowIndex;
        uint256 borrowFee = _borrowFee(trade.borrowIndexAtOpen, currentIndex, oi);

        int256 remainingMargin = int256(margin) + pricePnl - int256(borrowFee);
        uint256 minimumRemainingMargin = margin - ((margin * config.liquidationThreshold) / PRECISION);
        return remainingMargin <= int256(minimumRemainingMargin);
    }

    function _pnl(uint256 oi, uint256 openPrice, uint256 closePrice, uint8 direction) internal pure returns (int256) {
        int256 diff =
            direction == DIR_LONG ? int256(closePrice) - int256(openPrice) : int256(openPrice) - int256(closePrice);
        return (int256(oi) * diff) / int256(openPrice);
    }

    function _openingAmounts(uint256 assetId, uint256 collateral, uint256 leverage)
        internal
        view
        returns (uint256 margin, uint256 commission, uint256 oi)
    {
        commission = (collateral * leverage * assetConfigs[assetId].commissionRate) / PRECISION;
        if (commission >= collateral) revert InvalidInput();
        margin = collateral - commission;
        if (margin > type(uint64).max) revert InvalidInput();
        oi = margin * leverage;
    }

    function _handleCommission(address trader, uint256 commission, uint256 tradeId)
        internal
        returns (uint256 vaultCommission)
    {
        if (commission == 0) return 0;

        address referrer = referrers[trader];
        uint256 referralRate = referralRates[trader];
        if (referrer != address(0) && referralRate != 0) {
            uint256 referralReward = (commission * referralRate) / PRECISION;
            vaultCommission = commission - referralReward;

            if (referralReward != 0) {
                referralRewards[referrer] += referralReward;
                emit ReferralRewardAccrued(referrer, trader, tradeId, referralReward, uint40(block.timestamp));
            }
        } else {
            vaultCommission = commission;
        }
    }

    function _validateOpeningInput(uint256 assetId, uint8 direction, uint256 collateral, uint256 leverage)
        internal
        view
    {
        AssetConfig storage config = assetConfigs[assetId];
        if (
            (direction != DIR_LONG && direction != DIR_SHORT) || collateral < config.minTradeSize
                || collateral > type(uint64).max || leverage < config.minLeverage || leverage > config.maxLeverage
        ) revert InvalidInput();
    }

    function _sanitizeStops(
        uint8 direction,
        uint256 entryPrice,
        uint256 liqPrice,
        uint256 slPrice,
        uint256 tpPrice
    ) internal pure returns (uint64 safeSL, uint64 safeTP) {
        if (slPrice != 0 && slPrice <= type(uint64).max) {
            if (direction == DIR_LONG) {
                if (slPrice < entryPrice && slPrice >= liqPrice) safeSL = uint64(slPrice);
            } else {
                if (slPrice > entryPrice && slPrice <= liqPrice) safeSL = uint64(slPrice);
            }
        }

        if (tpPrice != 0 && tpPrice <= type(uint64).max) {
            if (direction == DIR_LONG) {
                if (tpPrice > entryPrice) safeTP = uint64(tpPrice);
            } else {
                if (tpPrice < entryPrice) safeTP = uint64(tpPrice);
            }
        }
    }

    function _getPriceAndTimestampFromInfo(ISupraOraclePull.PriceInfo memory info, uint256 assetId)
        internal
        view
        returns (uint256 normalizedPrice, uint256 oracleTime)
    {
        for (uint256 i = 0; i < info.pairs.length; i++) {
            if (info.pairs[i] == assetId) {
                oracleTime = info.timestamp[i];
                if (oracleTime > 1e11) {
                    oracleTime = oracleTime / 1000;
                }

                if (oracleTime > block.timestamp) {
                    if (oracleTime - block.timestamp > MAX_FUTURE_ORACLE_DRIFT) revert OracleUncertain();
                } else {
                    if (block.timestamp - oracleTime > MAX_PROOF_AGE) revert OracleUncertain();
                }

                uint256 rawPrice = info.prices[i];
                if (rawPrice == 0) revert OracleUncertain();

                uint256 decimals = info.decimal[i];
                if (decimals == 6) {
                    normalizedPrice = rawPrice;
                } else if (decimals < 6) {
                    normalizedPrice = rawPrice * (10 ** (6 - decimals));
                } else {
                    normalizedPrice = rawPrice / (10 ** (decimals - 6));
                }

                if (normalizedPrice == 0) revert OracleUncertain();
                _checkChainlinkSanity(assetId, normalizedPrice);
                return (normalizedPrice, oracleTime);
            }
        }
        revert InvalidInput();
    }

    function _checkChainlinkSanity(uint256 assetId, uint256 supraPrice) internal view {
        ChainlinkGuard memory guard = chainlinkGuards[assetId];
        if (guard.feed == address(0)) return;

        try IChainlinkAggregator(guard.feed).latestRoundData() returns (
            uint80,
            int256 answer,
            uint256,
            uint256 updatedAt,
            uint80
        ) {
            if (
                answer <= 0 ||
                updatedAt == 0 ||
                block.timestamp > updatedAt + 25 hours ||
                updatedAt > block.timestamp + 5 minutes
            ) revert OracleUncertain();

            uint8 clDecimals = 8;
            try IChainlinkAggregator(guard.feed).decimals() returns (uint8 dec) {
                clDecimals = dec;
            } catch {
                revert OracleUncertain();
            }

            uint256 chainlinkPrice;
            if (clDecimals == 6) {
                chainlinkPrice = uint256(answer);
            } else if (clDecimals > 6) {
                chainlinkPrice = uint256(answer) / (10 ** (clDecimals - 6));
            } else {
                chainlinkPrice = uint256(answer) * (10 ** (6 - clDecimals));
            }

            if (chainlinkPrice == 0) revert OracleUncertain();

            uint256 diff = supraPrice > chainlinkPrice ? supraPrice - chainlinkPrice : chainlinkPrice - supraPrice;
            uint256 divergence = (diff * PRECISION) / chainlinkPrice;

            uint32 maxDev = guard.maxDeviation == 0 ? 15_000 : guard.maxDeviation;
            if (divergence > maxDev) revert OracleUncertain();
        } catch {
            revert OracleUncertain();
        }
    }

    function _getPriceFromInfo(ISupraOraclePull.PriceInfo memory info, uint256 assetId) internal view returns (uint256) {
        (uint256 normalizedPrice, ) = _getPriceAndTimestampFromInfo(info, assetId);
        return normalizedPrice;
    }

    function _price(uint256 assetId, bytes[] calldata priceUpdateData) internal returns (uint256) {
        if (priceUpdateData.length == 0) revert InvalidInput();
        ISupraOraclePull.PriceInfo memory info = supra.verifyOracleProofV2(priceUpdateData[0]);
        return _getPriceFromInfo(info, assetId);
    }

    function _toUint64(uint256 value) internal pure returns (uint64) {
        if (value > type(uint64).max) revert InvalidInput();
        return uint64(value);
    }

    function _toUint40(uint256 value) internal pure returns (uint40) {
        if (value > type(uint40).max) revert InvalidInput();
        return uint40(value);
    }

    function _toUint8(uint256 value) internal pure returns (uint8) {
        if (value > type(uint8).max) revert InvalidInput();
        return uint8(value);
    }
}
