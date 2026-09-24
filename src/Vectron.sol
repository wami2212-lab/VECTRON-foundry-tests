// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;




// 🟢 PASTE THIS AT THE VERY TOP OF YOUR FILE
interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
}



/**
 @title VECTRON
 * @notice Fixed Tier-Security: Prevents "Downgrade" exploits.
 */

interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(address token, uint amountTokenDesired, uint amountTokenMin, uint amountETHMin, address to, uint deadline) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(uint amountIn, uint amountOutMin, address[] calldata path, address to, uint deadline) external;
    
    // ADDED: This allows the contract to look up market prices before a swap
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

// ADDED: Minimal pair interface — used to read cumulative price data for a manipulation-resistant TWAP
interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor() { _status = 1; }
    modifier nonReentrant() {
        require(_status != 2, "Reentrancy");
        _status = 2;
        _;
        _status = 1;
    }
}

contract VECTRON is ReentrancyGuard {
    string public constant name = "VECTRON";
    string public constant symbol = "VCT";
    uint8  public constant decimals = 18;

    uint256 public totalSupply;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public pendingOwner;
    address public immutable treasuryWallet;
    address public immutable teamWallet;
    mapping(address => bool) public isExchangePair;
    IUniswapV2Router02 public immutable router;
    bool public systemStarted;
    uint256 public startTime;
    bool private inSwap;
    bool public paused;
    uint256 public rescueRequestTime;
    uint256 public rescueRequestAmount;
    bool public rescuePending;

    // Fees
    uint256 public treasuryTaxBPS = 50;   // 0.5% for stakers
    uint256 public liquidityTaxBPS = 50;  // 0.5% for price stability
    uint256 public unstakeFeeBps = 100;   // 1% exit fee
    mapping(address => bool) public isExcludedFromFee;

    // --- ULTIMATE ALLOCATIONS (12-WEEK SPRINT) ---
    uint256 public constant VESTING_DURATION = 12 weeks;
    uint256 public vestingPoolSize; // 850M
    uint256 public totalTokensAllocated;

// Only Liquidity is funded from a raw mint to the owner wallet — it needs to be live at TGE
// to seed the DEX pool. Team and Treasury now vest through the same vestingPoolSize/
// claimMyVestedTokens() mechanism as Seed/Private/Public — see getTotalAllocation().
    uint256 public constant OWNER_POOL_SIZE = 150_000_000 ether;
    uint256 public totalOwnerPoolAllocated;
    
    mapping(address => uint256) public seedAllocation;
    mapping(address => uint256) public privateAllocation;
    mapping(address => uint256) public publicAllocation;
    mapping(address => uint256) public teamAllocation;
    mapping(address => uint256) public treasuryAllocation;
    mapping(address => uint256) public liquidityAllocation;
    mapping(address => uint256) public userClaimed;

    // ADDED: On-chain proof that a manually-paid-out allocation was actually fulfilled.
    // These do NOT move tokens — they're a public receipt the owner posts after paying
    // out from the owner wallet, so investors can verify promises against reality.
    mapping(address => uint256) public liquidityAllocationFulfilled;    

    struct StakeRecord {
        uint256 amount;
        uint256 lockEnd;
        uint256 tier;
    }

    // ADDED: Hard cap on staking slots per wallet — prevents unbounded StakeRecord[]
    // growth that could push per-user loops (e.g. reward calc, iteration) toward
    // out-of-gas territory over time.
    uint256 public constant MAX_STAKE_SLOTS = 25;

    struct User {
        uint256 totalStaked;
        uint256 totalStakedPoints; // <-- Add this line here
        uint256 rewardsStored;
        uint256 userRewardPerTokenPaid;
        StakeRecord[] stakeRecords;
    }

    uint256 public totalGlobalStakedPoints; // <-- Add this line here

    mapping(address => User) public users;
    uint256 public totalTokensStaked;
    uint256 public rewardPerTokenStored;
    uint256 public totalRewardsAvailable; // Tracks only fee-generated reward tokens — prevents vault leak
    uint256 public totalTaxCollected;

    uint256 public minTokensBeforeLiquidity = 1_500_000 * 1e18; // Calibrated for a 75M-token initial LP side (~1% price impact per auto-liquidity event)
    uint256 public liquidityTokensCollected;
    uint256 public liquiditySlippageBPS = 9000; // 10% slippage tolerance on auto-liquidity

    // --- TWAP ORACLE (manipulation-resistant price reference for auto-liquidity swaps) ---
    address public twapPair;                 // The token/WETH pair used as the TWAP source. Set via setTwapPair.
    bool public twapTokenIsToken0;            // Whether this token is token0 in twapPair (determines which cumulative to read)
    uint256 public twapPriceCumulativeLast;   // Last recorded cumulative price snapshot
    uint32 public twapTimestampLast;          // Timestamp (mod 2**32) of the last snapshot
    uint256 public twapMinInterval = 30 minutes; // Minimum time that must elapse before a TWAP is trusted
    bool public twapInitialized;              // False until the first snapshot has been taken
    uint256 public lastValidTwapPrice;
    uint256 public maxTwapDivergenceBPS = 2000; // 20% default — max allowed gap between TWAP and spot before auto-liquidity pauses

    function setMaxTwapDivergenceBPS(uint256 bps) external onlyOwner {
        require(bps > 0 && bps <= 5000, "Invalid divergence bound");
        maxTwapDivergenceBPS = bps;
    }

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Staked(address indexed user, uint256 amount, uint256 tier, uint256 lockEnd);
    event AllocatedClaimed(address indexed user, uint256 amount);
    event AllocationUpdated(string allocationType, address indexed account, uint256 amount);
    event AllocationFulfilled(string allocationType, address indexed account, uint256 amount, uint256 timestamp);
    event SystemStarted(uint256 startTime);
    event PauseStatusChanged(bool isPaused);
    event RescueRequested(uint256 amount, uint256 executeAfter);
    event RescueExecuted(uint256 amount);
    event RescueCancelled();
    event ExchangePairStatusUpdated(address indexed pair, bool isPair);
    event FeesUpdated(uint256 treasuryTax, uint256 liquidityTax, uint256 unstakeFee);
    event StakeIndexShifted(address indexed user, uint256 oldIndex, uint256 newIndex);
    event VestingPoolReconciled(uint256 unallocatedAmount, uint256 totalAllocated);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() { require(msg.sender == owner, "Not owner"); _; }
    modifier lockTheSwap { inSwap = true; _; inSwap = false; }
    modifier whenNotPaused() { require(!paused, "System is paused"); _; }

    constructor(address _router, address _teamWallet, address _treasury) {
        require(_router != address(0), "Router cannot be zero address");
        require(_teamWallet != address(0), "Team wallet cannot be zero address");
        require(_treasury != address(0), "Treasury cannot be zero address");

        owner = msg.sender;
        teamWallet = _teamWallet;
        treasuryWallet = _treasury;
        
        isExcludedFromFee[owner] = true;
        isExcludedFromFee[address(this)] = true;
        isExcludedFromFee[teamWallet] = true;
        isExcludedFromFee[treasuryWallet] = true;
        router = IUniswapV2Router02(_router);
        isExcludedFromFee[address(router)] = true;

        // 1. Mint 150M to your wallet (Liquidity only — must be live at TGE)
        _mint(owner, 150_000_000 ether); 

        // 2. Mint 850M to the CONTRACT (funds Seed/Private/Public/Team/Treasury vesting)
        _mint(address(this), 850_000_000 ether); 
        vestingPoolSize = 850_000_000 ether;
    }

    receive() external payable {}

    /* ================= 12-WEEK VESTING ENGINE ================= */

    function setSeedAllocation(address account, uint256 amount) external onlyOwner {
    require(!systemStarted, "System already live");
    require(account != address(0), "Zero address");
    totalTokensAllocated = totalTokensAllocated - seedAllocation[account] + amount;
    require(totalTokensAllocated <= vestingPoolSize, "Exceeds vesting pool");
    seedAllocation[account] = amount;
}

function setTeamAllocation(address account, uint256 amount) external onlyOwner {
    require(!systemStarted, "System already live");
    require(account != address(0), "Zero address");
    totalTokensAllocated = totalTokensAllocated - teamAllocation[account] + amount;
    require(totalTokensAllocated <= vestingPoolSize, "Exceeds vesting pool");
    teamAllocation[account] = amount;
}

function setTreasuryAllocation(address account, uint256 amount) external onlyOwner {
    require(!systemStarted, "System already live");
    require(account != address(0), "Zero address");
    totalTokensAllocated = totalTokensAllocated - treasuryAllocation[account] + amount;
    require(totalTokensAllocated <= vestingPoolSize, "Exceeds vesting pool");
    treasuryAllocation[account] = amount;
}

function setLiquidityAllocation(address account, uint256 amount) external onlyOwner {
    require(!systemStarted, "System already live");
    require(account != address(0), "Zero address");
    totalOwnerPoolAllocated = totalOwnerPoolAllocated - liquidityAllocation[account] + amount;
    require(totalOwnerPoolAllocated <= OWNER_POOL_SIZE, "Exceeds owner pool");
    liquidityAllocation[account] = amount;
}




function markLiquidityAllocationFulfilled(uint256 amount) external onlyOwner {
    require(amount > 0, "Amount must be greater than 0");
    require(
        liquidityAllocationFulfilled[owner] + amount <= liquidityAllocation[owner],
        "Exceeds allocated liquidity amount"
    );
    liquidityAllocationFulfilled[owner] += amount;
    emit AllocationFulfilled("liquidity", owner, amount, block.timestamp);
}

function setPrivateAllocation(address account, uint256 accountAmount) external onlyOwner {
    require(!systemStarted, "System already live");
    require(account != address(0), "Zero address");
    totalTokensAllocated = totalTokensAllocated - privateAllocation[account] + accountAmount;
    require(totalTokensAllocated <= vestingPoolSize, "Exceeds vesting pool");
    privateAllocation[account] = accountAmount;
}

function setPublicAllocation(address account, uint256 accountAmount) external onlyOwner {
    require(!systemStarted, "System already live");
    require(account != address(0), "Zero address");
    totalTokensAllocated = totalTokensAllocated - publicAllocation[account] + accountAmount;
    require(totalTokensAllocated <= vestingPoolSize, "Exceeds vesting pool");
    publicAllocation[account] = accountAmount;
}

function setSeedAllocationBatch(address[] calldata accounts, uint256[] calldata amounts) external onlyOwner {
    require(!systemStarted, "System already live");
    require(accounts.length == amounts.length, "Length mismatch");
    uint256 newTotal = totalTokensAllocated;
    for (uint256 i = 0; i < accounts.length; i++) {
        require(accounts[i] != address(0), "Zero address");
        newTotal = newTotal - seedAllocation[accounts[i]] + amounts[i];
        seedAllocation[accounts[i]] = amounts[i];
    }
    require(newTotal <= vestingPoolSize, "Exceeds vesting pool");
    totalTokensAllocated = newTotal;
}

function setPrivateAllocationBatch(address[] calldata accounts, uint256[] calldata amounts) external onlyOwner {
    require(!systemStarted, "System already live");
    require(accounts.length == amounts.length, "Length mismatch");
    uint256 newTotal = totalTokensAllocated;
    for (uint256 i = 0; i < accounts.length; i++) {
        require(accounts[i] != address(0), "Zero address");
        newTotal = newTotal - privateAllocation[accounts[i]] + amounts[i];
        privateAllocation[accounts[i]] = amounts[i];
    }
    require(newTotal <= vestingPoolSize, "Exceeds vesting pool");
    totalTokensAllocated = newTotal;
}

function setPublicAllocationBatch(address[] calldata accounts, uint256[] calldata amounts) external onlyOwner {
    require(!systemStarted, "System already live");
    require(accounts.length == amounts.length, "Length mismatch");
    uint256 newTotal = totalTokensAllocated;
    for (uint256 i = 0; i < accounts.length; i++) {
        require(accounts[i] != address(0), "Zero address");
        newTotal = newTotal - publicAllocation[accounts[i]] + amounts[i];
        publicAllocation[accounts[i]] = amounts[i];
    }
    require(newTotal <= vestingPoolSize, "Exceeds vesting pool");
    totalTokensAllocated = newTotal;
}

function getTotalAllocation(address account) public view returns (uint256) {
    return seedAllocation[account] + 
           privateAllocation[account] + 
           publicAllocation[account] +
           teamAllocation[account] +
           treasuryAllocation[account];
}


    function getVestedAmount(address account) public view returns (uint256) {
        if (!systemStarted) return 0;
        uint256 total = getTotalAllocation(account);
        if (total == 0) return 0;

        uint256 timePassed = block.timestamp - startTime;
        
        uint256 tgeAmount = (total * 10) / 100;
        if (timePassed >= VESTING_DURATION) {
            return total; 
        } else {
            uint256 remaining90 = total - tgeAmount;
            uint256 vested90 = (remaining90 * timePassed) / VESTING_DURATION;
            return tgeAmount + vested90;
        }
    } 

    function claimMyVestedTokens() external nonReentrant {
        uint256 totalVestedSoFar = getVestedAmount(msg.sender);
        uint256 claimable = totalVestedSoFar - userClaimed[msg.sender];
        require(claimable > 0, "Nothing to claim yet");
        require(vestingPoolSize >= claimable, "Vesting pool depleted");

        userClaimed[msg.sender] += claimable;
        vestingPoolSize -= claimable; // ← Deducts from investor ledger safely
        balanceOf[address(this)] -= claimable;
        balanceOf[msg.sender] += claimable;
        
        emit Transfer(address(this), msg.sender, claimable);
        emit AllocatedClaimed(msg.sender, claimable);
    
}

    /* ================= STAKING ENGINE ================= */

    

    function _updateRewards(address account) internal {
        if (account != address(0)) {
            User storage u = users[account];
            u.rewardsStored = earned(account);
            u.userRewardPerTokenPaid = rewardPerTokenStored;
        }
    }

    function earned(address account) public view returns (uint256) {
        User storage u = users[account];
        uint256 totalEarned = u.rewardsStored;

        // 🟢 FIXED: Safe conditional guard prevents any underflow reverts
        if (u.totalStakedPoints > 0 && rewardPerTokenStored >= u.userRewardPerTokenPaid) {
            uint256 taxPart = (u.totalStakedPoints * (rewardPerTokenStored - u.userRewardPerTokenPaid)) / 1e18;
            totalEarned += taxPart;
        }

        return totalEarned;
    }

    function stake(uint256 tier, uint256 amount) external nonReentrant whenNotPaused {
    require(systemStarted, "Not live");
    require(tier >= 1 && tier <= 3, "Invalid tier");
    require(amount > 0, "Cannot stake 0");

    User storage u = users[msg.sender];
    require(u.stakeRecords.length < MAX_STAKE_SLOTS, "Stake slot cap reached");
    _updateRewards(msg.sender);
    
    require(balanceOf[msg.sender] >= amount, "Inadequate balance");
    balanceOf[msg.sender] -= amount;
    balanceOf[address(this)] += amount;
    totalTokensStaked += amount;

    uint256 lockDuration = (tier == 1) ? 15 days : (tier == 2) ? 45 days : (tier == 3) ? 90 days : 0;
    uint256 expiry = block.timestamp + lockDuration;

    // Calculate Multiplier Points (Tier 1 = 1x, Tier 2 = 1.5x, Tier 3 = 2x)
    uint256 multiplier = (tier == 1) ? 10000 : (tier == 2) ? 15000 : 20000;
    uint256 points = (amount * multiplier) / 10000;

    u.stakeRecords.push(StakeRecord({
        amount: amount,
        lockEnd: expiry,
        tier: tier
    }));
    
    u.totalStaked += amount;
    u.totalStakedPoints += points;     // Track user points
    totalGlobalStakedPoints += points; // Track global pool points
    
    emit Transfer(msg.sender, address(this), amount);
    emit Staked(msg.sender, amount, tier, expiry);
}

/**
 * @notice Emergency withdrawal: Allows user to pull principal regardless of lock timer.
 * @dev Rewards ARE updated and split pro-rata: the caller keeps the share of accrued
 * rewards attributable to their remaining stakes, and forfeits the share attributable
 * to the slot being exited (sent to treasury). This is a partial penalty for skipping
 * the lock timer, not a full reward wipeout.
 * @param index The staking slot index to exit.
 */
function emergencyExit(uint256 index) external nonReentrant {
    User storage u = users[msg.sender];
    require(index < u.stakeRecords.length, "Invalid slot index");
    StakeRecord storage record = u.stakeRecords[index];
    uint256 amount = record.amount;
    require(amount > 0, "Slot empty");

    // 1. Calculate weighted points for this specific slot first
    uint256 multiplier = (record.tier == 1) ? 10000 : (record.tier == 2) ? 15000 : 20000;
    uint256 points = (amount * multiplier) / 10000;

    // 2. Sync the reward checkpoint from the global accumulator
    _updateRewards(msg.sender);
    uint256 totalRewards = u.rewardsStored;

    // 3. Calculate what the user KEEPS (not what they lose) — rounding this down
    //    means any rounding dust favors the protocol, never the user. Whatever
    //    isn't kept is forfeited, so there's no separate "loss" calculation to
    //    round the wrong way.
    uint256 remainingPoints = u.totalStakedPoints - points;
    uint256 keptRewards = 0;
    if (totalRewards > 0 && u.totalStakedPoints > 0) {
        keptRewards = (totalRewards * remainingPoints) / u.totalStakedPoints;
    }
    uint256 forfeitedRewards = totalRewards - keptRewards;

    // 4. Deduct only the slot's portion from the user's stored balances
    u.rewardsStored = keptRewards;

    // 5. Update overall staking pools
    u.totalStaked -= amount;
    totalTokensStaked -= amount;
    u.totalStakedPoints -= points;
    totalGlobalStakedPoints -= points;

    // 6. Clear the slot (Pop and Swap)
    uint256 lastIndex = u.stakeRecords.length - 1;
    if (index != lastIndex) {
        u.stakeRecords[index] = u.stakeRecords[lastIndex];
        emit StakeIndexShifted(msg.sender, lastIndex, index);
    }
    u.stakeRecords.pop();

    // 7. Process exit fees conditionally (0% if contract is paused)
    uint256 fee = 0;
    if (!paused) {
        fee = (amount * unstakeFeeBps) / 10000;
    }
    uint256 amountAfterFee = amount - fee;

    // --- EFFECTS: STATE CHANGES FIRST ---
    balanceOf[address(this)] -= amount;
    balanceOf[msg.sender] += amountAfterFee;

    if (fee > 0) {
        balanceOf[treasuryWallet] += fee;
    }

    if (forfeitedRewards > 0 && totalRewardsAvailable >= forfeitedRewards) {
        totalRewardsAvailable -= forfeitedRewards;
        balanceOf[address(this)] -= forfeitedRewards;
        balanceOf[treasuryWallet] += forfeitedRewards;
    }

    // --- INTERACTIONS: EMIT EVENTS AFTER STATE IS WRITTEN ---
    emit Transfer(address(this), msg.sender, amountAfterFee);

    if (fee > 0) {
        emit Transfer(address(this), treasuryWallet, fee);
    }

    if (forfeitedRewards > 0) {
        emit Transfer(address(this), treasuryWallet, forfeitedRewards);
    }
}

    function claim() external nonReentrant whenNotPaused {
    _updateRewards(msg.sender);
    uint256 reward = users[msg.sender].rewardsStored;
    require(reward > 0, "No rewards");

    // Ledger firewall: reward payout can never exceed actual reward tokens collected
    require(totalRewardsAvailable >= reward, "Insufficient reward pool");
    
    // Clear ledger balance first to maintain rock-solid security
    users[msg.sender].rewardsStored = 0;
    totalRewardsAvailable -= reward; // Debit the reward ledger

    // Move the physical tax tokens out of the contract pool and into the user's balance
    require(balanceOf[address(this)] >= reward, "Inadequate contract balance");
    balanceOf[address(this)] -= reward;
    balanceOf[msg.sender] += reward;

    emit Transfer(address(this), msg.sender, reward);
}

    function unstake(uint256 index) external nonReentrant whenNotPaused {
    User storage u = users[msg.sender];
    require(index < u.stakeRecords.length, "Invalid slot index");
    
    StakeRecord storage record = u.stakeRecords[index];
    uint256 amount = record.amount;
    require(amount > 0, "Slot is already empty");
    require(block.timestamp >= record.lockEnd, "Tokens are still locked");

    _updateRewards(msg.sender);

    // Calculate points to remove based on the slot's tier multiplier
    uint256 multiplier = (record.tier == 1) ? 10000 : (record.tier == 2) ? 15000 : 20000;
    uint256 points = (amount * multiplier) / 10000;

    u.totalStaked -= amount;
    totalTokensStaked -= amount;
    u.totalStakedPoints -= points;
    totalGlobalStakedPoints -= points;

    // Clear the slot (Pop and Swap) with index shift notification for frontend
    uint256 lastIndex = u.stakeRecords.length - 1;
    if (index != lastIndex) {
        u.stakeRecords[index] = u.stakeRecords[lastIndex];
        emit StakeIndexShifted(msg.sender, lastIndex, index);
    }
    u.stakeRecords.pop();

    uint256 fee = (amount * unstakeFeeBps) / 10000;
    uint256 amountAfterFee = amount - fee;

    // --- EFFECTS: STATE CHANGES FIRST ---
    balanceOf[address(this)] -= amount;
    balanceOf[msg.sender] += amountAfterFee;

    if (fee > 0) {
        balanceOf[treasuryWallet] += fee;
    }

    // --- INTERACTIONS: EMIT EVENTS AFTER STATE IS WRITTEN ---
    emit Transfer(address(this), msg.sender, amountAfterFee);

    if (fee > 0) {
        emit Transfer(address(this), treasuryWallet, fee);
    }
}

    /* ================= CORE TOKEN LOGIC ================= */

   function _transfer(address from, address to, uint256 amount) internal {
    require(to != address(0), "Transfer to zero address");
    require(balanceOf[from] >= amount, "Inadequate balance");
    uint256 tax = 0;
    uint256 stakerToTreasury = 0; // Tracks tokens diverted directly to treasury if no stakers exist

    if (!isExcludedFromFee[from] && !isExcludedFromFee[to] && from != address(this) && to != address(this)) {
        if (isExchangePair[from] || isExchangePair[to]) {
            // 🟢 Feed the TWAP oracle on every taxed swap, unconditionally — this is what
            // lets the oracle warm up from ordinary trading activity instead of only ever
            // being seeded from inside an auto-liquidity swap that requires it to already
            // be ready (the original deadlock).
            _updateTwapObservation();

            tax = (amount * (treasuryTaxBPS + liquidityTaxBPS)) / 10_000;
            uint256 stakerPart = (amount * treasuryTaxBPS) / 10000;
            uint256 liqPart = tax - stakerPart;

            if (totalGlobalStakedPoints > 0) {
                // Stakers exist — staker portion stays in contract as claimable rewards
                rewardPerTokenStored += (stakerPart * 1e18) / totalGlobalStakedPoints;
                totalRewardsAvailable += stakerPart;
            } else {
                // No stakers — stakerPart redirected to treasury instead
                stakerToTreasury = stakerPart;
            }

            liquidityTokensCollected += liqPart;

            // totalTaxCollected now reflects the FULL tax taken on this transfer (staker
            // portion + liquidity portion combined) — the true 1%, not just half of it.
            // This gives investors one honest number representing total protocol activity
            // across both the reward pool and the price-floor mechanism.
            totalTaxCollected += tax;
        }
    }

    // --- EFFECTS: SINGLE UNIFIED ACCOUNTING BLOCK ---
    balanceOf[from] -= amount;
    balanceOf[to] += (amount - tax);

    if (tax > 0) {
        if (stakerToTreasury > 0) {
            balanceOf[treasuryWallet] += stakerToTreasury;
            balanceOf[address(this)] += (tax - stakerToTreasury); // Remainder is the liquidity part
        } else {
            balanceOf[address(this)] += tax; // Full tax stays in contract
        }
    }

    // 🟢 Auto-liquidity trigger AFTER balances are updated — reads correct contract balance
    if (tax > 0 && !inSwap && !isExchangePair[from] && liquidityTokensCollected >= minTokensBeforeLiquidity && _isTwapReady()) {
        uint256 currentBalance = balanceOf[address(this)];
        uint256 totalLiabilities = totalTokensStaked + vestingPoolSize + totalRewardsAvailable;

        uint256 freeContractBalance = 0;
        if (currentBalance > totalLiabilities) {
            freeContractBalance = currentBalance - totalLiabilities;
        }

        uint256 tokensToSwap = liquidityTokensCollected;
        if (tokensToSwap > freeContractBalance) {
            tokensToSwap = freeContractBalance;
        }

        if (tokensToSwap >= minTokensBeforeLiquidity) {
            try this._autoAddLiquidity(tokensToSwap) {
                liquidityTokensCollected -= tokensToSwap;
            } catch {
                // Swap or liquidity-add failed this round (slippage, pool state, etc).
                // Tokens stay queued in liquidityTokensCollected and get retried on the
                // next taxed transfer that crosses the threshold — the user's own
                // transfer must still succeed regardless.
            }
        }
    }

    // --- INTERACTIONS: EMIT ALL EVENTS AFTER STATE WRITES ---
    if (tax > 0) {
        if (stakerToTreasury > 0) {
            uint256 liqPart = tax - stakerToTreasury;
            emit Transfer(from, treasuryWallet, stakerToTreasury);
            emit Transfer(from, address(this), liqPart);
        } else {
            emit Transfer(from, address(this), tax);
        }
    }

    emit Transfer(from, to, (amount - tax));
}
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
    uint256 currentAllowance = allowance[from][msg.sender];
    require(currentAllowance >= amount, "Allowance exceeded");
    
    // 🟢 FIXED: Skip decrementing if allowance is set to infinite (type(uint256).max)
    if (currentAllowance != type(uint256).max) {
        allowance[from][msg.sender] = currentAllowance - amount;
    }
    
    _transfer(from, to, amount);
    return true;
}


    /**
     * @dev Destroys `amount` tokens from the caller's account, reducing the total supply.
     * This makes the "Burned" counter on your dashboard go up.
     */
    function burn(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "Inadequate balance to burn");
        
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        
        // Emitting to address(0) is the universal signal that tokens are destroyed
        emit Transfer(msg.sender, address(0), amount);
    }

    function _mint(address to, uint256 amount) internal {
    require(to != address(0), "Mint to zero address");
    require(totalSupply + amount <= MAX_SUPPLY, "Exceeds MAX_SUPPLY"); // SAFE: Hard revert, no silent failures

    totalSupply += amount;
    balanceOf[to] += amount;
    emit Transfer(address(0), to, amount);
}

    function startSystem() external onlyOwner {
    require(!systemStarted, "Already started");
    
        // 🟢 RECONCILE POOL SIZE: Drop the phantom balance so only real allocations are locked
    uint256 unallocated = vestingPoolSize - totalTokensAllocated;
    vestingPoolSize = totalTokensAllocated;

    // 🟢 ROUTE UNSOLD TOKENS: unallocated seed/private/public/team/treasury tokens
    // move to treasury instead of sitting stranded in the contract forever.
    if (unallocated > 0) {
        balanceOf[address(this)] -= unallocated;
        balanceOf[treasuryWallet] += unallocated;
        emit Transfer(address(this), treasuryWallet, unallocated);
    }

    emit VestingPoolReconciled(unallocated, totalTokensAllocated);
    
    systemStarted = true;
    startTime = block.timestamp;
    
    emit SystemStarted(block.timestamp);
}

    function setPaused(bool _state) external onlyOwner {
    paused = _state;
    emit PauseStatusChanged(_state);
}

