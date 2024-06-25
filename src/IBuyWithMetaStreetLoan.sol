// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import {ISeaport} from "./ISeaport.sol";

interface IBuyWithMetaStreetLoan {
    function buyWithLoan(
        ISeaport.BasicOrderParameters calldata orderParams,
        uint256 downPayment,
        uint256 loanAmount,
        uint64 loanDuration,
        uint256 maxRepayment,
        uint128[] calldata loanTicks,
        bytes calldata loanOptions
    ) external;
}
