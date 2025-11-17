// test/integration/OracleLibTest.t.sol
pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {OracleLib} from "../../src/libraries/OracleLib.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract OracleLibTest is Test {
    MockV3Aggregator private priceFeed;

    uint8 private constant DECIMALS = 8;
    int256 private constant INITIAL_PRICE = 2000e8;
    uint256 private constant TIMEOUT = 3 hours;

    function setUp() public {
        priceFeed = new MockV3Aggregator(DECIMALS, INITIAL_PRICE);
    }

    function testStaleCheckReturnsDataWhenFresh() public view {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
            OracleLib.staleCheckLatestRoundData(priceFeed);

        assertEq(roundId, 1);
        assertEq(answer, INITIAL_PRICE);
        assertGt(updatedAt, 0);
        assertEq(block.timestamp - updatedAt, 0);
        assertEq(answeredInRound, 1);
    }

    function testStaleCheckRevertsIfStale() public {
        vm.warp(block.timestamp + TIMEOUT + 1);
        vm.roll(block.number + 1);

        vm.expectRevert(OracleLib.OracleLib__StalePrice.selector);
        OracleLib.staleCheckLatestRoundData(priceFeed);
    }

    function testStaleCheckAllowsExactlyTimeout() public {
        vm.warp(block.timestamp + TIMEOUT);
        vm.roll(block.number + 1);

        (uint80 roundId, int256 answer,,,) = OracleLib.staleCheckLatestRoundData(priceFeed);
        assertEq(roundId, 1);
        assertEq(answer, INITIAL_PRICE);
    }
}
