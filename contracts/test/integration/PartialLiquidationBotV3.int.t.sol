// SPDX-License-Identifier: UNLICENSED
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {
    DECREASE_DEBT_PERMISSION,
    ICreditFacadeV3Multicall,
    WITHDRAW_COLLATERAL_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ManageDebtAction} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    BorrowAmountOutOfLimitsException,
    CreditAccountNotLiquidatableException,
    DebtToZeroWithActiveQuotasException,
    NotEnoughCollateralException
} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";

import {IntegrationTestHelper} from "@gearbox-protocol/core-v3/contracts/test/helpers/IntegrationTestHelper.sol";
import {CONFIGURATOR, FRIEND, LIQUIDATOR, USER} from "@gearbox-protocol/core-v3/contracts/test/lib/constants.sol";
import {PriceFeedMock} from "@gearbox-protocol/core-v3/contracts/test/mocks/oracles/PriceFeedMock.sol";

import {Tokens} from "@gearbox-protocol/sdk-gov/contracts/Tokens.sol";

import {PartialLiquidationBotV3} from "../../bots/PartialLiquidationBotV3.sol";
import {IPartialLiquidationBotV3} from "../../interfaces/IPartialLiquidationBotV3.sol";

contract UpdatablePriceFeedMock is PriceFeedMock {
    bool public updatable = true;

    constructor(int256 price, uint8 decimals) PriceFeedMock(price, decimals) {
        updatedAt = block.timestamp;
    }

    function updatePrice(bytes calldata data) external {
        this.setPrice(abi.decode(data, (int256)));
        updatedAt = block.timestamp;
    }
}

