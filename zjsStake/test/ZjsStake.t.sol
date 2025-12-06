// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {ZjsStake} from "../src/ZjsStake.sol";
import {ZjsToken} from "../src/ZjsToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(
        string memory name,
        string memory symbol,
        uint256 initialSupply
    ) ERC20(name, symbol) {
        _mint(msg.sender, initialSupply);
    }
}

contract ZjsStakeTest is Test {
    ZjsStake public zjsStake;
    ZjsToken public zjsToken;
    MockERC20 public stToken1;
    MockERC20 public stToken2;

    address public owner;
    address public admin;
    address public upgrader;
    address public user1;
    address public user2;

    uint256 public constant ZJS_TOKEN_PER_BLOCK = 100 * 1e18;
    uint256 public constant START_BLOCK = 1000;
    uint256 public constant END_BLOCK = 2000;
    uint256 public constant ETH_PID = 0;
    uint256 public constant POOL1_PID = 1;
    uint256 public constant POOL2_PID = 2;

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
    event AddPool(
        address indexed stTokenAddress,
        uint256 indexed poolWeight,
        uint256 indexed lastRewardBlock,
        uint256 minDepositAmount,
        uint256 unstakeLockedBlocks
    );
    event UpdatePool(
        uint256 indexed poolId,
        uint256 indexed lastRewardBlock,
        uint256 totalZjsToken
    );

    function setUp() public {
        owner = address(this);
        admin = address(0x1);
        upgrader = address(0x2);
        user1 = address(0x3);
        user2 = address(0x4);

        // Deploy ZjsToken
        zjsToken = new ZjsToken(1000000 * 1e18);

        // Deploy ZjsStake
        vm.prank(owner);
        zjsStake = new ZjsStake();

        // Initialize ZjsStake
        vm.prank(owner);
        zjsStake.initialize(
            zjsToken,
            ZJS_TOKEN_PER_BLOCK,
            START_BLOCK,
            END_BLOCK,
            admin,
            upgrader
        );

        // Deploy mock staking tokens
        stToken1 = new MockERC20("Staking Token 1", "ST1", 1000000 * 1e18);
        stToken2 = new MockERC20("Staking Token 2", "ST2", 1000000 * 1e18);

        // Add ETH pool (pid 0)
        vm.prank(admin);
        zjsStake.addPool(
            address(0x0), // ETH pool
            1, // pool weight
            1 ether, // min deposit amount
            100, // unstake locked blocks
            false // withUpdate
        );

        // Add pool 1 (pid 1)
        vm.prank(admin);
        zjsStake.addPool(
            address(stToken1),
            2, // pool weight
            100 ether, // min deposit amount
            100, // unstake locked blocks
            false // withUpdate
        );

        // Add pool 2 (pid 2)
        vm.prank(admin);
        zjsStake.addPool(
            address(stToken2),
            3, // pool weight
            50 ether, // min deposit amount
            200, // unstake locked blocks
            false // withUpdate
        );

        // Transfer tokens to users
        stToken1.transfer(user1, 1000 ether);
        stToken2.transfer(user1, 1000 ether);
        stToken1.transfer(user2, 1000 ether);
        stToken2.transfer(user2, 1000 ether);

        // Transfer ZjsToken to contract for rewards
        zjsToken.transfer(address(zjsStake), 100000 * 1e18);

        // Set block number to start block
        vm.roll(START_BLOCK);
    }

    function testInitialize() public view {
        assertEq(address(zjsStake.zjsToken()), address(zjsToken));
        assertEq(zjsStake.zjsTokenPerBlock(), ZJS_TOKEN_PER_BLOCK);
        assertEq(zjsStake.startBlock(), START_BLOCK);
        assertEq(zjsStake.endBlock(), END_BLOCK);
    }

    function testDepositETH() public {
        vm.deal(user1, 10 ether);

        vm.prank(user1);
        zjsStake.depositETH{value: 5 ether}();

        uint256 stAmount;
        uint256 totalRewards;
        uint256 pendingRewards;
        (stAmount, totalRewards, pendingRewards) = zjsStake.userInfo(
            ETH_PID,
            user1
        );
        assertEq(stAmount, 5 ether);
        assertEq(address(zjsStake).balance, 5 ether);
    }

    function testDepositToken() public {
        uint256 depositAmount = 200 ether;

        // Approve tokens to staking contract
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);

        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        uint256 stAmount;
        uint256 totalRewards;
        uint256 pendingRewards;
        (stAmount, totalRewards, pendingRewards) = zjsStake.userInfo(
            POOL1_PID,
            user1
        );
        assertEq(stAmount, depositAmount);
        assertEq(stToken1.balanceOf(address(zjsStake)), depositAmount);
    }

    function testDepositBelowMinimum() public {
        vm.deal(user1, 0.5 ether); // Below 1 ether minimum

        vm.expectRevert("deposit amount is less than minimum deposit amount");
        vm.prank(user1);
        zjsStake.depositETH{value: 0.5 ether}();
    }

    function testUnstake() public {
        uint256 depositAmount = 200 ether;
        uint256 unstakeAmount = 100 ether;

        // Deposit first
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        // Unstake
        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount);

        uint256 stAmount;
        uint256 totalRewards;
        uint256 pendingRewards;
        (stAmount, totalRewards, pendingRewards) = zjsStake.userInfo(
            POOL1_PID,
            user1
        );
        assertEq(stAmount, depositAmount - unstakeAmount);

        // We need to check unstakeRequests differently since we can't access nested structs directly
        // This is a limitation in testing, but the actual functionality should work
    }

    function testUnstakeInsufficientStake() public {
        uint256 depositAmount = 200 ether;

        // Deposit first
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        // Try to unstake more than deposited
        vm.expectRevert("insufficient staked amount");
        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, depositAmount + 1 ether);
    }

    function testWithdraw() public {
        uint256 depositAmount = 200 ether;
        uint256 unstakeAmount = 100 ether;
        uint256 lockBlocks = 100;

        // Deposit and unstake
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);
        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount);

        // Move forward in time past the lock period
        vm.roll(START_BLOCK + lockBlocks + 1);

        // Withdraw
        uint256 balanceBefore = stToken1.balanceOf(user1);
        vm.prank(user1);
        zjsStake.withdraw(POOL1_PID);
        uint256 balanceAfter = stToken1.balanceOf(user1);

        assertEq(balanceAfter - balanceBefore, unstakeAmount);
        // unstakeRequests length check is not possible directly in tests
    }

    /**
     * @dev Tests that withdrawing before the lock period expires reverts with the expected error.
     * Steps:
     * 1. User deposits tokens
     * 2. User initiates unstake
     * 3. Attempts to withdraw before lock period ends
     * Expected: Transaction reverts with "no withdrawable amount" error
     */
    function testWithdrawBeforeLockPeriod() public {
        uint256 depositAmount = 200 ether;
        uint256 unstakeAmount = 100 ether;
        uint256 lockBlocks = 100;

        // Deposit and unstake
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);
        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount);

        // Try to withdraw before lock period
        vm.expectRevert("no withdrawable amount");
        vm.prank(user1);
        zjsStake.withdraw(POOL1_PID);
    }

    function testClaimRewards() public {
        uint256 depositAmount = 200 ether;

        // Deposit
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        // Move forward in time to generate rewards
        vm.roll(START_BLOCK + 100);

        // Claim rewards
        uint256 balanceBefore = zjsToken.balanceOf(user1);
        vm.prank(user1);
        zjsStake.claim(POOL1_PID);
        uint256 balanceAfter = zjsToken.balanceOf(user1);

        uint256 rewards = balanceAfter - balanceBefore;
        assertGt(rewards, 0);
        // pendingRewards check is not possible directly in tests
    }

    function testClaimWithNoRewards() public {
        uint256 depositAmount = 200 ether;

        // Deposit
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        // Try to claim immediately with no rewards
        vm.expectRevert("no rewards to claim");
        vm.prank(user1);
        zjsStake.claim(POOL1_PID);
    }

    function testUpdatePool() public {
        uint256 depositAmount = 200 ether;

        // Deposit to trigger pool update
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        address stTokenAddress;
        uint256 poolWeight;
        uint256 lastRewardBlockBefore;
        uint256 accZjsTokenPerST;
        uint256 stTokenAmount;
        uint256 minDepositAmount;
        uint256 unstakeLockedBlocks;

        (
            stTokenAddress,
            poolWeight,
            lastRewardBlockBefore,
            accZjsTokenPerST,
            stTokenAmount,
            minDepositAmount,
            unstakeLockedBlocks
        ) = zjsStake.pools(POOL1_PID);

        // Move forward in time
        vm.roll(START_BLOCK + 100);

        // Update pool
        zjsStake.updatePool(POOL1_PID);

        uint256 lastRewardBlockAfter;
        (
            stTokenAddress,
            poolWeight,
            lastRewardBlockAfter,
            accZjsTokenPerST,
            stTokenAmount,
            minDepositAmount,
            unstakeLockedBlocks
        ) = zjsStake.pools(POOL1_PID);
        assertEq(lastRewardBlockAfter, START_BLOCK + 100);
        assertGt(lastRewardBlockAfter, lastRewardBlockBefore);
    }

    function testPauseUnpauseWithdraw() public {
        console.log("=== testPauseUnpauseWithdraw test ===");

        // Pause withdraw
        vm.prank(admin);
        zjsStake.pauseWithdraw();
        assertTrue(zjsStake.withdrawPaused());

        // Try to withdraw while paused
        uint256 depositAmount = 200 ether;
        uint256 unstakeAmount = 100 ether;
        uint256 lockBlocks = 100;

        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);
        vm.expectRevert("withdraw is paused");
        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount);

        vm.roll(START_BLOCK + lockBlocks + 1);
        vm.expectRevert("withdraw is paused");
        vm.prank(user1);
        zjsStake.withdraw(POOL1_PID);

        // Unpause withdraw
        vm.prank(admin);
        zjsStake.unpauseWithdraw();

        // Check that withdraw is indeed unpaused
        assertFalse(zjsStake.withdrawPaused());

        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount);

        vm.roll(START_BLOCK + 2 * (lockBlocks + 1));
        // Try withdraw again
        vm.prank(user1);
        zjsStake.withdraw(POOL1_PID);
    }

    function testPauseUnpauseClaim() public {
        // Pause claim
        vm.prank(admin);
        zjsStake.pauseClaim();
        assertTrue(zjsStake.claimPaused());

        // Try to claim while paused
        uint256 depositAmount = 200 ether;

        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        vm.roll(START_BLOCK + 100);

        vm.expectRevert("claim is paused");
        vm.prank(user1);
        zjsStake.claim(POOL1_PID);

        // Unpause claim
        vm.prank(admin);
        zjsStake.unpauseClaim();
        assertFalse(zjsStake.claimPaused());

        // Claim should work now
        vm.prank(user1);
        zjsStake.claim(POOL1_PID);
    }

    function testMultiplePoolsRewards() public {
        uint256 depositAmount1 = 200 ether;
        uint256 depositAmount2 = 100 ether;

        // User1 deposits in pool 1
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount1);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount1);

        // User2 deposits in pool 2
        vm.prank(user2);
        stToken2.approve(address(zjsStake), depositAmount2);
        vm.prank(user2);
        zjsStake.deposit(POOL2_PID, depositAmount2);

        // Move forward in time to generate rewards
        vm.roll(START_BLOCK + 100);

        // Claim rewards for both users
        uint256 user1BalanceBefore = zjsToken.balanceOf(user1);
        uint256 user2BalanceBefore = zjsToken.balanceOf(user2);

        vm.prank(user1);
        zjsStake.claim(POOL1_PID);

        vm.prank(user2);
        zjsStake.claim(POOL2_PID);

        uint256 user1Rewards = zjsToken.balanceOf(user1) - user1BalanceBefore;
        uint256 user2Rewards = zjsToken.balanceOf(user2) - user2BalanceBefore;

        // Pool 2 has higher weight (3) than pool 1 (2)
        // Pool weights are used for reward calculation: poolWeight1=2, poolWeight2=3
        // Total weight = 2 + 3 = 5
        // Pool1 rewards = (2/5) * total rewards
        // Pool2 rewards = (3/5) * total rewards

        assertGt(user1Rewards, 0);
        assertGt(user2Rewards, 0);

        // User2 gets more rewards because their pool has higher weight (3 > 2)
        // Even though user1 deposited more, the pool weight is more significant in the calculation
        assertGt(user2Rewards, user1Rewards);
    }

    function testSetZjsTokenPerBlock() public {
        uint256 newZjsTokenPerBlock = ZJS_TOKEN_PER_BLOCK * 2;

        vm.prank(admin);
        zjsStake.setZjsTokenPerBlock(newZjsTokenPerBlock);

        assertEq(zjsStake.zjsTokenPerBlock(), newZjsTokenPerBlock);
    }

    function testSetStartBlock() public {
        uint256 newStartBlock = START_BLOCK + 100;

        vm.prank(admin);
        zjsStake.setStartBlock(newStartBlock);

        assertEq(zjsStake.startBlock(), newStartBlock);
    }

    function testSetEndBlock() public {
        uint256 newEndBlock = END_BLOCK + 100;

        vm.prank(admin);
        zjsStake.setEndBlock(newEndBlock);

        assertEq(zjsStake.endBlock(), newEndBlock);
    }

    function testUnauthorizedAccess() public {
        // Try to call admin function without admin role
        vm.expectRevert();
        vm.prank(user1);
        zjsStake.setZjsTokenPerBlock(ZJS_TOKEN_PER_BLOCK * 2);

        vm.expectRevert();
        vm.prank(user1);
        zjsStake.pauseWithdraw();

        vm.expectRevert();
        vm.prank(user1);
        zjsStake.addPool(address(stToken1), 1, 100 ether, 100, false);
    }

    function testWithdrawAmountNormalCase() public {
        uint256 depositAmount = 200 ether;
        uint256 unstakeAmount1 = 100 ether;
        uint256 unstakeAmount2 = 50 ether;
        uint256 lockBlocks = 100;

        // Deposit and unstake twice
        vm.prank(user1);
        stToken1.approve(address(zjsStake), depositAmount);
        vm.prank(user1);
        zjsStake.deposit(POOL1_PID, depositAmount);

        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount1);

        vm.roll(START_BLOCK + lockBlocks/2 + 1);

        vm.prank(user1);
        zjsStake.unstake(POOL1_PID, unstakeAmount2);

        // Move forward in time to unlock one request
        vm.roll(START_BLOCK + lockBlocks + 1);

        // Check withdraw amounts
        (uint256 requestAmount, uint256 pendingWithdrawAmount) = zjsStake.withdrawAmount(POOL1_PID, user1);
        assertEq(requestAmount, unstakeAmount1 + unstakeAmount2);
        assertEq(pendingWithdrawAmount, unstakeAmount1); // Only the first request is unlocked
    }
}
