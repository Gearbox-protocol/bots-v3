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

    /// @notice Emitted on successful partial liquidation
    /// @param creditManager Credit manager an account was liquidated in
    /// @param creditAccount Liquidated credit account
    /// @param token Collateral token seized from `creditAccount`
    /// @param repaidDebt Amount of `creditAccount`'s debt repaid
    /// @param seizedCollateral Amount of `token` seized from `creditAccount`
    /// @param fee Amount of underlying sent to the treasury as liqudiation fee
    event LiquidatePartial(
        address indexed creditManager,
        address indexed creditAccount,
        address indexed token,
        uint256 repaidDebt,
        uint256 seizedCollateral,
        uint256 fee
    );

    // ------ //
    // ERRORS //
    // ------ //

    /// @notice Thrown when health factor after liquidation is less than minimum allowed
    error LiquidatedLessThanNeededException();

    /// @notice Thrown when health factor after liquidation is greater than maximum allowed
    error LiquidatedMoreThanNeededException();

    /// @notice Thrown when amount of underlying repaid is greater than allowed
    error RepaidMoreThanAllowedException();

    /// @notice Thrown when amount of collateral seized is less than required
    error SeizedLessThanRequiredException();

    /// @notice Thrown when trying to specify underlying as token to seize
    error UnderlyingNotLiquidatableException();

    // ----------- //
    // LIQUIDATION //
    // ----------- //

    /// @notice Treasury to send liquidation fees to
    function treasury() external view returns (address);

    /// @notice Minimum health factor at which the liquidation is triggered
    function minHealthFactor() external view returns (uint16);

    /// @notice Maximum health factor allowed after the liquidation
    function maxHealthFactor() external view returns (uint16);

    /// @notice Scale factor of credit manager's liquidation premium
    function premiumScaleFactor() external view returns (uint16);

    /// @notice Scale factor of credit manager's liquidation fee
    function feeScaleFactor() external view returns (uint16);

    /// @notice Liquidates credit account by repaying the given amount of its debt in exchange for discounted collateral
    /// @param creditAccount Credit account to liquidate
    /// @param token Collateral token to seize
    /// @param repaidAmount Amount of underlying to repay
    /// @param minSeizedAmount Minimum amount of `token` to seize from `creditAccount`
    /// @param to Address to send seized `token` to
    /// @param priceUpdates On-demand price feed updates to apply before calculations, see `PriceUpdate` for details
    /// @return seizedAmount Amount of `token` seized
    /// @dev Requires underlying token approval from caller to this contract
    /// @dev Reverts if `creditAccount`'s credit manager is not registered
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `priceUpdates` contains updates of unknown feeds
    /// @dev Reverts if `creditAccount`'s health factor is not less than `minHealthFactor` before liquidation
    /// @dev Reverts if amount of `token` to be seized is less than `minSeizedAmount`
    /// @dev Reverts if `creditAccount`'s health factor is not within allowed range after liquidation
    function liquidateExactDebt(
        address creditAccount,
        address token,
        uint256 repaidAmount,
        uint256 minSeizedAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external returns (uint256 seizedAmount);

    /// @notice Liquidates credit account by repaying its debt in exchange for the given amount of discounted collateral
    /// @param creditAccount Credit account to liquidate
    /// @param token Collateral token to seize
    /// @param seizedAmount Amount of `token` to seize from `creditAccount`
    /// @param maxRepaidAmount Maxiumum amount of underlying to repay
    /// @param to Address to send seized `token` to
    /// @param priceUpdates On-demand price feed updates to apply before calculations, see `PriceUpdate` for details
    /// @return repaidAmount Amount of underlying repaid
    /// @dev Requires underlying token approval from caller to this contract
    /// @dev Reverts if `creditAccount`'s credit manager is not registered
    /// @dev Reverts if `token` is underlying
    /// @dev Reverts if `priceUpdates` contains updates of unknown feeds
    /// @dev Reverts if `creditAccount`'s health factor is not less than `minHealthFactor` before liquidation
    /// @dev Reverts if amount of underlying to be repaid is greater than `maxRepaidAmount`
    /// @dev Reverts if `creditAccount`'s health factor is not within allowed range after liquidation
    function liquidateExactCollateral(
        address creditAccount,
        address token,
        uint256 seizedAmount,
        uint256 maxRepaidAmount,
        address to,
        PriceUpdate[] calldata priceUpdates
    ) external returns (uint256 repaidAmount);
}
