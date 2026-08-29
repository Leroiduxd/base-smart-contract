// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BrokexCore} from "../BrokexCore.sol";
import {BrokexVault} from "../BrokexVault.sol";
import {BrokexLens} from "../BrokexLens.sol";

contract MockUSDC {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "ERC20: transfer amount exceeds balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "ERC20: insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockSupra {
    struct PriceInfo {
        uint256[] pairs;
        uint256[] prices;
        uint256[] timestamp;
        uint256[] decimal;
        uint256[] round;
    }

    uint256[] public activePairs;
    mapping(uint256 => uint256) public prices;
    mapping(uint256 => uint256) public timestamps;

    function setPrice(uint256 assetId, uint256 p) external {
        if (prices[assetId] == 0) activePairs.push(assetId);
        prices[assetId] = p;
        timestamps[assetId] = block.timestamp;
    }

    function setTimestamp(uint256 assetId, uint256 t) external {
        timestamps[assetId] = t;
    }

    function verifyOracleProofV2(bytes calldata) external view returns (PriceInfo memory) {
        uint256 length = activePairs.length;
        uint256[] memory pairs = new uint256[](length);
        uint256[] memory p = new uint256[](length);
        uint256[] memory t = new uint256[](length);
        uint256[] memory d = new uint256[](length);
        uint256[] memory r = new uint256[](length);

        for (uint256 i = 0; i < length; i++) {
            uint256 assetId = activePairs[i];
            pairs[i] = assetId;
            p[i] = prices[assetId];
            t[i] = timestamps[assetId];
            d[i] = 6;
            r[i] = 1;
        }

        return PriceInfo(pairs, p, t, d, r);
    }
}

contract MockVault {
    address public immutable usdc;

    constructor(address usdcAddress) {
        usdc = usdcAddress;
    }

    function payTrader(address trader, uint256 amount) external {
        MockUSDC(usdc).transfer(trader, amount);
    }
}

contract MockChainlinkFeed {
    int256 public price;
    uint8 public decimals = 8;
    uint256 public updatedAt;

    function setPrice(int256 p, uint8 d) external {
        price = p;
        decimals = d;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 _updatedAt,
            uint80 answeredInRound
        )
    {
        return (1, price, updatedAt, updatedAt, 1);
    }
}

interface Vm {
    function warp(uint256) external;
    function prank(address) external;
    function startPrank(address) external;
    function stopPrank() external;
}

contract BrokexCoreTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    MockUSDC public usdc;
    MockSupra public supra;
    MockVault public vault;
    BrokexCore public core;
    BrokexLens public lens;

    uint256 public constant FEED_GOLD = 20;
    uint256 public constant FEED_EUR = 100;

    function _defaultAssetConfig() internal pure returns (BrokexCore.AssetConfig memory) {
        return BrokexCore.AssetConfig({
            minLeverage: 2,
            maxLeverage: 50,
            minTradeSize: 10e6, // 10 USDC
            commissionRate: 1000, // 0.1%
            maxTraderOI: 100_000e6,
            maxOpenInterest: 1_000_000e6,
            maxSkew: 5_000e6, // 5k USDC
            minSpread: 500, // 0.05%
            maxSpread: 3_000, // 0.30%
            spreadVirtualOI: 10_000e6,
            maxSpreadPenalty: 2500,
            maxSpreadDiscount: 200,
            baseBorrowRateHourly: 40,
            maxBorrowRateHourly: 114,
            borrowVirtualOI: 10_000e6,
            recoveryTimeDays: 7,
            maxProfitRate: 80_000, // 8%
            lockedCapitalRate: 120_000, // 12%
            liquidationThreshold: 900_000 // 90%
        });
    }

    function setUp() public {
        usdc = new MockUSDC();
        supra = new MockSupra();
        vault = new MockVault(address(usdc));

        core = new BrokexCore(address(usdc), address(supra), address(vault));
        lens = new BrokexLens(address(core));

        // List Gold
        core.listAsset(FEED_GOLD, _defaultAssetConfig());
        supra.setPrice(uint256(FEED_GOLD), 2500_000000);

        // Fund vault with 100,000 USDC
        usdc.mint(address(vault), 100_000e6);

        // Fund test contract with USDC and approve core once
        usdc.mint(address(this), 500_000e6);
        usdc.approve(address(core), type(uint256).max);
    }

    // =========================================================================
    // MULTI-ASSET LISTING TESTS
    // =========================================================================

    function test_ListAsset_And_GetActiveAssets() public {
        require(core.getAssetCount() == 1, "Should have 1 asset initially");

        BrokexCore.AssetConfig memory eurConfig = _defaultAssetConfig();
        eurConfig.minSpread = 200; // 0.02%
        eurConfig.maxSpread = 1000; // 0.10%

        core.listAsset(FEED_EUR, eurConfig);
        require(core.getAssetCount() == 2, "Should have 2 assets");

        uint256[] memory active = core.getActiveAssets();
        require(active.length == 2, "Active assets length should be 2");
        require(active[0] == FEED_GOLD, "First asset should be GOLD");
        require(active[1] == FEED_EUR, "Second asset should be EUR");
    }

    function test_DynamicMaxOI_Calculation() public view {
        (uint256 maxLong, uint256 maxShort) = core.dynamicMaxOI(FEED_GOLD);
        require(maxLong == 5_000e6, "Initial maxLong should be 0 + maxSkew = 5k");
        require(maxShort == 5_000e6, "Initial maxShort should be 0 + maxSkew = 5k");
    }

    function test_MaxSkew_OpenLongWithinLimit() public {
        bytes[] memory emptyProof = new bytes[](1);

        BrokexCore.MarketOrder memory order = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1, // Long
            collateral: 400e6,
            leverage: 10, // ~4000$ OI <= 5000$ maxSkew
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        uint256 tradeId = core.openMarket(order, emptyProof);
        require(tradeId == 1, "Trade ID should be 1");

        (,,uint256 oiLong,,,,) = core.assetStates(FEED_GOLD);
        require(oiLong > 0, "Long OI should be > 0");

        (uint256 maxLongAfter, uint256 maxShortAfter) = core.dynamicMaxOI(FEED_GOLD);
        require(maxLongAfter == 5_000e6, "maxLong should remain 0 + 5k = 5k");
        require(maxShortAfter > 5_000e6, "maxShort should increase with Long OI");
    }

    function test_MaxSkew_Exceeded_Reverts() public {
        bytes[] memory emptyProof = new bytes[](1);

        BrokexCore.MarketOrder memory order = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1, // Long
            collateral: 700e6,
            leverage: 10, // ~7000$ OI > 5000$ maxSkew
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        bool success;
        try core.openMarket(order, emptyProof) {
            success = true;
        } catch {
            success = false;
        }
        require(!success, "Should revert when exceeding maxSkew limit");
    }

    // =========================================================================
    // DYNAMIC SPREAD & BORROW TESTS
    // =========================================================================

    function test_DynamicSpread_Calculation() public view {
        (uint256 l1, uint256 s1) = core.calculateSpreads(FEED_GOLD, 10_000e6, 10_000e6);
        require(l1 == 500 && s1 == 500, "Balanced spreads should equal minSpread");

        (uint256 l2, uint256 s2) = core.calculateSpreads(FEED_GOLD, 50_000e6, 10_000e6);
        require(l2 > 500, "Long dominant spread should increase");
        require(s2 < 500, "Short minority spread should decrease");
    }

    function test_DynamicBorrow_Calculation() public view {
        (uint256 l1, uint256 s1) = core.calculateBorrowRates(FEED_GOLD, 10_000e6, 10_000e6);
        require(l1 == 40 && s1 == 40, "Balanced borrow should equal base");

        (uint256 l2, uint256 s2) = core.calculateBorrowRates(FEED_GOLD, 30_000e6, 10_000e6);
        require(l2 > 40, "Long dominant borrow should increase");
        require(s2 == 40, "Short minority borrow should equal base rate");
    }

    // =========================================================================
    // ORDER EXECUTION TESTS
    // =========================================================================

    function test_Order_And_Execute() public {
        BrokexCore.PendingOrder memory pending = BrokexCore.PendingOrder({
            assetId: FEED_GOLD,
            direction: 1, // Long
            orderType: 1, // LIMIT
            targetPrice: 2400_000000,
            collateral: 200e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        uint256 orderId = core.openOrder(pending);
        require(orderId == 1, "Order ID should be 1");

        bytes[] memory emptyProof = new bytes[](1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        uint8[] memory reasons = new uint8[](1);
        reasons[0] = 0; // REASON_EXECUTION

        bool execFailed;
        try core.execute(emptyProof, ids, reasons) {
            execFailed = false;
        } catch {
            execFailed = true;
        }
        require(execFailed, "Execute should fail because limit price not reached");

        // Lower oracle price to 2350 -> should execute!
        supra.setPrice(FEED_GOLD, 2350_000000);
        core.execute(emptyProof, ids, reasons);

        (,,uint8 state,,,,,,,,,) = core.trades(orderId);
        require(state == 1, "Order should now be open (STATE_OPEN = 1)");
    }

    function test_Cancel_Order() public {
        BrokexCore.PendingOrder memory pending = BrokexCore.PendingOrder({
            assetId: FEED_GOLD,
            direction: 1,
            orderType: 1,
            targetPrice: 2400_000000,
            collateral: 200e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        uint256 orderId = core.openOrder(pending);
        uint256 balBefore = usdc.balanceOf(address(this));

        // Attempt cancel before 1 minute -> should fail
        bool earlyCancelFailed;
        try core.cancel(orderId) {
            earlyCancelFailed = false;
        } catch {
            earlyCancelFailed = true;
        }
        require(earlyCancelFailed, "Cancel before 1 minute should fail");

        // Advance time by 1 minute
        vm.warp(block.timestamp + 1 minutes);

        core.cancel(orderId);
        uint256 balAfter = usdc.balanceOf(address(this));
        require(balAfter == balBefore + 200e6, "Collateral should be refunded");

        (,,uint8 state,,,,,,,,,) = core.trades(orderId);
        require(state == 3, "State should be CANCELLED (3)");
    }

    // =========================================================================
    // MULTI-ASSET SIMULTANEOUS TRADING & VAULT SOLVENCY
    // =========================================================================

    function test_MultiAsset_Simultaneous_Trading() public {
        // 1. List EUR/USD asset
        core.listAsset(FEED_EUR, _defaultAssetConfig());
        supra.setPrice(FEED_EUR, 1_080000); // 1.080000 USD

        bytes[] memory emptyProof = new bytes[](1);

        // 2. Open Long on Gold
        BrokexCore.MarketOrder memory goldOrder = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1,
            collateral: 300e6,
            leverage: 10, // ~3000$ OI
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 goldTradeId = core.openMarket(goldOrder, emptyProof);
        require(goldTradeId == 1, "Gold trade ID should be 1");

        // 3. Open Short on EUR
        BrokexCore.MarketOrder memory eurOrder = BrokexCore.MarketOrder({
            assetId: FEED_EUR,
            direction: 0, // Short
            collateral: 200e6,
            leverage: 10, // ~2000$ OI
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 eurTradeId = core.openMarket(eurOrder, emptyProof);
        require(eurTradeId == 2, "EUR trade ID should be 2");

        // 4. Verify locked capital aggregates both assets
        uint256 goldLocked = core.assetLockedCapital(FEED_GOLD);
        uint256 eurLocked = core.assetLockedCapital(FEED_EUR);
        uint256 totalLocked = core.lockedCapital();

        require(goldLocked > 0, "Gold locked capital should be > 0");
        require(eurLocked > 0, "EUR locked capital should be > 0");
        require(totalLocked == goldLocked + eurLocked, "Total locked should sum both assets");
    }

    // =========================================================================
    // REFERRAL INTEGRATION TESTS
    // =========================================================================

    function test_AutoReferral_OnOpenMarket() public {
        address referrerAddr = address(0x999);
        bytes[] memory emptyProof = new bytes[](1);

        BrokexCore.MarketOrder memory order = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: referrerAddr
        });

        core.openMarket(order, emptyProof);
        require(core.referrers(address(this)) == referrerAddr, "Referrer should be set on first trade");
        require(core.referralRewards(referrerAddr) > 0, "Referrer should accrue commission reward");

        // Subsequent trade with another referrer should be ignored
        BrokexCore.MarketOrder memory order2 = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0x888)
        });
        core.openMarket(order2, emptyProof);
        require(core.referrers(address(this)) == referrerAddr, "Referrer should remain unchanged");
    }

    function test_InvalidStops_FallbackToZero_And_Execute() public {
        bytes[] memory emptyProof = new bytes[](1);

        // Open Long with invalid SL (SL > entryPrice) and invalid TP (TP < entryPrice)
        BrokexCore.MarketOrder memory order = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1, // Long at ~2500
            collateral: 100e6,
            leverage: 10,
            stopLoss: 2600_000000,
            takeProfit: 2400_000000,
            referrer: address(0)
        });

        uint256 tradeId = core.openMarket(order, emptyProof);
        require(tradeId > 0, "Trade should be executed successfully");

        (,,,,,,,,uint64 sl, uint64 tp,,) = core.trades(tradeId);
        require(sl == 0, "Invalid SL should be sanitized to 0");
        require(tp == 0, "Invalid TP should be sanitized to 0");
    }

    function test_SetAssetSecurityMode() public {
        core.listAsset(FEED_EUR, _defaultAssetConfig());
        core.setAssetSecurityMode(FEED_EUR, 1); // CLOSE_ONLY for EUR

        bytes[] memory emptyProof = new bytes[](1);

        // Opening EUR should fail
        BrokexCore.MarketOrder memory eurOrder = BrokexCore.MarketOrder({
            assetId: FEED_EUR,
            direction: 1,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        bool eurFailed;
        try core.openMarket(eurOrder, emptyProof) {} catch { eurFailed = true; }
        require(eurFailed, "Opening in CLOSE_ONLY should fail");

        // Opening GOLD should succeed
        BrokexCore.MarketOrder memory goldOrder = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 tradeId = core.openMarket(goldOrder, emptyProof);
        require(tradeId > 0, "Gold trading should remain unaffected");
    }

    function test_LockedCapital_MustBeGreaterThan_MaxProfit() public {
        BrokexCore.AssetConfig memory badConfig = _defaultAssetConfig();
        badConfig.lockedCapitalRate = 80_000; // 8%
        badConfig.maxProfitRate = 80_000; // 8% -> lockedCapital <= maxProfit -> should revert!

        bool failed;
        try core.listAsset(FEED_EUR, badConfig) {} catch { failed = true; }
        require(failed, "Listing asset with lockedCapitalRate <= maxProfitRate should fail");

        badConfig.lockedCapitalRate = 70_000; // 7% < 8% -> should revert!
        failed = false;
        try core.listAsset(FEED_EUR, badConfig) {} catch { failed = true; }
        require(failed, "Listing asset with lockedCapitalRate < maxProfitRate should fail");
    }

    function test_RealVault_Integration_ProfitableTrade_And_Settlement() public {
        // 1. Deploy Real Vault and Core
        BrokexVault realVault = new BrokexVault();
        BrokexCore realCore = new BrokexCore(address(usdc), address(supra), address(realVault));
        realVault.setPrimaryCore(address(realCore));

        // 2. List Gold on realCore
        realCore.listAsset(FEED_GOLD, _defaultAssetConfig());

        // 3. Deposit into Real Vault
        usdc.approve(address(realVault), type(uint256).max);
        realVault.deposit(50_000e6);
        require(usdc.balanceOf(address(realVault)) == 50_000e6, "Vault should have 50k USDC");

        // 4. Open Long position on Gold
        usdc.approve(address(realCore), type(uint256).max);
        bytes[] memory emptyProof = new bytes[](1);

        BrokexCore.MarketOrder memory order = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1, // Long at 2500
            collateral: 200e6,
            leverage: 10, // 2000$ OI
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 tradeId = realCore.openMarket(order, emptyProof);
        require(tradeId == 1, "Trade ID should be 1");

        // 5. Move Oracle price up to 2600 (Profitable!)
        vm.warp(block.timestamp + 2 minutes);
        supra.setPrice(FEED_GOLD, 2600_000000);

        // 6. Close Market -> calls realVault.payTrader() and settles profit!
        uint256 balanceBefore = usdc.balanceOf(address(this));
        realCore.closeMarket(tradeId, emptyProof);
        uint256 balanceAfter = usdc.balanceOf(address(this));

        require(balanceAfter > balanceBefore, "Trader should have received profit + margin from Real Vault");

        // 7. Test Real Vault withdraw
        realVault.withdraw(5_000e6);
        require(usdc.balanceOf(address(realVault)) < 50_000e6, "Vault withdrawal should succeed");
    }

    function test_DelistedAsset_OrderCannotExecute_CanOnlyCancel() public {
        // 1. List EUR asset
        core.listAsset(FEED_EUR, _defaultAssetConfig());
        supra.setPrice(FEED_EUR, 1_080000); // 1.08 USD

        // 2. Open Limit Order on EUR
        BrokexCore.PendingOrder memory pending = BrokexCore.PendingOrder({
            assetId: FEED_EUR,
            direction: 1, // Long
            orderType: 1, // LIMIT
            targetPrice: 1_050000, // Trigger below 1.08
            collateral: 200e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 orderId = core.openOrder(pending);
        require(orderId > 0, "Order ID should be > 0");

        // 3. Delist EUR asset (OI is 0 because order is pending, not open)
        core.delistAsset(FEED_EUR);

        // 4. Move price to trigger price
        supra.setPrice(FEED_EUR, 1_040000);

        bytes[] memory emptyProof = new bytes[](1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = orderId;
        uint8[] memory reasons = new uint8[](1);
        reasons[0] = 0; // REASON_EXECUTION

        // Attempt execution -> must revert / fail to execute because asset is delisted!
        bool execFailed;
        try core.execute(emptyProof, ids, reasons) {
            execFailed = false;
        } catch {
            execFailed = true;
        }
        require(execFailed, "Executing order on delisted asset must fail");

        // Verify state is still STATE_ORDER (0)
        (,,uint8 state,,,,,,,,,) = core.trades(orderId);
        require(state == 0, "State must remain STATE_ORDER");

        // 5. Trader cancels the order to get full collateral refund
        vm.warp(block.timestamp + 1 minutes);
        uint256 balBefore = usdc.balanceOf(address(this));
        core.cancel(orderId);
        uint256 balAfter = usdc.balanceOf(address(this));

        require(balAfter == balBefore + 200e6, "Collateral must be refunded to trader on cancel");
        (,,uint8 finalState,,,,,,,,,) = core.trades(orderId);
        require(finalState == 3, "State must be CANCELLED (3)");
    }

    function test_LensProtocolInfo() public view {
        BrokexLens.ProtocolInfo memory info = lens.getProtocolInfo();
        require(info.owner == address(this), "Owner mismatch");
        require(info.activeAssets.length == 1, "Should have 1 active asset");
        require(info.activeAssets[0] == FEED_GOLD, "Active asset should be GOLD");

        BrokexLens.AssetInfo memory goldInfo = lens.getAssetInfo(FEED_GOLD);
        require(goldInfo.minSpread == 500, "Lens minSpread mismatch");
        require(goldInfo.maxSpread == 3000, "Lens maxSpread mismatch");
        require(goldInfo.spreadVirtualOI == 10_000e6, "Lens spreadVirtualOI mismatch");
        require(goldInfo.maxSkew == 5_000e6, "Lens maxSkew mismatch");
        require(goldInfo.maxProfitRate == 80_000, "Lens maxProfitRate mismatch");
        require(goldInfo.recoveryTimeDays == 7, "Lens recoveryTimeDays mismatch");
    }

    function test_Oracle_MillisecondAndStalenessHandling() public {
        vm.warp(1_700_000_000);
        supra.setPrice(FEED_GOLD, 2500e6);
        bytes[] memory emptyProof = new bytes[](1);
        BrokexCore.MarketOrder memory order = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        // 1. Timestamp in milliseconds (current time in ms: 1.7e12) should succeed
        supra.setTimestamp(FEED_GOLD, block.timestamp * 1000);
        uint256 tradeId1 = core.openMarket(order, emptyProof);
        require(tradeId1 > 0, "Millisecond timestamp should succeed");

        // 2. Stale timestamp (older than 7s in ms) should revert
        supra.setTimestamp(FEED_GOLD, (block.timestamp - 10) * 1000);
        bool staleFailed;
        try core.openMarket(order, emptyProof) {} catch { staleFailed = true; }
        require(staleFailed, "Stale millisecond timestamp should revert");

        // 3. Future timestamp with excess drift (> 5s in ms) should revert
        supra.setTimestamp(FEED_GOLD, (block.timestamp + 10) * 1000);
        bool futureFailed;
        try core.openMarket(order, emptyProof) {} catch { futureFailed = true; }
        require(futureFailed, "Future timestamp beyond drift limit should revert");

        // Reset to valid timestamp
        supra.setTimestamp(FEED_GOLD, block.timestamp);
    }

    function test_Execute_SingleAssetBatchOnly() public {
        core.listAsset(FEED_EUR, _defaultAssetConfig());
        supra.setPrice(FEED_EUR, 1_080000);

        // Open Pending Order for Gold
        BrokexCore.PendingOrder memory goldOrder = BrokexCore.PendingOrder({
            assetId: FEED_GOLD,
            direction: 1,
            orderType: 1, // LIMIT
            targetPrice: 2400e6,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 goldTradeId = core.openOrder(goldOrder);

        // Open Pending Order for EUR
        BrokexCore.PendingOrder memory eurOrder = BrokexCore.PendingOrder({
            assetId: FEED_EUR,
            direction: 1,
            orderType: 1, // LIMIT
            targetPrice: 1_050000,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 eurTradeId = core.openOrder(eurOrder);

        // Try to batch execute Gold + EUR together in same execute call -> must revert!
        bytes[] memory emptyProof = new bytes[](1);
        uint256[] memory mixedIds = new uint256[](2);
        mixedIds[0] = goldTradeId;
        mixedIds[1] = eurTradeId;
        uint8[] memory reasons = new uint8[](2);
        reasons[0] = 0;
        reasons[1] = 0;

        supra.setPrice(FEED_GOLD, 2390e6);
        supra.setPrice(FEED_EUR, 1_040000);

        bool batchMixedFailed;
        try core.execute(emptyProof, mixedIds, reasons) {} catch { batchMixedFailed = true; }
        require(batchMixedFailed, "Mixed asset batch in execute must revert");

        // Single asset execution for Gold should succeed
        uint256[] memory singleId = new uint256[](1);
        singleId[0] = goldTradeId;
        uint8[] memory singleReason = new uint8[](1);
        singleReason[0] = 0;

        core.execute(emptyProof, singleId, singleReason);
        (,,uint8 goldState,,,,,,,,,) = core.trades(goldTradeId);
        require(goldState == 1, "Gold trade should be STATE_OPEN");
    }

    function test_H03_RejectExecutionBeforeOrderCreation() public {
        vm.warp(1_700_000_000);
        supra.setPrice(FEED_GOLD, 2500e6);

        // Open pending order at t = 1_700_000_005
        vm.warp(1_700_000_005);
        BrokexCore.PendingOrder memory goldOrder = BrokexCore.PendingOrder({
            assetId: FEED_GOLD,
            direction: 1,
            orderType: 1, // LIMIT
            targetPrice: 2400e6,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });
        uint256 tradeId = core.openOrder(goldOrder);

        // Try to execute with an oracle observation from t = 1_700_000_002 (predates order creation)
        supra.setPrice(FEED_GOLD, 2390e6);
        supra.setTimestamp(FEED_GOLD, 1_700_000_002);

        bytes[] memory emptyProof = new bytes[](1);
        uint256[] memory ids = new uint256[](1);
        ids[0] = tradeId;
        uint8[] memory reasons = new uint8[](1);
        reasons[0] = 0;

        bool rejectedPreOrder;
        try core.execute(emptyProof, ids, reasons) {} catch { rejectedPreOrder = true; }
        require(rejectedPreOrder, "Execution with pre-order observation timestamp must revert");

        // Now update oracle timestamp to t = 1_700_000_006 (after order creation)
        supra.setTimestamp(FEED_GOLD, 1_700_000_006);
        core.execute(emptyProof, ids, reasons);

        (,,uint8 finalState,,,,,,,,,) = core.trades(tradeId);
        require(finalState == 1, "Trade must be OPEN when executed with valid post-order timestamp");
    }

    function test_Lens_GetEstimatedSpreads() public view {
        // Estimate spread for opening 10,000 USDC Long
        BrokexLens.EstimatedSpreads memory openLongSpreads = lens.getEstimatedSpreads(
            FEED_GOLD,
            1, // LONG
            10_000e6, // 10k OI
            true // isOpening
        );
        require(openLongSpreads.longSpread >= 500, "Long spread must be at least minSpread");
        require(openLongSpreads.tradeSpread == openLongSpreads.longSpread, "Trade spread for long open must match longSpread");

        // Estimate spread for opening 10,000 USDC Short
        BrokexLens.EstimatedSpreads memory openShortSpreads = lens.getEstimatedSpreads(
            FEED_GOLD,
            0, // SHORT
            10_000e6,
            true
        );
        require(openShortSpreads.shortSpread >= 500, "Short spread must be at least minSpread");
        require(openShortSpreads.tradeSpread == openShortSpreads.shortSpread, "Trade spread for short open must match shortSpread");
    }

    function test_ChainlinkGuard_SuccessAndRevert() public {
        vm.warp(1_700_000_000);
        supra.setTimestamp(FEED_GOLD, 1_700_000_000);

        MockChainlinkFeed cl = new MockChainlinkFeed();
        // Supra gold price is 2500e6 ($2500.00)
        // Chainlink feed with 8 decimals: $2500.00 -> 2500 * 1e8 = 250000000000
        cl.setPrice(2500 * 1e8, 8);

        // Configure guard with 1.125% max deviation (11_250 / 1e6)
        core.setChainlinkGuard(FEED_GOLD, address(cl), 11_250);

        // 1. Open market when Supra and Chainlink match -> SUCCESS
        bytes[] memory emptyProof = new bytes[](1);
        BrokexCore.MarketOrder memory req = BrokexCore.MarketOrder({
            assetId: FEED_GOLD,
            direction: 1,
            collateral: 100e6,
            leverage: 10,
            stopLoss: 0,
            takeProfit: 0,
            referrer: address(0)
        });

        uint256 tradeId = core.openMarket(req, emptyProof);
        require(tradeId > 0, "Trade must open when oracle prices match");

        // 2. Modify Chainlink to diverge by 4% ($2600.00 vs $2500.00)
        cl.setPrice(2600 * 1e8, 8);
        bool revertedDivergence;
        try core.openMarket(req, emptyProof) {} catch {
            revertedDivergence = true;
        }
        require(revertedDivergence, "Must revert when divergence exceeds threshold");

        // 3. Remove guard (address(0)) -> Must succeed even if divergent
        core.setChainlinkGuard(FEED_GOLD, address(0), 0);
        uint256 tradeId2 = core.openMarket(req, emptyProof);
        require(tradeId2 > 0, "Must succeed when guard is removed");

        // 4. Stale Chainlink feed (> 25h old) -> Fail-closed must revert
        core.setChainlinkGuard(FEED_GOLD, address(cl), 11_250);
        cl.setUpdatedAt(block.timestamp - 26 hours);
        bool revertedStale;
        try core.openMarket(req, emptyProof) {} catch {
            revertedStale = true;
        }
        require(revertedStale, "Must revert on stale Chainlink feed (Fail-closed)");

        // 5. Test marketClosed toggle
        core.setChainlinkGuard(FEED_GOLD, address(0), 0); // remove guard
        core.setMarketClosed(FEED_GOLD, true);
        bool revertedClosed;
        try core.openMarket(req, emptyProof) {} catch {
            revertedClosed = true;
        }
        require(revertedClosed, "Must revert when market is closed");

        // Reopen market
        core.setMarketClosed(FEED_GOLD, false);
        uint256 tradeId4 = core.openMarket(req, emptyProof);
        require(tradeId4 > 0, "Must succeed when market is reopened");
    }
}
