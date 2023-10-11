// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSCEngine.s.sol";
import {DecentralisedStableCoin} from "../../src/DecentralisedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.t.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralisedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    event CollateralRedeemed(
        address indexed redeemFrom, address indexed redeemTo, address indexed token, uint256 amount
    );

    address public USER = makeAddr("user");
    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant AMOUNT_COLLATERAL_ABOVE = 11 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public AMOUNT_MINT = 5e18;
    uint256 public constant AMOUNT_MINT_ABOVE_ALLOWED = 11e18;
    uint256 public constant AMOUNT_MINT_EVEN = 10e18;
    uint256 public constant AMOUNT_BURN = 2e18;
    uint256 public constant AMOUNT_BURN_ABOVE = 10e18 + 1;
    uint256 public constant AMOUNT_REDEEM_MORE_THAN_MINT = 6e18;
    uint256 public constant AMOUNT_REDEEM = 2e18;
    uint256 public constant DEBT_TO_COVER = 1e18;
    uint256 public collateralToCover = 20 ether;
    uint256 public amountToMint = 100 ether;
    uint256 public collateralToCoverTwo = 1000 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(weth).mint(LIQUIDATOR, STARTING_ERC20_BALANCE);
    }

    ///////////////////////
    // Constructor Tests //
    ///////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testReertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dscEngine.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dscEngine.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock trwCoins = new ERC20Mock("TRW Coins", "TRW", USER, STARTING_ERC20_BALANCE);

        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(trwCoins), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);

        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedAmountDeposited = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedAmountDeposited);
    }

    // function testDepositIsNotSuccessful() public {
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
    //     vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
    //     dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
    //     vm.stopPrank();
    // }

    ///////////////////
    // mintDsc Tests //
    ///////////////////

    function testMintRevertsIfMintedZero() public depositedCollateral {
        //done
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();

        //we set amount to mint equal to price of amount collateral in USD, so we want to mint all our collateral
        AMOUNT_MINT =
            (AMOUNT_COLLATERAL * (uint256(price) * dscEngine.getAdditionalFeedPrecision())) / dscEngine.getPrecision();

        vm.startPrank(USER);
        //we calculate what our health factor will be if we tried to mint, so we can use expect revert and check it would revert
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(AMOUNT_MINT, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.mintDsc(AMOUNT_MINT);
        vm.stopPrank();
    }

    function testMintDsc() public depositedCollateral {
        //done
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_MINT);
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);

        uint256 expectedDsc = AMOUNT_MINT;

        assertEq(expectedDsc, totalDscMinted);
        vm.stopPrank();
    }

    function testMintDscIfEvenAllowedCollateral() public depositedCollateral {
        //done
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_MINT_EVEN);
        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);

        uint256 expectedDsc = AMOUNT_MINT_EVEN;

        assertEq(expectedDsc, totalDscMinted);
        vm.stopPrank();
    }

    function testCannotMintDscIfAboveAllowed() public depositedCollateral {
        //done
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.mintDsc(AMOUNT_MINT_ABOVE_ALLOWED);
        vm.stopPrank();
    }

    modifier mintedDsc() {
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_MINT);
        vm.stopPrank();
        _;
    }

    modifier mintedDscButBrokenHealthFactor() {
        vm.startPrank(USER);
        dscEngine.mintDsc(AMOUNT_MINT_ABOVE_ALLOWED);
        vm.stopPrank();
        _;
    }

    ////////////////////
    // depositAndMint //
    ////////////////////

    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        vm.stopPrank();
    }

    //////////////////////
    // Getter functions //
    //////////////////////

    function testGetMinHealthFactor() public {
        uint256 expectedMinHealthFactor = 1e18;
        uint256 actualMinHealthFactor = dscEngine.getMinHealthFactor();

        assertEq(expectedMinHealthFactor, actualMinHealthFactor);
    }

    function testGetPrecision() public {
        uint256 expectedPrecision = 1e18;
        uint256 actualPrecision = dscEngine.getPrecision();

        assertEq(expectedPrecision, actualPrecision);
    }

    function testGetLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dscEngine.getLiquidationPrecision();

        assertEq(expectedLiquidationPrecision, actualLiquidationPrecision);
    }

    function testGetLiquidationThreshold() public {
        uint256 expectedLiquidationThreshold = 50;
        uint256 actualLiquidationThreshold = dscEngine.getLiquidationThreshold();

        assertEq(expectedLiquidationThreshold, actualLiquidationThreshold);
    }

    function testGetAccountCollateralValue() public depositedCollateral {
        uint256 expectedCollateralInUsd = 20000e18;
        uint256 actualCollateralValueInUsd = dscEngine.getAccountCollateralValue(USER);

        assertEq(expectedCollateralInUsd, actualCollateralValueInUsd);
    }

    function testGetAdditionalPrecision() public {
        uint256 expectedAdditionalPrecision = 1e10;
        uint256 actualPrecision = dscEngine.getAdditionalFeedPrecision();

        assertEq(expectedAdditionalPrecision, actualPrecision);
    }

    ///////////////
    // Burn Dsc //
    //////////////

    function testCannotBurnZero() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.burnDsc(0);
        vm.stopPrank();
    }

    function testBurnDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_BURN);
        dscEngine.burnDsc(AMOUNT_BURN);
        vm.stopPrank();
    }

    function testCannotBurnThanUserHas() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_BURN);
        vm.expectRevert();
        dscEngine.burnDsc(AMOUNT_BURN_ABOVE);
        vm.stopPrank();
    }

    ///////////////////////
    // Redeem Collateral //
    ///////////////////////

    function testCannotRedeemZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCannotRedeemMoreThanHas() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert();
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL_ABOVE);
        vm.stopPrank();
    }

    function testCannotRedeemAndBreakHealthFactor() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
        dscEngine.redeemCollateral(weth, AMOUNT_REDEEM_MORE_THAN_MINT);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_REDEEM);

        (, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedCollateral = AMOUNT_COLLATERAL - AMOUNT_REDEEM;
        uint256 expectedCollateralInUsd = dscEngine.getUsdValue(weth, expectedCollateral);

        assertEq(expectedCollateralInUsd, collateralValueInUsd);

        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(dscEngine));
        emit CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dscEngine.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////
    // Redeem Collateral For DSC //
    ///////////////////////////////

    function testCannotBurnZeroAndRedeem() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemTheCollateralForDsc(weth, AMOUNT_REDEEM, 0);
        vm.stopPrank();
    }

    function testCannotRedeemZeroForDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_BURN);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.redeemTheCollateralForDsc(weth, 0, AMOUNT_BURN);
        vm.stopPrank();
    }

    function canRedeemForDsc() public depositedCollateral mintedDsc {
        vm.startPrank(USER);
        dsc.approve(address(dscEngine), AMOUNT_BURN);
        dscEngine.redeemTheCollateralForDsc(weth, AMOUNT_REDEEM, AMOUNT_BURN);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);

        uint256 expectedCollateral = AMOUNT_COLLATERAL - AMOUNT_REDEEM;
        uint256 expectedCollateralInUsd = dscEngine.getUsdValue(weth, expectedCollateral);
        uint256 expectedDsc = AMOUNT_MINT;

        assertEq(expectedDsc, totalDscMinted);
        assertEq(expectedCollateralInUsd, collateralValueInUsd);

        vm.stopPrank();
    }

    ////////////////
    // Liquidate //
    ///////////////

    function testCantLiquidateGoodHealthFactor() public depositedCollateral mintedDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, AMOUNT_MINT);
        dsc.approve(address(dscEngine), AMOUNT_MINT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, AMOUNT_MINT);
        vm.stopPrank();
    }

    function testCannotLiquidateZeroDebt() public depositedCollateral mintedDsc {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.liquidate(weth, USER, 0);
        vm.stopPrank();
    }

    function testRevertsIfhealthFactorOk() public depositedCollateral mintedDsc {
        vm.startPrank(LIQUIDATOR);
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dscEngine.liquidate(weth, USER, DEBT_TO_COVER);
        vm.stopPrank();
    }

    function testCanLiquidate() public depositedCollateral mintedDscButBrokenHealthFactor {
        vm.prank(USER);
        dsc.approve(LIQUIDATOR, AMOUNT_MINT_ABOVE_ALLOWED);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dsc.approve(address(dscEngine), AMOUNT_MINT);
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_MINT);
        dscEngine.liquidate(weth, USER, DEBT_TO_COVER);
        vm.stopPrank();

        (uint256 totalDscMinted,) = dscEngine.getAccountInformation(USER);
        uint256 exepctedDscForUSER = AMOUNT_MINT_ABOVE_ALLOWED - DEBT_TO_COVER;

        assertEq(exepctedDscForUSER, totalDscMinted);
    }

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL);
        dscEngine.mintDsc(amountToMint);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dscEngine.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
        dscEngine.depositCollateral(weth, collateralToCover);
        dscEngine.mintDsc(amountToMint);
        dsc.approve(address(dscEngine), amountToMint);
        dscEngine.liquidate(weth, USER, amountToMint); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR) - STARTING_ERC20_BALANCE;
        uint256 expectedWeth = dscEngine.getTokenAmountFromUsd(weth, amountToMint)
            + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus());
        console.log(
            dscEngine.getTokenAmountFromUsd(weth, amountToMint)
                + (dscEngine.getTokenAmountFromUsd(weth, amountToMint) / dscEngine.getLiquidationBonus())
        );

        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }
}
