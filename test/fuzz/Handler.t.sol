// SPDX-License-Identifier: MIT

// Handler is going to narrow down the way we call function

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

// We also need to handle other contracts that our protocol interact with
// Price Feed(Focus is here for now)
// WETH
// WBTC
contract Handler is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    ERC20Mock wethToken;
    ERC20Mock wbtcToken;

    uint256 public timesMintIsCalled;
    uint256 public timesRedeemIsCalled;
    address[] public userWithCollateralDeposited;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 MAX_DEPOSIT_SIZE = type(uint96).max; // the max uint96 value

    constructor(DSCEngine _engine, DecentralizedStableCoin _dsc) {
        dsce = _engine;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateraltokens();
        wethToken = ERC20Mock(collateralTokens[0]);
        wbtcToken = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(wethToken)));
    }

    // deposit collateral <--
    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), amountCollateral);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();

        for (uint256 i = 0; i < userWithCollateralDeposited.length; i++) {
            if (userWithCollateralDeposited[i] == msg.sender) return;
        }
        // This may double push addresses if an address is used to call the function more than once
        userWithCollateralDeposited.push(msg.sender);
    }

    // redeem collateral <--
    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral, uint256 addressSeed) public {
        if (userWithCollateralDeposited.length == 0) return;

        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        // Get the amount to of a collateral token a user deposited, they might deposit weth and not wbtc
        uint256 maxCollateral = dsce.getCollateralBalanceOfUser(sender, address(collateral));
        // if nothing deposited, nothing to do
        if (maxCollateral == 0) return;

        // bound incoming fuzzed amount to user's actual token balance (avoid huge values)
        amountCollateral = bound(amountCollateral, 0, maxCollateral);
        if (amountCollateral == 0) return;

        // Get user's account data
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(sender);

        uint256 maxTokensToRedeem;

        if (totalDscMinted == 0) {
            // user has no debt → can withdraw everything (but still clamp to balance)
            maxTokensToRedeem = maxCollateral;
        } else {
            // compute minimum collateral (USD) required to keep health factor >= MIN_HEALTH_FACTOR
            // requiredCollateralUsd = (MIN_HEALTH_FACTOR * totalDscMinted * LIQUIDATION_PRECISION)
            //                       / (LIQUIDATION_THRESHOLD * PRECISION)
            uint256 requiredCollateralUsd = (dsce.getMinHealthFactor()
                    * totalDscMinted
                    * dsce.getLiquidationPrecision()) / (dsce.getLiquidationThreshold() * dsce.getPrecision());

            // if requiredCollateralUsd >= collateralValueInUsd => they can't redeem anything safely
            if (requiredCollateralUsd >= collateralValueInUsd) {
                return;
            }

            uint256 maxRedeemableInUsd = collateralValueInUsd - requiredCollateralUsd;

            // convert USD -> token amount (must handle scaling inside this helper)
            maxTokensToRedeem = dsce.getTokenAmountFromUsd(address(collateral), maxRedeemableInUsd);

            // clamp to existing deposited balance
            if (maxTokensToRedeem > maxCollateral) {
                maxTokensToRedeem = maxCollateral;
            }
        }

        // finally bound the fuzzed amount to maxTokensToRedeem
        amountCollateral = bound(amountCollateral, 0, maxTokensToRedeem);
        if (amountCollateral == 0) return;

        vm.startPrank(sender);
        dsce.redeemCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        timesRedeemIsCalled++;
    }

    // mint DSC <--
    function mintDsc(uint256 amountToMint, uint256 addressSeed) public {
        if (userWithCollateralDeposited.length == 0) {
            return;
        }

        address sender = userWithCollateralDeposited[addressSeed % userWithCollateralDeposited.length];
        (uint256 totalDscMint, uint256 totalCollateralValue) = dsce.getAccountInformation(sender);

        // Makes sure they can only mint at maximum half of their entire collateral
        // In other not to break health factor
        int256 maxDscToMint = (int256(totalCollateralValue) / 2) - int256(totalDscMint); // uint don't recognize negative
        if (maxDscToMint < 0) {
            return;
        }

        amountToMint = bound(amountToMint, 0, uint256(maxDscToMint));
        if (amountToMint == 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
        timesMintIsCalled++;
    }

    // This breaks our invariant test suite
    // If the price of an asset pluumets too quickly the system is breaking
    // function updateCollateralPrice(uint96 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return wethToken;
        }
        return wbtcToken;
    }

    // function _getRedeemableAmount(address sender, ERC20Mock collateral) private returns (uint256) {}
}
