// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.10;
pragma abicoder v2;

// =================================================================================================================
//  _|_|_|    _|_|_|_|  _|    _|    _|_|_|      _|_|_|_|  _|                                                       |
//  _|    _|  _|        _|    _|  _|            _|            _|_|_|      _|_|_|  _|_|_|      _|_|_|    _|_|       |
//  _|    _|  _|_|_|    _|    _|    _|_|        _|_|_|    _|  _|    _|  _|    _|  _|    _|  _|        _|_|_|_|     |
//  _|    _|  _|        _|    _|        _|      _|        _|  _|    _|  _|    _|  _|    _|  _|        _|           |
//  _|_|_|    _|_|_|_|    _|_|    _|_|_|        _|        _|  _|    _|    _|_|_|  _|    _|    _|_|_|    _|_|_|     |
// =================================================================================================================
// ======================= Staking ======================
// ======================================================
// DEUS Finance: https://github.com/DeusFinance

// Includes veDEUS boost logic
// locked deposits + veDEUS boosted logic

// Primary Author(s)
// Vahid Gh: https://github.com/vahid-dev

// Reviewer(s) / Contributor(s)

// Originally inspired by Synthetix.io, but heavily modified by the Frax team and Deus team
// https://raw.githubusercontent.com/Synthetixio/synthetix/develop/contracts/StakingRewards.sol

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "../Math/Math.sol";
import "../veDEUS/IveDEUS.sol";
import '../Uniswap/TransferHelper.sol';
import "../DEI/IDEI.sol";
import "../Uniswap/Interfaces/IUniswapV2Pair.sol";

