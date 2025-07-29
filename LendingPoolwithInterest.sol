// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title Lending Pool with Interest
 * @dev A decentralized lending protocol with collateral-based borrowing and dynamic interest rates
 * @author Your Name
 */

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract LendingPoolWithInterest {
    
    // ===== STATE VARIABLES =====
    
    struct LendingPool {
        address asset;              // Token being lent/borrowed  
        uint256 totalDeposits;      // Total amount deposited
        uint256 totalBorrows;       // Total amount borrowed
        uint256 reserveFactor;      // Percentage kept as reserves (in basis points)
        uint256 baseRate;          // Base interest rate (annual %)
        uint256 multiplier;        // Rate multiplier based on utilization
        uint256 jumpMultiplier;    // Rate multiplier after optimal utilization
        uint256 optimalUtilization; // Optimal utilization rate (in basis points)
        bool isActive;             // Pool status
    }
    
    struct UserDeposit {
        uint256 amount;            // Deposited amount
        uint256 shareTokens;       // Share tokens representing ownership
        uint256 lastUpdateTime;    // Last interaction timestamp
        uint256 accruedInterest;   // Interest earned so far
    }
    
    struct UserBorrow {
        uint256 principal;         // Original borrowed amount
        uint256 collateralAmount;  // Collateral deposited
        address collateralAsset;   // Collateral token address
        uint256 borrowTime;        // When the loan was taken
        uint256 lastUpdateTime;    // Last interest calculation
        uint256 accruedInterest;   // Interest accumulated
        bool isActive;             // Loan status
    }
    
    // ===== STORAGE =====
    
    mapping(address => LendingPool) public pools;
    mapping(address => mapping(address => UserDeposit)) public userDeposits; // user => asset => deposit
    mapping(address => mapping(uint256 => UserBorrow)) public userBorrows;   // user => loanId => borrow
    mapping(address => uint256) public userLoanCount;
    
    address[] public supportedAssets;
    address public admin;
    
    // Constants
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MIN_COLLATERAL_RATIO = 15000; // 150% minimum collateralization
    uint256 public constant LIQUIDATION_THRESHOLD = 12000; // 120% liquidation threshold
    uint256 public constant LIQUIDATION_BONUS = 500; // 5% liquidation bonus
    
    // ===== EVENTS =====
    
    event PoolCreated(address indexed asset, uint256 baseRate, uint256 optimalUtilization);
    event Deposited(address indexed user, address indexed asset, uint256 amount, uint256 shareTokens);
    event Withdrawn(address indexed user, address indexed asset, uint256 amount, uint256 interest);
    event Borrowed(address indexed user, uint256 indexed loanId, address indexed asset, uint256 amount, address collateralAsset, uint256 collateralAmount);
    event Repaid(address indexed user, uint256 indexed loanId, uint256 principal, uint256 interest);
    event Liquidated(address indexed borrower, uint256 indexed loanId, address indexed liquidator, uint256 collateralSeized);
    event InterestRateUpdated(address indexed asset, uint256 newRate);
    
    // ===== MODIFIERS =====
    
    modifier onlyAdmin() {
        require(msg.sender == admin, "Only admin can call this function");
        _;
    }
    
    modifier poolExists(address _asset) {
        require(pools[_asset].isActive, "Pool does not exist or is inactive");
        _;
    }
    
    modifier validLoan(address _user, uint256 _loanId) {
        require(_loanId < userLoanCount[_user], "Invalid loan ID");
        require(userBorrows[_user][_loanId].isActive, "Loan is not active");
        _;
    }
    
    // ===== CONSTRUCTOR =====
    
    constructor() {
        admin = msg.sender;
    }
    
    // ===== ADMIN FUNCTIONS =====
    
    /**
     * @dev Creates a new lending pool for an asset
     * @param _asset Address of the ERC20 token
     * @param _baseRate Base annual interest rate (in basis points)
     * @param _multiplier Interest rate multiplier
     * @param _jumpMultiplier Jump multiplier for high utilization
     * @param _optimalUtilization Optimal utilization rate (in basis points)
     */
    function createPool(
        address _asset,
        uint256 _baseRate,
        uint256 _multiplier,
        uint256 _jumpMultiplier,
        uint256 _optimalUtilization
    ) external onlyAdmin {
        require(_asset != address(0), "Invalid asset address");
        require(!pools[_asset].isActive, "Pool already exists");
        require(_optimalUtilization <= BASIS_POINTS, "Invalid optimal utilization");
        
        pools[_asset] = LendingPool({
            asset: _asset,
            totalDeposits: 0,
            totalBorrows: 0,
            reserveFactor: 1000, // 10% reserve factor
            baseRate: _baseRate,
            multiplier: _multiplier,
            jumpMultiplier: _jumpMultiplier,
            optimalUtilization: _optimalUtilization,
            isActive: true
        });
        
        supportedAssets.push(_asset);
        emit PoolCreated(_asset, _baseRate, _optimalUtilization);
    }
    
    // ===== CORE FUNCTION 1: DEPOSIT & EARN INTEREST =====
    
    /**
     * @dev Deposit tokens into the lending pool to earn interest
     * @param _asset Address of the token to deposit
     * @param _amount Amount of tokens to deposit
     */
    function deposit(address _asset, uint256 _amount) external poolExists(_asset) {
        require(_amount > 0, "Amount must be greater than 0");
        require(IERC20(_asset).transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        _processDeposit(_asset, _amount);
    }
    
    function _processDeposit(address _asset, uint256 _amount) internal {
        UserDeposit storage userDeposit = userDeposits[msg.sender][_asset];
        
        // Calculate accrued interest for existing deposit
        if (userDeposit.amount > 0) {
            _updateUserDepositInterest(msg.sender, _asset);
        }
        
        // Calculate share tokens
        uint256 shareTokens = _calculateShareTokens(_asset, _amount);
        
        // Update user deposit
        userDeposit.amount += _amount;
        userDeposit.shareTokens += shareTokens;
        userDeposit.lastUpdateTime = block.timestamp;
        
        // Update pool
        pools[_asset].totalDeposits += _amount;
        
        emit Deposited(msg.sender, _asset, _amount, shareTokens);
    }
    
    function _calculateShareTokens(address _asset, uint256 _amount) internal view returns (uint256) {
        uint256 totalDeposits = pools[_asset].totalDeposits;
        if (totalDeposits == 0) {
            return _amount; // First depositor gets 1:1 ratio
        } else {
            uint256 totalShareTokens = _getTotalShareTokens(_asset);
            return (_amount * totalShareTokens) / totalDeposits;
        }
    }
    
    // ===== CORE FUNCTION 2: BORROW WITH COLLATERAL =====
    
    /**
     * @dev Borrow tokens by providing collateral
     * @param _borrowAsset Address of the token to borrow
     * @param _borrowAmount Amount to borrow
     * @param _collateralAsset Address of the collateral token
     * @param _collateralAmount Amount of collateral to provide
     */
    function borrow(
        address _borrowAsset,
        uint256 _borrowAmount,
        address _collateralAsset,
        uint256 _collateralAmount
    ) external poolExists(_borrowAsset) poolExists(_collateralAsset) {
        _validateBorrowInputs(_borrowAsset, _borrowAmount, _collateralAsset, _collateralAmount);
        _executeBorrow(_borrowAsset, _borrowAmount, _collateralAsset, _collateralAmount);
    }
    
    function _validateBorrowInputs(
        address _borrowAsset,
        uint256 _borrowAmount,
        address _collateralAsset,
        uint256 _collateralAmount
    ) internal view {
        require(_borrowAmount > 0, "Borrow amount must be greater than 0");
        require(_collateralAmount > 0, "Collateral amount must be greater than 0");
        require(_borrowAsset != _collateralAsset, "Cannot use same asset as collateral");
        require(pools[_borrowAsset].totalDeposits >= _borrowAmount, "Insufficient liquidity");
        
        // Check collateralization ratio (simplified: assume 1:1 price ratio)
        uint256 collateralRatio = (_collateralAmount * BASIS_POINTS) / _borrowAmount;
        require(collateralRatio >= MIN_COLLATERAL_RATIO, "Insufficient collateral");
    }
    
    function _executeBorrow(
        address _borrowAsset,
        uint256 _borrowAmount,
        address _collateralAsset,
        uint256 _collateralAmount
    ) internal {
        // Transfer collateral from user
        require(IERC20(_collateralAsset).transferFrom(msg.sender, address(this), _collateralAmount), "Collateral transfer failed");
        
        // Transfer borrowed tokens to user
        require(IERC20(_borrowAsset).transfer(msg.sender, _borrowAmount), "Borrow transfer failed");
        
        // Create loan record
        uint256 loanId = userLoanCount[msg.sender];
        userBorrows[msg.sender][loanId] = UserBorrow({
            principal: _borrowAmount,
            collateralAmount: _collateralAmount,
            collateralAsset: _collateralAsset,
            borrowTime: block.timestamp,
            lastUpdateTime: block.timestamp,
            accruedInterest: 0,
            isActive: true
        });
        
        userLoanCount[msg.sender]++;
        pools[_borrowAsset].totalBorrows += _borrowAmount;
        
        emit Borrowed(msg.sender, loanId, _borrowAsset, _borrowAmount, _collateralAsset, _collateralAmount);
    }
    
    // ===== CORE FUNCTION 3: REPAY LOAN & RECLAIM COLLATERAL =====
    
    /**
     * @dev Repay borrowed amount plus interest to reclaim collateral
     * @param _borrowAsset Address of the borrowed token
     * @param _loanId ID of the loan to repay
     */
    function repayLoan(address _borrowAsset, uint256 _loanId) 
        external 
        poolExists(_borrowAsset) 
        validLoan(msg.sender, _loanId) 
    {
        uint256 totalRepayment = _calculateRepaymentAmount(msg.sender, _loanId, _borrowAsset);
        _executeRepayment(_borrowAsset, _loanId, totalRepayment);
    }
    
    function _calculateRepaymentAmount(address _user, uint256 _loanId, address _borrowAsset) internal view returns (uint256) {
        UserBorrow storage loan = userBorrows[_user][_loanId];
        uint256 interest = _calculateBorrowInterest(_user, _loanId, _borrowAsset);
        return loan.principal + interest;
    }
    
    function _executeRepayment(address _borrowAsset, uint256 _loanId, uint256 _totalRepayment) internal {
        UserBorrow storage loan = userBorrows[msg.sender][_loanId];
        
        // Transfer repayment from user
        require(IERC20(_borrowAsset).transferFrom(msg.sender, address(this), _totalRepayment), "Repayment transfer failed");
        
        // Return collateral to user
        require(IERC20(loan.collateralAsset).transfer(msg.sender, loan.collateralAmount), "Collateral return failed");
        
        // Update pool and loan
        pools[_borrowAsset].totalBorrows -= loan.principal;
        uint256 interest = _totalRepayment - loan.principal;
        
        loan.isActive = false;
        loan.accruedInterest = interest;
        
        emit Repaid(msg.sender, _loanId, loan.principal, interest);
    }
    
    // ===== ADDITIONAL FUNCTION: WITHDRAW DEPOSITS =====
    
    /**
     * @dev Withdraw deposited tokens plus earned interest
     * @param _asset Address of the token to withdraw
     * @param _amount Amount to withdraw
     */
    function withdraw(address _asset, uint256 _amount) external poolExists(_asset) {
        require(_amount > 0, "Amount must be greater than 0");
        
        UserDeposit storage userDeposit = userDeposits[msg.sender][_asset];
        require(userDeposit.amount >= _amount, "Insufficient deposit balance");
        
        _processWithdrawal(_asset, _amount, userDeposit);
    }
    
    function _processWithdrawal(address _asset, uint256 _amount, UserDeposit storage userDeposit) internal {
        // Update interest before withdrawal
        _updateUserDepositInterest(msg.sender, _asset);
        
        // Check liquidity and calculate share tokens
        uint256 availableLiquidity = pools[_asset].totalDeposits - pools[_asset].totalBorrows;
        require(availableLiquidity >= _amount, "Insufficient liquidity");
        
        uint256 shareTokensToRemove = (_amount * userDeposit.shareTokens) / userDeposit.amount;
        
        // Update user deposit and pool
        userDeposit.amount -= _amount;
        userDeposit.shareTokens -= shareTokensToRemove;
        userDeposit.lastUpdateTime = block.timestamp;
        pools[_asset].totalDeposits -= _amount;
        
        // Transfer tokens to user
        require(IERC20(_asset).transfer(msg.sender, _amount), "Transfer failed");
        
        emit Withdrawn(msg.sender, _asset, _amount, userDeposit.accruedInterest);
    }
    
    // ===== LIQUIDATION FUNCTION =====
    
    /**
     * @dev Liquidate an undercollateralized loan
     * @param _borrower Address of the borrower
     * @param _loanId ID of the loan to liquidate
     * @param _borrowAsset Address of the borrowed asset
     */
    function liquidate(
        address _borrower,
        uint256 _loanId,
        address _borrowAsset
    ) external poolExists(_borrowAsset) validLoan(_borrower, _loanId) {
        _validateLiquidation(_borrower, _loanId, _borrowAsset);
        _executeLiquidation(_borrower, _loanId, _borrowAsset);
    }
    
    function _validateLiquidation(address _borrower, uint256 _loanId, address _borrowAsset) internal view {
        UserBorrow storage loan = userBorrows[_borrower][_loanId];
        uint256 interest = _calculateBorrowInterest(_borrower, _loanId, _borrowAsset);
        uint256 totalDebt = loan.principal + interest;
        uint256 collateralRatio = (loan.collateralAmount * BASIS_POINTS) / totalDebt;
        
        require(collateralRatio < LIQUIDATION_THRESHOLD, "Loan is sufficiently collateralized");
    }
    
    function _executeLiquidation(address _borrower, uint256 _loanId, address _borrowAsset) internal {
        UserBorrow storage loan = userBorrows[_borrower][_loanId];
        uint256 interest = _calculateBorrowInterest(_borrower, _loanId, _borrowAsset);
        uint256 totalDebt = loan.principal + interest;
        
        // Calculate liquidation amounts
        uint256 liquidationBonus = (loan.collateralAmount * LIQUIDATION_BONUS) / BASIS_POINTS;
        uint256 totalCollateralSeized = loan.collateralAmount + liquidationBonus;
        
        // Liquidator pays the debt
        require(IERC20(_borrowAsset).transferFrom(msg.sender, address(this), totalDebt), "Debt payment failed");
        
        // Transfer collateral to liquidator
        require(IERC20(loan.collateralAsset).transfer(msg.sender, totalCollateralSeized), "Collateral transfer failed");
        
        // Update pool and loan
        pools[_borrowAsset].totalBorrows -= loan.principal;
        loan.isActive = false;
        
        emit Liquidated(_borrower, _loanId, msg.sender, totalCollateralSeized);
    }
    
    // ===== INTERNAL FUNCTIONS =====
    
    /**
     * @dev Calculate current borrow interest for a loan
     */
    function _calculateBorrowInterest(address _user, uint256 _loanId, address _asset) internal view returns (uint256) {
        UserBorrow storage loan = userBorrows[_user][_loanId];
        
        uint256 timeElapsed = block.timestamp - loan.lastUpdateTime;
        uint256 currentRate = _calculateBorrowRate(_asset);
        
        // Simple interest calculation: principal * rate * time / (100 * SECONDS_PER_YEAR)
        uint256 interest = (loan.principal * currentRate * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
        
        return loan.accruedInterest + interest;
    }
    
    /**
     * @dev Update deposit interest for a user
     */
    function _updateUserDepositInterest(address _user, address _asset) internal {
        UserDeposit storage userDeposit = userDeposits[_user][_asset];
        
        uint256 timeElapsed = block.timestamp - userDeposit.lastUpdateTime;
        uint256 supplyRate = _calculateSupplyRate(_asset);
        
        // Calculate interest earned
        uint256 interest = (userDeposit.amount * supplyRate * timeElapsed) / (BASIS_POINTS * SECONDS_PER_YEAR);
        
        userDeposit.accruedInterest += interest;
        userDeposit.lastUpdateTime = block.timestamp;
    }
    
    /**
     * @dev Calculate current borrow rate based on utilization
     */
    function _calculateBorrowRate(address _asset) internal view returns (uint256) {
        LendingPool storage pool = pools[_asset];
        
        if (pool.totalDeposits == 0) {
            return pool.baseRate;
        }
        
        uint256 utilization = (pool.totalBorrows * BASIS_POINTS) / pool.totalDeposits;
        
        if (utilization <= pool.optimalUtilization) {
            // Below optimal: baseRate + (utilization * multiplier / optimal)
            return pool.baseRate + (utilization * pool.multiplier) / pool.optimalUtilization;
        } else {
            // Above optimal: baseRate + multiplier + ((utilization - optimal) * jumpMultiplier / (100% - optimal))
            uint256 excessUtilization = utilization - pool.optimalUtilization;
            uint256 excessRate = (excessUtilization * pool.jumpMultiplier) / (BASIS_POINTS - pool.optimalUtilization);
            return pool.baseRate + pool.multiplier + excessRate;
        }
    }
    
    /**
     * @dev Calculate supply rate (what depositors earn)
     */
    function _calculateSupplyRate(address _asset) internal view returns (uint256) {
        LendingPool storage pool = pools[_asset];
        
        if (pool.totalDeposits == 0) {
            return 0;
        }
        
        uint256 borrowRate = _calculateBorrowRate(_asset);
        uint256 utilization = (pool.totalBorrows * BASIS_POINTS) / pool.totalDeposits;
        
        // Supply rate = borrow rate * utilization * (1 - reserve factor)
        return (borrowRate * utilization * (BASIS_POINTS - pool.reserveFactor)) / (BASIS_POINTS * BASIS_POINTS);
    }
    
    /**
     * @dev Get total share tokens for an asset
     */
    function _getTotalShareTokens(address _asset) internal view returns (uint256) {
        // In a more complex implementation, this would track total share tokens
        // For simplicity, we'll use total deposits as proxy
        return pools[_asset].totalDeposits;
    }
    
    // ===== VIEW FUNCTIONS =====
    
    function getPoolInfo(address _asset) external view returns (
        uint256 totalDeposits,
        uint256 totalBorrows,
        uint256 availableLiquidity,
        uint256 utilizationRate,
        uint256 borrowRate,
        uint256 supplyRate
    ) {
        LendingPool storage pool = pools[_asset];
        
        totalDeposits = pool.totalDeposits;
        totalBorrows = pool.totalBorrows;
        availableLiquidity = totalDeposits - totalBorrows;
        
        if (totalDeposits > 0) {
            utilizationRate = (totalBorrows * BASIS_POINTS) / totalDeposits;
        }
        
        borrowRate = _calculateBorrowRate(_asset);
        supplyRate = _calculateSupplyRate(_asset);
    }
    
    function getUserDeposit(address _user, address _asset) external view returns (
        uint256 amount,
        uint256 shareTokens,
        uint256 accruedInterest,
        uint256 lastUpdateTime
    ) {
        UserDeposit storage userDeposit = userDeposits[_user][_asset];
        return (userDeposit.amount, userDeposit.shareTokens, userDeposit.accruedInterest, userDeposit.lastUpdateTime);
    }
    
    function getUserLoan(address _user, uint256 _loanId) external view returns (
        uint256 principal,
        uint256 collateralAmount,
        address collateralAsset,
        uint256 borrowTime,
        uint256 accruedInterest,
        bool isActive
    ) {
        UserBorrow storage loan = userBorrows[_user][_loanId];
        return (
            loan.principal,
            loan.collateralAmount,
            loan.collateralAsset,
            loan.borrowTime,
            loan.accruedInterest,
            loan.isActive
        );
    }
    
    function getCurrentBorrowInterest(address _user, uint256 _loanId, address _asset) external view returns (uint256) {
        return _calculateBorrowInterest(_user, _loanId, _asset);
    }
    
    function getSupportedAssets() external view returns (address[] memory) {
        return supportedAssets;
    }
    
    function getLoanCollateralRatio(address _user, uint256 _loanId, address _borrowAsset) external view returns (uint256) {
        UserBorrow storage loan = userBorrows[_user][_loanId];
        uint256 currentInterest = _calculateBorrowInterest(_user, _loanId, _borrowAsset);
        uint256 totalDebt = loan.principal + currentInterest;
        
        if (totalDebt == 0) return 0;
        
        // Simplified 1:1 price ratio
        return (loan.collateralAmount * BASIS_POINTS) / totalDebt;
    }
}
