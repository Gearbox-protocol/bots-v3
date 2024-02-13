// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IUpdatablePriceFeed} from "@gearbox-protocol/core-v2/contracts/interfaces/IPriceFeed.sol";
import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v2/contracts/libraries/Constants.sol";
import {MultiCall} from "@gearbox-protocol/core-v2/contracts/libraries/MultiCall.sol";

import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditFacadeV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditFacadeV3Multicall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {
    CreditAccountNotLiquidatableException,
    PriceFeedDoesNotExistException
} from "@gearbox-protocol/core-v3/contracts/interfaces/IExceptions.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ACLNonReentrantTrait} from "@gearbox-protocol/core-v3/contracts/traits/ACLNonReentrantTrait.sol";
import {ContractsRegisterTrait} from "@gearbox-protocol/core-v3/contracts/traits/ContractsRegisterTrait.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
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
///           (although fees are accumulated in this contract instead of being deposited into pools)
///         - this implementation can't handle fee-on-transfer underlyings
contract PartialLiquidationBotV3 is IPartialLiquidationBotV3, ACLNonReentrantTrait, ContractsRegisterTrait {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @dev Internal liquidation state
    struct LiquidationState {
        address creditManager;
        address creditFacade;
        address priceOracle;
        address underlying;
        uint256 feeRate;
        uint256 discountRate;
        uint256 repaidAmount;
        uint256 seizedAmount;
        uint256 feeAmount;
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
    ) external override nonReentrant allowedCreditManagersOnly(creditManager) returns (uint256) {
        LiquidationState memory state = _initState(creditManager);
        _checkLiquidation(state, creditAccount, token, priceUpdates);

        state.repaidAmount = repaidAmount;
        (state.seizedAmount, state.feeAmount) = _getAmountsExactDebt(state, token);
        if (state.seizedAmount < minSeizedAmount) revert SeizedLessThanRequiredException();

        _executeLiquidation(state, creditAccount, token, to);
        return state.seizedAmount;
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
    ) external override nonReentrant allowedCreditManagersOnly(creditManager) returns (uint256) {
        LiquidationState memory state = _initState(creditManager);
        _checkLiquidation(state, creditAccount, token, priceUpdates);

        state.seizedAmount = seizedAmount;
        (state.repaidAmount, state.feeAmount) = _getAmountsExactCollateral(state, token);
        if (state.repaidAmount > maxRepaidAmount) revert RepaidMoreThanAllowedException();

        _executeLiquidation(state, creditAccount, token, to);
        return state.repaidAmount;
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

    function _initState(address creditManager) internal view returns (LiquidationState memory state) {
        state.creditManager = creditManager;
        state.creditFacade = ICreditManagerV3(creditManager).creditFacade();
        state.priceOracle = ICreditManagerV3(creditManager).priceOracle();
        state.underlying = ICreditManagerV3(creditManager).underlying();
        (, state.feeRate, state.discountRate,,) = ICreditManagerV3(creditManager).fees();
    }

    function _checkLiquidation(
        LiquidationState memory state,
        address creditAccount,
        address token,
        PriceUpdate[] calldata priceUpdates
    ) internal {
        if (token == state.underlying) revert UnderlyingNotLiquidatableException();

        uint256 len = priceUpdates.length;
        unchecked {
            for (uint256 i; i < len; ++i) {
                PriceUpdate calldata update = priceUpdates[i];
                address priceFeed = IPriceOracleV3(state.priceOracle).priceFeedsRaw(update.token, update.reserve);
                if (priceFeed == address(0)) revert PriceFeedDoesNotExistException();
                IUpdatablePriceFeed(priceFeed).updatePrice(update.data);
            }
        }
        if (!ICreditManagerV3(state.creditManager).isLiquidatable(creditAccount, PERCENTAGE_FACTOR)) {
            revert CreditAccountNotLiquidatableException();
        }
    }

    function _getAmountsExactDebt(LiquidationState memory state, address token)
        internal
        view
        returns (uint256 seizedAmount, uint256 feeAmount)
    {
        feeAmount = state.repaidAmount * state.feeRate / PERCENTAGE_FACTOR;
        uint256 repaidDebt = state.repaidAmount - feeAmount;
        seizedAmount = IPriceOracleV3(state.priceOracle).convert(repaidDebt, state.underlying, token)
            * PERCENTAGE_FACTOR / state.discountRate;
    }

    function _getAmountsExactCollateral(LiquidationState memory state, address token)
        internal
        view
        returns (uint256 repaidAmount, uint256 feeAmount)
    {
        uint256 repaidDebt = IPriceOracleV3(state.priceOracle).convert(state.seizedAmount, token, state.underlying)
            * state.discountRate / PERCENTAGE_FACTOR;
        feeAmount = repaidAmount * state.feeRate / (PERCENTAGE_FACTOR - state.feeRate);
        repaidAmount = repaidDebt + feeAmount;
    }

    function _executeLiquidation(LiquidationState memory state, address creditAccount, address token, address to)
        internal
    {
        IERC20(state.underlying).transferFrom(msg.sender, address(this), state.repaidAmount);
        uint256 repaidDebt = state.repaidAmount - state.feeAmount;

        MultiCall[] memory calls = new MultiCall[](3);
        calls[0] = MultiCall({
            target: state.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.addCollateral, (state.underlying, repaidDebt))
        });
        calls[1] = MultiCall({
            target: state.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.decreaseDebt, (repaidDebt))
        });
        calls[2] = MultiCall({
            target: state.creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.withdrawCollateral, (token, state.seizedAmount, to))
        });
        ICreditFacadeV3(state.creditFacade).botMulticall(creditAccount, calls);

        emit Liquidate(state.creditManager, creditAccount, token, repaidDebt, state.seizedAmount);
    }
}
