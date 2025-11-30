pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

contract ZjsStake is
    Initializable,
    UUPSUpgradeable,
    PausableUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;
    using Address for address;
    using Math for uint256;

    // ************************************** INVARIANT **************************************

    bytes32 public constant ADMIN_ROLE = keccak256("admin_role");
    bytes32 public constant UPGRADE_ROLE = keccak256("upgrade_role");

    uint256 public constant ETH_PID = 0;

    // ************************************** DATA STRUCTURE **************************************

    struct Pool {
        // 质押代币的地址
        address stTokenAddress;
        // 不同资金池所占的权重
        uint256 poolWeight;
        // 最近一次分配奖励的区块号
        uint256 lastRewardBlock;
        // 累计每个质押代币所分配的ZjsToken代币数量
        uint256 accZjsTokenPerST;
        // 质押代币数量
        uint256 stTokenAmount;
        // 最小质押数量
        uint256 minDepositAmount;
        // 解除质押锁定的区块数
        uint256 unstakeLockedBlocks;
    }

    struct UnstakeRequest {
        // 用户请求解除质押的数量
        uint256 amount;
        // 可以提现的区块号
        uint256 unlockBlocks;
    }

    struct UserInfo {
        // 用户质押的数量
        uint256 stAmount;
        // 累计用户获得的奖励
        uint256 totalRewards;
        // 可以领取的奖励
        uint256 pendingRewards;
        // 用户的解除质押请求
        UnstakeRequest[] unstakeRequests;
    }

    // ************************************** STATE VARIABLES **************************************
    uint256 public startBlock; // 质押开始区块高度
    uint256 public endBlock; // 质押结束区块高度
    uint256 public zjsTokenPerBlock; // 每个区块分配的ZjsToken代币数量
    uint256 public totalPoolWeight; // 所有资金池的总权重

    bool public withdrawPaused; // 是否暂停提现
    bool public claimPaused; //是否暂停领取

    IERC20 public zjsToken; // 奖励代币ZjsToken的合约地址
    Pool[] public pools; // 资金池数组
    mapping(uint256 => mapping(address => UserInfo)) public userInfo; // 用户信息映射：pid => user address => UserInfo

    // ************************************** EVENT **************************************
    event SetZjsToken(IERC20 indexed ZjsToken);

    event PauseWithdraw();

    event UnpauseWithdraw();

    event PauseClaim();

    event UnpauseClaim();

    event SetStartBlock(uint256 indexed startBlock);

    event SetEndBlock(uint256 indexed endBlock);

    event SetZjsTokenPerBlock(uint256 indexed ZjsTokenPerBlock);

    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    );

    event UpdatePoolInfo(
        uint256 indexed poolId,
        uint256 indexed minDepositAmount,
        uint256 indexed unstakeLockedBlocks
    );

    event SetPoolWeight(
        uint256 indexed poolId,
        uint256 indexed poolWeight,
        uint256 totalPoolWeight
    );

    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalZjsToken
    );

    event Deposit(address indexed user, uint256 indexed poolId, uint256 amount);

    event RequestUnstake(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount
    );

    event Withdraw(
        address indexed user,
        uint256 indexed poolId,
        uint256 amount,
        uint256 indexed blockNumber
    );

    event Claim(
        address indexed user,
        uint256 indexed poolId,
        uint256 ZjsTokenReward
    );

    // ************************************** MODIFIER **************************************
    modifier checkPid(uint256 pid) {
        require(pid < pools.length, "ZjsStake: pool exists?");
        _;
    }

    modifier whenNotClaimPaused() {
        require(!claimPaused, "claim is paused");
        _;
    }

    modifier whenNotWithdrawPaused() {
        require(!withdrawPaused, "withdraw is paused");
        _;
    }

    // ************************************** INITIALIZER **************************************
    function initialize(
        IERC20 _zjsToken,
        uint256 _zjsTokenPerBlock,
        uint256 _startBlock,
        uint256 _endBlock,
        address admin,
        address upgrader
    ) public initializer {
        __Pausable_init();
        __AccessControl_init();

        zjsToken = _zjsToken;
        zjsTokenPerBlock = _zjsTokenPerBlock;
        startBlock = _startBlock;
        endBlock = _endBlock;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPGRADE_ROLE, upgrader);
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRole(UPGRADE_ROLE) {}

    // ************************************** ADMIN FUNCTION **************************************

    /**
     * @notice Set ZjsToken token address. Can only be called by admin
     */
    function setZjsToken(IERC20 _ZjsToken) public onlyRole(ADMIN_ROLE) {
        zjsToken = _ZjsToken;

        emit SetZjsToken(zjsToken);
    }

    /**
     * @notice Pause withdraw. Can only be called by admin.
     */
    function pauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(!withdrawPaused, "withdraw has been already paused");

        withdrawPaused = true;

        emit PauseWithdraw();
    }

    /**
     * @notice Unpause withdraw. Can only be called by admin.
     */
    function unpauseWithdraw() public onlyRole(ADMIN_ROLE) {
        require(withdrawPaused, "withdraw has been already unpaused");

        withdrawPaused = false;

        emit UnpauseWithdraw();
    }

    /**
     * @notice Pause claim. Can only be called by admin.
     */
    function pauseClaim() public onlyRole(ADMIN_ROLE) {
        require(!claimPaused, "claim has been already paused");

        claimPaused = true;

        emit PauseClaim();
    }

    /**
     * @notice Unpause claim. Can only be called by admin.
     */
    function unpauseClaim() public onlyRole(ADMIN_ROLE) {
        require(claimPaused, "claim has been already unpaused");

        claimPaused = false;

        emit UnpauseClaim();
    }

    /**
     * @notice Update staking start block. Can only be called by admin.
     */
    function setStartBlock(uint256 _startBlock) public onlyRole(ADMIN_ROLE) {
        require(
            _startBlock <= endBlock,
            "start block must be smaller than end block"
        );

        startBlock = _startBlock;

        emit SetStartBlock(_startBlock);
    }

    /**
     * @notice Update staking end block. Can only be called by admin.
     */
    function setEndBlock(uint256 _endBlock) public onlyRole(ADMIN_ROLE) {
        require(
            startBlock <= _endBlock,
            "start block must be smaller than end block"
        );

        endBlock = _endBlock;

        emit SetEndBlock(_endBlock);
    }

    /**
     * @notice Update the ZjsToken reward amount per block. Can only be called by admin.
     */
    function setZjsTokenPerBlock(
        uint256 _ZjsTokenPerBlock
    ) public onlyRole(ADMIN_ROLE) {
        require(_ZjsTokenPerBlock > 0, "invalid parameter");

        zjsTokenPerBlock = _ZjsTokenPerBlock;

        emit SetZjsTokenPerBlock(_ZjsTokenPerBlock);
    }

    function addPool(
        address _stTokenAddress,
        uint256 _poolWeight,
        uint256 _minDepositAmount,
        uint256 _unstakeLockedBlocks,
        bool _withUpdate
    ) public onlyRole(ADMIN_ROLE) {
        if (pool.length > 0) {
            require(
                _stTokenAddress != address(0x0),
                "invalid staking token address"
            );
        } else {
            require(
                _stTokenAddress == address(0x0),
                "invalid staking token address"
            );
        }
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardBlock = block.number > startBlock
            ? block.number
            : startBlock;

        totalPoolWeight += _poolWeight;

        pools.push(
            Pool({
                stTokenAddress: _stTokenAddress,
                poolWeight: _poolWeight,
                lastRewardBlock: lastRewardBlock,
                accZjsTokenPerST: 0,
                stTokenAmount: 0,
                minDepositAmount: _minDepositAmount,
                unstakeLockedBlocks: _unstakeLockedBlocks
            })
        );

        emit AddPool(
            _stTokenAddress,
            _poolWeight,
            lastRewardBlock,
            _minDepositAmount,
            _unstakeLockedBlocks
        );
    }

    // ************************************** PUBLIC FUNCTION **************************************

    function massUpdatePools() public {
        uint256 length = pools.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function updatePool(uint256 _pid) public checkPid(_pid) {
        Pool storage pool = pools[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }

        //更新 pool.lastRewardBlock
        uint256 stTokenAmount = pool.stTokenAmount;
        if (stTokenAmount == 0 || pool.poolWeight == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        //更新pool.accZjsTokenPerST， pool.lastRewardBlock
        uint256 applicableEndBlock = Math.min(block.number, endBlock);
        uint256 numBlocks = applicableEndBlock - pool.lastRewardBlock;
        if (numBlocks == 0) {
            return;
        }
        uint256 zjsTokenReward = (numBlocks *
            zjsTokenPerBlock *
            pool.poolWeight) / totalPoolWeight;
        pool.accZjsTokenPerST += (zjsTokenReward * 1e12) / stTokenAmount;
        pool.lastRewardBlock = block.number;

        emit UpdatePool(_pid, pool.lastRewardBlock, zjsTokenReward);
    }

    function depositETH() public payable whenNotPaused {
        Pool storage pool_ = pool[ETH_PID];

        require(
            pool_.stTokenAddress == address(0x0),
            "invalid staking token address"
        );

        require(
            msg.value >= pool_.minDepositAmount,
            "deposit amount is less than minimum deposit amount"
        );

        _deposit(ETH_PID, msg.value);
    }

    function deposit(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) {
        Pool storage pool_ = pools[_pid];

        require(
            pool_.stTokenAddress != address(0x0),
            "invalid staking token address"
        );

        require(
            _amount >= pool_.minDepositAmount,
            "deposit amount is less than minimum deposit amount"
        );

        IERC20(pool_.stTokenAddress).safeTransferFrom(
            msg.sender,
            address(this),
            _amount
        );

        _deposit(_pid, _amount);

        emit Deposit(msg.sender, _pid, _amount);
    }

    function unstake(
        uint256 _pid,
        uint256 _amount
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.stAmount >= _amount, "insufficient staked amount");

        //更新奖励
        updatePool(_pid);

        //更新user.pendingRewards
        if (user.stAmount > 0) {
            uint256 pending = (user.stAmount * pool.accZjsTokenPerST) /
                1e12 -
                user.totalRewards;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        //更新user.stAmount
        if (_amount > 0) {
            user.stAmount -= _amount;
        }
        pool.stTokenAmount -= _amount;

        //更新user.totalRewards
        user.totalRewards = (user.stAmount * pool.accZjsTokenPerST) / 1e12;

        //添加解除质押请求
        uint256 unlockBlockNumber = block.number + pool.unstakeLockedBlocks;
        user.unstakeRequests.push(
            UnstakeRequest({amount: _amount, unlockBlocks: unlockBlockNumber})
        );

        emit RequestUnstake(msg.sender, _pid, _amount);
    }

    function withdraw(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotWithdrawPaused {
        Pool storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint256 totalWithdrawAmount = 0;
        uint256 currentBlockNumber = block.number;

        //遍历用户的解除质押请求，计算可提现的总金额，并移除已解锁的请求
        uint256 i = 0;
        while (i < user.unstakeRequests.length) {
            UnstakeRequest storage request = user.unstakeRequests[i];
            if (currentBlockNumber >= request.unlockBlocks) {
                totalWithdrawAmount += request.amount;

                //移除该请求
                user.unstakeRequests[i] = user.unstakeRequests[
                    user.unstakeRequests.length - 1
                ];
                user.unstakeRequests.pop();
            } else {
                i++;
            }
        }

        require(totalWithdrawAmount > 0, "no withdrawable amount");

        if (_pid == ETH_PID) {
            // ETH提现
            _safeETHTransfer(msg.sender, totalWithdrawAmount);
        } else {
            // ERC20代币提现
            IERC20(pool.stTokenAddress).safeTransfer(
                msg.sender,
                totalWithdrawAmount
            );
        }

        emit Withdraw(
            msg.sender,
            _pid,
            totalWithdrawAmount,
            currentBlockNumber
        );
    }

    function claim(
        uint256 _pid
    ) public whenNotPaused checkPid(_pid) whenNotClaimPaused {
        Pool storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        //更新奖励
        updatePool(_pid);

        //更新user.pendingRewards
        if (user.stAmount > 0) {
            uint256 pending = (user.stAmount * pool.accZjsTokenPerST) /
                1e12 -
                user.totalRewards;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        uint256 rewardToClaim = user.pendingRewards;
        require(rewardToClaim > 0, "no rewards to claim");

        //重置user.pendingRewards
        user.pendingRewards = 0;

        //更新user.totalRewards
        user.totalRewards = (user.stAmount * pool.accZjsTokenPerST) / 1e12;

        //安全转移奖励代币
        _safeMetaNodeTransfer(msg.sender, rewardToClaim);

        emit Claim(msg.sender, _pid, rewardToClaim);
    }

    // ************************************** INTERNAL FUNCTION **************************************

    function _deposit(uint256 _pid, uint256 _amount) internal {
        Pool storage pool = pools[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        //更新奖励
        updatePool(_pid);

        //更新user.pendingRewards
        if (user.stAmount > 0) {
            uint256 pending = (user.stAmount * pool.accZjsTokenPerST) /
                1e12 -
                user.totalRewards;
            if (pending > 0) {
                user.pendingRewards += pending;
            }
        }

        //更新pool.stTokenAmount， user.stAmount
        if (_amount > 0) {
            if (_pid == ETH_PID) {
                // ETH staking
                pool.stTokenAmount += _amount;
            } else {
                pool.stTokenAmount += _amount;
            }
            user.stAmount += _amount;
        }

        //更新user.totalRewards
        user.totalRewards = (user.stAmount * pool.accZjsTokenPerST) / 1e12;
    }

    function _safeMetaNodeTransfer(address _to, uint256 _amount) internal {
        uint256 zjsTokenBal = zjsToken.balanceOf(address(this));
        if (_amount > zjsTokenBal) {
            zjsToken.safeTransfer(_to, zjsTokenBal);
        } else {
            zjsToken.safeTransfer(_to, _amount);
        }
    }

    function _safeETHTransfer(address _to, uint256 _amount) internal {
        uint256 ethBal = address(this).balance;
        if (_amount > ethBal) {
            payable(_to).transfer(ethBal);
        } else {
            payable(_to).transfer(_amount);
        }
    }
}
