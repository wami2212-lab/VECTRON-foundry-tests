// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

interface IERC20Like {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

// A trivial ERC20 standing in for a real LP token, minted straight to the
// VECTRON contract so lockLiquidity() has something real to lock.
contract FakeLPToken {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 amt) external { balanceOf[to] += amt; }
    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

contract VectronAdminTest is Test {
    VECTRON token;
    MockRouter router;
    FakeLPToken lp;

    address constant TEAM = address(0x7EA1);
    address constant TREASURY = address(0x7EA5);
    address constant WETH = address(0xBEEF0000);
    address owner = address(this);
    address stranger = address(0xBAD1);
    address newOwnerCandidate = address(0xC0FFEE);

    function setUp() public {
        router = new MockRouter(WETH);
        token = new VECTRON(address(router), TEAM, TREASURY);
          token.startSystem();
        lp = new FakeLPToken();
                router.setPair(address(lp));
    }

    /* ---------------- Two-step ownership ---------------- */

    function test_StrangerCannotInitiateOwnershipTransfer() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.transferOwnership(stranger);
    }

    function test_StrangerCannotAcceptOwnership() public {
        token.transferOwnership(newOwnerCandidate);
        vm.prank(stranger);
        vm.expectRevert("Not the pending owner");
        token.acceptOwnership();
    }

    function test_OldOwnerRetainsControlUntilAccepted() public {
        token.transferOwnership(newOwnerCandidate);
        // Old owner can still call owner-only functions before acceptance.
        token.setPaused(true);
        assertTrue(token.paused());
        assertEq(token.owner(), owner);
    }

    function test_OwnershipTransferCompletesOnAccept() public {
        token.transferOwnership(newOwnerCandidate);
        vm.prank(newOwnerCandidate);
        token.acceptOwnership();
        assertEq(token.owner(), newOwnerCandidate);
        assertEq(token.pendingOwner(), address(0));

        // Old owner has lost control.
        vm.expectRevert();
        token.setPaused(true);
    }

    function testFuzz_OnlyExactPendingOwnerCanAccept(address randomCaller) public {
        vm.assume(randomCaller != newOwnerCandidate);
        token.transferOwnership(newOwnerCandidate);
        vm.prank(randomCaller);
        vm.expectRevert("Not the pending owner");
        token.acceptOwnership();
    }

    /* ---------------- 48h rescue timelock ---------------- */

    function _fundFreeBalance(uint256 amount) internal {
        // Send tokens to the contract itself via a tax-free transfer path
        // (owner is fee-excluded), so they count as free balance for rescue.
        token.transfer(address(token), amount);
    }

    function test_StrangerCannotInitiateOrExecuteRescue() public {
        vm.prank(stranger);
        vm.expectRevert();
        token.initiateRescue(1 ether);

        vm.prank(stranger);
        vm.expectRevert();
        token.executeRescue();
    }

    function test_RescueBlockedBeforeTimelockExpires() public {
        _fundFreeBalance(1000 ether);
        token.initiateRescue(500 ether);

        vm.expectRevert("Timelock not expired yet");
        token.executeRescue();

        vm.warp(block.timestamp + 47 hours);
        vm.expectRevert("Timelock not expired yet");
        token.executeRescue();
    }

    function test_RescueSucceedsExactlyAtTimelockExpiry() public {
        _fundFreeBalance(1000 ether);
        token.initiateRescue(500 ether);
        vm.warp(block.timestamp + 48 hours);

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        token.executeRescue();
        assertEq(token.balanceOf(TREASURY), treasuryBefore + 500 ether);
        assertFalse(token.rescuePending());
    }

    function test_RescueCannotExceedFreeBalance() public {
        _fundFreeBalance(100 ether);
        vm.expectRevert("Exceeds safe unallocated balance");
        token.initiateRescue(200 ether);
    }

    function test_CancelClearsStateCompletely() public {
        _fundFreeBalance(1000 ether);
        token.initiateRescue(500 ether);
        token.cancelRescue();

        assertFalse(token.rescuePending());
        assertEq(token.rescueRequestAmount(), 0);
        assertEq(token.rescueRequestTime(), 0);

        // A fresh rescue can be initiated right after cancellation.
        token.initiateRescue(300 ether);
        assertTrue(token.rescuePending());
    }

