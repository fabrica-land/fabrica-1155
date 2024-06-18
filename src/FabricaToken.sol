// SPDX-License-Identifier: MIT

pragma solidity ^0.8.25;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165CheckerUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "./FabricaUUPSUpgradeable.sol";
import "./IFabricaValidator.sol";
import "./IFabricaValidatorRegistry.sol";

/**
 * @dev Implementation of the Fabrica ERC1155 multi-token.
 * See https://eips.ethereum.org/EIPS/eip-1155
 * Originally based on code by Enjin: https://github.com/enjin/erc-1155
 *
 * _Available since v3.1._
 */
contract FabricaToken is Initializable, ERC165Upgradeable, IERC1155Upgradeable, IERC1155MetadataURIUpgradeable, OwnableUpgradeable, PausableUpgradeable, FabricaUUPSUpgradeable {
    using AddressUpgradeable for address;

    constructor() {
        _disableInitializers();
    }

    function initialize() public initializer {
        __ERC165_init();
        __FabricaUUPSUpgradeable_init();
        __Ownable_init();
        __Pausable_init();
    }

    function initializeV2() public reinitializer(2) {
        // Token-specific migration code has been removed
    }

    function initializeV3() public reinitializer(3) {
        emit TraitMetadataURIUpdated();
    }

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

    address private _defaultValidator;

    address private _validatorRegistry;

    string private _contractURI;

    // On-chain data update
    event UpdateConfiguration(uint256, string newData);
    event UpdateOperatingAgreement(uint256, string newData);
    event UpdateValidator(uint256 tokenId, string dataType, address validator);
    event TraitMetadataURIUpdated();
    event TraitUpdated(bytes32 indexed traitKey, uint256 tokenId, bytes32 traitValue);
    event ContractURIUpdated();

    /**
     * @dev See {IERC165-supportsInterface}.
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165Upgradeable, IERC165Upgradeable) returns (bool) {
        return
            interfaceId == type(IERC1155Upgradeable).interfaceId ||
            interfaceId == type(IERC1155MetadataURIUpgradeable).interfaceId ||
            // 0xaf332f3e is ERC-7496
            interfaceId == 0xaf332f3e ||
            super.supportsInterface(interfaceId);
    }

    function pause() public onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() public onlyOwner whenPaused {
        _unpause();
    }

    function setDefaultValidator(address newDefaultValidator) public onlyOwner {
        _defaultValidator = newDefaultValidator;
    }

    function defaultValidator() public view returns (address) {
        return _defaultValidator;
    }

    function setValidatorRegistry(address newValidatorRegistry) public onlyOwner {
        _validatorRegistry = newValidatorRegistry;
    }

    function validatorRegistry() public view returns (address) {
        return _validatorRegistry;
    }

    // getTraitValue() defined as part of ERC-7496 Specification
    function getTraitValue(uint256 tokenId, bytes32 traitKey) external view returns (bytes32) {
        if (traitKey == keccak256("validator")) {
            return bytes32(bytes(_getValidatorName(tokenId)));
        }
        if (traitKey == keccak256("operatingAgreement")) {
            return bytes32(bytes(_getOperatingAgreementName(tokenId)));
        }
        revert("Unknown trait key");
    }

    // getTraitValues() defined as part of ERC-7496 Specification
    function getTraitValues(uint256 tokenId, bytes32[] calldata traitKeys) external view returns (bytes32[] memory) {
        bytes32[] memory values = new bytes32[](traitKeys.length);
        for (uint256 i = 0 ; i < traitKeys.length ; i++) {
          bytes32 traitKey = traitKeys[i];
          if (traitKey == keccak256("validator")) {
              values[i] = bytes32(bytes(_getValidatorName(tokenId)));
              continue;
          }
          if (traitKey == keccak256("operatingAgreement")) {
              values[i] = bytes32(bytes(_getOperatingAgreementName(tokenId)));
              continue;
          }
          revert(string.concat("Unknown trait key at index ", StringsUpgradeable.toString(i)));
        }
        return values;
    }

    // getTraitMetadataURI() defined as part of the ERC-7496 Specification
    function getTraitMetadataURI() external pure returns (string memory) {
        return "data:application/json;charset=utf-8;base64,ewogICJ0cmFpdHMiOiB7CiAgICAidmFsaWRhdG9yIjogewogICAgICAiZGlzcGxheU5hbWUiOiAiVmFsaWRhdG9yIiwKICAgICAgImRhdGFUeXBlIjogewogICAgICAgICJ0eXBlIjogInN0cmluZyIsCiAgICAgICAgIm1pbkxlbmd0aCI6IDEKICAgICAgfSwKICAgICAgInZhbGlkYXRlT25TYWxlIjogInJlcXVpcmVFcSIKICAgIH0sCiAgICAib3BlcmF0aW5nQWdyZWVtZW50IjogewogICAgICAiZGlzcGxheU5hbWUiOiAiT3BlcmF0aW5nIEFncmVlbWVudCIsCiAgICAgICJkYXRhVHlwZSI6IHsKICAgICAgICAidHlwZSI6ICJzdHJpbmciLAogICAgICAgICJtaW5MZW5ndGgiOiAxCiAgICAgIH0sCiAgICAgICJ2YWxpZGF0ZU9uU2FsZSI6ICJyZXF1aXJlRXEiCiAgICB9CiAgfQp9";
    }

    /**
     * Implements ERC-7572: Contract-level metadata
     */
    function contractURI() public view returns (string memory) {
        return _contractURI;
    }
    function setContractURI(string memory newURI) external onlyOwner {
        _contractURI = newURI;
        emit ContractURIUpdated();
    }

    /**
     * @dev Delegate to the validator contract: default to the Fabrica validator
     */
    function uri(uint256 id) override public view returns (string memory) {
        address validator = _property[id].validator == address(0)
            ? _defaultValidator
            : _property[id].validator;
        return IFabricaValidator(validator).uri(id);
    }

    /**
     * @dev `mint` allows users to mint to 3rd party (although it allows to mint to self as well)
     */
    function mint(
        address[] memory recipients,
        uint256 sessionId,
        uint256[] memory amounts,
        string memory definition,
        string memory operatingAgreement,
        string memory configuration,
        address validator
    ) public whenNotPaused returns (uint256) {
        uint256 supply = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            require(amount > 0, 'Each amount must be greater than zero');
            supply += amount;
        }
        Property memory property;
        property.supply = supply;
        property.operatingAgreement = operatingAgreement;
        property.definition = definition;
        property.configuration = configuration;
        property.validator = validator;
        uint256 id = _mint(recipients, sessionId, amounts, property, "");
        return id;
    }

    /**
     * @dev `mintBatch` allows users to mint in bulk
     */
    function mintBatch(
        address[] memory recipients,
        uint256[] memory sessionIds,
        uint256[] memory amounts,
        string[] memory definitions,
        string[] memory operatingAgreements,
        string[] memory configurations,
        address[] memory validators
    ) public whenNotPaused returns (uint256[] memory ids) {
        uint256 supply = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 amount = amounts[i];
            require(amount > 0, 'Each amount must be greater than zero');
            supply += amount;
        }
        uint256 size = sessionIds.length;
        Property[] memory properties = new Property[](size);
        for (uint256 i = 0; i < size; i++) {
            properties[i].supply = supply;
            properties[i].operatingAgreement = operatingAgreements[i];
            properties[i].definition = definitions[i];
            properties[i].configuration = configurations[i];
            properties[i].validator = validators[i];
        }
        ids = _mintBatch(recipients, sessionIds, amounts, properties, "");
    }

    function burn(
        address from,
        uint256 id,
        uint256 amount
    ) public whenNotPaused returns (bool success) {
        _burn(from, id, amount);
        success = true;
    }

    function burnBatch(
        address from,
        uint256[] memory ids,
        uint256[] memory amounts
    ) public whenNotPaused returns (bool success) {
        _burnBatch(from, ids, amounts);
        success = true;
    }

    /**
     * @dev generate token id (to avoid frontrunning)
     */
    function generateId(address operator, uint256 sessionId, string memory operatingAgreement) public view whenNotPaused returns(uint256) {
        /**
         * @dev hash operator address with sessionId and chainId to generate unique token Id
         *      format: string(sender_address) + string(sessionId) => hash to byte32 => cast to uint
         */
        string memory operatorString = StringsUpgradeable.toHexString(uint(uint160(operator)), 20);
        string memory idString = string.concat(
            StringsUpgradeable.toString(block.chainid),
            StringsUpgradeable.toHexString(address(this)),
            operatorString,
            StringsUpgradeable.toString(sessionId),
            operatingAgreement
        );
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
        emit TraitUpdated(keccak256("operatingAgreement"), id, bytes32(bytes(_getOperatingAgreementName(id))));
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
        emit TraitUpdated(keccak256("validator"), id, bytes32(bytes(_getValidatorName(id))));
        return true;
    }

    function _getValidatorName(uint256 tokenId) internal view returns (string memory) {
        string memory validatorName = IFabricaValidatorRegistry(_validatorRegistry).name(_property[tokenId].validator);
        if (bytes(validatorName).length > 0) {
            return validatorName;
        } else {
            return "Custom";
        }
    }

    function _getOperatingAgreementName(uint256 tokenId) internal view returns (string memory) {
        return IFabricaValidator(_property[tokenId].validator)
            .operatingAgreementName(_property[tokenId].operatingAgreement);
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
        uint256 percent = MathUpgradeable.mulDiv(shares, 100, supply);
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
    ) internal virtual whenNotPaused {
        require(to != address(0), "ERC1155: transfer to the zero address");
        address operator = _msgSender();
        uint256 fromBalance = _balances[id][from];
        require(fromBalance >= amount, "ERC1155: insufficient balance for transfer");
        unchecked {
            _balances[id][from] = fromBalance - amount;
        }
        _balances[id][to] += amount;
        emit TransferSingle(operator, from, to, id, amount);
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
    ) internal virtual whenNotPaused {
        require(ids.length == amounts.length, "ERC1155: ids and amounts length mismatch");
        require(to != address(0), "ERC1155: transfer to the zero address");
        address operator = _msgSender();
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
        address[] memory recipients,
        uint sessionId,
        uint256[] memory amounts,
        Property memory property,
        bytes memory data
    ) internal virtual whenNotPaused returns(uint256) {
        require(bytes(property.definition).length > 0, "Definition is required");
        require(sessionId > 0, "Valid sessionId is required");
        require(property.supply > 0, "Minimum supply is 1");
        require(recipients.length == amounts.length, 'Number of recipients and amounts must match');
        // If validator is not specified during mint, use default validator address
        if (property.validator == address(0)) {
            // set default validator address
            property.validator = _defaultValidator;
        }
        if (bytes(property.operatingAgreement).length < 1) {
            property.operatingAgreement = IFabricaValidator(property.validator).defaultOperatingAgreement();
        }
        uint256 id = generateId(_msgSender(), sessionId, property.operatingAgreement);
        require(_property[id].supply == 0, "Session ID already exist, please use a different one");
        for (uint256 i = 0; i < recipients.length; i++) {
            address to = recipients[i];
            require(to != address(0), "ERC1155: mint to the zero address");
            uint256 amount = amounts[i];
            _balances[id][to] += amount;
            _doSafeTransferAcceptanceCheck(_msgSender(), address(0), to, id, amount, data);
            emit TransferSingle(_msgSender(), address(0), to, id, amount);
        }
        // Update property data
        _property[id] = property;
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
        address[] memory recipients,
        uint256[] memory sessionIds,
        uint256[] memory amounts,
        Property[] memory properties,
        bytes memory data
    ) internal virtual whenNotPaused returns(uint256[] memory) {
        require(recipients.length == amounts.length, 'Number of recipients and amounts must match');
        require(sessionIds.length == properties.length, "sessionIds and properties length mismatch");
        // hit stack too deep error when using more variables, so we use sessionsIds.length in multiple
        // places instead of creating new variables
        uint256[] memory ids = new uint256[](sessionIds.length);
        for (uint256 i = 0; i < sessionIds.length; i++) {
            require(bytes(properties[i].definition).length > 0, "Definition is required");
            require(sessionIds[i] > 0, "Valid sessionId is required");
            require(properties[i].supply > 0, "Minimum supply is 1");
            uint256 id = generateId(_msgSender(), sessionIds[i], properties[i].operatingAgreement);
            for (uint256 j = 0; j < recipients.length; j++) {
                address to = recipients[j];
                require(to != address(0), "ERC1155: mint to the zero address");
                uint256 amount = amounts[j];
                _balances[id][to] += amount;
                uint256[] memory amountsForRecipient = new uint256[](ids.length);
                for (uint256 k = 0; k < ids.length; k++) {
                    amountsForRecipient[k] = amount;
                }
                _doSafeBatchTransferAcceptanceCheck(_msgSender(), address(0), to, ids, amountsForRecipient, data);
                emit TransferBatch(_msgSender(), address(0), to, ids, amountsForRecipient);
            }
            require(_property[id].supply == 0, "Session ID already exist, please use a different one");
            // If validator is not specified during mint, use default validator address
            if (properties[i].validator == address(0)) {
                // set default validator address
                properties[i].validator = _defaultValidator;
            }
            ids[i] = id;
            // Update property data
            _property[id] = properties[i];
        }

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
        require(operator == from, "ERC1155: operator can only burn own token supply");
        uint256 fromBalance = _balances[id][from];
        uint256 fromSupply = _property[id].supply;
        require(fromBalance >= amount, "ERC1155: burn amount exceeds balance");
        require(fromSupply >= amount, "ERC1155: burn amount exceeds supply");
        unchecked {
            _balances[id][from] = fromBalance - amount;
            _property[id].supply = fromSupply - amount;
        }
        emit TransferSingle(operator, from, address(0), id, amount);
        _doSafeTransferAcceptanceCheck(operator, from, address(0), id, amount, "");
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
        require(operator == from, "ERC1155: operator can only burn own token supply");
        for (uint256 i = 0; i < ids.length; i++) {
            uint256 id = ids[i];
            uint256 amount = amounts[i];
            uint256 fromBalance = _balances[id][from];
            uint256 fromSupply = _property[id].supply;
            require(fromBalance >= amount, "ERC1155: burn amount exceeds balance");
            require(fromSupply >= amount, "ERC1155: burn amount exceeds supply");
            unchecked {
                _balances[id][from] = fromBalance - amount;
                _property[id].supply = fromSupply - amount;
            }
        }
        emit TransferBatch(operator, from, address(0), ids, amounts);
        _doSafeBatchTransferAcceptanceCheck(operator, from, address(0), ids, amounts, "");
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

    function _doSafeTransferAcceptanceCheck(
        address operator,
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes memory data
    ) private whenNotPaused {
        if (to.isContract()) {
            try IERC1155ReceiverUpgradeable(to).onERC1155Received(operator, from, id, amount, data) returns (bytes4 response) {
                if (response != IERC1155ReceiverUpgradeable.onERC1155Received.selector) {
                    revert("ERC1155: ERC1155ReceiverUpgradeable rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non-ERC1155ReceiverUpgradeable implementer");
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
            try IERC1155ReceiverUpgradeable(to).onERC1155BatchReceived(operator, from, ids, amounts, data) returns (
                bytes4 response
            ) {
                if (response != IERC1155ReceiverUpgradeable.onERC1155BatchReceived.selector) {
                    revert("ERC1155: ERC1155ReceiverUpgradeable rejected tokens");
                }
            } catch Error(string memory reason) {
                revert(reason);
            } catch {
                revert("ERC1155: transfer to non-ERC1155ReceiverUpgradeable implementer");
            }
        }
    }
}
