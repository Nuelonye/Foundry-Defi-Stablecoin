// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {OracleLib} from "./libraries/OracleLib.sol";
/**
 * @title DSCEngine
 * @author Nuel Onyeka
 *
 * This system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stable coin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC System should always be "overcollateralized". At no point, should the value of all collateral <= the dollar backed value of all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic of minting and redeeming DSC, as well as depositing & withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO DSS (DAI) system.
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////////////
    //          Errors       //
    //////////////////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TransferFailed();
    error DSCEngine__TokenCollateralAndPriceFeedAddressMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__BreaksHealthFactor(uint256 userHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    // Types
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////////////
    //     State Variable    //
    //////////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50;
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant BONUS_AMOUNT = 10; // 10%

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amount) private s_DSCMinted;
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////////////
    //         Events       //
    //////////////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    ///////////////////////////
    //      Modifiers       //
    //////////////////////////
    function _moreThanZero(uint256 amount) private pure {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
    }

    modifier moreThanZero(uint256 amount) {
        // This is just to improve coverage
        // We can decide to use just the modifier
        _moreThanZero(amount);
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////////////////
    //      Functions       //
    //////////////////////////
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenCollateralAndPriceFeedAddressMustBeSameLength();
        }
        // For example ETH / USD, BTC / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////////////
    //  External Functions  //
    //////////////////////////
    /*
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 dscAmountToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(dscAmountToMint);
    }

    /*
    * @notice follows CEI (Checks Effects Interctions)
    * @param tokenCollaterlAddress The address of the token to deposit as collateral
    * @param amountCollateral The amount of collateral to deposit
    */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant // Great ideal when working with external contracts
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        // @dev Wrap tokenCollateral as ERC20 and call the transferFrom function
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // $100 ETH backing $50 DSC ✅
    // $20 ETH backing $50 DSC  ❌ (Won't allow it get here)

    // $75 backing $50 DSC (lower than 50 percent threshold)
    // Liquidator take $75 backing and burns off $50 DSC

    // If someone is almost undercollateralized, we'll pay you to liquidate them!

    /*
     * @param collateral The erc20 collateral address to liquidate from the uer 
     * @param user The user who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR
     * @param debtToCover Amount of DSC to burn to improve users health factor
     * @notice You can partially liquidate a user.
     * @notice You will get a liquidation bonus for taking the users funds
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in other for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we wouldn't be able to incentivise the liquidators
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * 
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address tokenCollateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // Need to check health factor of user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }

        // We want to burn their DSC "debt"
        // And take their collateral
        // Bad User: $140 ETH, $100 DSC
        // debtToCover: $100
        // $100 of DSC == ??? ETH
        // If ETH/USD: 2000e18, $100 DSC == 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(tokenCollateral, debtToCover);

        // We are giving the liquidator 10% bonus so $110 ETH for $100 DSC payment
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury

        // (0.05 * 10) / 100 = 0.005.
        // Liquidator gets 0.055 ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * BONUS_AMOUNT) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;

        _redeemCollateral(user, msg.sender, tokenCollateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved();
        }

        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress The collateral address to redeem
     * @param amountCollateral The amount collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * This function burns DSC and redeems underlying collateral in one transaction
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral Already Checks Health Factor
    }

    ///////////////////////////
    //   Public Functions   //
    //////////////////////////
    /*
     * @notice follows CEI
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice they must have more value than the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // If they minted too much ($150 DSC, but have $100 ETH)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // In order to redeem collateral:
    // 1. health factor must be > 1 AFTER collateral pulled
    function redeemCollateral(address tokenCollateral, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateral, amountCollateral);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // Can burn if nervous about having to much DSC and worried the collateral might tank/fall
    // thereby leading to liquidation of the DSC
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // This Might probably never hit
    }

    // function healthFactor() public {}

    //////////////////////////
    //  Private Functions  //
    /////////////////////////
    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool sucees = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        // revert here is almost unreacheable cause if tranferFrom fails, an error is gonna be thrown
        if (!sucees) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    /////////////////////////////////////////
    //  Private & Internal View Functions  //
    ////////////////////////////////////////
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total collateral VALUE
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

        if (totalDscMinted == 0) return type(uint256).max; // or 1e18

        uint256 adjustedCollateralForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (adjustedCollateralForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor (do they have enough collateral)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    //////////////////////////////////////
    // Public & External View Functions //
    //////////////////////////////////////
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited
        // and map it to the price, to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // We need the ETH value of DSC amount to burn $/ETH
        // Say $100 DSC and ETH/USD is: $2000
        // 100e18/2000e18 == 0.050000000000000000 eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralInUsd)
    {
        (totalDscMinted, totalCollateralInUsd) = _getAccountInformation(user);
    }

    function getUserHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateraltokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }
}
