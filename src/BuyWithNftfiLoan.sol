// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import {AaveFlashLoanSimpleReceiverBase} from "./AaveFlashLoanSimpleReceiverBase.sol";
import {BytesLib} from "./BytesLib.sol";
import {IAavePool} from "./IAavePool.sol";
import {IAavePoolAddressesProvider} from './IAavePoolAddressesProvider.sol';
import {IBuyWithNftfiLoan} from "./IBuyWithNftfiLoan.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {INftfiDirectLoanFixedOffer} from "./INftfiDirectLoanFixedOffer.sol";
import {ISeaport} from "./ISeaport.sol";

contract BuyWithNftfiLoan is IBuyWithNftfiLoan, AaveFlashLoanSimpleReceiverBase {

    INftfiDirectLoanFixedOffer public immutable NFTFI_DIRECT_LOAN;
    ISeaport public immutable SEAPORT;

    constructor(
        address aavePoolAddressesProviderAddress,
        address nftfiLoanAddress,
        address seaportAddress
    ) AaveFlashLoanSimpleReceiverBase(IAavePoolAddressesProvider(aavePoolAddressesProviderAddress)) {
        NFTFI_DIRECT_LOAN = INftfiDirectLoanFixedOffer(nftfiLoanAddress);
        SEAPORT = ISeaport(seaportAddress);
    }

    function buyWithLoan(
        ISeaport.BasicOrderParameters calldata orderParams,
        INftfiDirectLoanFixedOffer.Offer calldata offer,
        INftfiDirectLoanFixedOffer.Signature calldata signature,
        INftfiDirectLoanFixedOffer.BorrowerSettings calldata borrowerSettings
    ) external {
        require(offer.loanERC20Denomination == orderParams.considerationToken, "Order consideration token does not match loan-offer denomination");
        require(offer.nftCollateralContract == orderParams.offerToken, "Order offer token does not match loan-offer collateral token");
        uint256 flashLoanInterest = offer.loanPrincipalAmount * POOL.FLASHLOAN_PREMIUM_TOTAL() / 10000;
        uint256 downPayment = orderParams.considerationAmount - offer.loanPrincipalAmount;
        uint256 additionalAmount = 0;
        for (uint256 i = 0 ; i < orderParams.additionalRecipients.length ; i++) {
            additionalAmount = additionalAmount + orderParams.additionalRecipients[i].amount;
        }
        uint256 totalRequiredFromOperator = downPayment + additionalAmount + flashLoanInterest;
        require(IERC20(orderParams.considerationToken).balanceOf(msg.sender) >= totalRequiredFromOperator, "Operator does not have sufficient consideration");
        // 1) Take out Aave Flash Loan
        bytes memory params = abi.encode(
            orderParams,
            offer,
            signature,
            borrowerSettings
        );
        POOL.flashLoanSimple(
            msg.sender,
            orderParams.considerationToken,
            offer.loanPrincipalAmount,
            params,
            0
        );
        // Next steps are in executeOperation()
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) public override returns (bool) {
        require(initiator == msg.sender, "Flash-loan initiator must be the operator");
        (
            ISeaport.BasicOrderParameters memory orderParams,
            INftfiDirectLoanFixedOffer.Offer memory offer,
            INftfiDirectLoanFixedOffer.Signature memory signature,
            INftfiDirectLoanFixedOffer.BorrowerSettings memory borrowerSettings
        ) = abi.decode(
            params,
            (
                ISeaport.BasicOrderParameters,
                INftfiDirectLoanFixedOffer.Offer,
                INftfiDirectLoanFixedOffer.Signature,
                INftfiDirectLoanFixedOffer.BorrowerSettings
            )
        );
        require(asset == orderParams.considerationToken, "Flash-loan asset must equal the order's consideration token");
        require(amount == offer.loanPrincipalAmount, "Flash-loan amount must equal the loan offer's principal amount");
        // 2) Buy the Fabrica token
        if (SEAPORT.fulfillBasicOrder(orderParams)) {
            revert("Seaport order failed to be fulfilled.");
        }
        // 3) Take out the NFTfi loan
        NFTFI_DIRECT_LOAN.acceptOffer(
            offer,
            signature,
            borrowerSettings
        );
        // 4) Approve repayment of the Aave Flash Loan
        IERC20(orderParams.considerationToken).approve(ADDRESSES_PROVIDER.getPool(), amount + premium);
        return true;
    }
}
