// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinTest is Test {
    DecentralizedStableCoin dsc;

    address USER = makeAddr("user");
    address OWNER = makeAddr("owner");
    uint256 public constant MINT_AMOUNT = 1000e18;

    function setUp() public {
        dsc = new DecentralizedStableCoin(OWNER);
    }

    function testCheckCoinName() public view {
        assertEq(keccak256(abi.encodePacked("DecentralizedStableCoin")), keccak256(abi.encodePacked(dsc.name())));
    }

    function testMintCoinWorks() public {
        vm.prank(OWNER);
        dsc.mint(USER, MINT_AMOUNT);
        assertEq(dsc.balanceOf(USER), MINT_AMOUNT);
    }

    function testRevertIfMintToZeroAddress() public {
        vm.prank(OWNER);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__NoZeroAddress.selector);
        dsc.mint(address(0), MINT_AMOUNT);
    }

    function testRevertIfAmountIsZero() public {
        vm.prank(OWNER);
        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.mint(USER, 0);
    }

    function testBurnWorks() public {
        vm.startPrank(OWNER);

        dsc.mint(OWNER, MINT_AMOUNT);
        assertEq(dsc.balanceOf(OWNER), MINT_AMOUNT);

        dsc.burn(MINT_AMOUNT);
        assertEq(dsc.balanceOf(OWNER), 0);
        vm.stopPrank();
    }

    function testBurningZeroReverts() public {
        vm.startPrank(OWNER);

        dsc.mint(OWNER, MINT_AMOUNT);
        assertEq(dsc.balanceOf(OWNER), MINT_AMOUNT);

        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__MustBeMoreThanZero.selector);
        dsc.burn(0);
        vm.stopPrank();
    }

    function testRevertIfBurnAmountExceedsBalance() public {
        vm.startPrank(OWNER);

        dsc.mint(OWNER, MINT_AMOUNT);
        assertEq(dsc.balanceOf(OWNER), MINT_AMOUNT);

        vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
        dsc.burn(MINT_AMOUNT + 1);
        vm.stopPrank();
    }
}
