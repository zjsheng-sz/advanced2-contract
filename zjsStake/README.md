# zjsStake

## Overview

zjsStake 是一个基于 Solidity 开发的智能合约质押系统，允许用户质押代币并赚取奖励。该系统使用 Foundry 框架开发，支持多种代币的质押，包括 ETH 和 ERC20 代币。

## 系统架构

### 核心组件

1. **ZjsStake**: 主质押合约，处理质押、解除质押和奖励分发
2. **ZjsToken**: 奖励代币，作为质押的激励代币
3. **资金池(Pools)**: 支持多种质押代币，每个池有独立的权重和规则

### 主要特性

- 支持多代币质押（ETH 和 ERC20 代币）
- 动态奖励分配机制
- 解除质押锁定机制
- 角色基础的访问控制
- 可升级合约（UUPS 模式）

## Foundry Tools

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

For detailed documentation on Foundry, visit:

https://book.getfoundry.sh/

## Getting Started

### Prerequisites

- [Rust](https://www.rust-lang.org/tools/install)
- [Foundry](https://getfoundry.sh/)

### Installation

1. Clone this repository:
   ```shell
   git clone <repository_url>
   cd zjsStake
   ```

2. Install dependencies:
   ```shell
   forge install
   ```

## 详细使用指南

### 1. 合约部署

#### 1.1 环境变量配置

在项目根目录创建 `.env` 文件，配置以下变量：

```env
PRIVATE_KEY=你的私钥
Account2=管理员账户地址
Account3=升级者账户地址
RPC_URL=你的RPC节点地址
```

#### 1.2 执行部署脚本

```shell
forge script script/Deploy.s.sol:DeployZjsStake --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast
```

部署脚本会完成以下操作：
- 部署 ZjsToken 代币合约
- 部署 ZjsStake 质押合约
- 初始化 ZjsStake 合约，设置基本参数

### 2. 合约交互

#### 2.1 添加质押池

管理员可以添加新的质押池：

```javascript
// 添加 ETH 质押池 (PID = 0)
zjsStake.addPool(
    address(0),              // ETH 地址
    100,                     // 池权重
    currentBlock,            // 开始奖励的区块
    1e18,                    // 最小质押数量 (1 ETH)
    100                      // 解除质押锁定区块数
);

// 添加 ERC20 代币质押池
zjsStake.addPool(
    tokenAddress,            // 代币地址
    100,                     // 池权重
    currentBlock,            // 开始奖励的区块
    1000 * 10**18,          // 最小质押数量
    200                      // 解除质押锁定区块数
);
```

#### 2.2 用户质押

用户可以质押代币到指定池中：

```javascript
// 质押 ETH
zjsStake.deposit{value: amount}(0); // 0 是 ETH 的 PID

// 质押 ERC20 代币
// 首先需要授权合约使用用户的代币
token.approve(zjsStakeAddress, amount);
zjsStake.deposit(poolId, amount);
```

#### 2.3 请求解除质押

用户可以请求解除质押，但需要等待锁定期：

```javascript
// 请求解除质押
zjsStake.requestUnstake(poolId, amount);

// 等待锁定区块数后，可以提取
// after locked blocks have passed
zjsStake.withdraw(poolId, amount);
```

#### 2.4 领取奖励

用户可以随时领取累积的奖励：

```javascript
// 领取奖励
zjsStake.claim(poolId);
```

#### 2.5 查询信息

合约提供了多种查询功能：

```javascript
// 查询用户质押信息
(uint256 stAmount, uint256 unstakeAmount, uint256 unstakeRequestBlock, uint256 pendingZjsToken) = zjsStake.userInfo(poolId, userAddress);

// 查询池信息
(address stTokenAddress, uint256 poolWeight, uint256 lastRewardBlock, uint256 accZjsTokenPerST, uint256 stTokenAmount, uint256 minDepositAmount, uint256 unstakeLockedBlocks) = zjsStake.poolInfo(poolId);

// 计算待领取奖励
uint256 reward = zjsStake.pendingZjsToken(poolId, userAddress);
```

### 3. 合约管理

#### 3.1 暂停/恢复合约

管理员可以暂停和恢复合约：

```javascript
// 暂停合约
zjsStake.pause();

// 恢复合约
zjsStake.unpause();
```

#### 3.2 合约升级

具有升级角色的账户可以升级合约：

```javascript
// 部署新的实现合约
ZjsStake newImplementation = new ZjsStake();

// 升级合约
zjsStake.upgradeTo(address(newImplementation));
```

## 开发指南

### 测试

运行测试套件：

```shell
forge test
```

运行特定测试：

```shell
forge test --match-test testName
```

查看详细测试输出：

```shell
forge test -vvv
```

### Gas 分析

分析合约函数的 Gas 消耗：

```shell
forge test --gas-report
```

### 合约构建

构建合约：

```shell
forge build
```

### 代码格式化

格式化代码：

```shell
forge fmt
```

## 安全注意事项

1. **私钥安全**: 妥善保管私钥，不要在公共环境中暴露
2. **角色管理**: 严格控制管理员和升级角色账户
3. **测试**: 部署前进行全面测试
4. **审计**: 生产环境部署前进行专业审计
5. **监控**: 部署后持续监控合约状态和异常活动

## 常见问题

### Q: 如何更改奖励代币每区块的发放量？

A: 合约初始化时设置了 `zjsTokenPerBlock` 参数，此参数不可更改。如需更改，需要重新部署合约。

### Q: 可以同时质押多个代币吗？

A: 是的，可以在不同的池中同时质押多种代币。

### Q: 质押的代币安全吗？

A: 智能合约经过测试，但智能合约风险永远存在。请在充分理解风险的前提下进行质押。

### Q: 如何添加新的质押池？

A: 只有管理员角色可以添加新池，使用 `addPool` 函数。

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

## Contributing

Contributions are welcome! Please fork the repository and submit a pull request.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.