function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "New owner cannot be zero address");
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "Not the pending owner");
        address previousOwner = owner;
        owner = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, owner);
    }

// Step 1: Owner announces rescue intention — starts 48hr countdown
function initiateRescue(uint256 amount) external onlyOwner {
    require(!rescuePending, "Rescue already pending");
    require(amount > 0, "Amount must be greater than 0");
    
    // Calculate locked liabilities (staking, vesting, rewards, AND tokens already queued for auto-liquidity)
uint256 totalLiabilities = totalTokensStaked + vestingPoolSize + totalRewardsAvailable + liquidityTokensCollected;
    uint256 currentBalance = balanceOf[address(this)];
    
    uint256 freeContractBalance = 0;
    if (currentBalance > totalLiabilities) {
        freeContractBalance = currentBalance - totalLiabilities;
    }
    
    require(amount <= freeContractBalance, "Exceeds safe unallocated balance");
    
    rescueRequestTime = block.timestamp;
    rescueRequestAmount = amount;
    rescuePending = true;
    
    emit RescueRequested(amount, block.timestamp + 48 hours);
}

// Step 2: Owner executes rescue after 48hr delay
function executeRescue() external onlyOwner {
    require(rescuePending, "No rescue pending");
    require(block.timestamp >= rescueRequestTime + 48 hours, "Timelock not expired yet");
    
    uint256 amount = rescueRequestAmount;

    // Re-check liabilities NOW, not just at request time — staking/vesting/rewards
    // activity during the 48hr delay can have shrunk the truly "free" balance.
    uint256 totalLiabilities = totalTokensStaked + vestingPoolSize + totalRewardsAvailable + liquidityTokensCollected;
    uint256 currentBalance = balanceOf[address(this)];

    uint256 freeContractBalance = 0;
    if (currentBalance > totalLiabilities) {
        freeContractBalance = currentBalance - totalLiabilities;
    }

    require(amount <= freeContractBalance, "Amount no longer safe to rescue");

    // Reset state before transfer (CEI pattern)
    rescuePending = false;
    rescueRequestAmount = 0;
    rescueRequestTime = 0;

    balanceOf[address(this)] -= amount;
    balanceOf[treasuryWallet] += amount;

    emit Transfer(address(this), treasuryWallet, amount);
    emit RescueExecuted(amount);
}

