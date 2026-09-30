// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockPair} from "./mocks/MockPair.sol";
import {MaliciousReentrant} from "./mocks/MaliciousReentrant.sol";

contract Handler is Test {
    VECTRON public token;
    address public pair;
    MockPair public mockPair;
    address[] public actors;

    bool public stakeFailed;
    bool public unstakeFailed;
    bool public exitFailed;
    bool public claimFailed;
    bool public sellFailed;
        uint256 public exitsDone;

    constructor(VECTRON _token, address _pair, MockPair _mockPair, address[] memory _actors) {
        token = _token;
        pair = _pair;
        mockPair = _mockPair;
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
                (, uint256 lockEnd, uint256 tier) = token.getStakeDetails(actor, idx);
        uint256 lockLen = tier == 1 ? 15 days : tier == 2 ? 45 days : 90 days;
        if (!token.paused() && block.timestamp < lockEnd - lockLen + 1 hours) return; // gate: too young to exit
        vm.prank(actor);
                try token.emergencyExit(idx) { exitsDone++; } catch { exitFailed = true; }
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

    // Keeps the TWAP oracle alive by advancing time and nudging reserves,
    // simulating the price accrual a real pair does automatically on every
    // swap. Wiggle is kept small so the TWAP-vs-spot divergence check
    // usually still passes and auto-liquidity actually gets exercised.
    function touchMarket(uint256 timeSeed, uint256 wiggleSeed) external {
        vm.warp(block.timestamp + bound(timeSeed, 31 minutes, 3 days));
        (uint112 r0, uint112 r1, ) = mockPair.getReserves();
        int256 wiggleBps = int256(bound(wiggleSeed, 0, 1000)) - 500; // ±5%
        uint112 newR1 = uint112(uint256(int256(uint256(r1)) + (int256(uint256(r1)) * wiggleBps) / 10000));
        if (newR1 == 0) newR1 = r1;
        mockPair.setReserves(r0, newR1);
    }
}

contract VectronInvariant is Test {
    VECTRON token;
    Handler handler;
    MockRouter router;
    MockPair pair;
    MaliciousReentrant attacker;

    address constant TEAM = address(0x7EA1);
    address constant TREASURY = address(0x7EA5);
    address constant WETH = address(0xBEEF0000);
    address[] actors;

    function setUp() public {
        router = new MockRouter(WETH);
        token = new VECTRON(address(router), TEAM, TREASURY);

        pair = new MockPair(address(token), WETH, 75_000_000 ether, 60 ether);

        token.setExchangePair(address(pair), true);
        token.setTwapPair(address(pair));
        token.setMinTokensBeforeLiquidity(500_000 ether);
        token.startSystem();

        vm.deal(address(router), 1000 ether);
        router.setRate(1e13);

        attacker = new MaliciousReentrant(address(token), address(pair), 0);
        router.setReenterTarget(address(attacker));

        for (uint256 i = 0; i < 3; i++) {
            address actor = address(uint160(0xA000 + i));
            actors.push(actor);
            token.transfer(actor, 10_000_000 ether);
        }
        token.transfer(address(pair), 50_000_000 ether);
        token.transfer(address(attacker), 2_000_000 ether);
        attacker.setReenterAmount(100_000 ether);

        // Bootstrap the TWAP so auto-liquidity isn't dead on arrival.
        pair.setReserves(75_000_000 ether, 60 ether);
        vm.prank(actors[0]);
        token.transfer(address(pair), 1 ether);
        vm.warp(block.timestamp + 31 minutes);
        pair.setReserves(74_000_000 ether, 61 ether);
        vm.prank(actors[0]);
        token.transfer(address(pair), 1 ether);

        handler = new Handler(token, address(pair), pair, actors);
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
            + token.balanceOf(TEAM) + token.balanceOf(TREASURY) + token.balanceOf(address(pair))
            + token.balanceOf(address(router)) + token.balanceOf(address(attacker));
        for (uint256 i = 0; i < actors.length; i++) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, token.totalSupply());
    }

        function afterInvariant() public {
        emit log_named_uint("emergency exits completed", handler.exitsDone());
    }

    function invariant_honestUsersNeverBlocked() public view {
        assertFalse(handler.stakeFailed(), "stake reverted");
        assertFalse(handler.unstakeFailed(), "unstake reverted");
        assertFalse(handler.exitFailed(), "emergencyExit reverted");
        assertFalse(handler.claimFailed(), "claim reverted");
        assertFalse(handler.sellFailed(), "sell reverted");
    }

    // The whole point of wiring the real mock router in: every single
    // auto-liquidity swap the fuzzer triggers along the way gets a live
    // reentrancy attempt from `attacker` fired mid-swap. If this ever
    // fails, the inSwap gate broke under real, randomized, concurrent
    // contract activity — not just the isolated one-shot scenario.
    function invariant_reentrancyNeverSucceedsMidSwap() public view {
        assertLe(router.maxDepthSeen(), 1, "swap function was reentered - inSwap gate failed under load");
    }
}