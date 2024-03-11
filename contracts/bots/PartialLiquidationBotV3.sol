// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {
    AP_TREASURY,
    IAddressProviderV3,
    NO_VERSION_CONTROL
} from "@gearbox-protocol/core-v3/contracts/interfaces/IAddressProviderV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {
    CollateralCalcTask,
    CollateralDebtData,
    ICreditManagerV3
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    CreditAccountNotLiquidatableException,
    IncorrectParameterException,
    NotEnoughCollateralException,
    PriceFeedDoesNotExistException
} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";
import {ReentrancyGuardTrait} from "@gearbox-protocol/core-v3/contracts/traits/ReentrancyGuardTrait.sol";

import {IPartialLiquidationBotV3} from "../interfaces/IPartialLiquidationBotV3.sol";

/// @title Partial liquidation bot V3
/// @author Gearbox Foundation
/// @notice Partial liquidation bot helps to bring credit accounts back to solvency in conditions when liquidity
///         on the market is not enough to convert all account's collateral to underlying for full liquidation.
///         Thanks to special permissons in the bot list, it extends the core system by allowing anyone to repay
///         a fraction of liquidatable credit account's debt in exchange for discounted collateral, as long as
///         account passes a collateral check after the operation.
/// @notice There are certain limitations that liquidators, configurators and account owners should be aware of:
///         - since operation repays debt, an account can't be partially liquidated if its debt is near minimum
///         - due to `withdrawCollateral` inside the liquidation, collateral check with safe prices is triggered,
///           which would only succeed if reserve price feeds for collateral tokens are set in the price oracle
///         - liquidator premium and DAO fee are the same as for the full liquidation in a given credit manager
///           (although fees are sent to the treasury instead of being deposited into pools)
///         - this implementation can't handle fee-on-transfer underlyings
/// @dev Requires permissions for `withdrawCollateral` and `decreaseDebt` calls in the bot list
contract PartialLiquidationBotV3 is IPartialLiquidationBotV3, ContractsRegisterTrait, ReentrancyGuardTrait {
    /// @dev Internal liquidation variables
    struct LiquidationVars {
        address creditManager;
        address creditFacade;
        address priceOracle;
        address underlying;
        uint256 version;
        uint256 scaledFeeLiquidation;
        uint256 scaledLiquidationDiscount;
    }

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @inheritdoc IPartialLiquidationBotV3
    address public immutable override treasury;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override minHealthFactor;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override maxHealthFactor;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override discountScaleFactor;

    /// @inheritdoc IPartialLiquidationBotV3
    uint16 public immutable override feeScaleFactor;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    /// @param minHealthFactor_ Minimum health factor to trigger the liquidation (must be >= `PERCENTAGE_FACTOR`).
    ///        Can be used to setup a liquidation prevention bot that triggers earlier but charges lower fees.
    /// @param maxHealthFactor_ Maximum health factor to allow after the liquidation (must be >= `minHealthFactor_`).
    ///        Can be used to limit the liquidation size. `type(uint16).max` disables the check.
    /// @param discountScaleFactor_ Factor to scale credit manager's liquidation discount (must be <= `PERCENTAGE_FACTOR`)
    /// @param feeScaleFactor_ Factor to scale credit manager's liquidation fee (must be <= `PERCENTAGE_FACTOR`)
    constructor(
        address addressProvider,
        uint16 minHealthFactor_,
        uint16 maxHealthFactor_,
        uint16 discountScaleFactor_,
        uint16 feeScaleFactor_
    ) ContractsRegisterTrait(addressProvider) {
        treasury = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
        if (minHealthFactor_ < PERCENTAGE_FACTOR) revert IncorrectParameterException();
        if (maxHealthFactor_ < minHealthFactor_) revert IncorrectParameterException();
        if (discountScaleFactor_ > PERCENTAGE_FACTOR) revert IncorrectParameterException();
        if (feeScaleFactor_ > PERCENTAGE_FACTOR) revert IncorrectParameterException();
        minHealthFactor = minHealthFactor_;
        maxHealthFactor = maxHealthFactor_;
        discountScaleFactor = discountScaleFactor_;
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
        _applyOnDemandPriceUpdates(vars, priceUpdates);
        _validateLiquidation(vars, creditAccount, token);

        seizedAmount = IPriceOracleV3(vars.priceOracle).convert(repaidAmount, vars.underlying, token)
            * PERCENTAGE_FACTOR / vars.scaledLiquidationDiscount;
        if (seizedAmount < minSeizedAmount) revert SeizedLessThanRequiredException();

        _executeLiquidation(vars, creditAccount, token, repaidAmount, seizedAmount, to);
    }

    /// @inheritdoc IPartialLiquidationBotV3
    function liquidateExactCollateral(
        address creditAccount,
        address token,
        uint256 seizedAmount,
        uint256 maxRepaidAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external override nonReentrant returns (uint256 repaidAmount) {
        LiquidationVars memory vars = _initVars(creditAccount);
        _applyOnDemandPriceUpdates(vars, priceUpdates);
        _validateLiquidation(vars, creditAccount, token);

        repaidAmount = IPriceOracleV3(vars.priceOracle).convert(seizedAmount, token, vars.underlying)
            * vars.scaledLiquidationDiscount / PERCENTAGE_FACTOR;
        if (repaidAmount > maxRepaidAmount) revert RepaidMoreThanAllowedException();

        _executeLiquidation(vars, creditAccount, token, repaidAmount, seizedAmount, to);
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
        vars.version = ICreditManagerV3(vars.creditManager).version();
        (, uint256 feeLiquidation, uint256 liquidationDiscount,,) = ICreditManagerV3(vars.creditManager).fees();
        vars.scaledLiquidationDiscount = liquidationDiscount * discountScaleFactor / PERCENTAGE_FACTOR;
        vars.scaledFeeLiquidation = feeLiquidation * feeScaleFactor / PERCENTAGE_FACTOR;
    }

    /// @dev Applies on-demand price feed updates, reverts if trying to update unknown price feeds
    function _applyOnDemandPriceUpdates(LiquidationVars memory vars, PriceUpdate[] calldata priceUpdates) internal {
        uint256 len = priceUpdates.length;
        for (uint256 i; i < len; ++i) {
            PriceUpdate calldata update = priceUpdates[i];
            address priceFeed = IPriceOracleV3(vars.priceOracle).priceFeedsRaw(update.token, update.reserve);
            if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();
            IUpdatablePriceFeed(priceFeed).updatePrice(update.data);
        }
    }

    /// @dev Ensures that `creditAccount` is liquidatable, its credit manager is registered and `token` is not underlying
    function _validateLiquidation(LiquidationVars memory vars, address creditAccount, address token) internal view {
        _ensureRegisteredCreditManager(vars.creditManager);
        if (token == vars.underlying) revert UnderlyingNotLiquidatableException();

        bool isLiquidatable = _isWorkaroundNeeded(vars)
            ? _isLiquidatableWorkaround(vars.creditManager, creditAccount, minHealthFactor, false)
            : ICreditManagerV3(vars.creditManager).isLiquidatable(creditAccount, minHealthFactor);
        if (!isLiquidatable) revert CreditAccountNotLiquidatableException();
    }

    /// @dev Executes partial liquidation:
    ///      - transfers `repaidAmount` of underlying from the caller to `creditAccount`
    ///      - performs a multicall on `creditAccount` that repays debt, withdraws fee to the treasury,
    ///        and withdraws `seizedAmount` of `token` to `to`
    function _executeLiquidation(
        LiquidationVars memory vars,
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 seizedAmount,
        address to
    ) internal {
        IERC20(vars.underlying).transferFrom(msg.sender, creditAccount, repaidAmount);
        uint256 fee = repaidAmount * vars.scaledFeeLiquidation / PERCENTAGE_FACTOR;
        repaidAmount -= fee;

        MultiCall[] memory calls = new MultiCall[](4);
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
        calls[3] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.setFullCheckParams, (new uint256[](0), minHealthFactor))
        });
        ICreditFacadeV3(vars.creditFacade).botMulticall(creditAccount, calls);

        if (
            _isWorkaroundNeeded(vars)
                && _isLiquidatableWorkaround(vars.creditManager, creditAccount, minHealthFactor, true)
        ) revert NotEnoughCollateralException();

        if (
            maxHealthFactor != type(uint16).max
                && !_isLiquidatableWorkaround(vars.creditManager, creditAccount, maxHealthFactor, true)
        ) revert LiquidatedMoreThanNeededException();

        emit LiquidatePartial(vars.creditManager, creditAccount, token, repaidAmount, seizedAmount, fee);
    }

    /// @dev Whether workaround is needed for collateral check with non-trivial health factor
    function _isWorkaroundNeeded(LiquidationVars memory vars) internal view returns (bool) {
        return vars.version == 3_00 && minHealthFactor > PERCENTAGE_FACTOR;
    }

    /// @dev Collateral check workaround with non-trivial health factor
    function _isLiquidatableWorkaround(
        address creditManager,
        address creditAccount,
        uint16 healthFactor,
        bool useSafePrices
    ) internal view returns (bool) {
        CollateralDebtData memory cdd = ICreditManagerV3(creditManager).calcDebtAndCollateral(
            creditAccount,
            useSafePrices ? CollateralCalcTask.DEBT_COLLATERAL_SAFE_PRICES : CollateralCalcTask.DEBT_COLLATERAL
        );
        return cdd.twvUSD < cdd.totalDebtUSD * healthFactor / PERCENTAGE_FACTOR;
    }
}