// Step 3: Owner can cancel a pending rescue at any time
function cancelRescue() external onlyOwner {
    require(rescuePending, "No rescue pending");
    
    rescuePending = false;
    rescueRequestAmount = 0;
    rescueRequestTime = 0;
    
    emit RescueCancelled();
}

function rescueETH() external onlyOwner nonReentrant {
    uint256 balance = address(this).balance;
    require(balance > 0, "No ETH to rescue");
    (bool success, ) = payable(treasuryWallet).call{value: balance}("");
    require(success, "ETH transfer failed");
}

// 🟢 FIXED: Recovers accidentally sent external ERC-20 tokens safely
    function rescueERC20(address tokenAddress, uint256 amount) external onlyOwner nonReentrant {
        require(tokenAddress != address(0), "Invalid token address");
        
        // 🔒 ANTI-RUG GUARD: Prevents the owner from ever touching staking/vesting tokens
        require(tokenAddress != address(this), "Cannot rescue native project tokens");

        uint256 contractBalance = IERC20(tokenAddress).balanceOf(address(this));
        if (amount > contractBalance) {
            amount = contractBalance;
        }
        
        // Sent securely to the treasury wallet using the correct state variable layout
        bool success = IERC20(tokenAddress).transfer(treasuryWallet, amount);
        require(success, "ERC20 transfer failed");
    }

