// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

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
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    CreditAccountNotLiquidatableException,
    PriceFeedDoesNotExistException
} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ReentrancyGuardTrait} from "@gearbox-protocol/core-v3/contracts/traits/ReentrancyGuardTrait.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
/// @dev Absence of validation that interacted contracts are part of Gearbox is intentional
contract PartialLiquidationBotV3 is IPartialLiquidationBotV3, ReentrancyGuardTrait {
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
    uint256 public constant override version = 3_00;

    /// @inheritdoc IPartialLiquidationBotV3
    address public immutable override treasury;

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider) {
        treasury = IAddressProviderV3(addressProvider).getAddressOrRevert(AP_TREASURY, NO_VERSION_CONTROL);
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
            * PERCENTAGE_FACTOR / vars.liquidationDiscount;
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
            * vars.liquidationDiscount / PERCENTAGE_FACTOR;
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
        (, vars.feeLiquidation, vars.liquidationDiscount,,) = ICreditManagerV3(vars.creditManager).fees();
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

    /// @dev Ensures that `creditAccount` is liquidatable and `token` is not underlying
    function _validateLiquidation(LiquidationVars memory vars, address creditAccount, address token) internal view {
        if (token == vars.underlying) revert UnderlyingNotLiquidatableException();
        if (!ICreditManagerV3(vars.creditManager).isLiquidatable(creditAccount, PERCENTAGE_FACTOR)) {
            revert CreditAccountNotLiquidatableException();
        }
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
        uint256 fee = repaidAmount * vars.feeLiquidation / PERCENTAGE_FACTOR;

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

        emit LiquidatePartial(vars.creditManager, creditAccount, token, repaidAmount - fee, seizedAmount, fee);
    }
}
