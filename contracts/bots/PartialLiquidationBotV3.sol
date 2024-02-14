// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {
    CreditAccountNotLiquidatableException,
    PriceFeedDoesNotExistException
} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

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
///           (although fees are accumulated in this contract instead of being deposited into pools)
///         - this implementation can't handle fee-on-transfer underlyings
contract PartialLiquidationBotV3 is IPartialLiquidationBotV3, ACLNonReentrantTrait, ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Internal liquidation variables
    struct LiquidationVars {
        address creditManager;
        address creditFacade;
        address priceOracle;
        address underlying;
        uint256 feeRate;
        uint256 discountRate;
    }

    /// @inheritdoc IVersion
    uint256 public constant override version = 3_00;

    /// @dev Set of allowed credit managers
    EnumerableSet.AddressSet internal _creditManagersSet;

    /// @dev Ensures that `creditManager` is an allowed credit manager
    modifier allowedCreditManagersOnly(address creditManager) {
        if (!_creditManagersSet.contains(creditManager)) revert CreditManagerIsNotAllowedException();
        _;
    }

    /// @notice Constructor
    /// @param addressProvider Address provider contract address
    constructor(address addressProvider)
        ACLNonReentrantTrait(addressProvider)
        ContractsRegisterTrait(addressProvider)
    {}

    // ----------- //
    // LIQUIDATION //
    // ----------- //

    /// @inheritdoc IPartialLiquidationBotV3
    function liquidateExactDebt(
        address creditManager,
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external override nonReentrant allowedCreditManagersOnly(creditManager) returns (uint256 seizedAmount) {
        LiquidationVars memory vars = _initVars(creditManager);
        _checkLiquidation(vars, creditAccount, token, priceUpdates);

        seizedAmount = IPriceOracleV3(vars.priceOracle).convert(repaidAmount, vars.underlying, token)
            * PERCENTAGE_FACTOR / vars.discountRate;
        if (seizedAmount < minSeizedAmount) revert SeizedLessThanRequiredException();

        _executeLiquidation(vars, creditAccount, token, repaidAmount, seizedAmount, to);
    }

    /// @inheritdoc IPartialLiquidationBotV3
    function liquidateExactCollateral(
        address creditManager,
        address creditAccount,
        address token,
        uint256 seizedAmount,
        uint256 maxRepaidAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external override nonReentrant allowedCreditManagersOnly(creditManager) returns (uint256 repaidAmount) {
        LiquidationVars memory vars = _initVars(creditManager);
        _checkLiquidation(vars, creditAccount, token, priceUpdates);

        repaidAmount = IPriceOracleV3(vars.priceOracle).convert(seizedAmount, token, vars.underlying)
            * vars.discountRate / PERCENTAGE_FACTOR;
        if (repaidAmount > maxRepaidAmount) revert RepaidMoreThanAllowedException();

        _executeLiquidation(vars, creditAccount, token, repaidAmount, seizedAmount, to);
    }

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @inheritdoc IPartialLiquidationBotV3
    function creditManagers() external view override returns (address[] memory) {
        return _creditManagersSet.values();
    }

    /// @inheritdoc IPartialLiquidationBotV3
    function addCreditManager(address creditManager)
        external
        override
        configuratorOnly
        registeredCreditManagerOnly(creditManager)
    {
        if (_creditManagersSet.contains(creditManager)) return;
        _creditManagersSet.add(creditManager);
        emit AddCreditManager(creditManager);

        address underlying = ICreditManagerV3(creditManager).underlying();
        IERC20(underlying).approve(creditManager, type(uint256).max);
    }

    /// @inheritdoc IPartialLiquidationBotV3
    function withdrawFees(address token, uint256 amount, address to) external override configuratorOnly {
        if (amount == type(uint256).max) amount = IERC20(token).balanceOf(address(this));
        IERC20(token).transfer(to, amount);
    }

    // --------- //
    // INTERNALS //
    // --------- //

    /// @dev Loads `creditManager`'s state variables used in liquidation
    function _initVars(address creditManager) internal view returns (LiquidationVars memory vars) {
        vars.creditManager = creditManager;
        vars.creditFacade = ICreditManagerV3(creditManager).creditFacade();
        vars.priceOracle = ICreditManagerV3(creditManager).priceOracle();
        vars.underlying = ICreditManagerV3(creditManager).underlying();
        (, vars.feeRate, vars.discountRate,,) = ICreditManagerV3(creditManager).fees();
    }

    /// @dev Internal function that checks liquidation validity:
    ///      - `token` is not underlying
    ///      - `creditAccount` is liquidatable after applying `priceUpdates`
    function _checkLiquidation(
        LiquidationVars memory vars,
        address creditAccount,
        address token,
        PriceUpdate[] calldata priceUpdates
    ) internal {
        if (token == vars.underlying) revert UnderlyingNotLiquidatableException();

        uint256 len = priceUpdates.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                PriceUpdate calldata update = priceUpdates[i];
                address priceFeed = IPriceOracleV3(vars.priceOracle).priceFeedsRaw(update.token, update.reserve);
                if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();
                IUpdatablePriceFeed(priceFeed).updatePrice(update.data);
            }
        }
        if (!ICreditManagerV3(vars.creditManager).isLiquidatable(creditAccount, PERCENTAGE_FACTOR)) {
            revert CreditAccountNotLiquidatableException();
        }
    }

    /// @dev Internal function that executes liquidation:
    ///      - transfers `repaidAmount` of underlying from the caller
    ///      - performs a multicall on `creditAccount` that repays debt and withdraws `seizedAmount` of `token` to `to`
    function _executeLiquidation(
        LiquidationVars memory vars,
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 seizedAmount,
        address to
    ) internal {
        IERC20(vars.underlying).transferFrom(msg.sender, address(this), repaidAmount);
        repaidAmount -= repaidAmount * vars.feeRate / PERCENTAGE_FACTOR;

        MultiCall[] memory calls = new MultiCall[](3);
        calls[0] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (vars.underlying, repaidAmount))
        });
        calls[1] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (repaidAmount))
        });
        calls[2] = MultiCall({
            target: vars.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, seizedAmount, to))
        });
        ICreditFacadeV3(vars.creditFacade).botMulticall(creditAccount, calls);

        emit Liquidate(vars.creditManager, creditAccount, token, repaidAmount, seizedAmount);
    }
}
