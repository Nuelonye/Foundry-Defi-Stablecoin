// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    DeployDSC deployer;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address wethToken;
    address wbtcToken;

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");

    uint256 public constant AMOUNT_COLLATERAL = 10e18;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    function setUp() public {
        config = new HelperConfig();
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, wethToken, wbtcToken,,) = config.activeNetworkConfig();
        ERC20Mock(wethToken).mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(wbtcToken).mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(wethToken).mint(LIQUIDATOR, AMOUNT_COLLATERAL * 3);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TEST
    //////////////////////////////////////////////////////////////*/
    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeeds() public {
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);
        tokenAddresses.push(wethToken);
        vm.expectRevert(DSCEngine.DSCEngine__TokenCollateralAndPriceFeedAddressMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                               PRICE TEST
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public view {
        uint256 wethAmount = 15e18;
        uint256 expectedUsdValue = 30000e18;

        uint256 actualUsdValue = dsce.getUsdValue(wethToken, wethAmount);
        assertEq(expectedUsdValue, actualUsdValue);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmountInWei = 4000e18;
        uint256 expectedWethValue = 2e18; // 4000/2000 = 2e18

        uint256 actualWethValue = dsce.getTokenAmountFromUsd(wethToken, usdAmountInWei);
        assertEq(expectedWethValue, actualWethValue);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        ERC20Mock(wbtcToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wethToken, AMOUNT_COLLATERAL);
        dsce.depositCollateral(wbtcToken, AMOUNT_COLLATERAL);
        vm.stopPrank();

        // USER deposit 10e18 WETH, 10e18 * $2,000 = $20,000
        // and another 10e18 WBTC, 10e18 * $1,000 = $10,000
        // Total $30,000
        uint256 expectedValueInUsd = 30_000e18;
        uint256 totalCollateralInUsd = dsce.getAccountCollateralValue(USER);
        assertEq(expectedValueInUsd, totalCollateralInUsd);
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT COLLATERAL TEST
    //////////////////////////////////////////////////////////////*/
    function testRevertIfCollateralIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(wethToken, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(randomToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertIfTransferToEngineFails() public {
        bytes memory depositCall =
            abi.encodeWithSelector(IERC20(wethToken).transferFrom.selector, USER, address(dsce), AMOUNT_COLLATERAL);

        vm.mockCall(
            address(wethToken), // Mock call token contract
            depositCall, // Using encoded callData
            abi.encode(false) // Set transaction to always return false
        );

        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.depositCollateral(wethToken, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(wethToken, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInformation() public depositedCollateral {
        uint256 expectedDscMinted = 0;
        uint256 expectedCollateralValueInUsd = 20000e18; // 10e18 * 2000 = 20,000e18
        (uint256 actualDscMinted, uint256 actualCollateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(expectedDscMinted, actualDscMinted);
        assertEq(expectedCollateralValueInUsd, actualCollateralValueInUsd);
    }

    function testDepositCollateralEmitsEvent() public {
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.stopPrank();

        // Act & Assert: Expect the event
        vm.expectEmit(true, true, true, false);
        emit CollateralDeposited(USER, wethToken, AMOUNT_COLLATERAL);

        // Call the function
        vm.prank(USER);
        dsce.depositCollateral(wethToken, AMOUNT_COLLATERAL);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT DSC TEST
    //////////////////////////////////////////////////////////////*/
    function testRevertIfMintAmountIsZero() public depositedCollateral {
        uint256 dscAmount = 0;

        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(dscAmount);
    }

    function testValueBeforeAndAfterMint() public depositedCollateral {
        uint256 dscAmount = 1000e18;

        vm.startPrank(USER);
        dsce.mintDsc(dscAmount);
        vm.stopPrank();

        (uint256 dscMinted,) = dsce.getAccountInformation(USER);
        assertEq(dscMinted, dscAmount);
    }

    function testRevertIfMintBreaksHealthFactor() public {
        uint256 dscAmountToMint = 100;
        uint256 expectedHealthFactor = 0;

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        vm.prank(USER);
        dsce.mintDsc(dscAmountToMint); // Mint without Depositing collateral
    }

    function testMintDscRevertsIfMintFails() public depositedCollateral {
        uint256 dscAmountToMint = 1000e18;

        bytes memory mintCall = abi.encodeWithSelector(dsc.mint.selector, USER, dscAmountToMint);

        vm.mockCall(
            address(dsc), // Mock call token contract
            mintCall, // Using encoded callData
            abi.encode(false) // Set transaction to always return false
        );

        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        dsce.mintDsc(dscAmountToMint);
    }

    function testCanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 dscAmountToMint = 100;
        vm.prank(USER);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL, dscAmountToMint);
    }

    /*//////////////////////////////////////////////////////////////
                         REDEEM COLLATERAL TEST
    //////////////////////////////////////////////////////////////*/
    function testRedeemCollateral() public depositedCollateral {
        vm.prank(USER);
        dsce.redeemCollateral(wethToken, AMOUNT_COLLATERAL);

        uint256 expectedCollateralValue = 0;
        (, uint256 actualCollateralValue) = dsce.getAccountInformation(USER);

        assertEq(expectedCollateralValue, actualCollateralValue);
    }

    function testRedeemCollateralRevertIfTranferFails() public depositedCollateral {
        bytes memory transferCall = abi.encodeWithSelector(IERC20(wethToken).transfer.selector, USER, AMOUNT_COLLATERAL);

        vm.mockCall(
            address(wethToken), // Mock call token contract
            transferCall, // Using encoded callData
            abi.encode(false) // Set transaction to always return false
        );

        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.redeemCollateral(wethToken, AMOUNT_COLLATERAL);
    }

    function testRedeemCollateralForDscMinted() public {
        uint256 dscAmount = 1000e18;

        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL, dscAmount);
        vm.stopPrank();
        (uint256 dscMintedBeforeRedeem, uint256 collateralBeforeRedeem) = dsce.getAccountInformation(USER);

        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmount);
        dsce.redeemCollateralForDsc(wethToken, AMOUNT_COLLATERAL, dscAmount);
        vm.stopPrank();
        (uint256 dscMintedAfterRedeem, uint256 collateralAfterRedeem) = dsce.getAccountInformation(USER);

        uint256 amountCollateralInUsd = dsce.getUsdValue(wethToken, AMOUNT_COLLATERAL);
        assertEq(dscMintedAfterRedeem, dscMintedBeforeRedeem - dscAmount);
        assertEq(collateralAfterRedeem, collateralBeforeRedeem - amountCollateralInUsd);
    }

    /*//////////////////////////////////////////////////////////////
                             BURN DSC TEST
    //////////////////////////////////////////////////////////////*/
    function testDscTokenValueAferBurn() public {
        uint256 dscAmountToMint = 1000e18;

        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL, dscAmountToMint);
        vm.stopPrank();
        (uint256 dscAmountBeforeBurn,) = dsce.getAccountInformation(USER);

        console.log(dscAmountBeforeBurn); // 1000,000,000,000,000,000,000

        vm.startPrank(USER);
        dsc.approve(address(dsce), dscAmountToMint);
        dsce.burnDsc(dscAmountToMint);
        (uint256 dscAmountAfterBurn,) = dsce.getAccountInformation(USER);
        vm.stopPrank();

        assertEq(dscAmountAfterBurn, dscAmountBeforeBurn - dscAmountToMint);
    }

    function testBurningZeroAmountReverts() public depositedCollateral {
        uint256 dscAmountToBurn = 0;

        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(dscAmountToBurn);
        vm.stopPrank();
    }

    function testBurnRevertIfTransferFails() public {
        uint256 dscAmount = 1000e18;

        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL, dscAmount);
        vm.stopPrank();

        bytes memory transferCall = abi.encodeWithSelector(dsc.transferFrom.selector, USER, address(dsce), dscAmount);

        vm.mockCall(address(dsc), transferCall, abi.encode(false));

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        dsce.burnDsc(dscAmount);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                               LIQUIDATE
    //////////////////////////////////////////////////////////////*/
    function testRevertIfHealthFactorIsOk() public depositedCollateral {
        uint256 debtToCover = 1000e18;

        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(wethToken, USER, debtToCover);
    }

    function testLiquidationIfHealthFactorIsBroken() public {
        uint256 dscAmountToMint = 10_000e18; // 10,000 DSC
        uint256 debtToCover = 10_000e18; // 10,000 DSC
        uint256 priceDrop = 1500e8; // $1,500

        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL, dscAmountToMint);
        vm.stopPrank();
        // Health factor should be > MIN_HEALTH_FACTOR
        uint256 userHealthFactorBeforePriceDrop = dsce.getUserHealthFactor(USER);
        assertGe(userHealthFactorBeforePriceDrop, MIN_HEALTH_FACTOR);

        // Drop WETH price from $2,000 → $1,000
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(priceDrop));
        // Health factor now < MIN_HEALTH_FACTOR
        uint256 userHealthFactorAfterPriceDrop = dsce.getUserHealthFactor(USER);
        assertLt(userHealthFactorAfterPriceDrop, MIN_HEALTH_FACTOR);

        // LIQUIDATOR should mint DSC to pay USER debt
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL * 3);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL * 3, dscAmountToMint);
        vm.stopPrank();

        // LIQUIDATOR calls liquuidate function on USER
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dsce), debtToCover);
        dsce.liquidate(wethToken, USER, debtToCover);
        vm.stopPrank();
        // USER health factor should now again be > MIN_HEALTH_FACTOR
        uint256 userHealthFactorAfterLiquidation = dsce.getUserHealthFactor(USER);
        assertGe(userHealthFactorAfterLiquidation, MIN_HEALTH_FACTOR);
    }

    function testRevertIfLiquidationDontImproveHealthFactor() public {
        uint256 dscAmountToMint = 10_000e18; // 10,000 DSC
        uint256 debtToCover = 3000e18; // pay back less to trigger revert
        uint256 priceDrop = 1500e8; // $1,500

        vm.startPrank(USER);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL, dscAmountToMint);
        vm.stopPrank();

        // Drop WETH price from $2,000 → $1,000
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(priceDrop));

        // LIQUIDATOR should mint DSC to pay USER debt
        vm.startPrank(LIQUIDATOR);
        ERC20Mock(wethToken).approve(address(dsce), AMOUNT_COLLATERAL * 3);
        dsce.depositCollateralAndMintDsc(wethToken, AMOUNT_COLLATERAL * 3, dscAmountToMint);
        vm.stopPrank();

        // LIQUIDATOR pays lesser debt which triggers revert
        vm.startPrank(LIQUIDATOR);
        dsc.approve(address(dsce), debtToCover * 5);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        dsce.liquidate(wethToken, USER, debtToCover);
        vm.stopPrank();
    }
}
