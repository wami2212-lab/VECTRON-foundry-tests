

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

// Minimal UniswapV2-style pair mock. Accrues price0/price1 cumulative
// exactly like the real pair does: at the OLD reserves ratio, for the
// time elapsed since the last update, before applying new reserves.
// This lets time-warped fuzz runs produce a genuine, manipulable TWAP.
contract MockPair {
    address public immutable token0;
    address public immutable token1;

    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;

    constructor(address _token0, address _token1, uint112 _reserve0, uint112 _reserve1) {
        token0 = _token0;
        token1 = _token1;
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = uint32(block.timestamp % 2**32);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    // Call this to simulate market movement: accrues cumulative price at the
    // CURRENT (pre-update) reserves for elapsed time, then sets new reserves.
    function setReserves(uint112 newReserve0, uint112 newReserve1) external {
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed;
        unchecked { timeElapsed = blockTimestamp - blockTimestampLast; }

        if (timeElapsed > 0 && reserve0 > 0 && reserve1 > 0) {
            price0CumulativeLast += (uint256(reserve1) << 112) / reserve0 * timeElapsed;
            price1CumulativeLast += (uint256(reserve0) << 112) / reserve1 * timeElapsed;
        }

        reserve0 = newReserve0;
        reserve1 = newReserve1;
        blockTimestampLast = blockTimestamp;
    }
}
