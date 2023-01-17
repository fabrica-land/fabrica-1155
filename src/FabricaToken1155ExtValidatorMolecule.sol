// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (last updated v4.8.0) (token/ERC1155/ERC1155.sol)

pragma solidity ^0.8.12;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./IFabricaValidator.sol";
import "./MoleculeScanV2.sol";


/**
 * @dev Implementation of the Fabrica ERC1155 multi-token.
 * See https://eips.ethereum.org/EIPS/eip-1155
 * Originally based on code by Enjin: https://github.com/enjin/erc-1155
 *
 * _Available since v3.1._
 */
contract FabricaToken is Context, ERC165, IERC1155, IERC1155MetadataURI, Ownable, Pausable, MoleculeScanV2 {
    using Address for address;

    // specify the regionalId list from the molecule general regionalID List
    // US: 1, UK: 2, UN: 3
    uint [] private regionalId = [1];

    // Struct needed to avoid stack too deep error
    struct Property {
        uint256 supply;
        string operatingAgreement;
        string definition;
        string configuration;
        address validator;
    }

    // Mapping from token ID to account balances
    mapping(uint256 => mapping(address => uint256)) private _balances;

    // Mapping from account to operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Mapping from token ID to property info
    mapping(uint256 => Property) public _property;

    // default validator
    // Goerli address:
    // MainNet address:
    address public _validator = 0x1234567890123456789012345678901234567890;

    // On-chain data update
    event UpdateConfiguration(uint256, string newData);
    event UpdateOperatingAgreement(uint256, string newData);
    event UpdateValidator(uint256 tokenId, string dataType, address validator);

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155).interfaceId ||
            interfaceId == type(IERC1155MetadataURI).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    function pause() public onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() public onlyOwner whenPaused {
        _unpause();
    }

    /**
     * @dev See {IERC1155MetadataURI-uri}.
     *
     * This implementation returns the same URI for *all* token types. It relies
     * on the token type ID substitution mechanism
     * https://eips.ethereum.org/EIPS/eip-1155#metadata[defined in the EIP].
     *
     * Clients calling this function must replace the `\{id\}` substring with the
     * actual token type ID.
     *
     * function uri(uint256) public view virtual override returns (string memory) {return _uri;}
     *
     * Fabrica: use network name subdomain and contract address + tokenId, no suffix '.json'
     *
     *`delegatecall` is most gas efficient, `call` can be used, too, to 
     * call validator. But this `uri` function is a `view` contract by 1155
     * spec, and both `delegatecall` or `call` can potentially change state,
     * need to change the `view` to `nonpayable` which does not conform to 
     * standard. Therefore, it is safer to use Interface to load the validator
     * methods.
     *
     */
    function uri(uint256 id) override public view returns (string memory) {
        // Validator is an optional param during mint, but it will get the default value
        // in the _mint function so it will NEVER be null
        IValidator validator = IValidator(_property[id].validator);
        return validator.uri(id);
    }

    /**
     * @dev `mint` allows users to mint to 3rd party (although it allows to mint to self as well)
     */
    function mint(
        address to,
        uint256 sessionId,
        uint256 supply,
        string memory definition,
        string memory operatingAgreement,
        string memory configuration,
        address validator
    ) public whenNotPaused returns (uint256) {
        Property memory property;
        property.supply = supply;
        property.operatingAgreement = operatingAgreement;
        property.definition = definition;
        property.configuration = configuration;
        property.validator = validator;
        uint256 id = _mint(to, sessionId, property, "");
        return id;
    }

    /**
     * @dev `mintBatch` allows users to mint in bulk
     */
    function mintBatch(
        address to,
        uint256[] memory sessionIds,
        uint256[] memory supplies,
        string[] memory definitions,
        string[] memory operatingAgreements,
        string[] memory configurations,
        address[] memory validators
    ) public whenNotPaused returns (uint256[] memory ids) {
        uint256 size = sessionIds.length;
        Property[] memory properties = new Property[](size);
        for (uint256 i = 0; i < size; i++) {
            properties[i].supply = supplies[i];
            properties[i].operatingAgreement = operatingAgreements[i];
            properties[i].definition = definitions[i];
            properties[i].configuration = configurations[i];
            properties[i].validator = validators[i];
        }
        ids = _mintBatch(to, sessionIds, properties, "");
    }

    /**
     * @dev generate token id (to avoid frontrunning)
     */
    function generateId(address operator, uint256 sessionId) public view whenNotPaused returns(uint256) {
        /**
         * @dev hash operator address with sessionId and chainId to generate unique token Id
         *      format: string(sender_address) + string(sessionId) => hash to byte32 => cast to uint
         */
        string memory operatorString = Strings.toHexString(uint(uint160(operator)), 20);
        string memory idString = string.concat(Strings.toString(block.chainid), operatorString, Strings.toString(sessionId));
        uint256 bigId = uint256(keccak256(abi.encodePacked(idString)));
        uint64 smallId = uint64(bigId);
        return uint256(smallId);
    }

    /**
     * @dev See {IERC1155-balanceOf}.
     *
     * Requirements:
     *
     * - `account` cannot be the zero address.
     */
    function balanceOf(address account, uint256 id) public view virtual override returns (uint256) {
        require(account != address(0), "ERC1155: address zero is not a valid owner");
        return _balances[id][account];
    }

    /**
     * @dev See {IERC1155-balanceOfBatch}.
     *
     * Requirements:
     *
     * - `accounts` and `ids` must have the same length.
     */
    function balanceOfBatch(address[] memory accounts, uint256[] memory ids)
        public
        view
        virtual
        override
        returns (uint256[] memory)
    {
        require(accounts.length == ids.length, "ERC1155: accounts and ids length mismatch");

        uint256[] memory batchBalances = new uint256[](accounts.length);

        for (uint256 i = 0; i < accounts.length; ++i) {
            batchBalances[i] = balanceOf(accounts[i], ids[i]);
        }

        return batchBalances;
    }

    /**
     * @dev See {IERC1155-setApprovalForAll}.
     */
    function setApprovalForAll(address operator, bool approved) public virtual override whenNotPaused {
        _setApprovalForAll(_msgSender(), operator, approved);
    }

    /**
     * @dev See {IERC1155-isApprovedForAll}.
     */
    function isApprovedForAll(address account, address operator) public view virtual override whenNotPaused returns (bool) {
        return _operatorApprovals[account][operator];
    }

    /**
     * @dev See {IERC1155-safeTransferFrom}.
     */
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) public virtual override whenNotPaused {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );
        _safeTransferFrom(from, to, id, amount, data);
    }

    /**
     * @dev See {IERC1155-safeBatchTransferFrom}.
     */
    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public virtual override whenNotPaused {
        require(
            from == _msgSender() || isApprovedForAll(from, _msgSender()),
            "ERC1155: caller is not token owner or approved"
        );
        _safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    // @dev only executable by > 70% owner
    function updateOperatingAgreement(string memory operatingAgreement, uint256 id) public whenNotPaused returns (bool) {
        require(_percentOwner(_msgSender(), id, 70), "Only > 70% can update");
        _property[id].operatingAgreement = operatingAgreement;
        emit UpdateOperatingAgreement(id, operatingAgreement);
        return true;
    }

    // @dev only executable by > 50% owner
    function updateConfiguration(string memory configuration, uint256 id) public whenNotPaused returns (bool) {
        require(_percentOwner(_msgSender(), id, 50), "Only > 50% can update");
        _property[id].configuration = configuration;
        emit UpdateConfiguration(id, configuration);
        return true;
    }

    // @dev only executable by > 70% owner
    function updateValidator(address validator, uint256 id) public whenNotPaused returns (bool) {
        require(_percentOwner(_msgSender(), id, 70), "Only > 70% can update");
        _property[id].validator = validator;
        emit UpdateValidator(id, "validator", validator);
        return true;
    }

    // @dev `threshold`: percentage threshold
    function _percentOwner(address wallet, uint256 id, uint256 threshold) internal virtual returns (bool) {
        uint256 shares = _balances[id][wallet];
        if (shares == 0) {
            return false;
        }
        uint256 supply = _property[id].supply;
        if (supply == 0) {
            return false;
        }
        uint256 percent = Math.mulDiv(shares, 100, supply);
        return percent > threshold;
    }

    /**
     * @dev Transfers `amount` tokens of token type `id` from `from` to `to`.
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - `from` must have a balance of tokens of type `id` of at least `amount`.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155Received} and return the
     * acceptance magic value.
     */
    function _safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) internal virtual moleculeGeneralBatchVerify(regionalId) whenNotPaused {
        require(to != address(0), "ERC1155: transfer to the zero address");

        address operator = _msgSender();
        uint256[] memory ids = _asSingletonArray(id);
        uint256[] memory amounts = _asSingletonArray(amount);

        _beforeTokenTransfer(operator, from, to, ids, amounts, data);

        uint256 fromBalance = _balances[id][from];
        require(fromBalance >= amount, "ERC1155: insufficient balance for transfer");
        unchecked {
            _balances[id][from] = fromBalance - amount;
        }
        _balances[id][to] += amount;

        emit TransferSingle(operator, from, to, id, amount);

        _afterTokenTransfer(operator, from, to, ids, amounts, data);

        _doSafeTransferAcceptanceCheck(operator, from, to, id, amount, data);
    }

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_safeTransferFrom}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155BatchReceived} and return the
     * acceptance magic value.
     */
    function _safeBatchTransferFrom(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual moleculeGeneralBatchVerify(regionalId) whenNotPaused {
        require(ids.length == amounts.length, "ERC1155: ids and amounts length mismatch");
        require(to != address(0), "ERC1155: transfer to the zero address");

        address operator = _msgSender();

        _beforeTokenTransfer(operator, from, to, ids, amounts, data);

        for (uint256 i = 0; i < ids.length; ++i) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];

            uint256 fromBalance = _balances[id][from];
            require(fromBalance >= amount, "ERC1155: insufficient balance for transfer");
            unchecked {
                _balances[id][from] = fromBalance - amount;
            }
            _balances[id][to] += amount;
        }

        emit TransferBatch(operator, from, to, ids, amounts);

        _afterTokenTransfer(operator, from, to, ids, amounts, data);

        _doSafeBatchTransferAcceptanceCheck(operator, from, to, ids, amounts, data);
    }

    /**
     * @dev Creates `amount` tokens of token type `id`, and assigns them to `to`.
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155Received} and return the
     * acceptance magic value.
     * - `definition` cannot be null.
     */
    function _mint(
        address to,
        uint sessionId,
        Property memory property,
        bytes memory data
    ) internal virtual moleculeGeneralBatchVerify(regionalId) whenNotPaused returns(uint256) {
        require(to != address(0), "ERC1155: mint to the zero address");
        require(bytes(property.definition).length > 0, "Definition is required");
        require(sessionId > 0, "Valid sessionId is required");
        require(property.supply > 0, "Minimum supply is 1");


        // If validator is not specified during mint, use default validator address
        if (property.validator == address(0)) {
            property.validator = _validator;
        }
        uint256 amount = property.supply;

        uint256 id = generateId(_msgSender(), sessionId);

        require(_property[id].supply == 0, "Session ID already exist, please use a different one");

        // uint256[] memory ids = _asSingletonArray(id);
        // uint256[] memory amounts = _asSingletonArray(amount);

        // _beforeTokenTransfer(_msgSender(), address(0), to, ids, amounts, data);

        _balances[id][to] += amount;
        // Update property data
        _property[id] = property;

        emit TransferSingle(_msgSender(), address(0), to, id, amount);

        // _afterTokenTransfer(_msgSender(), address(0), to, ids, amounts, data);

        _doSafeTransferAcceptanceCheck(_msgSender(), address(0), to, id, amount, data);
        return id;
    }

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_mint}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - `ids` and `amounts` must have the same length.
     * - If `to` refers to a smart contract, it must implement {IERC1155Receiver-onERC1155BatchReceived} and return the
     * acceptance magic value.
     */
    function _mintBatch(
        address to,
        uint256[] memory sessionIds,
        Property[] memory properties,
        bytes memory data
    ) internal virtual moleculeGeneralBatchVerify(regionalId) whenNotPaused returns(uint256[] memory) {
        require(to != address(0), "ERC1155: mint to the zero address");
        require(sessionIds.length == properties.length, "sessionIds and properties length mismatch");

        // hit stack too deep error when using more variables, so we use sessionsIds.length in multiple
        // places instead of creating new variables
        uint256[] memory ids = new uint256[](sessionIds.length);
        uint256[] memory amounts = new uint256[](sessionIds.length);

        // _beforeTokenTransfer(_msgSender(), address(0), to, ids, amounts, data);

        for (uint256 i = 0; i < sessionIds.length; i++) {
            require(bytes(properties[i].definition).length > 0, "Definition is required");
            require(sessionIds[i] > 0, "Valid sessionId is required");
            require(properties[i].supply > 0, "Minimum supply is 1");

            uint256 id = generateId(_msgSender(), sessionIds[i]);
            require(_property[id].supply == 0, "Session ID already exist, please use a different one");
            uint256 amount = properties[i].supply;

            ids[i] = id;
            amounts[i] = amount;

            _balances[id][to] += amount;
            // Update property data
            _property[id] = properties[i];
        }

        emit TransferBatch(_msgSender(), address(0), to, ids, amounts);

        // _afterTokenTransfer(_msgSender(), address(0), to, ids, amounts, data);

        _doSafeBatchTransferAcceptanceCheck(_msgSender(), address(0), to, ids, amounts, data);
        return ids;
    }

    /**
     * @dev Destroys `amount` tokens of token type `id` from `from`
     *
     * Emits a {TransferSingle} event.
     *
     * Requirements:
     *
     * - `from` cannot be the zero address.
     * - `from` must have at least `amount` tokens of token type `id`.
     */
    function _burn(address from, uint256 id, uint256 amount) internal virtual {
        require(from != address(0), "ERC1155: burn from the zero address");

        address operator = _msgSender();
        uint256[] memory ids = _asSingletonArray(id);
        uint256[] memory amounts = _asSingletonArray(amount);

        _beforeTokenTransfer(operator, from, address(0), ids, amounts, "");

        uint256 fromBalance = _balances[id][from];
        require(fromBalance >= amount, "ERC1155: burn amount exceeds balance");
        unchecked {
            _balances[id][from] = fromBalance - amount;
        }

        emit TransferSingle(operator, from, address(0), id, amount);

        _afterTokenTransfer(operator, from, address(0), ids, amounts, "");
    }

    /**
     * @dev xref:ROOT:erc1155.adoc#batch-operations[Batched] version of {_burn}.
     *
     * Emits a {TransferBatch} event.
     *
     * Requirements:
     *
     * - `ids` and `amounts` must have the same length.
     */
    function _burnBatch(address from, uint256[] memory ids, uint256[] memory amounts) internal virtual {
        require(from != address(0), "ERC1155: burn from the zero address");
        require(ids.length == amounts.length, "ERC1155: ids and amounts length mismatch");

        address operator = _msgSender();

        _beforeTokenTransfer(operator, from, address(0), ids, amounts, "");

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];

            uint256 fromBalance = _balances[id][from];
            require(fromBalance >= amount, "ERC1155: burn amount exceeds balance");
            unchecked {
                _balances[id][from] = fromBalance - amount;
            }
        }

        emit TransferBatch(operator, from, address(0), ids, amounts);

        _afterTokenTransfer(operator, from, address(0), ids, amounts, "");
    }

    /**
     * @dev Approve `operator` to operate on all of `owner` tokens
     *
     * Emits an {ApprovalForAll} event.
     */
    function _setApprovalForAll(
        address owner,
        address operator,
        bool approved
    ) internal virtual whenNotPaused {
        require(owner != operator, "ERC1155: setting approval status for self");
        _operatorApprovals[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /**
     * @dev Hook that is called before any token transfer. This includes minting
     * and burning, as well as batched variants.
     *
     * The same hook is called on both single and batched variants. For single
     * transfers, the length of the `ids` and `amounts` arrays will be 1.
     *
     * Calling conditions (for each `id` and `amount` pair):
     *
     * - When `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * of token type `id` will be  transferred to `to`.
     * - When `from` is zero, `amount` tokens of token type `id` will be minted
     * for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens of token type `id`
     * will be burned.
     * - `from` and `to` are never both zero.
     * - `ids` and `amounts` have the same, non-zero length.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual whenNotPaused {}

    /**
     * @dev Hook that is called after any token transfer. This includes minting
     * and burning, as well as batched variants.
     *
     * The same hook is called on both single and batched variants. For single
     * transfers, the length of the `id` and `amount` arrays will be 1.
     *
     * Calling conditions (for each `id` and `amount` pair):
     *
     * - When `from` and `to` are both non-zero, `amount` of ``from``'s tokens
     * of token type `id` will be  transferred to `to`.
     * - When `from` is zero, `amount` tokens of token type `id` will be minted
     * for `to`.
     * - when `to` is zero, `amount` of ``from``'s tokens of token type `id`
     * will be burned.
     * - `from` and `to` are never both zero.
     * - `ids` and `amounts` have the same, non-zero length.
     *
     * To learn more about hooks, head to xref:ROOT:extending-contracts.adoc#using-hooks[Using Hooks].
     */
    function _afterTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual whenNotPaused {}

    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private whenNotPaused {
        if (to.isContract()) {
            try IERC1155Receiver(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 response) {
                if (response != IERC1155Receiver.onERC1155Received.selector) {
                    revert("ERC1155: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non-ERC1155Receiver implementer");
            }
        }
    }

    function _doSafeBatchTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) private whenNotPaused {
        if (to.isContract()) {
            try IERC1155Receiver(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (
                bytes4 response
            ) {
                if (response != IERC1155Receiver.onERC1155BatchReceived.selector) {
                    revert("ERC1155: ERC1155Receiver rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non-ERC1155Receiver implementer");
            }
        }
    }

    function _asSingletonArray(uint256 element) private pure returns (uint256[] memory) {
        uint256[] memory array = new uint256[](1);
        array[0] = element;

        return array;
    }
}