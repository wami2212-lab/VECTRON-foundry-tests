
pragma solidity ^0.8.19;

interface IVectronLike {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IReentrantHook {
    function attemptReenter() external;
}

// Mock PancakeSwap/Uniswap V2 router. Pulls tokens via transferFrom (matching
// real fee-on-transfer routers), pays ETH out at a controllable rate, and can
// optionally fire a reentrant callback INSIDE the swap — after tokens have
// been debited from the caller but before ETH is sent back — which is
// exactly the window the inSwap fix is supposed to hold closed.
contract MockRouter {
    address public immutable weth;
    uint256 public ethPerTokenWei = 1e18; // 1:1 default, override per test case

    address public reenterTarget; // zero = no reentrancy attempt this call
    uint256 public reentrancyDepth;
    uint256 public maxDepthSeen;

    constructor(address _weth) {
        weth = _weth;
    }

    function setRate(uint256 _ethPerTokenWei) external {
        ethPerTokenWei = _ethPerTokenWei;
    }

    function setReenterTarget(address target) external {
        reenterTarget = target;
    }

    function factory() external pure returns (address) {
        return address(0x1234);
    }

    function WETH() external view returns (address) {
        return weth;
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint /*deadline*/
    ) external {
        reentrancyDepth++;
        if (reentrancyDepth > maxDepthSeen) maxDepthSeen = reentrancyDepth;

        require(IVectronLike(path[0]).transferFrom(msg.sender, address(this), amountIn), "pull failed");

        uint256 ethOut = (amountIn * ethPerTokenWei) / 1e18;
        require(ethOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(address(this).balance >= ethOut, "router underfunded");

        // 🔴 Reentrancy window under test: tokens already debited from the
        // VECTRON contract's own balance, ETH not sent yet, inSwap == true.
        if (reenterTarget != address(0)) {
            try IReentrantHook(reenterTarget).attemptReenter() {} catch {}
        }

        (bool sent, ) = to.call{value: ethOut}("");
        require(sent, "eth send failed");

        reentrancyDepth--;
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint /*amountTokenMin*/,
        uint /*amountETHMin*/,
        address /*to*/,
        uint /*deadline*/
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity) {
        require(IVectronLike(token).transferFrom(msg.sender, address(this), amountTokenDesired), "pull failed");
        return (amountTokenDesired, msg.value, 0);
    }

    receive() external payable {}
}
