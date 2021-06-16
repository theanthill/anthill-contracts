// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./lib/PancakeLibrary.sol";
import "./lib/PancakeOracleLibrary.sol";
import "./lib/FixedPoint.sol";
import "./utils/Epoch.sol";

import "./interfaces/IOracle.sol";
import "./interfaces/IERC20Extended.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IStdReference.sol";

// fixed window oracle that recomputes the average price for the entire period once every period
// note that the price average is only guaranteed to be over at least 1 period, but may be over a longer period
contract Oracle is IOracle, Epoch {
    /* ========== STATE ======== */
    using SafeMath for uint256;
    using FixedPoint for *;

    // Constants
    string constant ExternalOraclePair = "BUSD";

    // Immutables
    IPancakePair public immutable pair;
    address public immutable token0;
    address public immutable token1;
    IStdReference public immutable bandOracle;

    // Latest price from PancakeSwap
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint32 public blockTimestampLast;

    // TWAP for an epoch period
    FixedPoint.uq112x112 public price0Average;
    FixedPoint.uq112x112 public price1Average;

    constructor(
        address _factory,
        address _tokenA,
        address _tokenB,
        uint256 _period,
        uint256 _startTime,
        IStdReference _bandOracle
    ) Epoch(_period, _startTime, 0) {
        // [workerant] The pair could be passed directly to the constructor
        //             so we can avoid having the PancakeLibrary contract
        IPancakePair _pair = IPancakePair(PancakeLibrary.pairFor(_factory, _tokenA, _tokenB));
        
        pair = _pair;

        token0 = _pair.token0();
        token1 = _pair.token1();

        bandOracle = _bandOracle;

        price0CumulativeLast = _pair.price0CumulativeLast();
        price1CumulativeLast = _pair.price1CumulativeLast();

        uint112 reserve0;
        uint112 reserve1;
        (reserve0, reserve1, blockTimestampLast) = _pair.getReserves();

        require(reserve0 != 0 && reserve1 != 0, "Oracle: NO_RESERVES");

        price0Average = FixedPoint.fraction(reserve1, reserve0);
        price1Average = FixedPoint.fraction(reserve0, reserve1);
    }

    /** 
        Update the price from PancakeSwap

        @dev Updates 1-day EMA price from PancakeSwap
    */
    function update() external override checkEpoch {

        // Obtain the TWAP for the latest block
        (uint256 price0Cumulative, uint256 price1Cumulative, uint32 blockTimestamp) = 
            PancakeOracleLibrary.currentCumulativePrices(address(pair));
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired

        // overflow is desired, casting never truncates
        // cumulative price is in (uq112x112 price * seconds) units so we simply wrap it after division by time elapsed
        price0Average = FixedPoint.uq112x112(uint224((price0Cumulative - price0CumulativeLast) / timeElapsed));
        price1Average = FixedPoint.uq112x112(uint224((price1Cumulative - price1CumulativeLast) / timeElapsed));

        price0CumulativeLast = price0Cumulative;
        price1CumulativeLast = price1Cumulative;
        blockTimestampLast = blockTimestamp;

        emit Updated(price0CumulativeLast, price1CumulativeLast);
    }

    /**
        Returns the latest updated average price for the given token

        @param token   Address of the token to get the average price for

        @return price  Average price of the token multiplied by 1e18
    */
    function priceAverage(address token) public view override returns (uint256 price)
    {
        if (token == token0) {
            price = price0Average.mul(1e18).decode144();
        } else {
            require(token == token1, 'ExampleOracleSimple: INVALID_TOKEN');
            price = price1Average.mul(1e18).decode144();
        }
    }

    /**
        Returns the latest known price from the external oracle for the given token

        @param token   Address of the token to get the latest external price for

        @return price  Latest external price of the token multiplied by 1e18
    */
    function priceExternal(address token) public view override returns (uint256 price) {
        price = bandOracle.getReferenceData(IERC20Extended(token).symbol(), ExternalOraclePair).rate;
    }

    /**
        Calculates the percentage of the price variation between the internal liquidity price
        and the external Oracle price

        @param token   Address of the token to get price variation for

        @return percentage  Price variation percentage multiplied by 1e18
    */
    function priceVariationPercentage(address token) external view override returns(uint256 percentage)
    {
        uint256 averageExternal = priceExternal(token);
        uint256 averageInternal = priceAverage(token);
        
        percentage =  averageInternal.div(averageExternal).sub(1e18);
    }

    function consult(address token, uint amountIn) external view override returns (uint256 amountOut) {
        if (token == token0) {
            amountOut = price0Average.mul(amountIn).decode144();
        } else {
            require(token == token1, 'ExampleOracleSimple: INVALID_TOKEN');
            amountOut = price1Average.mul(amountIn).decode144();
        }
    }

    // [workerant] This should not be here, we must use PancakeLibrary from js code
    function pairFor(
        address factory,
        address tokenA,
        address tokenB
    ) external pure returns (address lpt) {
        return PancakeLibrary.pairFor(factory, tokenA, tokenB);
    }

    /* ======= EVENTS ====== */
    event Updated(uint256 price0CumulativeLast, uint256 price1CumulativeLast);
}