contract StakingRewardsDualV5 is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // Instances
    IveDEUS private veDeus;
    IERC20 private rewardToken;
    IUniswapV2Pair private stakingToken;

    // Constant for various precisions
    uint256 private constant MULTIPLIER_PRECISION = 1e18;

    // Time tracking
    uint256 public periodFinish;
    uint256 public lastUpdateTime;

    // Lock time and multiplier settings
    uint256 public lockMaxMultiplier = uint256(3e18); // E18. 1x = e18
    uint256 public lockTimeForMaxMultiplier = 3 * 365 * 86400; // 3 years
    uint256 public lockTimeMin = 86400; // 1 * 86400  (1 day)

    // veDEUS related
    uint256 public veDeusPerDeiForMaxBoost = uint256(4e18); // E18. 4e18 means 4 veDEUS must be held by the staker per 1 DEI
    uint256 public veDeusMaxMultiplier = uint256(2e18); // E18. 1x = 1e18
    mapping(address => uint256) private _veDeusMultiplierStored;

    // Max reward per second
    uint256 public rewardRate;

    // Reward period
    uint256 public rewardsDuration = 604800; // 7 * 86400  (7 days)

    // Reward tracking
    uint256 private rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    // Balance tracking
    uint256 private _totalLiquidityLocked;
    uint256 private _totalCombinedWeight;
    mapping(address => uint256) private _lockedLiquidity;
    mapping(address => uint256) private _combinedWeights;

    // Uniswap related
    bool deiIsToken0;

    // Stake tracking
    mapping(address => LockedStake[]) private lockedStakes;

    // List of valid migrators (set by governance)
    mapping(address => bool) public validMigrators;

    // Stakers set which migrator(s) they want to use
    mapping(address => mapping(address => bool)) public stakerAllowedMigrators;

    // Greylisting of bad addresses
    mapping(address => bool) public greylist;

    // Administrative booleans
    bool public migrationsOn; // Used for migrations. Prevents new stakes, but allows LP and reward withdrawals
    bool public stakesUnlocked; // Release locked stakes in case of system migration or emergency
    bool public withdrawalsPaused; // For emergencies
    bool public rewardsCollectionPaused; // For emergencies
    bool public stakingPaused; // For emergencies

    /* ========== STRUCTS ========== */

    struct LockedStake {
        bytes32 kekId;
        uint256 startTimestamp;
        uint256 liquidity;
        uint256 endingTimestamp;
        uint256 lockMultiplier; // 6 decimals of precision. 1x = 1000000
    }

    /* ========== MODIFIERS ========== */

    modifier isMigrating() {
        require(migrationsOn == true, "Not in migration");
        _;
    }

    modifier notStakingPaused() {
        require(stakingPaused == false, "Staking paused");
        _;
    }

    modifier updateRewardAndBalance(address account, bool syncToo) {
        _updateRewardAndBalance(account, syncToo);
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor (
        address _rewardToken,
        address _stakingToken,
        address _deiAddress,
        address _veDeusAddress
    ) {
        rewardToken = IERC20(_rewardToken);
        stakingToken = IUniswapV2Pair(_stakingToken);
        veDeus = IveDEUS(_veDeusAddress);

        // 10 DEUS a day
        rewardRate = 0; // (uint256(3650e18)).div(365 * 86400); 


        // Uniswap related. Need to know which token dei is (0 or 1)
        address token0 = stakingToken.token0();
        if (token0 == _deiAddress) deiIsToken0 = true;
        else deiIsToken0 = false;

        // Other booleans
        migrationsOn = false;
        stakesUnlocked = false;

        // Initialization
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + rewardsDuration;
    }

    /* ========== VIEWS ========== */

    // Total locked liquidity tokens
    function totalLiquidityLocked() external view returns (uint256) {
        return _totalLiquidityLocked;
    }

    // Locked liquidity for a given account
    function lockedLiquidityOf(address account) external view returns (uint256) {
        return _lockedLiquidity[account];
    }

    // Total 'balance' used for calculating the percent of the pool the account owns
    // Takes into account the locked stake time multiplier and veDEUS multiplier
    function totalCombinedWeight() external view returns (uint256) {
        return _totalCombinedWeight;
    }

    // Combined weight for a specific account
    function combinedWeightOf(address account) external view returns (uint256) {
        return _combinedWeights[account];
    }

    // All the locked stakes for a given account
    function lockedStakesOf(address account) external view returns (LockedStake[] memory) {
        return lockedStakes[account];
    }

    function lockMultiplier(uint256 secs) public view returns (uint256) {
        uint256 _lockMultiplier = uint256(MULTIPLIER_PRECISION) + (secs * (lockMaxMultiplier / (MULTIPLIER_PRECISION)) / lockTimeForMaxMultiplier);
        if (_lockMultiplier > lockMaxMultiplier) _lockMultiplier = lockMaxMultiplier;
        return _lockMultiplier;
    }

    function lastTimeRewardApplicable() internal view returns (uint256) {
        return Math.min(block.timestamp, periodFinish);
    }

    function deiPerLPToken() public view returns (uint256) {
        // Get the amount of DEI 'inside' of the lp tokens
        uint256 _deiPerLpToken;
        {
            uint256 totalDeiReserves;
            (uint256 reserve0, uint256 reserve1, ) = (stakingToken.getReserves());
            if (deiIsToken0) totalDeiReserves = reserve0;
            else totalDeiReserves = reserve1;

            _deiPerLpToken = totalDeiReserves * 1e18 / (stakingToken.totalSupply());
        }
        return _deiPerLpToken;
    }

    function userStakedDei(address account) public view returns (uint256) {
        return deiPerLPToken() * _lockedLiquidity[account] / 1e18;
    }

    function minVeDeusForMaxBoost(address account) public view returns (uint256) {
        return userStakedDei(account) * veDeusPerDeiForMaxBoost / MULTIPLIER_PRECISION;
    }

    function veDeusMultiplier(address account) public view returns (uint256) {
        // The claimer gets a boost depending on amount of veDEUS they have relative to the amount of DEI 'inside'
        // of their locked LP tokens
        uint256 veDeusNeededForMaxBoost = minVeDeusForMaxBoost(account);
        if (veDeusNeededForMaxBoost > 0) { 
            uint256 userVeDeusFraction = (veDeus.balanceOf(account)) * MULTIPLIER_PRECISION / veDeusNeededForMaxBoost;

            uint256 _veDeusMultiplier = ((userVeDeusFraction) * veDeusMaxMultiplier) / MULTIPLIER_PRECISION;

            // Cap the boost to the veDeusMaxMultiplier
            if (_veDeusMultiplier > veDeusMaxMultiplier) _veDeusMultiplier = veDeusMaxMultiplier;

            return _veDeusMultiplier;        
        }
        else return 0; // This will happen with the first stake, when user_staked_dei is 0
    }

    function calcCurCombinedWeight(address account) public view
        returns (
            uint256 oldCombinedWeight,
            uint256 newVeDeusMultiplier,
            uint256 newCombinedWeight
        )
    {
        // Get the old combined weight
        oldCombinedWeight = _combinedWeights[account];

        // Get the veDEUS multipliers
        // For the calculations, use the midpoint (analogous to midpoint Riemann sum)
        newVeDeusMultiplier = veDeusMultiplier(account);
        
        uint256 midpointVeDeusMultiplier;
        if (_lockedLiquidity[account] == 0 && _combinedWeights[account] == 0) {
            // This is only called for the first stake to make sure the veDEUS multiplier is not cut in half
            midpointVeDeusMultiplier = newVeDeusMultiplier;
        }
        else {
            midpointVeDeusMultiplier = (newVeDeusMultiplier + _veDeusMultiplierStored[account]) / 2;
        }

        // Loop through the locked stakes, first by getting the liquidity * lockMultiplier portion
        newCombinedWeight = 0;
        for (uint256 i = 0; i < lockedStakes[account].length; i++) {
            LockedStake memory thisStake = lockedStakes[account][i];
            uint256 lockMultiplier = thisStake.lockMultiplier;

            // If the lock period is over, drop the lock multiplier down to 1x for the weight calculations
            if (thisStake.endingTimestamp <= block.timestamp){
                lockMultiplier = MULTIPLIER_PRECISION;
            }

            uint256 liquidity = thisStake.liquidity;
            uint256 combinedBoostedAmount = liquidity * (lockMultiplier + midpointVeDeusMultiplier) / MULTIPLIER_PRECISION;
            newCombinedWeight = newCombinedWeight + combinedBoostedAmount;
        }
    }

    function rewardPerToken() public view returns (uint256) {
        if (_totalLiquidityLocked == 0 || _totalCombinedWeight == 0) {
            return (rewardPerTokenStored);
        }
        return rewardPerTokenStored + ((lastTimeRewardApplicable() - lastUpdateTime) * (rewardRate) * (1e18) / (_totalCombinedWeight));
    }

    function earned(address account) public view returns (uint256) {
        (uint256 _rewardPerToken) = rewardPerToken();
        if (_combinedWeights[account] == 0){
            return 0;
        }
        return ((_combinedWeights[account] * (_rewardPerToken - userRewardPerTokenPaid[account])) / 1e18) + rewards[account];
    }

    function getRewardForDuration() external view returns (uint256) {
        return rewardRate * rewardsDuration;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function _updateRewardAndBalance(address account, bool syncToo) internal {
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        if (syncToo){
            sync();
        }
        
        if (account != address(0)) {
            // To keep the math correct, the user's combined weight must be recomputed to account for their
            // ever-changing veDEUS balance.
            (   
                uint256 oldCombinedWeight,
                uint256 newVeDeusMultiplier,
                uint256 newCombinedWeight
            ) = calcCurCombinedWeight(account);

            // Calculate the earnings first
            _syncEarned(account);

            // Update the user's stored veDEUS multipliers
            _veDeusMultiplierStored[account] = newVeDeusMultiplier;

            // Update the user's and the global combined weights
            if (newCombinedWeight >= oldCombinedWeight) {
                uint256 weight_diff = newCombinedWeight - oldCombinedWeight;
                _totalCombinedWeight = _totalCombinedWeight + weight_diff;
                _combinedWeights[account] = oldCombinedWeight + weight_diff;
            } else {
                uint256 weight_diff = oldCombinedWeight - newCombinedWeight;
                _totalCombinedWeight = _totalCombinedWeight - weight_diff;
                _combinedWeights[account] = oldCombinedWeight - weight_diff;
            }
        }
    }

    function _syncEarned(address account) internal {
        if (account != address(0)) {
            // Calculate the earnings
            uint256 earned = earned(account);
            rewards[account] = earned;
            userRewardPerTokenPaid[account] = rewardPerTokenStored;
        }
    }

    // Staker can allow a migrator 
    function stakerAllowMigrator(address migratorAddress) external {
        require(validMigrators[migratorAddress], "Invalid migrator address");
        stakerAllowedMigrators[msg.sender][migratorAddress] = true; 
    }

    // Staker can disallow a previously-allowed migrator  
    function stakerDisallowMigrator(address migratorAddress) external {
        // Delete from the mapping
        delete stakerAllowedMigrators[msg.sender][migratorAddress];
    }
    
    // Two different stake functions are needed because of delegateCall and msg.sender issues (important for migration)
    function stakeLocked(uint256 liquidity, uint256 secs) nonReentrant public {
        _stakeLocked(msg.sender, msg.sender, liquidity, secs, block.timestamp);
    }

    // If this were not internal, and sourceAddress had an infinite approve, this could be exploitable
    // (pull funds from sourceAddress and stake for an arbitrary stakerAddress)
    function _stakeLocked(
        address stakerAddress, 
        address sourceAddress, 
        uint256 liquidity, 
        uint256 secs,
        uint256 startTimestamp
    ) internal updateRewardAndBalance(stakerAddress, true) {
        require(!stakingPaused || validMigrators[msg.sender] == true, "Staking paused or in migration");
        require(liquidity > 0, "Must stake more than zero");
        require(greylist[stakerAddress] == false, "Address has been greylisted");
        require(secs >= lockTimeMin, "Minimum stake time not met");
        require(secs <= lockTimeForMaxMultiplier,"Trying to lock for too long");

        uint256 _lockMultiplier = lockMultiplier(secs);
        bytes32 kekId = keccak256(abi.encodePacked(stakerAddress, startTimestamp, liquidity, _lockedLiquidity[stakerAddress]));
        lockedStakes[stakerAddress].push(LockedStake(
            kekId,
            startTimestamp,
            liquidity,
            startTimestamp + secs,
            _lockMultiplier
        ));

        // Pull the tokens from the sourceAddress
        TransferHelper.safeTransferFrom(address(stakingToken), sourceAddress, address(this), liquidity);

        // Update liquidities
        _totalLiquidityLocked = _totalLiquidityLocked + liquidity;
        _lockedLiquidity[stakerAddress] = _lockedLiquidity[stakerAddress] + liquidity;

        // Need to call to update the combined weights
        _updateRewardAndBalance(stakerAddress, false);

        emit StakeLocked(stakerAddress, liquidity, secs, kekId, sourceAddress);
    }

    // Two different withdrawLocked functions are needed because of delegateCall and msg.sender issues (important for migration)
    function withdrawLocked(bytes32 kekId) nonReentrant public {
        require(withdrawalsPaused == false, "Withdrawals paused");
        _withdrawLocked(msg.sender, msg.sender, kekId);
    }

    // No withdrawer == msg.sender check needed since this is only internally callable and the checks are done in the wrapper
    // functions like withdraw(), migrator_withdraw_unlocked() and migratorWithdrawLocked()
    function _withdrawLocked(address stakerAddress, address destinationAddress, bytes32 kekId) internal  {
        // Collect rewards first and then update the balances
        _getReward(stakerAddress, destinationAddress);

        LockedStake memory thisStake;
        thisStake.liquidity = 0;
        uint theArrayIndex;
        for (uint i = 0; i < lockedStakes[stakerAddress].length; i++){ 
            if (kekId == lockedStakes[stakerAddress][i].kekId){
                thisStake = lockedStakes[stakerAddress][i];
                theArrayIndex = i;
                break;
            }
        }
        require(thisStake.kekId == kekId, "Stake not found");
        require(block.timestamp >= thisStake.endingTimestamp || stakesUnlocked == true || validMigrators[msg.sender] == true, "Stake is still locked!");

        uint256 liquidity = thisStake.liquidity;

        if (liquidity > 0) {
            // Update liquidities
            _totalLiquidityLocked = _totalLiquidityLocked - liquidity;
            _lockedLiquidity[stakerAddress] = _lockedLiquidity[stakerAddress] - liquidity;

            // Remove the stake from the array
            delete lockedStakes[stakerAddress][theArrayIndex];

            // Need to call to update the combined weights
            _updateRewardAndBalance(stakerAddress, false);

            // Give the tokens to the destinationAddress
            // Should throw if insufficient balance
            stakingToken.transfer(destinationAddress, liquidity);

            emit WithdrawLocked(stakerAddress, liquidity, kekId, destinationAddress);
        }

    }
    
    // Two different getReward functions are needed because of delegateCall and msg.sender issues (important for migration)
    function getReward() external nonReentrant returns (uint256) {
        require(rewardsCollectionPaused == false,"Rewards collection paused");
        return _getReward(msg.sender, msg.sender);
    }

    // No withdrawer == msg.sender check needed since this is only internally callable
    // This distinction is important for the migrator
    function _getReward(address rewardee, address destinationAddress) internal updateRewardAndBalance(rewardee, true) returns (uint256 reward) {
        reward = rewards[rewardee];
        if (reward > 0) {
            rewards[rewardee] = 0;
            rewardToken.transfer(destinationAddress, reward);
            emit RewardPaid(rewardee, reward, address(rewardToken), destinationAddress);
        }
    }

    // If the period expired, renew it
    function retroCatchUp() internal {
        // Failsafe check
        require(block.timestamp > periodFinish, "Period has not expired yet!");

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        uint256 numPeriodsElapsed = uint256(block.timestamp - periodFinish) / rewardsDuration; // Floor division to the nearest period
        uint balance = rewardToken.balanceOf(address(this));
        require(rewardRate * rewardsDuration * (numPeriodsElapsed + 1) <= balance, "Not enough DEUS available");

        periodFinish = periodFinish + ((numPeriodsElapsed + 1) * rewardsDuration);

        uint256 reward = rewardPerToken();
        rewardPerTokenStored = reward;
        lastUpdateTime = lastTimeRewardApplicable();

        emit RewardsPeriodRenewed(address(stakingToken));
    }

    function sync() public {
        if (block.timestamp > periodFinish) {
            retroCatchUp();
        }
        else {
            uint256 reward = rewardPerToken();
            rewardPerTokenStored = reward;
            lastUpdateTime = lastTimeRewardApplicable();
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Migrator can stake for someone else (they won't be able to withdraw it back though, only stakerAddress can). 
    function migratorStakeLockedFor(address stakerAddress, uint256 amount, uint256 secs, uint256 startTimestamp) external isMigrating {
        require(stakerAllowedMigrators[stakerAddress][msg.sender] && validMigrators[msg.sender], "Mig. invalid or unapproved");
        _stakeLocked(stakerAddress, msg.sender, amount, secs, startTimestamp);
    }

    // Used for migrations
    function migratorWithdrawLocked(address stakerAddress, bytes32 kekId) external isMigrating {
        require(stakerAllowedMigrators[stakerAddress][msg.sender] && validMigrators[msg.sender], "Mig. invalid or unapproved");
        _withdrawLocked(stakerAddress, msg.sender, kekId);
    }

    // Adds supported migrator address
    function addMigrator(address migratorAddress) external onlyOwner {
        validMigrators[migratorAddress] = true;
    }

    // Remove a migrator address
    function removeMigrator(address migratorAddress) external onlyOwner {
        require(validMigrators[migratorAddress] == true, "Address nonexistant");
        
        // Delete from the mapping
        delete validMigrators[migratorAddress];
    }

    // Added to support recovering LP Rewards and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyOwner {
        // Admin cannot withdraw the staking token from the contract unless currently migrating
        if(!migrationsOn){
            require(tokenAddress != address(stakingToken), "Not in migration"); // Only Governance / Timelock can trigger a migration
        }
        // Only the owner address can ever receive the recovery withdrawal
        IERC20(tokenAddress).transfer(owner(), tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function setRewardsDuration(uint256 _rewardsDuration) external onlyOwner {
        require(
            periodFinish == 0 || block.timestamp > periodFinish,
            "Reward period incomplete"
        );
        rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration);
    }

    function setMultipliers(uint256 _lockMaxMultiplier, uint256 _veDeusMaxMultiplier, uint256 _veDeusPerDeiForMaxBoost) external onlyOwner {
        require(_lockMaxMultiplier >= MULTIPLIER_PRECISION, "Mult must be >= MULTIPLIER_PRECISION");
        require(_veDeusMaxMultiplier >= 0, "veDEUS mul must be >= 0");
        require(_veDeusPerDeiForMaxBoost > 0, "veDEUS pct max must be >= 0");

        lockMaxMultiplier = _lockMaxMultiplier;
        veDeusMaxMultiplier = _veDeusMaxMultiplier;
        veDeusPerDeiForMaxBoost = _veDeusPerDeiForMaxBoost;

        emit MaxVeDeusMultiplierSet(veDeusMaxMultiplier);
        emit LockedStakeMaxMultiplierUpdated(lockMaxMultiplier);
        emit veDeusPerDeiForMaxBoostSet(veDeusPerDeiForMaxBoost);
    }

    function setLockedStakeTimeForMinAndMaxMultiplier(uint256 _lockTimeForMaxMultiplier, uint256 _lockTimeMin) external onlyOwner {
        require(_lockTimeForMaxMultiplier >= 1, "Mul max time must be >= 1");
        require(_lockTimeMin >= 1, "Mul min time must be >= 1");

        lockTimeForMaxMultiplier = _lockTimeForMaxMultiplier;
        lockTimeMin = _lockTimeMin;

        emit LockedStakeTimeForMaxMultiplier(lockTimeForMaxMultiplier);
        emit LockedStakeMinTime(_lockTimeMin);
    }

    function greylistAddress(address _address) external onlyOwner {
        greylist[_address] = !(greylist[_address]);
    }

    function unlockStakes() external onlyOwner {
        stakesUnlocked = !stakesUnlocked;
    }

    function toggleMigrations() external onlyOwner {
        migrationsOn = !migrationsOn;
    }

    function toggleStaking() external onlyOwner {
        stakingPaused = !stakingPaused;
    }

    function toggleWithdrawals() external onlyOwner {
        withdrawalsPaused = !withdrawalsPaused;
    }

    function toggleRewardsCollection() external onlyOwner {
        rewardsCollectionPaused = !rewardsCollectionPaused;
    }

    function setRewardRates(uint256 _new_rate, bool syncToo) external onlyOwner {
        rewardRate = _new_rate;

        if (syncToo){
            sync();
        }
    }

    /* ========== EVENTS ========== */

    event StakeLocked(address indexed user, uint256 amount, uint256 secs, bytes32 kekId, address sourceAddress);
    event WithdrawLocked(address indexed user, uint256 amount, bytes32 kekId, address destinationAddress);
    event RewardPaid(address indexed user, uint256 reward, address token_address, address destinationAddress);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
    event RewardsPeriodRenewed(address token);
    event LockedStakeMaxMultiplierUpdated(uint256 multiplier);
    event LockedStakeTimeForMaxMultiplier(uint256 secs);
    event LockedStakeMinTime(uint256 secs);
    event MaxVeDeusMultiplierSet(uint256 multiplier);
    event veDeusPerDeiForMaxBoostSet(uint256 scaleFactor);
}
