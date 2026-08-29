// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./IERC20.sol";

interface IBrokexCoreLens {
    struct AssetConfig {
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 minTradeSize;
        uint256 commissionRate;
        uint256 maxTraderOI;
        uint256 maxOpenInterest;
        uint256 maxSkew;
        uint256 minSpread;
        uint256 maxSpread;
        uint256 spreadVirtualOI;
        uint256 maxSpreadPenalty;
        uint256 maxSpreadDiscount;
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

    function trades(uint256 tradeId)
        external
        view
        returns (
            address trader,
            uint40 openTimestamp,
            uint8 state,
            uint8 direction,
            uint8 orderType,
            uint8 leverage,
            uint64 margin,
            uint64 price,
            uint64 stopLoss,
            uint64 takeProfit,
            uint128 borrowIndexAtOpen,
            uint256 assetId
        );

    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function USDC() external view returns (address);
    function supra() external view returns (address);
    function vault() external view returns (address);
    function securityMode() external view returns (uint8);
    function nextTradeId() external view returns (uint256);
    function lockedCapital() external view returns (uint256);
    function assetLockedCapital(uint256 assetId) external view returns (uint256);
    function getActiveAssets() external view returns (uint256[] memory);
    function getAssetCount() external view returns (uint256);
    function assetConfigs(uint256 assetId) external view returns (AssetConfig memory);
    function assetStates(uint256 assetId) external view returns (AssetState memory);
    function currentBorrowRates(uint256 assetId) external view returns (uint256 longRate, uint256 shortRate);
    function currentSpreads(uint256 assetId) external view returns (uint256 longSpread, uint256 shortSpread);
    function dynamicMaxOI(uint256 assetId) external view returns (uint256 maxOILong, uint256 maxOIShort);
    function calculateSpreads(uint256 assetId, uint256 longOI, uint256 shortOI)
        external
        view
        returns (uint256 longSpread, uint256 shortSpread);
    function calculateBorrowRates(uint256 assetId, uint256 longOI, uint256 shortOI)
        external
        view
        returns (uint256 longRate, uint256 shortRate);
    function previewBorrowFee(uint256 tradeId) external view returns (uint256);
}

contract BrokexLens {
    uint256 public constant MAX_BATCH_SIZE = 500;
    uint256 internal constant PRECISION = 1e6;
    uint256 internal constant BORROW_INDEX_RATE_SCALE = 1e12;
    uint8 internal constant STATE_OPEN = 1;
    uint8 internal constant DIR_LONG = 1;

    IBrokexCoreLens public immutable core;

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

    struct TradeState {
        bool exists;
        uint8 state;
    }

    struct Stops {
        uint64 stopLoss;
        uint64 takeProfit;
    }

    struct LiquidationInfo {
        bool exists;
        bool open;
        uint256 liquidationPrice;
        uint256 borrowFee;
    }

    struct CurrentRates {
        uint256 longBorrowRateHourly;
        uint256 shortBorrowRateHourly;
        uint256 longSpread;
        uint256 shortSpread;
    }

    struct EstimatedSpreads {
        uint256 longSpread;
        uint256 shortSpread;
        uint256 tradeSpread;
    }

    struct CurrentBorrowIndexes {
        uint256 longIndex;
        uint256 shortIndex;
    }

    struct AssetInfo {
        uint256 assetId;
        bool listed;
        uint8 securityMode;
        uint256 minLeverage;
        uint256 maxLeverage;
        uint256 minTradeSize;
        uint256 commissionRate;
        uint256 maxTraderOI;
        uint256 maxOpenInterest;
        uint256 maxSkew;
        uint256 dynamicMaxOILong;
        uint256 dynamicMaxOIShort;
        uint256 minSpread;
        uint256 maxSpread;
        uint256 spreadVirtualOI;
        uint256 maxSpreadPenalty;
        uint256 maxSpreadDiscount;
        uint256 baseBorrowRateHourly;
        uint256 maxBorrowRateHourly;
        uint256 borrowVirtualOI;
        uint256 currentLongBorrowRate;
        uint256 currentShortBorrowRate;
        uint256 currentLongSpread;
        uint256 currentShortSpread;
        uint256 lockedCapitalRate;
        uint256 liquidationThreshold;
        uint256 maxProfitRate;
        uint256 recoveryTimeDays;
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 assetLockedCapital;
        uint256 longBorrowIndex;
        uint256 shortBorrowIndex;
        uint256 currentLongBorrowIndex;
        uint256 currentShortBorrowIndex;
        uint256 lastBorrowUpdate;
    }

    struct ProtocolInfo {
        address owner;
        address pendingOwner;
        address usdc;
        address supra;
        address vault;
        uint256 lockedCapital;
        uint256 vaultBalance;
        uint256 latestTradeId;
        uint8 securityMode;
        uint256[] activeAssets;
    }

    error InvalidCore();
    error InvalidRange();
    error BatchTooLarge();

    constructor(address coreAddress) {
        if (coreAddress == address(0) || coreAddress.code.length == 0) revert InvalidCore();
        core = IBrokexCoreLens(coreAddress);
    }

    function getTradesByIds(uint256[] calldata tradeIds) external view returns (Trade[] memory result) {
        _validateBatch(tradeIds.length);
        result = new Trade[](tradeIds.length);
        for (uint256 i; i < tradeIds.length; ++i) result[i] = _trade(tradeIds[i]);
    }

    function getTradesByRange(uint256 fromId, uint256 toId) external view returns (Trade[] memory result) {
        uint256 length = _rangeLength(fromId, toId);
        result = new Trade[](length);
        for (uint256 i; i < length; ++i) result[i] = _trade(fromId + i);
    }

    function getStatesByIds(uint256[] calldata tradeIds) external view returns (TradeState[] memory result) {
        _validateBatch(tradeIds.length);
        result = new TradeState[](tradeIds.length);
        for (uint256 i; i < tradeIds.length; ++i) {
            Trade memory trade = _trade(tradeIds[i]);
            result[i] = TradeState(trade.trader != address(0), trade.state);
        }
    }

    function getStatesByRange(uint256 fromId, uint256 toId) external view returns (TradeState[] memory result) {
        uint256 length = _rangeLength(fromId, toId);
        result = new TradeState[](length);
        for (uint256 i; i < length; ++i) {
            Trade memory trade = _trade(fromId + i);
            result[i] = TradeState(trade.trader != address(0), trade.state);
        }
    }

    function getStopsByIds(uint256[] calldata tradeIds) external view returns (Stops[] memory result) {
        _validateBatch(tradeIds.length);
        result = new Stops[](tradeIds.length);
        for (uint256 i; i < tradeIds.length; ++i) {
            Trade memory trade = _trade(tradeIds[i]);
            result[i] = Stops(trade.stopLoss, trade.takeProfit);
        }
    }

    function getStopsByRange(uint256 fromId, uint256 toId) external view returns (Stops[] memory result) {
        uint256 length = _rangeLength(fromId, toId);
        result = new Stops[](length);
        for (uint256 i; i < length; ++i) {
            Trade memory trade = _trade(fromId + i);
            result[i] = Stops(trade.stopLoss, trade.takeProfit);
        }
    }

    function getLiquidationsByIds(uint256[] calldata tradeIds)
        external
        view
        returns (LiquidationInfo[] memory result)
    {
        _validateBatch(tradeIds.length);
        result = new LiquidationInfo[](tradeIds.length);
        for (uint256 i; i < tradeIds.length; ++i) result[i] = _liquidation(tradeIds[i]);
    }

    function getLiquidationsByRange(uint256 fromId, uint256 toId)
        external
        view
        returns (LiquidationInfo[] memory result)
    {
        uint256 length = _rangeLength(fromId, toId);
        result = new LiquidationInfo[](length);
        for (uint256 i; i < length; ++i) result[i] = _liquidation(fromId + i);
    }

    function latestTradeId() public view returns (uint256) {
        uint256 nextId = core.nextTradeId();
        return nextId == 0 ? 0 : nextId - 1;
    }

    function getCurrentRates(uint256 assetId) external view returns (CurrentRates memory rates) {
        (rates.longBorrowRateHourly, rates.shortBorrowRateHourly) = core.currentBorrowRates(assetId);
        (rates.longSpread, rates.shortSpread) = core.currentSpreads(assetId);
    }

    function getEstimatedSpreads(
        uint256 assetId,
        uint8 direction,
        uint256 oi,
        bool isOpening
    ) external view returns (EstimatedSpreads memory spreads) {
        IBrokexCoreLens.AssetState memory state = core.assetStates(assetId);
        uint256 postLong = state.openInterestLong;
        uint256 postShort = state.openInterestShort;

        if (isOpening) {
            if (direction == DIR_LONG) {
                postLong += oi;
            } else {
                postShort += oi;
            }
        } else {
            if (direction == DIR_LONG) {
                postLong = postLong >= oi ? postLong - oi : 0;
            } else {
                postShort = postShort >= oi ? postShort - oi : 0;
            }
        }

        (spreads.longSpread, spreads.shortSpread) = core.calculateSpreads(assetId, postLong, postShort);

        if (isOpening) {
            spreads.tradeSpread = direction == DIR_LONG ? spreads.longSpread : spreads.shortSpread;
        } else {
            spreads.tradeSpread = direction == DIR_LONG ? spreads.shortSpread : spreads.longSpread;
        }
    }

    function getCurrentBorrowIndexes(uint256 assetId) public view returns (CurrentBorrowIndexes memory indexes) {
        IBrokexCoreLens.AssetState memory state = core.assetStates(assetId);
        indexes.longIndex = state.longBorrowIndex;
        indexes.shortIndex = state.shortBorrowIndex;

        uint256 elapsed = block.timestamp - state.lastBorrowUpdate;
        if (elapsed == 0) return indexes;

        (uint256 longRate, uint256 shortRate) = core.currentBorrowRates(assetId);
        indexes.longIndex += (longRate * elapsed * BORROW_INDEX_RATE_SCALE) / 1 hours;
        indexes.shortIndex += (shortRate * elapsed * BORROW_INDEX_RATE_SCALE) / 1 hours;
    }

    function getAssetInfo(uint256 assetId) public view returns (AssetInfo memory info) {
        IBrokexCoreLens.AssetConfig memory config = core.assetConfigs(assetId);
        IBrokexCoreLens.AssetState memory state = core.assetStates(assetId);

        info.assetId = assetId;
        info.listed = state.listed;
        info.securityMode = state.securityMode;
        info.minLeverage = config.minLeverage;
        info.maxLeverage = config.maxLeverage;
        info.minTradeSize = config.minTradeSize;
        info.commissionRate = config.commissionRate;
        info.maxTraderOI = config.maxTraderOI;
        info.maxOpenInterest = config.maxOpenInterest;
        info.maxSkew = config.maxSkew;
        (info.dynamicMaxOILong, info.dynamicMaxOIShort) = core.dynamicMaxOI(assetId);
        info.minSpread = config.minSpread;
        info.maxSpread = config.maxSpread;
        info.spreadVirtualOI = config.spreadVirtualOI;
        info.maxSpreadPenalty = config.maxSpreadPenalty;
        info.maxSpreadDiscount = config.maxSpreadDiscount;
        info.baseBorrowRateHourly = config.baseBorrowRateHourly;
        info.maxBorrowRateHourly = config.maxBorrowRateHourly;
        info.borrowVirtualOI = config.borrowVirtualOI;
        (info.currentLongBorrowRate, info.currentShortBorrowRate) = core.currentBorrowRates(assetId);
        (info.currentLongSpread, info.currentShortSpread) = core.currentSpreads(assetId);
        info.lockedCapitalRate = config.lockedCapitalRate;
        info.liquidationThreshold = config.liquidationThreshold;
        info.maxProfitRate = config.maxProfitRate;
        info.recoveryTimeDays = config.recoveryTimeDays;
        info.openInterestLong = state.openInterestLong;
        info.openInterestShort = state.openInterestShort;
        info.assetLockedCapital = core.assetLockedCapital(assetId);
        info.longBorrowIndex = state.longBorrowIndex;
        info.shortBorrowIndex = state.shortBorrowIndex;
        CurrentBorrowIndexes memory currentIndexes = getCurrentBorrowIndexes(assetId);
        info.currentLongBorrowIndex = currentIndexes.longIndex;
        info.currentShortBorrowIndex = currentIndexes.shortIndex;
        info.lastBorrowUpdate = state.lastBorrowUpdate;
    }

    function getAllAssetsInfo() external view returns (AssetInfo[] memory assets) {
        uint256[] memory active = core.getActiveAssets();
        assets = new AssetInfo[](active.length);
        for (uint256 i; i < active.length; ++i) {
            assets[i] = getAssetInfo(active[i]);
        }
    }

    function getProtocolInfo() external view returns (ProtocolInfo memory info) {
        info.owner = core.owner();
        info.pendingOwner = core.pendingOwner();
        info.usdc = core.USDC();
        info.supra = core.supra();
        info.vault = core.vault();
        info.lockedCapital = core.lockedCapital();
        info.vaultBalance = IERC20(info.usdc).balanceOf(info.vault);
        info.latestTradeId = latestTradeId();
        info.securityMode = core.securityMode();
        info.activeAssets = core.getActiveAssets();
    }

    function _trade(uint256 tradeId) internal view returns (Trade memory trade) {
        (
            trade.trader,
            trade.openTimestamp,
            trade.state,
            trade.direction,
            trade.orderType,
            trade.leverage,
            trade.margin,
            trade.price,
            trade.stopLoss,
            trade.takeProfit,
            trade.borrowIndexAtOpen,
            trade.assetId
        ) = core.trades(tradeId);
    }

    function _liquidation(uint256 tradeId) internal view returns (LiquidationInfo memory info) {
        Trade memory trade = _trade(tradeId);
        info.exists = trade.trader != address(0);
        info.open = trade.state == STATE_OPEN;
        if (!info.open) return info;

        info.borrowFee = core.previewBorrowFee(tradeId);
        IBrokexCoreLens.AssetConfig memory config = core.assetConfigs(trade.assetId);
        uint256 liquidationLoss = (uint256(trade.margin) * config.liquidationThreshold) / PRECISION;
        uint256 oi = uint256(trade.margin) * trade.leverage;

        if (info.borrowFee <= liquidationLoss) {
            uint256 move = (uint256(trade.price) * (liquidationLoss - info.borrowFee)) / oi;
            info.liquidationPrice =
                trade.direction == DIR_LONG ? uint256(trade.price) - move : uint256(trade.price) + move;
        } else {
            uint256 move = (uint256(trade.price) * (info.borrowFee - liquidationLoss)) / oi;
            if (trade.direction == DIR_LONG) info.liquidationPrice = uint256(trade.price) + move;
            else info.liquidationPrice = move >= trade.price ? 0 : uint256(trade.price) - move;
        }
    }

    function _rangeLength(uint256 fromId, uint256 toId) internal pure returns (uint256 length) {
        if (fromId == 0 || toId < fromId) revert InvalidRange();
        length = toId - fromId + 1;
        _validateBatch(length);
    }

    function _validateBatch(uint256 length) internal pure {
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();
    }
}
