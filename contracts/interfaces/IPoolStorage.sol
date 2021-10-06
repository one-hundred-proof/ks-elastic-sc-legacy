// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.0;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IProAMMFactory} from './IProAMMFactory.sol';

interface IPoolStorage {
  /// @notice The contract that deployed the pool, which must adhere to the IProAMMFactory interface
  /// @return The contract address
  function factory() external view returns (IProAMMFactory);

  /// @notice The first of the two tokens of the pool, sorted by address
  /// @return The token contract address
  function token0() external view returns (IERC20);

  /// @notice The second of the two tokens of the pool, sorted by address
  /// @return The token contract address
  function token1() external view returns (IERC20);

  /// @notice The pool's fee in basis points
  /// @return The fee in basis points
  function swapFeeBps() external view returns (uint16);

  /// @notice The pool tick distance
  /// @dev Tick can only be initialized and used at multiples of this value
  /// It remains an int24 to avoid casting even though it is >= 1.
  /// e.g: a tickDistance of 5 means ticks can be initialized every 5th tick, i.e., ..., -10, -5, 0, 5, 10, ...
  /// @return The tick distance
  function tickDistance() external view returns (int24);

  /// @notice The maximum amount of position liquidity that can use any tick in the range
  /// @dev This parameter is enforced per tick to prevent liquidity from overflowing a uint128 at any point, and
  /// also prevents out-of-range liquidity from being used to prevent adding in-range liquidity to a pool
  /// @return The max amount of liquidity per tick
  function maxTickLiquidity() external view returns (uint128);

  /// @notice Look up information about a specific tick in the pool
  /// @param tick The tick to look up
  /// @return liquidityGross the total amount of position liquidity
  /// that uses the pool either as tick lower or tick upper
  /// liquidityNet how much liquidity changes when the pool tick crosses above the tick
  /// feeGrowthOutside the fee growth on the other side of the tick from the current tick
  /// secondsPerLiquidityOutside the seconds spent on the other side of the tick from the current tick
  function ticks(int24 tick)
    external
    view
    returns (
      uint128 liquidityGross,
      int128 liquidityNet,
      uint256 feeGrowthOutside,
      uint128 secondsPerLiquidityOutside
    );

  function initializedTicks(int24 tick) external view returns (int24 previous, int24 next);

  /// @notice Returns the information about a position by the position's key
  /// @return liquidity the liquidity quantity of the position
  /// @return feeGrowthInsideLast fee growth inside the tick range as of the last mint / burn action performed
  function getPositions(
    address owner,
    int24 tickLower,
    int24 tickUpper
  ) external view returns (uint128 liquidity, uint256 feeGrowthInsideLast);

  /// @notice All-time seconds per unit of liquidity of the pool
  /// @dev The value has been multiplied by 2^96
  function secondsPerLiquidityGlobal() external view returns (uint128);

  /// @notice The timestamp in which secondsPerLiquidity was last updated
  function secondsPerLiquidityUpdateTime() external view returns (uint32);

  /// @notice Fetches the pool's current price, tick and liquidity
  /// @return poolSqrtPrice pool's current price: sqrt(token1/token0)
  /// @return poolTick pool's current tick
  /// @return nearestCurrentTick pool's nearest initialized tick that is <= pool's current tick
  /// @return locked true if pool is locked, false otherwise
  /// @return poolLiquidity pool's current liquidity that is in range
  function getPoolState()
    external
    view
    returns (
      uint160 poolSqrtPrice,
      int24 poolTick,
      int24 nearestCurrentTick,
      bool locked,
      uint128 poolLiquidity
    );

  /// @notice Fetches the pool's feeGrowthGlobal, reinvestment liquidity and its last cached value
  /// @return poolFeeGrowthGlobal pool's fee growth in LP fees (reinvestment tokens) collected per unit of liquidity since pool creation
  /// @return poolReinvestmentLiquidity total liquidity from collected LP fees (reinvestment tokens) that are reinvested into the pool
  /// @return poolReinvestmentLiquidityLast last cached total liquidity from collected fees
  /// This value will differ from poolReinvestmentLiquidity when swaps that won't result in tick crossings occur
  function getReinvestmentState()
    external
    view
    returns (
      uint256 poolFeeGrowthGlobal,
      uint128 poolReinvestmentLiquidity,
      uint128 poolReinvestmentLiquidityLast
    );

  /// @notice Calculates and returns the active time per unit of liquidity
  /// @param tickLower The lower tick (of a position)
  /// @param tickUpper The upper tick (of a position)
  /// @return secondsPerLiquidityInside active time (multiplied by 2^96)
  /// between the 2 ticks, per unit of liquidity.
  function getSecondsPerLiquidityInside(int24 tickLower, int24 tickUpper)
    external
    view
    returns (uint128 secondsPerLiquidityInside);
}