contract PartialLiquidationBotV3IntegrationTest is IntegrationTestHelper {
    event LiquidatePartial(
        address indexed creditManager,
        address indexed creditAccount,
        address indexed token,
        uint256 repaidDebt,
        uint256 seizedCollateral,
        uint256 fee
    );

    PartialLiquidationBotV3 bot;
    address treasury;

    address dai;
    address link;

    uint256 daiMask;
    uint256 linkMask;

    uint256 daiAmount = 100_000e18;
    uint256 linkAmount = 10_000e18;

    int256 daiPrice = 1e8;
    int256 linkPrice = 15e8;
    int256 newLinkPrice = 12e8;

    address creditAccount;

    // ----- //
    // SETUP //
    // ----- //

    function _setUp() internal {
        _setUp(BotParams(1e4, type(uint16).max, 1e4, 1e4));
    }

    struct BotParams {
        uint16 minHealthFactor;
        uint16 maxHealthFactor;
        uint16 premiumScaleFactor;
        uint16 feeScaleFactor;
    }

    function _setUp(BotParams memory params) internal {
        treasury = makeAddr("TREASURY");

        bot = new PartialLiquidationBotV3(
            treasury, params.minHealthFactor, params.maxHealthFactor, params.premiumScaleFactor, params.feeScaleFactor
        );

        dai = tokenTestSuite.addressOf(Tokens.DAI);
        link = tokenTestSuite.addressOf(Tokens.LINK);

        daiMask = creditManager.getTokenMaskOrRevert(dai);
        linkMask = creditManager.getTokenMaskOrRevert(link);

        vm.startPrank(CONFIGURATOR);
        address priceFeed = address(new UpdatablePriceFeedMock(linkPrice, 8));
        priceOracle.setReservePriceFeed(link, priceFeed, 1);
        priceOracle.addUpdatablePriceFeed(priceFeed);
        vm.stopPrank();

        deal(link, USER, linkAmount);
        tokenTestSuite.approve(link, USER, address(creditManager), linkAmount);

        deal(dai, LIQUIDATOR, 2 * daiAmount);
        tokenTestSuite.approve(dai, LIQUIDATOR, address(bot), 2 * daiAmount);

        creditAccount = _openCreditAccount();
    }

    function _openCreditAccount() internal returns (address _creditAccount) {
        uint96 quotaAmount = uint96(6 * daiAmount / 5);

        MultiCall[] memory calls = new MultiCall[](5);
        calls[0] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.increaseDebt, (daiAmount))
        });
        calls[1] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (dai, type(uint256).max, USER))
        });
        calls[2] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (link, linkAmount))
        });
        calls[3] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(ICreditFacadeV3Multicall.updateQuota, (link, int96(quotaAmount), quotaAmount))
        });
        calls[4] = MultiCall({
            target: address(creditFacade),
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.setBotPermissions,
                (address(bot), DECREASE_DEBT_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION)
            )
        });

        vm.prank(USER);
        _creditAccount = creditFacade.openCreditAccount(USER, calls, 0);

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);
    }

    function _getPriceUpdates() internal view returns (PriceUpdate[] memory priceUpdates) {
        priceUpdates = new PriceUpdate[](1);
        priceUpdates[0] = PriceUpdate(priceOracle.reservePriceFeeds(link), abi.encode(newLinkPrice));
    }

    function test_I_PL_01_setup_is_correct() public creditTest {
        _setUp();

        assertEq(underlying, dai, "Incorrect underlying");
        assertEq(creditManager.liquidationThresholds(dai), 94_50, "Incorrect DAI liquidation threshold");
        assertEq(creditManager.liquidationThresholds(link), 73_00, "Incorrect LINK liquidation threshold");

        (uint256 minDebt, uint256 maxDebt) = creditFacade.debtLimits();
        assertEq(minDebt, daiAmount / 10, "Incorrect minDebt");
        assertEq(maxDebt, 2 * daiAmount, "Incorrect maxDebt");

        assertEq(priceOracle.getPrice(dai), uint256(daiPrice), "Incorrect DAI price");
        assertEq(priceOracle.getPrice(link), uint256(linkPrice), "Incorrect LINK price");
    }

    // ----------- //
    // BASIC TESTS //
    // ----------- //

    function test_I_PL_02_liquidateExactDebt_sanitizes_inputs() public creditTest {
        _setUp();

        PriceUpdate[] memory priceUpdates = _getPriceUpdates();

        // reverts on trying to liquidate underlying
        vm.expectRevert(IPartialLiquidationBotV3.UnderlyingNotLiquidatableException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, dai, 0, 0, FRIEND, priceUpdates);

        // reverts on trying to liquidate healthy account
        vm.expectRevert(CreditAccountNotLiquidatableException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, 0, 0, FRIEND, priceUpdates);
    }

    function test_I_PL_03_liquidateExactDebt_works_as_expected() public creditTest {
        _setUp();

        // make account liquidatable by lowering the collateral price
        PriceFeedMock(priceOracle.priceFeeds(link)).setPrice(newLinkPrice);
        PriceUpdate[] memory priceUpdates = _getPriceUpdates();

        uint256 repaidAmount = daiAmount * 3 / 4;

        // reverts on paying too little
        vm.expectRevert(IPartialLiquidationBotV3.SeizedLessThanRequiredException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, repaidAmount, linkAmount, FRIEND, priceUpdates);

        uint256 expectedSeizedAmount = repaidAmount * uint256(25 * daiPrice) / uint256(24 * newLinkPrice);
        uint256 expectedFeeAmount = repaidAmount * 3 / 200;

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(
                creditManager.manageDebt,
                (creditAccount, repaidAmount - expectedFeeAmount, daiMask | linkMask, ManageDebtAction.DECREASE_DEBT)
            )
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(creditManager.withdrawCollateral, (creditAccount, dai, expectedFeeAmount, treasury))
        );

        vm.expectCall(
            address(creditManager),
            abi.encodeCall(creditManager.withdrawCollateral, (creditAccount, link, expectedSeizedAmount, FRIEND))
        );

        vm.expectEmit(true, true, true, true, address(bot));
        emit LiquidatePartial(
            address(creditManager),
            creditAccount,
            link,
            repaidAmount - expectedFeeAmount,
            expectedSeizedAmount,
            expectedFeeAmount
        );

        vm.prank(LIQUIDATOR);
        uint256 seizedAmount = bot.liquidateExactDebt(creditAccount, link, repaidAmount, 0, FRIEND, priceUpdates);

        assertEq(seizedAmount, expectedSeizedAmount, "Incorrect seized amount");
    }

    // ------------------ //
    // ADVANCED SCENARIOS //
    // ------------------ //

    function test_I_PL_04_partialLiquidation_reverts_on_inadequate_amounts() public creditTest {
        _setUp();

        // make account liquidatable by lowering the collateral price
        PriceFeedMock(priceOracle.priceFeeds(link)).setPrice(newLinkPrice);
        PriceUpdate[] memory priceUpdates = _getPriceUpdates();

        // reverts when account is still insolvent after liquidation
        vm.expectRevert(NotEnoughCollateralException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, daiAmount / 10, 0, FRIEND, priceUpdates);

        // reverts when account's debt is below minimum after liquidation
        vm.expectRevert(BorrowAmountOutOfLimitsException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, daiAmount, 0, FRIEND, priceUpdates);

        // reverts when repaid more debt than account had
        vm.expectRevert(DebtToZeroWithActiveQuotasException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, daiAmount * 11 / 10, 0, FRIEND, priceUpdates);
    }

    function test_I_PL_05_partialLiquidation_does_not_steal_underlying_from_account() public creditTest {
        _setUp();

        // make account liquidatable by lowering the collateral price
        PriceFeedMock(priceOracle.priceFeeds(link)).setPrice(newLinkPrice);
        PriceUpdate[] memory priceUpdates = _getPriceUpdates();

        // mint small amount of underlying to credit account
        deal(dai, creditAccount, daiAmount / 10);

        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, daiAmount * 3 / 4, 0, FRIEND, priceUpdates);

        assertEq(tokenTestSuite.balanceOf(dai, creditAccount), daiAmount / 10, "Incorrect DAI balance");
    }

    function test_I_PL_06_partialLiquidation_works_as_expected_with_non_default_params() public creditTest {
        _setUp(BotParams(1.02e4, 1.05e4, 0.5e4, 0));

        // set collateral price such that account's health factor is above 1 but below 1.02
        newLinkPrice = 13.75e8;
        PriceFeedMock(priceOracle.priceFeeds(link)).setPrice(newLinkPrice);
        PriceUpdate[] memory priceUpdates = _getPriceUpdates();

        // reverts on liquidating less than needed
        vm.expectRevert(IPartialLiquidationBotV3.LiquidatedLessThanNeededException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, 0, 0, FRIEND, priceUpdates);

        // reverts on liquidating more than needed (note that this amount works in other tests)
        vm.expectRevert(IPartialLiquidationBotV3.LiquidatedMoreThanNeededException.selector);
        vm.prank(LIQUIDATOR);
        bot.liquidateExactDebt(creditAccount, link, daiAmount * 3 / 4, 0, FRIEND, priceUpdates);

        // here we liquidate 12.5K DAI of debt, which results in 12.5K / 13.75 / 0.98 ~= 928 LINK seized
        // after the liquidation, account has 87.5K DAI of debt and 9072 LINK of collateral, which gives
        // HF = 9072 * 13.75 * 0.73 / 87500 ~= 1.04, which is within the allowed range
        uint256 repaidAmount = daiAmount / 8;
        uint256 expectedSeizedAmount = repaidAmount * uint256(50 * daiPrice) / uint256(49 * newLinkPrice);
        vm.prank(LIQUIDATOR);
        uint256 seizedAmount = bot.liquidateExactDebt(creditAccount, link, repaidAmount, 0, FRIEND, priceUpdates);
        assertApproxEqAbs(seizedAmount, expectedSeizedAmount, 1, "Incorrect seized amount");
    }
}