    function test_CannotInitiateSecondRescueWhilePending() public {
        _fundFreeBalance(1000 ether);
        token.initiateRescue(500 ether);
        vm.expectRevert("Rescue already pending");
        token.initiateRescue(100 ether);
    }

        function testFuzz_LegitimateActivityDuringDelayNeverBlocksExecute(
        uint256 stakeAmount,
        uint256 tier,
        uint256 warpTime
    ) public {
        _fundFreeBalance(1_000_000 ether);
        token.initiateRescue(1_000_000 ether);

        address staker = address(0xF00D);
        stakeAmount = bound(stakeAmount, 1 ether, 400_000 ether);
        tier = bound(tier, 1, 3);
        token.transfer(staker, stakeAmount);
        vm.prank(staker);
        token.stake(tier, stakeAmount);

        warpTime = bound(warpTime, 48 hours, 60 hours);
        vm.warp(block.timestamp + warpTime);

        uint256 treasuryBefore = token.balanceOf(TREASURY);
        token.executeRescue();
        assertEq(token.balanceOf(TREASURY), treasuryBefore + 1_000_000 ether);
    }

    /* ---------------- LP lock + rescueERC20 guard ---------------- */

    function test_LockLiquidityRequiresNonZeroBalance() public {
        vm.expectRevert("No LP tokens to lock");
        token.lockLiquidity(address(lp));
    }

    function test_WithdrawLPBlockedBeforeUnlock() public {
        lp.mint(address(token), 1000 ether);
        token.lockLiquidity(address(lp));

        vm.expectRevert("Still locked");
        token.withdrawLP();

        vm.warp(block.timestamp + 149 days);
        vm.expectRevert("Still locked");
        token.withdrawLP();
    }

    function test_WithdrawLPSucceedsAfterLock() public {
        lp.mint(address(token), 1000 ether);
        token.lockLiquidity(address(lp));
        vm.warp(block.timestamp + 150 days);

        token.withdrawLP();
        assertEq(lp.balanceOf(owner), 1000 ether);
        assertFalse(token.lpLocked());
    }

    // This is the test that catches the actual bug: rescueERC20 must never
    // be able to move the locked LP token, at any amount, at any time,
    // regardless of the 150-day lock state.
        function test_RescueERC20CannotTouchLockedLPToken() public {
        lp.mint(address(token), 1000 ether);
        token.lockLiquidity(address(lp));

        vm.expectRevert("Cannot rescue locked LP tokens");
        token.initiateERC20Rescue(address(lp), 1000 ether);

        // Still blocked even after the lock period has technically expired -
        // the LP token should only ever leave via withdrawLP(), never rescueERC20.
        vm.warp(block.timestamp + 150 days);
        vm.expectRevert("Cannot rescue locked LP tokens");
        token.initiateERC20Rescue(address(lp), 1000 ether);
    }

        function testFuzz_RescueERC20CannotTouchLPTokenAnyAmount(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000 ether);
        lp.mint(address(token), amount);
        token.lockLiquidity(address(lp));

