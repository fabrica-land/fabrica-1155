// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BytesLib} from "./BytesLib.sol";
import {IAavePool} from "./IAavePool.sol";
import {IBuyWithMetaStreetLoan} from "./IBuyWithMetaStreetLoan.sol";
import {IMetaStreetPool} from "./IMetaStreetPool.sol";
import {IMetaStreetCollateralWrapper} from "./IMetaStreetCollateralWrapper.sol";
import {ISeaport} from "./ISeaport.sol";

contract BuyWithMetaStreetLoan is IBuyWithMetaStreetLoan {

    address public aaveFlashLoanAddress;
    address public collateralWrapperAddress;
    address public fabricaTokenAddress;
    address public metaStreetPoolAddress;
    address public seaportAddress;

    constructor(
        address aaveFlashLoanAddress_,
        address collateralWrapperAddress_,
        address fabricaTokenAddress_,
        address metaStreetPoolAddress_,
        address seaportAddress_
    ) {
        aaveFlashLoanAddress = aaveFlashLoanAddress_;
        collateralWrapperAddress = collateralWrapperAddress_;
        fabricaTokenAddress = fabricaTokenAddress_;
        metaStreetPoolAddress = metaStreetPoolAddress_;
        seaportAddress = seaportAddress_;
    }

    function buyWithLoan(
        ISeaport.BasicOrderParameters calldata orderParams,
        uint256 downPayment,
        uint256 loanAmount,
        uint64 loanDuration,
        uint256 maxRepayment,
        uint128[] calldata loanTicks,
        bytes calldata loanOptions
    ) external {
        require(IERC20(orderParams.considerationToken).balanceOf(msg.sender) >= downPayment, "Operator does not have sufficient consideration");
        require(orderParams.offerToken == fabricaTokenAddress, "Order must be for a Fabrica token");
        uint256 additionalAmount = 0;
        for (uint256 i = 0 ; i < orderParams.additionalRecipients.length ; i++) {
            additionalAmount = additionalAmount + orderParams.additionalRecipients[i].amount;
        }
        require(
            loanAmount + downPayment == orderParams.considerationAmount + additionalAmount,
            "loanAmount plus downPayment must equal considerationAmount in offer, plus fees"
        );
        // 1) Take out Aave Flash Loan
        bytes memory params = abi.encode(
            orderParams,
            downPayment,
            loanAmount,
            loanDuration,
            maxRepayment,
            loanTicks,
            loanOptions
        );
        IAavePool(aaveFlashLoanAddress).flashLoanSimple(
            msg.sender,
            orderParams.considerationToken,
            loanAmount,
            params,
            0
        );
        // Next steps are in executeOperation()
    }

    function executeOperation(bytes calldata params) public {
        (
            ISeaport.BasicOrderParameters memory orderParams,
            uint256 downPayment,
            uint256 loanAmount,
            uint64 loanDuration,
            uint256 maxRepayment,
            uint128[] memory loanTicks,
            bytes memory loanOptions
        ) = abi.decode(
            params,
            (
                ISeaport.BasicOrderParameters,
                uint256,
                uint256,
                uint64,
                uint256,
                uint128[],
                bytes
            )
        );
        uint256 additionalAmount = 0;
        for (uint256 i = 0 ; i < orderParams.additionalRecipients.length ; i++) {
            additionalAmount = additionalAmount + orderParams.additionalRecipients[i].amount;
        }
        require(
            loanAmount + downPayment == orderParams.considerationAmount + additionalAmount,
            "loanAmount plus downPayment must equal considerationAmount in offer, plus fees"
        );
        // 2) Buy the Fabrica token
        if (!ISeaport(seaportAddress).fulfillBasicOrder(orderParams)) {
            revert("Seaport order failed to be fulfilled.");
        }
        // 3) Wrap the Fabrica token in the collateral wrapper
        if (!IERC1155(fabricaTokenAddress).isApprovedForAll(msg.sender, collateralWrapperAddress)) {
            IERC1155(fabricaTokenAddress).setApprovalForAll(collateralWrapperAddress, true);
        }
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = orderParams.offerIdentifier;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = orderParams.offerAmount;
        uint256 wrapperId = IMetaStreetCollateralWrapper(collateralWrapperAddress).mint(
            fabricaTokenAddress,
            tokenIds,
            amounts
        );
        // 4) Take out MetaStreet loan
        uint256 flashLoanInterest = loanAmount * IAavePool(aaveFlashLoanAddress).FLASHLOAN_PREMIUM_TOTAL();
        uint256 loanTotalWithFlashFee = loanAmount + flashLoanInterest;
        IMetaStreetPool(metaStreetPoolAddress).borrow(
            loanTotalWithFlashFee,
            loanDuration,
            collateralWrapperAddress,
            wrapperId,
            maxRepayment,
            loanTicks,
            loanOptions
        );
        // 5) Approve repayment of the Aave Flash Loan
        IERC20(orderParams.considerationToken).approve(aaveFlashLoanAddress, loanTotalWithFlashFee);
    }
}
