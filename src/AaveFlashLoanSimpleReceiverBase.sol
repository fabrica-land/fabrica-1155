// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.0;

import {IAaveFlashLoanSimpleReceiver} from './IAaveFlashLoanSimpleReceiver.sol';
import {IAavePoolAddressesProvider} from './IAavePoolAddressesProvider.sol';
import {IAavePool} from './IAavePool.sol';

/**
 * @title FlashLoanSimpleReceiverBase
 * @author Aave
 * @notice Base contract to develop a flashloan-receiver contract.
 */
abstract contract AaveFlashLoanSimpleReceiverBase is IAaveFlashLoanSimpleReceiver {
    IAavePoolAddressesProvider public immutable override ADDRESSES_PROVIDER;
    IAavePool public immutable override POOL;

    constructor(IAavePoolAddressesProvider provider) {
        ADDRESSES_PROVIDER = provider;
        POOL = IAavePool(provider.getPool());
    }
}