        vm.expectRevert("Cannot rescue locked LP tokens");
        token.initiateERC20Rescue(address(lp), amount);
    }

        function test_RescueERC20StillWorksForUnrelatedTokens() public {
        FakeLPToken randomToken = new FakeLPToken();
        randomToken.mint(address(token), 500 ether);

        token.initiateERC20Rescue(address(randomToken), 500 ether);
        vm.warp(block.timestamp + 48 hours);
        token.executeERC20Rescue();
        assertEq(randomToken.balanceOf(TREASURY), 500 ether);
    }

        function test_RescueERC20StillBlocksNativeToken() public {
        vm.expectRevert("Cannot rescue native project tokens");
        token.initiateERC20Rescue(address(token), 1 ether);
    }


        /* ---------------- ETH rescue timelock (new) ---------------- */

    function test_ETHRescueBlockedBeforeTimelockExpires() public {
        vm.deal(address(token), 5 ether);
        token.initiateETHRescue(2 ether);

        vm.expectRevert("Timelock not expired yet");
        token.executeETHRescue();

        vm.warp(block.timestamp + 47 hours);
        vm.expectRevert("Timelock not expired yet");
        token.executeETHRescue();
    }

    function test_ETHRescueSucceedsAfterTimelock() public {
        vm.deal(address(token), 5 ether);
        token.initiateETHRescue(2 ether);
        vm.warp(block.timestamp + 48 hours);

        uint256 before = TREASURY.balance;
        token.executeETHRescue();
        assertEq(TREASURY.balance, before + 2 ether);
        assertFalse(token.ethRescuePending());
    }

    function test_ETHRescueCancelClearsState() public {
        vm.deal(address(token), 5 ether);
        token.initiateETHRescue(2 ether);
        token.cancelETHRescue();

        assertFalse(token.ethRescuePending());
        assertEq(token.ethRescueRequestAmount(), 0);
    }

    function test_StrangerCannotInitiateOrExecuteETHRescue() public {
        vm.deal(address(token), 5 ether);
        vm.prank(stranger);
        vm.expectRevert();
        token.initiateETHRescue(1 ether);

        token.initiateETHRescue(1 ether);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(stranger);
        vm.expectRevert();
        token.executeETHRescue();
    }

    function testFuzz_ETHRescueNeverExceedsRequestedAmount(uint256 funded, uint256 requested) public {
        funded = bound(funded, 1, 1000 ether);
        requested = bound(requested, 1, funded);
        vm.deal(address(token), funded);

        token.initiateETHRescue(requested);
        vm.warp(block.timestamp + 48 hours);

        uint256 before = TREASURY.balance;
        token.executeETHRescue();
        assertEq(TREASURY.balance, before + requested);
    }

    /* ---------------- ERC20 rescue timelock (new) ---------------- */

    function test_ERC20RescueBlockedBeforeTimelockExpires() public {
        FakeLPToken randomToken = new FakeLPToken();
        randomToken.mint(address(token), 500 ether);
        token.initiateERC20Rescue(address(randomToken), 500 ether);

        vm.expectRevert("Timelock not expired yet");
        token.executeERC20Rescue();
    }

    function test_ERC20RescueCancelClearsState() public {
        FakeLPToken randomToken = new FakeLPToken();
        randomToken.mint(address(token), 500 ether);
        token.initiateERC20Rescue(address(randomToken), 500 ether);
        token.cancelERC20Rescue();

        assertFalse(token.erc20RescuePending());
        assertEq(token.erc20RescueAmount(), 0);
    }

        function test_ERC20RescueOfLPTokenBlockedFromTheStart() public {
        // The real pair is now protected by construction (derived from the router's
        // factory), so an LP rescue is refused at initiate time, not only at execute time.
        lp.mint(address(token), 1000 ether);
        vm.expectRevert("Cannot rescue LP tokens");
        token.initiateERC20Rescue(address(lp), 1000 ether);
    }

    function test_StrangerCannotInitiateOrExecuteERC20Rescue() public {
        FakeLPToken randomToken = new FakeLPToken();
        randomToken.mint(address(token), 500 ether);

        vm.prank(stranger);
        vm.expectRevert();
        token.initiateERC20Rescue(address(randomToken), 500 ether);

        token.initiateERC20Rescue(address(randomToken), 500 ether);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(stranger);
        vm.expectRevert();
        token.executeERC20Rescue();
    }

        function test_GetRescueStatusViewsReportPendingState() public {
        vm.deal(address(token), 5 ether);
        token.initiateETHRescue(2 ether);

        (bool ethPending, uint256 ethAmount, uint256 ethExecuteAfter) = token.getETHRescueStatus();
        assertTrue(ethPending);
        assertEq(ethAmount, 2 ether);
        assertEq(ethExecuteAfter, block.timestamp + 48 hours);

        FakeLPToken randomToken = new FakeLPToken();
        randomToken.mint(address(token), 500 ether);
        token.initiateERC20Rescue(address(randomToken), 500 ether);

        (bool ercPending, address ercToken, uint256 ercAmount, uint256 ercExecuteAfter) = token.getERC20RescueStatus();
        assertTrue(ercPending);
        assertEq(ercToken, address(randomToken));
        assertEq(ercAmount, 500 ether);
        assertEq(ercExecuteAfter, block.timestamp + 48 hours);
    }
}
