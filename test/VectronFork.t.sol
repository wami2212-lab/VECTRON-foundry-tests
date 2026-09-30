// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";

interface IPancakeRouterFork {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256 amountTokenMin, uint256 amountETHMin, address to, uint256 deadline)
        external payable returns (uint256, uint256, uint256);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external;
}

interface IPancakeFactoryFork {
    function getPair(address a, address b) external view returns (address);
}

interface IPancakePairFork {
    function sync() external;
    function balanceOf(address who) external view returns (uint256);
        function transfer(address to, uint256 amount) external returns (bool);
            function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

contract VectronForkTest is Test {
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    VECTRON token;
    IPancakeRouterFork router;
    address pair;
    address wbnb;
    address seller;
    address team;
    address treasury;

    receive() external payable {}

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string("https://bsc-dataseed.binance.org"));
        vm.createSelectFork(rpc);

        router = IPancakeRouterFork(PANCAKE_ROUTER);
        wbnb = router.WETH();
        seller = makeAddr("seller");
        team = makeAddr("team");
        treasury = makeAddr("treasury");

        token = new VECTRON(PANCAKE_ROUTER, team, treasury);

        // Mainnet order: seed the real pool first, register the pair afterwards.
        vm.deal(address(this), 100 ether);
        token.approve(PANCAKE_ROUTER, type(uint256).max);
        router.addLiquidityETH{value: 60 ether}(address(token), 75_000_000 ether, 0, 0, address(this), block.timestamp + 1 hours);
        pair = IPancakeFactoryFork(router.factory()).getPair(address(token), wbnb);
        require(pair != address(0), "pair not created");

        token.setTwapPair(pair);
        token.setTwapMinInterval(5 minutes);
        token.setMinTokensBeforeLiquidity(1000 ether);
        token.setExchangePair(pair, true);
        token.startSystem();

        token.transfer(seller, 5_000_000 ether);
    }

    function _sell(uint256 amount) internal {
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = wbnb;
        vm.startPrank(seller);
        token.approve(PANCAKE_ROUTER, type(uint256).max);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, seller, block.timestamp + 1 hours);
        vm.stopPrank();
        }

            function test_TwapReadingAfterIdleGap() public {
        // Pair sits untouched for 1 hour after LP creation, then two small sells 10 min apart.
        vm.warp(block.timestamp + 1 hours);
        _sell(10_000 ether);   // first observation (contract stores a snapshot)
        vm.warp(block.timestamp + 10 minutes);
        _sell(10_000 ether);   // second observation: this is where lastValidTwapPrice is computed

        (uint112 r0, uint112 r1, ) = IPancakePairFork(pair).getReserves();
        uint256 spot = token.twapTokenIsToken0()
            ? (uint256(r1) << 112) / r0
            : (uint256(r0) << 112) / r1;

        emit log_named_uint("lastValidTwapPrice", token.lastValidTwapPrice());
        emit log_named_uint("spot price (Q112)  ", spot);

        // Constant-price scenario, so the TWAP should be within ~5% of spot.
        assertApproxEqRel(token.lastValidTwapPrice(), spot, 0.05e18);
    
    }

        function test_EmergencyExitOneHourGate() public {
        vm.startPrank(seller);
        token.stake(1, 1000 ether);
        vm.expectRevert(bytes4(keccak256("ExitTooSoon()")));
        token.emergencyExit(0);          // same block: must be refused
        vm.warp(block.timestamp + 1 hours);
        token.emergencyExit(0);          // after one hour: allowed
        vm.stopPrank();
    }

    function test_EmergencyExitWorksImmediatelyWhenPaused() public {
        vm.prank(seller);
        token.stake(2, 1000 ether);
        token.setPaused(true);           // this test contract is the owner
        vm.prank(seller);
        token.emergencyExit(0);          // paused: no gate, users are never trapped
    }

    function test_SmallSellTriggersAutoLiquidityOnRealRouter() public {
        _sell(200_000 ether); // starts the oracle, fills the queue

        vm.warp(block.timestamp + 6 minutes);
        IPancakePairFork(pair).sync(); // lets the real pair accumulate its price counter

        _sell(200_000 ether); // completes the TWAP observation, queue grows

        uint256 queueBefore = token.liquidityTokensCollected();
        assertGe(queueBefore, token.minTokensBeforeLiquidity(), "queue should be above threshold");
        uint256 lpBefore = IPancakePairFork(pair).balanceOf(address(token));
        uint256 bnbBefore = seller.balance;

        _sell(1_000 ether); // the small sell that broke under the old ordering

        assertGt(seller.balance, bnbBefore, "seller was not paid BNB");
        assertGt(IPancakePairFork(pair).balanceOf(address(token)), lpBefore, "auto-liquidity did not add LP");
        assertLt(token.liquidityTokensCollected(), queueBefore, "queue was not consumed");
    }

        function test_LockLiquidityAcceptsRealPairOnRealFactory() public {
        uint256 lpBal = IPancakePairFork(pair).balanceOf(address(this));
        assertGt(lpBal, 0, "test contract should hold the seeded LP");
        IPancakePairFork(pair).transfer(address(token), lpBal);

        vm.expectRevert(bytes4(keccak256("NotTheNativeLPPair()")));
        token.lockLiquidity(wbnb); // any other token must be refused

        token.lockLiquidity(pair); // the real pair from the real factory must be accepted
        assertEq(token.lpToken(), pair);
        assertTrue(token.lpLocked());
    }
}