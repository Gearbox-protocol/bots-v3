// SPDX-License-Identifier: MIT
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2024.
pragma solidity ^0.8.17;

import {IVersion} from "@gearbox-protocol/core-v2/contracts/interfaces/IVersion.sol";

/// @title Partial liquidation bot V3
/// @author Gearbox Foundation
interface IPartialLiquidationBotV3 is IVersion {
    // ----- //
    // TYPES //
    // ----- //

    /// @notice Update params for an on-demand price feed in the price oracle
    /// @param token Token to update the price for
    /// @param reserve Whether main or reserve feed should be updated
    /// @param data Update data
    struct PriceUpdate {
        address token;
        bool reserve;
        bytes data;
    }

    // ------ //
    // EVENTS //
    // ------ //

    /// @notice Emitted when `creditManager` is added to the list of allowed credit managers
    event AddCreditManager(address indexed creditManager);

    /// @notice Emitted on successful partial liquidation
    /// @param creditManager Credit manager an account was liquidated in
    /// @param creditAccount Liquidated credit account
    /// @param token Collateral token seized from `creditAccount`
    /// @param repaidAmount Amount of `creditManager`'s underlying repaid
    /// @param feeAmount Amount of `creditManager`'s underlying sent to treasury
    /// @param seizedAmount Amount of `token` seized from `creditAccount`
    event Liquidate(
        address indexed creditManager,
        address indexed creditAccount,
        address indexed token,
        uint256 repaidAmount,
        uint256 feeAmount,
        uint256 seizedAmount
    );

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice Thrown when trying to liquidate an account in the contract that is not an allowed credit manager
    error CreditManagerIsNotAllowedException();

    /// @notice Thrown when amount of underlying repaid is greater than allowed
    error RepaidMoreThanAllowedException();

    /// @notice Thrown when amount of collateral seized is less than required
    error SeizedLessThanRequiredException();

    /// @notice Thrown when trying to specify underlying as token to seize
    error UnderlyingNotLiquidatableException();

    // ----------- //
    // LIQUIDATION //
    // ----------- //

    /// @notice Liquidates credit account by repaying the given amount of its debt in exchange for discounted collateral
    /// @param creditManager Credit manager to liquidate an account in
    /// @param creditAccount Credit account to liquidate
    /// @param token Collateral token to seize
    /// @param repaidAmount Amount of `creditManager`'s underlying to repay
    /// @param minSeizedAmount Minimum amount of `token` to seize from `creditAccount`
    /// @param to Address to send seized `token` to
    /// @param priceUpdates On-demand price feed updates to apply before calculations, see `PriceUpdate` for details
    /// @return seizedAmount Amount of `token` seized
    /// @dev Reverts if `creditManager` is not an allowed credit manager
    /// @dev Reverts if `token` is `creditManager`'s underlying
    /// @dev Reverts if `creditAccount` is not liquidatable after applying `priceUpdates`
    /// @dev Reverts if amount of `token` to be seized is less than `minSeizedAmount`
    function liquidateExactDebt(
        address creditManager,
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external returns (uint256 seizedAmount);

    /// @notice Liquidates credit account by repaying its debt in exchange for the given amount of discounted collateral
    /// @param creditManager Credit manager to liquidate an account in
    /// @param creditAccount Credit account to liquidate
    /// @param token Collateral token to seize
    /// @param seizedAmount Amount of `token` to seize from `creditAccount`
    /// @param maxRepaidAmount Maxiumum amount of `creditManager`'s underlying to repay
    /// @param to Address to send seized `token` to
    /// @param priceUpdates On-demand price feed updates to apply before calculations, see `PriceUpdate` for details
    /// @return repaidAmount Amount of `creditManager`'s underlying repaid
    /// @dev Reverts if `creditManager` is not an allowed credit manager
    /// @dev Reverts if `token` is `creditManager`'s underlying
    /// @dev Reverts if `creditAccount` is not liquidatable after applying `priceUpdates`
    /// @dev Reverts if amount of underlying to be repaid is greater than `maxRepaidAmount`
    function liquidateExactCollateral(
        address creditManager,
        address creditAccount,
        address token,
        uint256 seizedAmount,
        uint256 maxRepaidAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external returns (uint256 repaidAmount);

    // ------------- //
    // CONFIGURATION //
    // ------------- //

    /// @notice Returns the list of allowed credit managers
    function creditManagers() external view returns (address[] memory);

    /// @notice Allows `creditManager`'s accounts to be liquidated with this bot (one-way action)
    /// @dev This bot must in turn be allowed to make `addCollateral`, `withdrawCollateral` and `decreaseDebt` calls
    ///      in `creditManager`'s accounts by giving it special permissions in the bot list
    /// @dev Approves underlying to `creditManager` to be able to perform `addCollateral` calls
    /// @dev Reverts if `creditManager` is not a registered credit manager
    /// @dev Reverts if caller is not configurator
    function addCreditManager(address creditManager) external;

    /// @notice Withdraws `amount` of accumulated fees in `token` to `to`
    /// @dev If `amount` is `type(uint256).max`, withdraws full balance
    /// @dev Reverts if caller is not configurator
    function withdrawFees(address token, uint256 amount, address to) external;
}
