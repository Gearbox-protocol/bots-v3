// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@1inch/solidity-utils/contracts/libraries/SafeERC20.sol";

import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {
    DECREASE_DEBT_PERMISSION,
    ICreditFacadeV3Multicall,
    WITHDRAW_COLLATERAL_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    CreditAccountNotLiquidatableException,
    IncorrectParameterException
} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3, PriceUpdate} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {IBot} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IBot.sol";
import {IVersion} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IVersion.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {ReentrancyGuardTrait} from "@gearbox-protocol/core-v3/contracts/traits/ReentrancyGuardTrait.sol";
import {SanityCheckTrait} from "@gearbox-protocol/core-v3/contracts/traits/SanityCheckTrait.sol";

import {IPartialLiquidationBotV3} from "../interfaces/IPartialLiquidationBotV3.sol";

/// @title Partial liquidation bot V3
/// @author Gearbox Foundation
/// @notice Partial liquidation bot helps to bring credit accounts back to solvency in conditions when liquidity
///         on the market is not enough to convert all account's collateral to underlying for full liquidation.
///         The bot allows anyone to repay a fraction of liquidatable credit account's debt in exchange for
///         discounted collateral, as long as account passes a collateral check after the operation.
///         There are certain limitations that liquidators, configurators and account owners should be aware of:
///         - since operation repays debt, an account can't be partially liquidated if its debt is near minimum;
///         - due to `withdrawCollateral` inside the liquidation, collateral check with safe prices is triggered,
///           which would only succeed if reserve price feeds for collateral tokens are set in the price oracle;
///         - health factor range check is made using normal prices, which, under certain circumstances, may be
///           mutually exclusive with the former;
///         - liquidator premium and DAO fee are the same as for the full liquidation in a given credit manager
///           (although fees are sent to the treasury instead of being deposited into pools).
///         The bot can also be used for deleverage to prevent liquidations by triggering earlier, limiting
///         operation size and/or charging less in premium and fees.
contract PartialLiquidationBotV3 is IPartialLiquidationBotV3, ReentrancyGuardTrait, SanityCheckTrait {
    using SafeERC20 for IERC20;

    /// @dev Internal liquidation variables
    struct LiquidationVars {
        address creditManager;
        address creditFacade;
        address priceOracle;
        address underlying;
        uint256 feeLiquidation;
        uint256 liquidationDiscount;
    }

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_10;

    /// @inheritdoc IVersion
    bytes32 public constant override contractType = "BOT_PARTIAL_LIQUIDATION";

    /// @inheritdoc IBot
    uint192 public constant override requiredPermissions = DECREASE_DEBT_PERMISSION | WITHDRAW_COLLATERAL_PERMISSION;

    /// @inheritdoc IPartialLiquidationBotV3
    address public immutable override treasury;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override minHealthFactor;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override maxHealthFactor;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override premiumScaleFactor;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override feeScaleFactor;

    /// @notice Constructor
    /// @param treasury_ Treasury address
    /// @param minHealthFactor_ Minimum health factor to trigger the liquidation
    /// @param maxHealthFactor_ Maximum health factor to allow after the liquidation
    /// @param premiumScaleFactor_ Factor to scale credit manager's liquidation premium by
    /// @param feeScaleFactor_ Factor to scale credit manager's liquidation fee by
    /// @dev Reverts if `maxHealthFactor` is below 100% or below `minHealthFactor_`
    /// @dev Reverts if `treasury_` is zero address
    constructor(
        address treasury_,
        uint16 minHealthFactor_,
        uint16 maxHealthFactor_,
        uint16 premiumScaleFactor_,
        uint16 feeScaleFactor_
    ) nonZeroAddress(treasury_) {
        treasury = treasury_;
        if (maxHealthFactor_ < PERCENTAGE_FACTOR || maxHealthFactor_ < minHealthFactor_) {
            revert IncorrectParameterException();
        }
        minHealthFactor = minHealthFactor_;
        maxHealthFactor = maxHealthFactor_;
        premiumScaleFactor = premiumScaleFactor_;
        feeScaleFactor = feeScaleFactor_;
    }

    // ----------- //
    // LIQUIDATION //
    // ----------- //

    /// @inheritdoc IPartialLiquidationBotV3
    function liquidateExactDebt(
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external override nonReentrant returns (uint256 seizedAmount) {
        LiquidationVars memory vars = _initVars(creditAccount);
        if (priceUpdates.length != 0) IPriceOracleV3(vars.priceOracle).updatePrices(priceUpdates);
        _validateLiquidation(vars, creditAccount, token);

        uint256 balanceBefore = IERC20(vars.underlying).safeBalanceOf(creditAccount);
        IERC20(vars.underlying).safeTransferFrom(msg.sender, creditAccount, repaidAmount);
        repaidAmount = IERC20(vars.underlying).safeBalanceOf(creditAccount) - balanceBefore;

        uint256 fee;
        (repaidAmount, fee, seizedAmount) = _calcPartialLiquidationPayments(vars, repaidAmount, token);
        if (seizedAmount < minSeizedAmount) revert SeizedLessThanRequiredException();

        _executeLiquidation(vars, creditAccount, token, repaidAmount, seizedAmount, fee, to);
        _checkHealthFactor(vars, creditAccount);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Loads state variables used in `creditAccount` liquidation
    function _initVars(address creditAccount) internal view returns (LiquidationVars memory vars) {
        vars.creditManager = ICreditAccountV3(creditAccount).creditManager();
        vars.creditFacade = ICreditManagerV3(vars.creditManager).creditFacade();
        vars.priceOracle = ICreditManagerV3(vars.creditManager).priceOracle();
        vars.underlying = ICreditManagerV3(vars.creditManager).underlying();
        (, uint256 feeLiquidation, uint256 liquidationDiscount,,) = ICreditManagerV3(vars.creditManager).fees();
        vars.liquidationDiscount =
            PERCENTAGE_FACTOR - (PERCENTAGE_FACTOR - liquidationDiscount) * premiumScaleFactor / PERCENTAGE_FACTOR;
        vars.feeLiquidation = feeLiquidation * feeScaleFactor / PERCENTAGE_FACTOR;
    }

    /// @dev Ensures that `creditAccount` is liquidatable and `token` is not underlying
    function _validateLiquidation(LiquidationVars memory vars, address creditAccount, address token) internal view {
        if (token == vars.underlying) revert UnderlyingNotLiquidatableException();
        if (!_isLiquidatable(_calcDebtAndCollateral(vars.creditManager, creditAccount), minHealthFactor)) {
            revert CreditAccountNotLiquidatableException();
        }
    }

    /// @dev Calculates and returns partial liquidation payment amounts:
    ///      - amount of underlying that should go towards repaying debt
    ///      - amount of underlying that should go towards liquidation fees
    ///      - amount of collateral that should be withdrawn to the liquidator
    function _calcPartialLiquidationPayments(LiquidationVars memory vars, uint256 amount, address token)
        internal
        view
        returns (uint256 repaidAmount, uint256 fee, uint256 seizedAmount)
    {
        seizedAmount = IPriceOracleV3(vars.priceOracle).convert(amount, vars.underlying, token) * PERCENTAGE_FACTOR
            / vars.liquidationDiscount;
        fee = amount * vars.feeLiquidation / PERCENTAGE_FACTOR;
        repaidAmount = amount - fee;
    }

    /// @dev Executes partial liquidation by performing a multicall on `creditAccount` that repays debt,
    ///      withdraws fee to the treasury and withdraws `token` to `to`
    function _executeLiquidation(
        LiquidationVars memory vars,
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 seizedAmount,
        uint256 fee,
        address to
    ) internal {
        MultiCall[] memory calls = new MultiCall[](3);
        calls[0] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (repaidAmount))
        });
        calls[1] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (vars.underlying, fee, treasury))
        });
        calls[2] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, seizedAmount, to))
        });
        ICreditFacadeV3(vars.creditFacade).botMulticall(creditAccount, calls);

        emit LiquidatePartial(vars.creditManager, creditAccount, token, repaidAmount, seizedAmount, fee);
    }

    /// @dev Ensures that `creditAccount`'s health factor is within allowed range after partial liquidation
    function _checkHealthFactor(LiquidationVars memory vars, address creditAccount) internal view {
        if (minHealthFactor <= PERCENTAGE_FACTOR && maxHealthFactor == type(uint16).max) return;
        CollateralDebtData memory cdd = _calcDebtAndCollateral(vars.creditManager, creditAccount);
        if (minHealthFactor > PERCENTAGE_FACTOR && _isLiquidatable(cdd, minHealthFactor)) {
            revert LiquidatedLessThanNeededException();
        }
        if (maxHealthFactor != type(uint16).max && !_isLiquidatable(cdd, maxHealthFactor + 1)) {
            revert LiquidatedMoreThanNeededException();
        }
    }

    /// @dev Returns `creditAccount`'s collateral and debt data
    function _calcDebtAndCollateral(address creditManager, address creditAccount)
        internal
        view
        returns (CollateralDebtData memory)
    {
        return ICreditManagerV3(creditManager).calcDebtAndCollateral(creditAccount, CollateralCalcTask.DEBT_COLLATERAL);
    }

    /// @dev Checks whether account's health factor is below `healthFactor`
    function _isLiquidatable(CollateralDebtData memory cdd, uint16 healthFactor) internal pure returns (bool) {
        return cdd.twvUSD < cdd.totalDebtUSD * healthFactor / PERCENTAGE_FACTOR;
    }
}
