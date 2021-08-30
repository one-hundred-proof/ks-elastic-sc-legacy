// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.4;
pragma abicoder v2;

import {IERC20, IProAMMPool, IProAMMFactory} from '../interfaces/IProAMMPool.sol';
import {IProAMMRouter} from '../interfaces/periphery/IProAMMRouter.sol';
import {IWETH} from '../interfaces/IWETH.sol';

import {TickMath} from '../libraries/TickMath.sol';
import {SafeCast} from '../libraries/SafeCast.sol';
import {PathHelper} from './libraries/PathHelper.sol';

import {DeadlineValidation} from './base/DeadlineValidation.sol';
import {ImmutableRouterStorage} from './base/ImmutableRouterStorage.sol';
import {Multicall} from './base/Multicall.sol';
import {RouterTokenHelperWithFee} from './base/RouterTokenHelperWithFee.sol';

/// @title KyberDMM V2 Swap Router
contract ProAMMRouter is
  IProAMMRouter,
  ImmutableRouterStorage,
  RouterTokenHelperWithFee,
  Multicall,
  DeadlineValidation
{
  using PathHelper for bytes;
  using SafeCast for uint256;

  /// @dev Use as the placeholder value for amountInCached
  uint256 private constant DEFAULT_AMOUNT_IN_CACHED = type(uint256).max;

  /// @dev Use to cache the computed amount in for an exact output swap.
  uint256 private amountInCached = DEFAULT_AMOUNT_IN_CACHED;

  constructor(address _factory, address _WETH) ImmutableRouterStorage(_factory, _WETH) {}

  struct SwapCallbackData {
    bytes path;
    address source;
  }

  function proAMMSwapCallback(
    int256 deltaQty0,
    int256 deltaQty1,
    bytes calldata data
  ) external override {
    require(deltaQty0 > 0 || deltaQty1 > 0, 'ProAMMRouter: invalid delta qties');
    SwapCallbackData memory swapData = abi.decode(data, (SwapCallbackData));
    (address tokenIn, address tokenOut, uint16 fee) = swapData.path.decodeFirstPool();
    require(
      msg.sender == address(_getPool(tokenIn, tokenOut, fee)),
      'ProAMMRouter: invalid callback sender'
    );

    (bool isExactInput, uint256 amountToTransfer) = deltaQty0 > 0
      ? (tokenIn < tokenOut, uint256(deltaQty0))
      : (tokenOut < tokenIn, uint256(deltaQty1));
    if (isExactInput) {
      // transfer token from source to the pool which is the msg.sender
      // wrap eth -> weth and transfer if needed
      transferTokens(tokenIn, swapData.source, msg.sender, amountToTransfer);
    } else {
      if (swapData.path.hasMultiplePools()) {
        swapData.path = swapData.path.skipToken();
        swapExactOutputInternal(amountToTransfer, msg.sender, 0, swapData);
      } else {
        amountInCached = amountToTransfer;
        // transfer tokenOut to the pool (it's the original tokenIn)
        // wrap eth -> weth and transfer if user uses passes eth with the swap
        transferTokens(tokenOut, swapData.source, msg.sender, amountToTransfer);
      }
    }
  }

  /// @dev Performs a single exact input swap
  function swapExactInputInternal(
    uint256 amountIn,
    address recipient,
    uint160 sqrtPriceLimitX96,
    SwapCallbackData memory data
  ) private returns (uint256 amountOut) {
    // allow swapping to the router address with address 0
    if (recipient == address(0)) recipient = address(this);

    (address tokenIn, address tokenOut, uint16 fee) = data.path.decodeFirstPool();

    bool isFromToken0 = tokenIn < tokenOut;

    (int256 amount0, int256 amount1) = _getPool(tokenIn, tokenOut, fee).swap(
      recipient,
      amountIn.toInt256(),
      isFromToken0,
      sqrtPriceLimitX96 == 0
        ? (isFromToken0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
        : sqrtPriceLimitX96,
      abi.encode(data)
    );
    return uint256(-(isFromToken0 ? amount1 : amount0));
  }

  function swapExactInputSingle(ExactInputSingleParams calldata params)
    external
    payable
    override
    onlyNotExpired(params.deadline)
    returns (uint256 amountOut)
  {
    amountOut = swapExactInputInternal(
      params.amountIn,
      params.recipient,
      params.sqrtPriceLimitX96,
      SwapCallbackData({
        path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut),
        source: msg.sender
      })
    );
    require(amountOut >= params.amountOutMinimum, 'ProAMMRouter: insufficient amount out');
  }

  function swapExactInput(ExactInputParams memory params)
    external
    payable
    override
    onlyNotExpired(params.deadline)
    returns (uint256 amountOut)
  {
    address source = msg.sender; // msg.sender is the source of tokenIn for the first swap

    while (true) {
      bool hasMultiplePools = params.path.hasMultiplePools();

      params.amountIn = swapExactInputInternal(
        params.amountIn,
        hasMultiplePools ? address(this) : params.recipient, // for intermediate swaps, this contract custodies
        0,
        SwapCallbackData({path: params.path.getFirstPool(), source: source})
      );

      if (hasMultiplePools) {
        source = address(this);
        params.path = params.path.skipToken();
      } else {
        amountOut = params.amountIn;
        break;
      }
    }

    require(amountOut >= params.amountOutMinimum, 'ProAMMRouter: insufficient amount out');
  }

  /// @dev Perform a swap exact amount out using callback
  function swapExactOutputInternal(
    uint256 amountOut,
    address recipient,
    uint160 sqrtPriceLimitX96,
    SwapCallbackData memory data
  ) private returns (uint256 amountIn) {
    // consider address 0 as the router address
    if (recipient == address(0)) recipient = address(this);

    (address tokenOut, address tokenIn, uint16 fee) = data.path.decodeFirstPool();

    bool isFromToken0 = tokenOut < tokenIn;

    (int256 amount0Delta, int256 amount1Delta) = _getPool(tokenIn, tokenOut, fee).swap(
      recipient,
      -amountOut.toInt256(),
      isFromToken0,
      sqrtPriceLimitX96 == 0
        ? (isFromToken0 ? TickMath.MAX_SQRT_RATIO - 1 : TickMath.MIN_SQRT_RATIO + 1)
        : sqrtPriceLimitX96,
      abi.encode(data)
    );

    uint256 amountOutReceived;
    (amountIn, amountOutReceived) = isFromToken0
      ? (uint256(amount1Delta), uint256(-amount0Delta))
      : (uint256(amount0Delta), uint256(-amount1Delta));
    // it's technically possible to not receive the full output amount,
    // so if no price limit has been specified, require this possibility away
    if (sqrtPriceLimitX96 == 0) require(amountOutReceived == amountOut);
  }

  function swapExactOutputSingle(ExactOutputSingleParams calldata params)
    external
    payable
    override
    onlyNotExpired(params.deadline)
    returns (uint256 amountIn)
  {
    amountIn = swapExactOutputInternal(
      params.amountOut,
      params.recipient,
      params.sqrtPriceLimitX96,
      SwapCallbackData({
        path: abi.encodePacked(params.tokenOut, params.fee, params.tokenIn),
        source: msg.sender
      })
    );
    require(amountIn <= params.amountInMaximum, 'ProAMMRouter: amountIn is too high');
    // has to be reset even though we don't use it in the single hop case
    amountInCached = DEFAULT_AMOUNT_IN_CACHED;
  }

  function swapExactOutput(ExactOutputParams calldata params)
    external
    payable
    override
    onlyNotExpired(params.deadline)
    returns (uint256 amountIn)
  {
    swapExactOutputInternal(
      params.amountOut,
      params.recipient,
      0,
      SwapCallbackData({path: params.path, source: msg.sender})
    );

    amountIn = amountInCached;
    require(amountIn <= params.amountInMaximum, 'ProAMMRouter: amountIn is too high');
    amountInCached = DEFAULT_AMOUNT_IN_CACHED;
  }

  /**
   * @dev Return the pool for the given token pair and fee. The pool contract may or may not exist.
   *  Use determine function to save gas, instead of reading from factory
   */
  function _getPool(
    address tokenA,
    address tokenB,
    uint16 fee
  ) private view returns (IProAMMPool) {
    return IProAMMPool(IProAMMFactory(factory).getPool(tokenA, tokenB, fee));
  }
}
