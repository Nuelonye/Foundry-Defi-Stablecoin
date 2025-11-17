// SPDX-License-Identifier: MIT

// Have our invariants aka properties of the system that should always hold

// What are our invariants
// 1. The total supply of DSC should allways be less than total value of collateral
// 2. Getter view functions should never revert <- evergreen invariant

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Handler} from "./Handler.t.sol";

contract Invariant is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address wethToken;
    address wbtcToken;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, wethToken, wbtcToken,,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    // This OpenInvariant is usefull when trying to write some quick Test
    // But it's not great because it make a bunch of silly calls. Example
    // 1. Trying to depositCollateral using a random collatral Address that's not suppoert that will revert
    // 2. Trying to mint DSC without having depositing collateral. These and so mch more.
    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (dsc minted)

        uint256 dscTotalSuppy = dsc.totalSupply(); // All the DSC ever minted
        uint256 totalWethDeposited = IERC20(wethToken).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtcToken).balanceOf(address(dsce));

        uint256 totalWethInUsd = dsce.getUsdValue(wethToken, totalWethDeposited);
        uint256 totalWbtcInUsd = dsce.getUsdValue(wbtcToken, totalWbtcDeposited);

        assert((totalWethInUsd + totalWbtcInUsd) >= dscTotalSuppy);

        console.log("WETH balance: ", totalWethInUsd);
        console.log("WBTC balance: ", totalWbtcInUsd);
        console.log("Total DSC: ", dscTotalSuppy);
        console.log("Mint Calls", handler.timesMintIsCalled());
        console.log("Redeem Calls", handler.timesRedeemIsCalled());
    }
}
