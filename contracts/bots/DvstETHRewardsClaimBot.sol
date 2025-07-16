// SPDX-License-Identifier: GPL-2.0-or-later
// Gearbox Protocol. Generalized leverage for DeFi protocols
// (c) Gearbox Foundation, 2025.
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IBot} from "@gearbox-protocol/core-v3/contracts/interfaces/base/IBot.sol";
import {PERCENTAGE_FACTOR} from "@gearbox-protocol/core-v3/contracts/libraries/Constants.sol";
import {
    ICreditFacadeV3Multicall,
    EXTERNAL_CALLS_PERMISSION,
    UPDATE_QUOTA_PERMISSION
} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3Multicall.sol";
import {ICreditFacadeV3, MultiCall} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditFacadeV3.sol";
import {ICreditManagerV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditManagerV3.sol";
import {ICreditAccountV3} from "@gearbox-protocol/core-v3/contracts/interfaces/ICreditAccountV3.sol";
import {IPriceOracleV3} from "@gearbox-protocol/core-v3/contracts/interfaces/IPriceOracleV3.sol";
import {ISwapRouter} from "@gearbox-protocol/integrations-v3/contracts/integrations/uniswap/IUniswapV3.sol";
import {IUniswapV3Adapter} from "@gearbox-protocol/integrations-v3/contracts/interfaces/uniswap/IUniswapV3Adapter.sol";
import {BalanceDelta} from "@gearbox-protocol/core-v3/contracts/libraries/BalancesLogic.sol";

struct ObolClaimData {
    address distributor;
    uint256 index;
    uint256 amount;
    bytes32[] merkleProof;
}

struct SsvClaimData {
    address distributor;
    uint256 cumulativeAmount;
    bytes32 expectedMerkleRoot;
    bytes32[] merkleProof;
}

interface IObolDistributor {
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata merkleProof) external;
}

interface ISsvDistributor {
    function claim(
        address account,
        uint256 cumulativeAmount,
        bytes32 expectedMerkleRoot,
        bytes32[] calldata merkleProof
    ) external;
}

contract DvstETHRewardsClaimBot is IBot {
    uint256 public constant override version = 3_10;

    bytes32 public constant override contractType = "BOT::DVSTETH_REWARDS_CLAIM";

    uint192 public constant override requiredPermissions = EXTERNAL_CALLS_PERMISSION | UPDATE_QUOTA_PERMISSION;

    address public constant uniV3Router = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address public immutable obol;

    address public immutable ssv;

    address public immutable weth;

    uint24 public immutable obolUniV3PoolFee;

    uint24 public immutable ssvUniV3PoolFee;

    uint16 public immutable maxSlippage;

    constructor(
        address _obol,
        address _ssv,
        address _weth,
        uint24 _obolUniV3PoolFee,
        uint24 _ssvUniV3PoolFee,
        uint16 _maxSlippage
    ) {
        obol = _obol;
        ssv = _ssv;
        weth = _weth;
        obolUniV3PoolFee = _obolUniV3PoolFee;
        ssvUniV3PoolFee = _ssvUniV3PoolFee;
        maxSlippage = _maxSlippage;
    }

    function claimAndReinvest(
        address creditAccount,
        ObolClaimData calldata obolClaimData,
        SsvClaimData calldata ssvClaimData
    ) public {
        uint256 obolAmount = _claimObolRewards(creditAccount, obolClaimData);
        uint256 ssvAmount = _claimSsvRewards(creditAccount, ssvClaimData);

        _reinvestRewards(creditAccount, obolAmount, ssvAmount);
    }

    function _claimObolRewards(address creditAccount, ObolClaimData calldata obolClaimData)
        internal
        returns (uint256 obolAmount)
    {
        uint256 balanceBefore = IERC20(obol).balanceOf(creditAccount);

        IObolDistributor(obolClaimData.distributor).claim(
            obolClaimData.index, creditAccount, obolClaimData.amount, obolClaimData.merkleProof
        );

        return IERC20(obol).balanceOf(creditAccount) - balanceBefore;
    }

    function _claimSsvRewards(address creditAccount, SsvClaimData calldata ssvClaimData)
        internal
        returns (uint256 ssvAmount)
    {
        uint256 balanceBefore = IERC20(ssv).balanceOf(creditAccount);

        ISsvDistributor(ssvClaimData.distributor).claim(
            creditAccount, ssvClaimData.cumulativeAmount, ssvClaimData.expectedMerkleRoot, ssvClaimData.merkleProof
        );

        return IERC20(ssv).balanceOf(creditAccount) - balanceBefore;
    }

    function _reinvestRewards(address creditAccount, uint256 obolAmount, uint256 ssvAmount) internal {
        address creditManager = ICreditAccountV3(creditAccount).creditManager();
        address creditFacade = ICreditManagerV3(creditManager).creditFacade();
        address priceOracle = ICreditManagerV3(creditManager).priceOracle();
        address uniV3Adapter = ICreditManagerV3(creditManager).contractToAdapter(uniV3Router);

        MultiCall[] memory calls =
            _getCalls(creditAccount, creditFacade, priceOracle, uniV3Adapter, obolAmount, ssvAmount);

        ICreditFacadeV3(creditFacade).botMulticall(creditAccount, calls);
    }

    function _getCalls(
        address creditAccount,
        address creditFacade,
        address priceOracle,
        address uniV3Adapter,
        uint256 obolAmount,
        uint256 ssvAmount
    ) internal view returns (MultiCall[] memory calls) {
        uint256 wethEquivalent = IPriceOracleV3(priceOracle).convert(obolAmount, obol, weth)
            + IPriceOracleV3(priceOracle).convert(ssvAmount, ssv, weth);

        uint256 expectedWethDelta = wethEquivalent * (PERCENTAGE_FACTOR - maxSlippage) / PERCENTAGE_FACTOR;

        calls = new MultiCall[](5);

        BalanceDelta[] memory balanceDeltas = new BalanceDelta[](1);

        balanceDeltas[0] = BalanceDelta({token: weth, amount: int256(expectedWethDelta)});

        calls[0] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(ICreditFacadeV3Multicall.storeExpectedBalances, (balanceDeltas))
        });

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: obol,
            fee: obolUniV3PoolFee,
            recipient: creditAccount,
            deadline: block.timestamp,
            amountIn: obolAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        calls[1] =
            MultiCall({target: uniV3Adapter, callData: abi.encodeCall(IUniswapV3Adapter.exactInputSingle, (params))});

        params = ISwapRouter.ExactInputSingleParams({
            tokenIn: weth,
            tokenOut: ssv,
            fee: ssvUniV3PoolFee,
            recipient: creditAccount,
            deadline: block.timestamp,
            amountIn: ssvAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        calls[2] =
            MultiCall({target: uniV3Adapter, callData: abi.encodeCall(IUniswapV3Adapter.exactInputSingle, (params))});

        calls[3] = MultiCall({
            target: creditFacade,
            callData: abi.encodeCall(
                ICreditFacadeV3Multicall.updateQuota, (weth, int96(uint96(wethEquivalent)), uint96(wethEquivalent))
            )
        });

        calls[4] =
            MultiCall({target: creditFacade, callData: abi.encodeCall(ICreditFacadeV3Multicall.compareBalances, ())});
    }

    function serialize() external view returns (bytes memory serializedData) {
        serializedData = abi.encode(obol, ssv, weth, obolUniV3PoolFee, ssvUniV3PoolFee, maxSlippage);
    }
}
