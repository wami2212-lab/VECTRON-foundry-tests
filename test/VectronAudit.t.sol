// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract DustToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract VectronAuditTest is Test {
    VECTRON token;
    MockRouter router;
    DustToken dust;
    DustToken realLp;
    address constant TEAM = address(0x7EA1);
    address constant TREASURY = address(0x7EA5);
    address constant WETH = address(0xBEEF0000);
    address alice = address(0xA11CE);

    function setUp() public {
        router = new MockRouter(WETH);
        token = new VECTRON(address(router), TEAM, TREASURY);
        dust = new DustToken();
        realLp = new DustToken();
        router.setPair(address(realLp));
        token.setSeedAllocation(alice, 100_000_000 ether);
        token.startSystem();
    }

    function test_NativeTokenCannotBeLockedAsLP() public {
        vm.expectRevert("Not the native LP pair");
        token.lockLiquidity(address(token));
    }

    function test_DustTokenCannotBeLockedAsLP() public {
        dust.mint(address(token), 1 ether);
        vm.expectRevert("Not the native LP pair");
        token.lockLiquidity(address(dust));
    }

    function test_RealPairLocksOnceAndCannotBeRelocked() public {
        realLp.mint(address(token), 1 ether);
        token.lockLiquidity(address(realLp));
        vm.warp(block.timestamp + 150 days);
        token.withdrawLP();
        realLp.mint(address(token), 1 ether);
        vm.expectRevert("LP lock is one-time only");
        token.lockLiquidity(address(realLp));
    }

    function test_RealPairCannotBeRescuedEvenIfNeverLocked() public {
        realLp.mint(address(token), 1 ether);
        vm.expectRevert("Cannot rescue LP tokens");
        token.initiateERC20Rescue(address(realLp), 1 ether);
    }
}