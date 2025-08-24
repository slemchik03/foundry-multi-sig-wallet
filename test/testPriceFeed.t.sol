// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract PriceFeed is Test {
    AggregatorV3Interface internal dataFeed;

    /**

      * Aggregator: BTC/USD
      * Address: 0x1b44F3514812d835EB1BDB0acB33d3fA3351Ee43
      */
    constructor(address _dataFeed) {
        dataFeed = AggregatorV3Interface(_dataFeed);
    }

    /**

      * @notice Returns the latest price
      * @return price The latest price
      */
    function getLatestPrice() public view returns (int256) {
        (, int256 price, , , ) = dataFeed.latestRoundData();
        return price;
    }
}