// 🟢 FIXED: Allows updating the liquidity trigger threshold if price or volume changes
    function setMinTokensBeforeLiquidity(uint256 newMinTokens) external onlyOwner {
        require(newMinTokens > 0, "Threshold must be greater than 0");
        minTokensBeforeLiquidity = newMinTokens;
    }

    // ADDED: Configures which pair the TWAP oracle reads from. Must be called before TWAP
    // protection becomes active. Resets twapInitialized so the oracle re-bootstraps cleanly.
    function setTwapPair(address pair) external onlyOwner {
    require(pair != address(0), "Zero address protection");
    twapPair = pair;
    twapTokenIsToken0 = IUniswapV2Pair(pair).token0() == address(this);
    twapInitialized = false;
    lastValidTwapPrice = 0; // 🟢 don't let an old pair's price protect a new pair
}

    // ADDED: Configures the minimum time window required before a TWAP snapshot is trusted.
    function setTwapMinInterval(uint256 newInterval) external onlyOwner {
        require(newInterval >= 5 minutes, "Interval too short to resist manipulation");
        twapMinInterval = newInterval;
    }

    // ADDED: Reads the pair's cumulative price, compares it against the last stored snapshot,
    // and returns a time-weighted average price for `amountIn` tokens denominated in ETH.
    // Returns 0 (meaning "no TWAP protection available yet") if the oracle isn't configured,
    // hasn't taken its first snapshot yet, or the minimum interval hasn't elapsed since the
    // last snapshot — callers must handle that fallback case explicitly.
   function _isTwapReady() internal view returns (bool) {
    return twapPair != address(0) && (twapInitialized && lastValidTwapPrice > 0);
}

