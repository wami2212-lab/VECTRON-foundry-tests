// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {MaliciousReentrant} from "./mocks/MaliciousReentrant.sol";

contract VectronReentrancyTest is Test {
    VECTRON token;
    MockRouter router;
    MockPair pair;
    MaliciousReentrant attacker;

    address constant TEAM = address(0x7EA1);
    address constant TREASURY = address(0x7EA5);
    address constant WETH = address(0xBEEF0000);
    address seller = address(0xA001);

    function setUp() public {
        router = new MockRouter(WETH);
        token = new VECTRON(address(router), TEAM, TREASURY);

        pair = new MockPair(address(token), WETH, 75_000_000 ether, 60 ether);

        token.setExchangePair(address(pair), true);
        token.setTwapPair(address(pair));
        token.setMinTokensBeforeLiquidity(1000 ether);
        token.startSystem();

        vm.deal(address(router), 1000 ether);
        router.setRate(1e13); // generously above the TWAP-implied rate so slippage never blocks the swap

        token.transfer(seller, 5_000_000 ether);

        attacker = new MaliciousReentrant(address(token), address(pair), 0);
        router.setReenterTarget(address(attacker));
    }

    function _warmUpTwap() internal {
        vm.prank(seller);
        token.transfer(address(pair), 1 ether);

        vm.warp(block.timestamp + 31 minutes);
        pair.setReserves(74_000_000 ether, 61 ether);

        vm.prank(seller);
        token.transfer(address(pair), 1 ether);

        assertTrue(token.twapInitialized(), "twap should be initialized");
    }

    function testFuzz_ReentrancyDuringAutoLiquidity(uint256 sellAmount, uint256 reenterAmount) public {
        sellAmount = bound(sellAmount, 250_000 ether, 4_000_000 ether);
        reenterAmount = bound(reenterAmount, 1 ether, 500_000 ether);

        _warmUpTwap();

                vm.prank(seller);
        token.transfer(address(pair), 250_000 ether); // fills the auto-liquidity queue so the fuzzed sell below triggers the swap

        token.transfer(address(attacker), reenterAmount);
        attacker.setReenterAmount(reenterAmount);

        vm.prank(seller);
        token.transfer(address(pair), sellAmount); // must never revert regardless of what happens inside

        assertTrue(attacker.attempted(), "reentrant hook never fired - swap path not exercised");
        assertEq(router.maxDepthSeen(), 1, "swap function was reentered - inSwap gate failed");

        assertEq(
            token.balanceOf(address(token)),
            token.totalTokensStaked() + token.totalRewardsAvailable() + token.liquidityTokensCollected(),
            "contract ledger vs actual balance mismatch after reentrant swap"
        );

        uint256 sumBalances = token.balanceOf(address(token))
            + token.balanceOf(seller)
            + token.balanceOf(address(attacker))
            + token.balanceOf(address(pair))
            + token.balanceOf(TEAM)
            + token.balanceOf(TREASURY)
            + token.balanceOf(address(this))
            + token.balanceOf(address(router));

        assertEq(sumBalances, token.totalSupply(), "supply conservation broken by reentrancy");
    }
}