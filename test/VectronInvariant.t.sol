// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";

contract Handler is Test {
    VECTRON public token;
    address public pair;
    address[] public actors;

    bool public stakeFailed;
    bool public unstakeFailed;
    bool public exitFailed;
    bool public claimFailed;
    bool public sellFailed;

    constructor(VECTRON _token, address _pair, address[] memory _actors) {
        token = _token;
        pair = _pair;
        actors = _actors;
    }

    function stake(uint256 a, uint256 tierSeed, uint256 amtSeed) external {
        address actor = actors[a % actors.length];
        uint256 bal = token.balanceOf(actor);
        if (bal == 0 || token.getStakeCount(actor) >= 25) return;
        uint256 tier = bound(tierSeed, 1, 3);
        uint256 amount = bound(amtSeed, 1, bal);
        vm.prank(actor);
        try token.stake(tier, amount) {} catch { stakeFailed = true; }
    }

    function unstake(uint256 a, uint256 i) external {
        address actor = actors[a % actors.length];
        uint256 n = token.getStakeCount(actor);
        if (n == 0) return;
        uint256 idx = bound(i, 0, n - 1);
        (, uint256 lockEnd, ) = token.getStakeDetails(actor, idx);
        if (block.timestamp < lockEnd) vm.warp(lockEnd);
        vm.prank(actor);
        try token.unstake(idx) {} catch { unstakeFailed = true; }
    }

    function emergencyExit(uint256 a, uint256 i) external {
        address actor = actors[a % actors.length];
        uint256 n = token.getStakeCount(actor);
        if (n == 0) return;
        uint256 idx = bound(i, 0, n - 1);
        vm.prank(actor);
        try token.emergencyExit(idx) {} catch { exitFailed = true; }
    }

    function claim(uint256 a) external {
        address actor = actors[a % actors.length];
        if (token.earned(actor) == 0) return;
        vm.prank(actor);
        try token.claim() {} catch { claimFailed = true; }
    }

    function sell(uint256 a, uint256 amtSeed) external {
        address actor = actors[a % actors.length];
        uint256 bal = token.balanceOf(actor);
        if (bal == 0) return;
        uint256 amount = bound(amtSeed, 1, bal);
        vm.prank(actor);
        try token.transfer(pair, amount) {} catch { sellFailed = true; }
    }

    function buy(uint256 a, uint256 amtSeed) external {
        address actor = actors[a % actors.length];
        uint256 bal = token.balanceOf(pair);
        if (bal == 0) return;
        uint256 amount = bound(amtSeed, 1, bal);
        vm.prank(pair);
        token.transfer(actor, amount);
    }

    function passTime(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1, 30 days));
    }
}

contract VectronInvariant is Test {
    VECTRON token;
    Handler handler;
    address constant PAIR = address(0xBEEF);
    address constant ROUTER = address(0xCAFE);
    address constant TEAM = address(0x7EA1);
    address constant TREASURY = address(0x7EA5);
    address[] actors;

    function setUp() public {
        token = new VECTRON(ROUTER, TEAM, TREASURY);
        token.setExchangePair(PAIR, true);
        token.startSystem();
        for (uint256 i = 0; i < 3; i++) {
            address actor = address(uint160(0xA000 + i));
            actors.push(actor);
            token.transfer(actor, 10_000_000 ether);
        }
        token.transfer(PAIR, 50_000_000 ether);
        handler = new Handler(token, PAIR, actors);
        targetContract(address(handler));
    }

    function invariant_contractCoversLiabilities() public view {
        assertGe(
            token.balanceOf(address(token)),
            token.totalTokensStaked() + token.totalRewardsAvailable()
        );
    }

    function invariant_exactContractBalance() public view {
        assertEq(
            token.balanceOf(address(token)),
            token.totalTokensStaked() + token.totalRewardsAvailable() + token.liquidityTokensCollected()
        );
    }

    function invariant_pointsAndRewardsConsistent() public view {
        uint256 pts;
        uint256 staked;
        uint256 earnedSum;
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 ts, uint256 p, , ) = token.users(actors[i]);
            staked += ts;
            pts += p;
            earnedSum += token.earned(actors[i]);
        }
        assertEq(pts, token.totalGlobalStakedPoints());
        assertEq(staked, token.totalTokensStaked());
        assertLe(earnedSum, token.totalRewardsAvailable());
    }

    function invariant_supplyConserved() public view {
        uint256 sum = token.balanceOf(address(this)) + token.balanceOf(address(token))
            + token.balanceOf(TEAM) + token.balanceOf(TREASURY) + token.balanceOf(PAIR);
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
    }

    function invariant_honestUsersNeverBlocked() public view {
        assertFalse(handler.stakeFailed(), "stake reverted");
        assertFalse(handler.unstakeFailed(), "unstake reverted");
        assertFalse(handler.exitFailed(), "emergencyExit reverted");
        assertFalse(handler.claimFailed(), "claim reverted");
        assertFalse(handler.sellFailed(), "sell reverted");
    }
}