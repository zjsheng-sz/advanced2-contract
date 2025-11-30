// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Address.sol";

interface IUniswapV2Router {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    )
        external
        payable
        returns (uint amountToken, uint amountETH, uint liquidity);
    function removeLiquidityETH(
        address token,
        uint liquidity,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external returns (uint amountToken, uint amountETH);
}

interface IUniswapV2Factory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

contract MyMemeToken is ERC20, Ownable {
    using Address for address payable;

    // 代币税配置
    uint256 public constant TAX_RATE = 5; // 5% 交易税
    address public constant TAX_RECEIVER =
        0x742d35Cc6634C0532925a3b844Bc454e4438f44e; // 示例地址
    address public constant BURN_ADDRESS =
        0x000000000000000000000000000000000000dEaD;

    // 交易限制配置
    uint256 public maxTransactionAmount;
    uint256 public maxDailyTransferCount = 3;
    mapping(address => uint256) public dailyTransferCount;
    mapping(address => uint256) public lastTransferDate;

    // 流动性池相关
    IUniswapV2Router public uniswapV2Router;
    address public uniswapV2Pair;
    bool public tradingEnabled = false;

    // 排除名单（不收取税费）
    mapping(address => bool) public excludedFromTax;

    // 事件
    event TaxCollected(
        address indexed from,
        uint256 amount,
        address indexed receiver
    );
    event LiquidityAdded(
        uint256 tokenAmount,
        uint256 ethAmount,
        uint256 liquidity
    );
    event LiquidityRemoved(
        uint256 liquidity,
        uint256 tokenAmount,
        uint256 ethAmount
    );
    event TradingEnabled();

    constructor(
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address routerAddress
    ) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, totalSupply * 10 ** decimals());

        // 设置交易限制（最大交易量为总供应量的1%）
        maxTransactionAmount = (totalSupply * 10 ** decimals()) / 100;

        // 初始化Uniswap路由
        uniswapV2Router = IUniswapV2Router(routerAddress);
        uniswapV2Pair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(
            address(this),
            uniswapV2Router.WETH()
        );

        // 将合约创建者和零地址排除在税费之外
        excludedFromTax[msg.sender] = true;
        excludedFromTax[address(0)] = true;
        excludedFromTax[TAX_RECEIVER] = true;
        excludedFromTax[BURN_ADDRESS] = true;
    }

    // 重写transfer函数以包含税费机制
    function transfer(
        address to,
        uint256 amount
    ) public override returns (bool) {
        _validateTransfer(msg.sender, to, amount);

        if (excludedFromTax[msg.sender] || excludedFromTax[to]) {
            _transfer(msg.sender, to, amount);
        } else {
            uint256 taxAmount = (amount * TAX_RATE) / 100;
            uint256 transferAmount = amount - taxAmount;

            _transfer(msg.sender, to, transferAmount);
            _collectTax(msg.sender, taxAmount);
        }

        _updateTransferLimits(msg.sender);
        return true;
    }

    // 重写transferFrom函数
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        _validateTransfer(from, to, amount);

        if (excludedFromTax[from] || excludedFromTax[to]) {
            _spendAllowance(from, msg.sender, amount);
            _transfer(from, to, amount);
        } else {
            uint256 taxAmount = (amount * TAX_RATE) / 100;
            uint256 transferAmount = amount - taxAmount;

            _spendAllowance(from, msg.sender, amount);
            _transfer(from, to, transferAmount);
            _collectTax(from, taxAmount);
        }

        _updateTransferLimits(from);
        return true;
    }

    // 收取税费
    function _collectTax(address from, uint256 taxAmount) private {
        // 80%分配给税收接收地址，20%销毁
        uint256 receiverTax = (taxAmount * 80) / 100;
        uint256 burnTax = taxAmount - receiverTax;

        _transfer(from, TAX_RECEIVER, receiverTax);
        _transfer(from, BURN_ADDRESS, burnTax);

        emit TaxCollected(from, taxAmount, TAX_RECEIVER);
    }

    // 验证交易
    function _validateTransfer(
        address from,
        address to,
        uint256 amount
    ) private view {
        require(
            tradingEnabled || from == owner() || to == owner(),
            "Trading not enabled"
        );
        require(
            amount <= maxTransactionAmount,
            "Exceeds max transaction amount"
        );

        // 检查每日交易次数限制（排除特定地址）
        if (!excludedFromTax[from]) {
            if (_isNewDay(from)) {
                dailyTransferCount[from] = 0;
            }
            require(
                dailyTransferCount[from] < maxDailyTransferCount,
                "Exceeds daily transfer limit"
            );
        }
    }

    // 更新交易限制
    function _updateTransferLimits(address from) private {
        if (!excludedFromTax[from]) {
            if (_isNewDay(from)) {
                dailyTransferCount[from] = 0;
            }
            dailyTransferCount[from]++;
            lastTransferDate[from] = block.timestamp;
        }
    }

    // 检查是否是新的一天
    function _isNewDay(address account) private view returns (bool) {
        if (lastTransferDate[account] == 0) return true;
        return (block.timestamp - lastTransferDate[account]) >= 1 days;
    }

    // 添加流动性
    function addLiquidity(
        uint256 tokenAmount,
        uint256 ethAmount
    ) external payable onlyOwner {
        require(msg.value == ethAmount, "ETH amount mismatch");

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        (
            uint256 amountToken,
            uint256 amountETH,
            uint256 liquidity
        ) = uniswapV2Router.addLiquidityETH{value: ethAmount}(
                address(this),
                tokenAmount,
                0, // slippage tolerance
                0, // slippage tolerance
                owner(),
                block.timestamp + 300
            );

        emit LiquidityAdded(amountToken, amountETH, liquidity);
    }

    // 移除流动性
    function removeLiquidity(uint256 liquidity) external onlyOwner {
        IERC20(uniswapV2Pair).approve(address(uniswapV2Router), liquidity);

        (uint256 amountToken, uint256 amountETH) = uniswapV2Router
            .removeLiquidityETH(
                address(this),
                liquidity,
                0, // slippage tolerance
                0, // slippage tolerance
                owner(),
                block.timestamp + 300
            );

        emit LiquidityRemoved(liquidity, amountToken, amountETH);
    }

    // 启用交易
    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Trading already enabled");
        tradingEnabled = true;
        emit TradingEnabled();
    }

    // 设置交易限制（仅管理员）
    function setTransactionLimits(
        uint256 maxAmount,
        uint256 dailyCount
    ) external onlyOwner {
        require(maxAmount > 0, "Max amount must be > 0");
        require(dailyCount > 0, "Daily count must be > 0");

        maxTransactionAmount = maxAmount;
        maxDailyTransferCount = dailyCount;
    }

    // 添加/移除税费排除名单
    function setTaxExclusion(
        address account,
        bool excluded
    ) external onlyOwner {
        excludedFromTax[account] = excluded;
    }

    // 提取意外发送的ETH
    function withdrawStuckETH() external onlyOwner {
        payable(owner()).sendValue(address(this).balance);
    }

    // 接收ETH（用于流动性添加）
    receive() external payable {}
}
