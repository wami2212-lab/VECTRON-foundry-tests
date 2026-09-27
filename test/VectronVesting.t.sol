// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {VECTRON} from "../src/Vectron.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract VestingHandler is Test {
    VECTRON public token;
    address[] public actors;

    bool public dishonestRevert; // claim() reverted despite claimable > 0

    constructor(VECTRON _token, address[] memory _actors) {
        token = _token;
        actors = _actors;
    }

    function claim(uint256 a) external {
        address actor = actors[a % actors.length];
        uint256 vested = token.getVestedAmount(actor);
        uint256 claimed = token.userClaimed(actor);
        bool shouldBeClaimable = vested > claimed;

        vm.prank(actor);
        try token.claimMyVestedTokens() {
            if (!shouldBeClaimable) {
                // Claimed when it shouldn't have been possible - handled by invariant, not here.
            }
        } catch {
            if (shouldBeClaimable) dishonestRevert = true;
        }
    }

    function passTime(uint256 s) external {
        vm.warp(block.timestamp + bound(s, 1 hours, 2 weeks));
    }
}

contract VectronVestingTest is Test {
    VECTRON token;
    VestingHandler handler;
    MockRouter router;

    address constant TEAM = address(0x7EA1);
    address constant TREASURY = address(0x7EA5);
    address constant WETH = address(0xBEEF0000);
    address[] actors;

    function setUp() public {
        router = new MockRouter(WETH);
        token = new VECTRON(address(router), TEAM, TREASURY);

        for (uint256 i = 0; i < 5; i++) {
            actors.push(address(uint160(0xB000 + i)));
        }

        // Spread allocations across all five vesting categories, deliberately
        // uneven amounts so rounding/edge behavior in getVestedAmount gets exercised.
        token.setSeedAllocation(actors[0], 1_000_000 ether);
        token.setSeedAllocation(actors[1], 2_500_000 ether);
        token.setPrivateAllocation(actors[1], 500_000 ether);
        token.setPublicAllocation(actors[2], 3_333_333 ether);
        token.setTeamAllocation(actors[3], 10_000_000 ether);
        token.setTreasuryAllocation(actors[4], 7_777_777 ether);
        token.setPublicAllocation(actors[4], 1 ether); // tiny secondary allocation, dust-rounding case

        token.startSystem();

        handler = new VestingHandler(token, actors);
        targetContract(address(handler));
    }

    function invariant_noUserExceedsOwnVestedAmount() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            assertLe(
                token.userClaimed(actors[i]),
                token.getVestedAmount(actors[i]),
                "user claimed more than vested"
            );
        }
    }

    function invariant_poolLedgerMatchesClaims() public view {
        uint256 totalClaimed;
        for (uint256 i = 0; i < actors.length; i++) {
            totalClaimed += token.userClaimed(actors[i]);
        }
        assertEq(
            token.vestingPoolSize(),
            token.totalTokensAllocated() - totalClaimed,
            "vestingPoolSize drifted from allocated-minus-claimed"
        );
    }

    function invariant_contractBalanceCoversObligation() public view {
        assertGe(
            token.balanceOf(address(token)),
            token.vestingPoolSize(),
            "contract balance can't cover remaining vesting obligation"
        );
    }

    function invariant_honestClaimNeverReverts() public view {
        assertFalse(handler.dishonestRevert(), "a genuinely claimable amount reverted on claim");
    }
}