// ADDED: Records a TWAP price snapshot unconditionally on every taxed transfer.
// This lets the oracle "warm up" from ordinary trading activity, independent of
// whether an auto-liquidity swap is being attempted — breaking the bootstrap
// deadlock where the oracle could only ever be seeded from inside a swap that
// itself required the oracle to already be ready.
function _updateTwapObservation() internal {
    if (twapPair == address(0)) {
        return;
    }

    IUniswapV2Pair pair = IUniswapV2Pair(twapPair);
    uint256 priceCumulative = twapTokenIsToken0
        ? pair.price0CumulativeLast()
        : pair.price1CumulativeLast();

    uint32 blockTimestamp = uint32(block.timestamp % 2**32);

    if (!twapInitialized) {
        // First observation ever — nothing to compare against yet. Store it and wait.
        twapPriceCumulativeLast = priceCumulative;
        twapTimestampLast = blockTimestamp;
        twapInitialized = true;
        return;
    }

    uint32 timeElapsed;
    unchecked {
        timeElapsed = blockTimestamp - twapTimestampLast;
    }

    if (timeElapsed < twapMinInterval) {
        return; // Not enough time has passed yet — keep the existing snapshot
    }

    uint256 priceCumulativeDelta;
    unchecked {
        priceCumulativeDelta = priceCumulative - twapPriceCumulativeLast;
    }

    uint256 priceAverageQ112 = priceCumulativeDelta / timeElapsed;

    twapPriceCumulativeLast = priceCumulative;
    twapTimestampLast = blockTimestamp;
    lastValidTwapPrice = priceAverageQ112;
}




    // ⚠️ Pure read-only now — all snapshot-writing happens in _updateTwapObservation(),
    // called unconditionally on every taxed transfer. This function just converts the
    // last cached price into an ETH-out quote for a given token amount.
    function _getTwapEthOut(uint256 amountIn) internal view returns (uint256 ethOut) {
    if (!_isTwapReady()) {
        return 0; // Caller must handle this via _isTwapReady() gate — no fallback here
    }

    ethOut = (amountIn * lastValidTwapPrice) >> 112;
}

    // Reads the CURRENT spot price directly from pool reserves, in the same
    // Q112 format as lastValidTwapPrice, so the two can be compared directly.
    function _getSpotPriceQ112() internal view returns (uint256) {
        if (twapPair == address(0)) return 0;
        (uint112 reserve0, uint112 reserve1, ) = IUniswapV2Pair(twapPair).getReserves();
        if (reserve0 == 0 || reserve1 == 0) return 0;
        return twapTokenIsToken0
            ? (uint256(reserve1) << 112) / reserve0
            : (uint256(reserve0) << 112) / reserve1;
    }

    // External (not internal) so _transfer can call it via try/catch — a failed swap
    // must never revert the user's own transfer. Guarded so only the contract itself
    // can call it; nobody else can trigger a swap directly from outside.
    function _autoAddLiquidity(uint256 tokensToSwap) external lockTheSwap {
    require(msg.sender == address(this), "Internal only");
    uint256 halfToEth = tokensToSwap / 2;
    uint256 halfToLiquidity = tokensToSwap - halfToEth;

    uint256 initialBalance = address(this).balance;

    address[] memory path = new address[](2);
    path[0] = address(this);
    path[1] = router.WETH();

    
    uint256 twapEthOut = _getTwapEthOut(halfToEth);
require(twapEthOut > 0, "TWAP not ready"); // should be unreachable given the _isTwapReady() gate in _transfer, but fail closed rather than silently swap unprotected

uint256 spotPriceQ112 = _getSpotPriceQ112();
require(spotPriceQ112 > 0, "Spot price unavailable");
uint256 priceDiff = lastValidTwapPrice > spotPriceQ112
    ? lastValidTwapPrice - spotPriceQ112
    : spotPriceQ112 - lastValidTwapPrice;
uint256 divergenceBPS = (priceDiff * 10000) / spotPriceQ112;
require(divergenceBPS <= maxTwapDivergenceBPS, "TWAP-spot divergence too high");

uint256 minEthFromSwap = (twapEthOut * liquiditySlippageBPS) / 10000;

    _approve(address(this), address(router), halfToEth);

    router.swapExactTokensForETHSupportingFeeOnTransferTokens(
        halfToEth,
        minEthFromSwap, // 🟢 Now protected — rejects if ETH out is below threshold
        path,
        address(this),
        block.timestamp + 300
    );

    uint256 ethSwapped = address(this).balance - initialBalance;

    if (ethSwapped > 0 && halfToLiquidity > 0) {
        _approve(address(this), address(router), halfToLiquidity);

        uint256 minTokensLiquidity = (halfToLiquidity * liquiditySlippageBPS) / 10000;
        uint256 minEthLiquidity = (ethSwapped * liquiditySlippageBPS) / 10000;

        router.addLiquidityETH{value: ethSwapped}(
            address(this),
            halfToLiquidity,
            minTokensLiquidity,
            minEthLiquidity,
            address(this),
            block.timestamp + 300
        );
    }
}

