
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IVectronTransfer {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}


// Fires from inside MockRouter's swap call, mid-_autoAddLiquidity, and tries
// to push a second transfer through the live token contract while inSwap is
// still true. We record whether the attempt succeeded and, separately,
// whether it left more than one swap active at once (checked via the
// router's maxDepthSeen instead of trying to re-enter the swap function
// itself, since that would just be a second unrelated attack).
contract MaliciousReentrant {
    IVectronTransfer public token;
    address public recipient;
    uint256 public reenterAmount;

    bool public attempted;
    bool public succeeded;

    constructor(address _token, address _recipient, uint256 _reenterAmount) {
        token = IVectronTransfer(_token);
        recipient = _recipient;
        reenterAmount = _reenterAmount;
    }

    function setReenterAmount(uint256 amount) external {
        reenterAmount = amount;
    }

    function attemptReenter() external {
        attempted = true;
        uint256 amt = reenterAmount;
        uint256 bal = token.balanceOf(address(this));
        if (amt > bal) amt = bal;
        if (amt == 0) return;
        try token.transfer(recipient, amt) {
            succeeded = true;
        } catch {
            succeeded = false;
        }
    }
}