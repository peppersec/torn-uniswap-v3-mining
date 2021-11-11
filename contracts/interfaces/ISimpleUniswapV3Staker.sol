// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-core/contracts/interfaces/IERC20Minimal.sol";

import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";

interface ISimpleUniswapV3Staker is IERC721Receiver {
  /// @param rewardToken The token being distributed as a reward
  /// @param startTime The time when the incentive program begins
  /// @param pool The Uniswap V3 pool
  /// @param endTime The time when rewards stop accruing
  /// @param factory The Uniswap V3 factory on mainnet
  /// @param unlockDelay period user needs to wait before unlocking
  /// @param refundee The address which receives any remaining reward tokens when the incentive is ended
  struct IncentiveKey {
    IERC20 rewardToken;
    uint96 startTime;
    IUniswapV3Pool pool;
    uint96 endTime;
    IUniswapV3Factory factory;
    uint96 unlockDelay;
    address refundee;
  }

  /// @notice event fired when NFT is staked
  /// @param from who staked
  /// @param tokenId which univ3 nft
  event NFTStaked(address from, uint256 tokenId);
  /// @notice event fired when NFT is unstaked
  /// @param to who unstaked
  /// @param tokenId which univ3 nft
  event NFTUnstaked(address to, uint256 tokenId);
  /// @notice event fired when rewards are collected
  /// @param to who collected rewards
  /// @param amount how much was collected
  event RewardCollected(address to, uint256 amount);
  /// @notice event fired when refund is executed
  /// @param refundee who received refund
  event RefundExecuted(address refundee);

  /// @notice The nonfungible position manager with which this staking contract is compatible
  function nonfungiblePositionManager() external view returns (INonfungiblePositionManager);

  /// @notice Unique incentive data of the contract
  /// @dev for returns please see IncentiveKey struct
  function key()
    external
    view
    returns (
      IERC20,
      uint96,
      IUniswapV3Pool,
      uint96,
      IUniswapV3Factory,
      uint96,
      address
    );

  /// @notice Returns the owner of the NFT deposited in this contract
  /// @param tokenId The ID of the NFT
  /// @return address of owner
  function ownerOf(uint256 tokenId) external view returns (address);

  /// @notice Stakes a Uniswap V3 LP token
  /// @param tokenId The ID of the token to stake
  function stakeToken(uint256 tokenId) external;

  /// @notice Stakes a Uniswap V3 LP token
  /// @param tokenId The ID of the token to stake
  /// @param beneficiary The beneficiary to stake for
  function stakeTokenFor(uint256 tokenId, address beneficiary) external;

  /// @notice activate a staked NFT to start accruing rewards
  /// @param tokenId The ID of the token to activate
  function activateStaked(uint256 tokenId) external;

  /// @notice Unstakes a Uniswap V3 LP token
  /// @param tokenId The ID of the token to unstake
  function unstakeToken(uint256 tokenId) external;

  /// @notice claim reward in rewardToken for the tokenId position
  /// @dev can be executed by anyone and directly attributed to staker, since registered
  /// @param tokenId The ID of the token to claim rewards for
  function claimReward(uint256 tokenId) external;

  /// @notice refund the reward tokens to the refundee, can only be called after end of incentives
  function refund() external;
}