address public lpToken;
    uint256 public lpLockedAmount;
    uint256 public lpUnlockTime;
    bool public lpLocked;

    event LPLocked(address indexed lpToken, uint256 amount, uint256 unlockTime);
    event LPWithdrawn(uint256 amount);

    function lockLiquidity(address _lpToken) external onlyOwner {
        require(!lpLocked, "Already locked");
        require(_lpToken != address(0), "Zero address");

        uint256 balance = IERC20(_lpToken).balanceOf(address(this));
        require(balance > 0, "No LP tokens to lock");

        lpToken = _lpToken;
        lpLockedAmount = balance;
        lpUnlockTime = block.timestamp + 150 days;
        lpLocked = true;

        emit LPLocked(_lpToken, balance, lpUnlockTime);
    }

    function withdrawLP() external onlyOwner {
        require(lpLocked, "No lock active");
        require(block.timestamp >= lpUnlockTime, "Still locked");

        uint256 amount = lpLockedAmount;
        lpLockedAmount = 0;
        lpLocked = false;

        require(IERC20(lpToken).transfer(owner, amount), "LP transfer failed");
        emit LPWithdrawn(amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) { _transfer(msg.sender, to, amount); return true; }
    function approve(address s, uint256 a) external returns (bool) { _approve(msg.sender, s, a); return true; }
    function _approve(address o, address s, uint256 a) internal { allowance[o][s] = a; emit Approval(o, s, a); }
    function setFees(uint256 _treasuryBPS, uint256 _liquidityBPS, uint256 _unstakeBPS) external onlyOwner {
    require(_treasuryBPS + _liquidityBPS <= 200, "Transfer fees exceed maximum cap of 2%");
    require(_unstakeBPS <= 300, "Unstake fee exceeds maximum cap of 3%");
    
    treasuryTaxBPS = _treasuryBPS;
    liquidityTaxBPS = _liquidityBPS;
    unstakeFeeBps = _unstakeBPS;

    emit FeesUpdated(_treasuryBPS, _liquidityBPS, _unstakeBPS);
}
    function setExchangePair(address pair, bool status) external onlyOwner {
    require(pair != address(0), "Zero address protection");
    isExchangePair[pair] = status;
    emit ExchangePairStatusUpdated(pair, status);
}


// Returns current rescue status so investors can monitor on-chain
function getRescueStatus() external view returns (
    bool pending,
    uint256 amount,
    uint256 executeAfter
) {
    return (
        rescuePending,
        rescueRequestAmount,
        rescuePending ? rescueRequestTime + 48 hours : 0
    );
}


    // This button will show you how many stakes a user has
    function getStakeCount(address account) external view returns (uint256) {
        return users[account].stakeRecords.length;
    }

        
    

    // This button will let you look into a specific slot (0, 1, 2...)
    function getStakeDetails(address account, uint256 index) external view returns (uint256 amount, uint256 lockEnd, uint256 tier) {
        StakeRecord storage record = users[account].stakeRecords[index];
        return (record.amount, record.lockEnd, record.tier);
    }
}