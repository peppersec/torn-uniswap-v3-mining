// SPDX-License-Identifier: MIT

pragma solidity ^0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@uniswap/v3-staker/contracts/libraries/NFTPositionInfo.sol";

import "./interfaces/ISimpleUniswapV3Staker.sol";

/// @notice one use staking contract
/// @dev send cash after deploying to the contract, inherit from any functions and call super for diff visibility
contract SimpleUniswapV3Staker is ISimpleUniswapV3Staker {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  /// @param secondsInside seconds price was in range of ticks
  /// @param tickUpper upper tick
  struct Stake {
    uint32 secondsInside;
    uint224 unlockTime;
  }

  /// @dev notice that this is only a memory struct, there is no double saving
  /// @param secondsInside seconds price was in range of ticks
  /// @param tickLower lower tick
  /// @param tickUpper upper tick
  /// @param liquidity liquidity owned by position
  struct Position {
    uint32 secondsInside;
    int24 tickLower;
    int24 tickUpper;
    uint176 liquidity;
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  INonfungiblePositionManager public immutable override nonfungiblePositionManager;
  /// @inheritdoc ISimpleUniswapV3Staker
  IncentiveKey public override key;
  /// @inheritdoc ISimpleUniswapV3Staker
  mapping(uint256 => address) public override ownerOf;

  /// @dev holds data used to calculate rewards for each NFT staked
  mapping(uint256 => Stake) private stakes;

  // self explanatory
  uint256 public totalDepositedLiquidity;
  /// @notice the amount of reward tokens left in this contract divided by totalDepositedLiquidity
  uint256 public rewardTokensLeftPerTorn;

  constructor(
    IncentiveKey memory stakingData,
    address nonfungiblePositionManagerAddress,
    uint256 depositedRewardTokens
  ) {
    key = stakingData;
    nonfungiblePositionManager = INonfungiblePositionManager(nonfungiblePositionManagerAddress);
    rewardTokensLeftPerTorn = depositedRewardTokens;
    totalDepositedLiquidity = 1;
  }

  modifier onlyNonfungiblePositionManager() {
    require(msg.sender == address(nonfungiblePositionManager), "!positionManager");
    _;
  }

  modifier onlyBeforeEnd() {
    require(block.timestamp < key.endTime, "incentives over");
    _;
  }

  modifier onlyAfterEnd() {
    require(key.endTime <= block.timestamp, "incentives not over");
    _;
  }

  modifier onlyIfDeposited(uint256 tokenId) {
    require(nonfungiblePositionManager.ownerOf(tokenId) == address(this), "!deposited");
    _;
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  function stakeToken(uint256 tokenId) public virtual override {
    // triggers onERC721Received
    nonfungiblePositionManager.safeTransferFrom(msg.sender, address(this), tokenId);
    emit NFTStaked(msg.sender, tokenId);
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  function stakeTokenFor(uint256 tokenId, address beneficiary) public virtual override {
    // triggers onERC721Received
    nonfungiblePositionManager.safeTransferFrom(beneficiary, address(this), tokenId);
    emit NFTStaked(beneficiary, tokenId);
  }

  /// @inheritdoc IERC721Receiver
  function onERC721Received(
    address,
    address from,
    uint256 tokenId,
    bytes calldata
  ) public virtual override onlyNonfungiblePositionManager onlyBeforeEnd returns (bytes4) {
    // get position data
    (IUniswapV3Pool pool, int24 tickLower, int24 tickUpper, uint128 liquidity) = NFTPositionInfo.getPositionInfo(
      key.factory,
      nonfungiblePositionManager,
      tokenId
    );

    // check if proper pool
    require(pool == key.pool, "!pool");

    // register to depositor
    ownerOf[tokenId] = from;

    // update rewardTokensLeftPerTorn, we're scaling it basically
    // initial case: totalDepositedLiquidity = 1, there will always be 1 (very small) extra to dilution, in comparison to 1e18 small
    rewardTokensLeftPerTorn = rewardTokensLeftPerTorn.mul(totalDepositedLiquidity).div(totalDepositedLiquidity.add(liquidity));

    // add liq for calculation
    totalDepositedLiquidity = totalDepositedLiquidity.add(liquidity);

    uint32 secondsInside;

    // if started set secondsInside to the initial value
    if (block.timestamp >= key.startTime)
      (, , secondsInside) = key.pool.snapshotCumulativesInside(tickLower, tickUpper);
      // set this so it yields a negative number and thus reverts if not started and updated after delay
    else secondsInside = type(uint32).max;

    // set stakes to proper and add lock
    stakes[tokenId] = Stake(secondsInside, uint224(block.timestamp.add(key.unlockDelay)));

    // ERC721 compliance
    return this.onERC721Received.selector;
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  function activateStaked(uint256 tokenId) public virtual override {
    // very important require because secondsInside should never be manipulable
    require(stakes[tokenId].secondsInside == type(uint32).max, "activated already!");

    // cache position
    Position memory position = _getPosition(tokenId);

    // get current seconds inside
    (, , uint32 secondsInside) = key.pool.snapshotCumulativesInside(position.tickLower, position.tickUpper);

    // assign it
    stakes[tokenId].secondsInside = secondsInside;
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  function unstakeToken(uint256 tokenId) public virtual override {
    // cache beneficiary and stake
    address beneficiary = ownerOf[tokenId];
    Stake memory cachedStake = stakes[tokenId];

    // check if can unlock and if owner
    require(msg.sender == beneficiary, "!owner");
    require(cachedStake.unlockTime <= block.timestamp, "!timelock");

    // transfer NFT back, this is handled first because it reverts if (this) is not owner of nft
    nonfungiblePositionManager.safeTransferFrom(address(this), beneficiary, tokenId);

    // call internal update rewards and get reward and liquidity
    // but DON'T update stakes after (checked in claim)
    (uint256 reward, , uint256 positionLiquidity) = _calculateRewardAmount(tokenId);

    // handle payouts
    key.rewardToken.safeTransfer(beneficiary, reward);

    // only then update rewardTokensLeftPerTorn
    rewardTokensLeftPerTorn = rewardTokensLeftPerTorn.sub(reward.div(positionLiquidity)).mul(totalDepositedLiquidity).div(
      totalDepositedLiquidity.sub(positionLiquidity)
    );

    emit RewardCollected(beneficiary, reward);

    // lastly update liquidity
    totalDepositedLiquidity = totalDepositedLiquidity.sub(positionLiquidity);

    emit NFTUnstaked(beneficiary, tokenId);
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  function claimReward(uint256 tokenId) public virtual override onlyIfDeposited(tokenId) {
    // call internal update rewards and get reward, seconds and liquidity
    (uint256 reward, uint256 secondsInside, uint256 positionLiquidity) = _calculateRewardAmount(tokenId);

    // cache stake and beneficiary
    address beneficiary = ownerOf[tokenId];
    Stake memory cachedStake = stakes[tokenId];

    // update stakes greedily
    stakes[tokenId] = Stake(uint32(secondsInside), cachedStake.unlockTime);

    // handle payouts
    key.rewardToken.safeTransfer(beneficiary, reward);

    // decrease total reward tokens left, but only by reward since already accounted for
    rewardTokensLeftPerTorn = rewardTokensLeftPerTorn.sub(reward.div(positionLiquidity));

    emit RewardCollected(beneficiary, reward);
  }

  /// @inheritdoc ISimpleUniswapV3Staker
  function refund() public virtual override onlyAfterEnd {
    key.rewardToken.safeTransfer(key.refundee, key.rewardToken.balanceOf(address(this)));
    emit RefundExecuted(key.refundee);
  }

  function _calculateRewardAmount(uint256 tokenId)
    internal
    view
    virtual
    returns (
      uint256 reward,
      uint256 secondsInside,
      uint256 positionLiquidity
    )
  {
    // get position (nft) data
    Position memory position = _getPosition(tokenId);
    positionLiquidity = position.liquidity;

    // get seconds inside
    (, , secondsInside) = key.pool.snapshotCumulativesInside(position.tickLower, position.tickUpper);

    // calculate rewards based on liquidity and seconds inside, this will revert if timestamp > endTime or position.secondsInside > secondsInside
    // that would mean no claiming after endTime or if not activated
    reward = rewardTokensLeftPerTorn.mul(secondsInside.sub(position.secondsInside)).mul(positionLiquidity).div(
      uint256(key.endTime).sub(block.timestamp)
    );
  }

  function _getPosition(uint256 tokenId) internal view virtual returns (Position memory position) {
    // read secondsInside
    position.secondsInside = stakes[tokenId].secondsInside;

    // fill rest and return
    (, position.tickLower, position.tickUpper, position.liquidity) = NFTPositionInfo.getPositionInfo(
      key.factory,
      nonfungiblePositionManager,
      tokenId
    );
  }
}
