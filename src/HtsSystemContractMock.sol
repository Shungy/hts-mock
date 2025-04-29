// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.9;

import './system-contracts/HederaResponseCodes.sol';
import './system-contracts/hedera-token-service/KeyHelper.sol';
import './HederaFungibleToken.sol';
import './base/NoDelegateCall.sol';
import './libraries/Constants.sol';

import './interfaces/IHtsSystemContractMock.sol';
import './libraries/HederaTokenValidation.sol';

contract HtsSystemContractMock is NoDelegateCall, KeyHelper, IHtsSystemContractMock {

    error HtsPrecompileError(int64 responseCode);
    error NotImplemented();

    /// @dev only for Fungible tokens
    // Fungible token -> FungibleTokenInfo
    mapping(address => FungibleTokenInfo) internal _fungibleTokenInfos;
    // Fungible token -> _isFungible
    mapping(address => bool) internal _isFungible;

    /// @dev common to both NFT and Fungible HTS tokens
    // HTS token -> account -> isAssociated
    mapping(address => mapping(address => bool)) internal _association;
    // HTS token -> account -> isKyced
    mapping(address => mapping(address => TokenConfig)) internal _kyc; // is KYCed is the positive case(i.e. explicitly requires KYC approval); see defaultKycStatus
    // HTS token -> account -> isFrozen
    mapping(address => mapping(address => TokenConfig)) internal _unfrozen; // is unfrozen is positive case(i.e. explicitly requires being unfrozen); see freezeDefault
    // HTS token -> keyType -> key address(contractId) e.g. tokenId -> 16 -> 0x123 means that the SUPPLY key for tokenId is account 0x123
    mapping(address => mapping(uint => address)) internal _tokenKeys; /// @dev faster access then getting keys via {FungibleTokenInfo|NonFungibleTokenInfo}#TokenInfo.HederaToken.tokenKeys[]; however only supports KeyValueType.CONTRACT_ID
    // HTS token -> deleted
    mapping(address => bool) internal _tokenDeleted;
    // HTS token -> paused
    mapping(address => TokenConfig) internal _tokenPaused;

    // - - - - - - EVENTS - - - - - -

    // emitted for convenience of having the token address accessible in a Hardhat environment
    event TokenCreated(address indexed token);

    constructor() NoDelegateCall(HTS_PRECOMPILE) {}

    modifier onlyHederaToken() {
        require(_isToken(msg.sender), 'NOT_HEDERA_TOKEN');
        _;
    }

    // Check if the address is a token
    function _isToken(address token) internal view returns (bool) {
        return _isFungible[token];
    }

    function _isAccountSender(address account) internal view returns (bool) {
        return account == msg.sender;
    }

    function _getTreasuryAccount(address token) internal view returns (address treasury) {
        treasury = _fungibleTokenInfos[token].tokenInfo.token.treasury;
    }

    function _hasTreasurySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getTreasuryAccount(token);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasAdminKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.ADMIN);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasKycKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.KYC);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasFreezeKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.FREEZE);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasWipeKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.WIPE);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasSupplyKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.SUPPLY);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasFeeScheduleKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.FEE);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _hasPauseKeySig(address token) internal view returns (bool validKey, bool noKey) {
        address key = _getKey(token, KeyHelper.KeyType.PAUSE);
        noKey = key == address(0);
        validKey = _isAccountSender(key);
    }

    function _setFungibleTokenInfoToken(address token, HederaToken memory hederaToken) internal {
        _fungibleTokenInfos[token].tokenInfo.token.name = hederaToken.name;
        _fungibleTokenInfos[token].tokenInfo.token.symbol = hederaToken.symbol;
        _fungibleTokenInfos[token].tokenInfo.token.treasury = hederaToken.treasury;
        _fungibleTokenInfos[token].tokenInfo.token.memo = hederaToken.memo;
        _fungibleTokenInfos[token].tokenInfo.token.tokenSupplyType = hederaToken.tokenSupplyType;
        _fungibleTokenInfos[token].tokenInfo.token.maxSupply = hederaToken.maxSupply;
        _fungibleTokenInfos[token].tokenInfo.token.freezeDefault = hederaToken.freezeDefault;
    }

    function _setFungibleTokenExpiry(address token, Expiry memory expiryInfo) internal {
        _fungibleTokenInfos[token].tokenInfo.token.expiry.second = expiryInfo.second;
        _fungibleTokenInfos[token].tokenInfo.token.expiry.autoRenewAccount = expiryInfo.autoRenewAccount;
        _fungibleTokenInfos[token].tokenInfo.token.expiry.autoRenewPeriod = expiryInfo.autoRenewPeriod;
    }

    function _setFungibleTokenInfo(address token, TokenInfo memory tokenInfo) internal {
        _fungibleTokenInfos[token].tokenInfo.totalSupply = tokenInfo.totalSupply;
        _fungibleTokenInfos[token].tokenInfo.deleted = tokenInfo.deleted;
        _fungibleTokenInfos[token].tokenInfo.defaultKycStatus = tokenInfo.defaultKycStatus;
        _fungibleTokenInfos[token].tokenInfo.pauseStatus = tokenInfo.pauseStatus;
        _fungibleTokenInfos[token].tokenInfo.ledgerId = tokenInfo.ledgerId;

        // TODO: Handle copying of other arrays (fixedFees, fractionalFees, and royaltyFees) if needed
    }

    function _setFungibleTokenKeys(address token, TokenKey[] memory tokenKeys) internal {

        // Copy the tokenKeys array
        uint256 length = tokenKeys.length;
        for (uint256 i = 0; i < length; i++) {
            TokenKey memory tokenKey = tokenKeys[i];
            _fungibleTokenInfos[token].tokenInfo.token.tokenKeys.push(tokenKey);

            /// @dev contractId can in fact be any address including an EOA address
            ///      The KeyHelper lists 5 types for KeyValueType; however only CONTRACT_ID is considered
            for (uint256 j; j < 256; j++) {
                uint256 keyType = uint256(1) << j;
                if (tokenKey.keyType & keyType != 0) {
                    _tokenKeys[token][keyType] = tokenKey.key.contractId;
                }
            }
        }

    }

    function _setFungibleTokenInfo(FungibleTokenInfo memory fungibleTokenInfo) internal returns (address treasury) {
        address tokenAddress = msg.sender;
        treasury = fungibleTokenInfo.tokenInfo.token.treasury;

        _setFungibleTokenInfoToken(tokenAddress, fungibleTokenInfo.tokenInfo.token);
        _setFungibleTokenExpiry(tokenAddress, fungibleTokenInfo.tokenInfo.token.expiry);
        _setFungibleTokenKeys(tokenAddress, fungibleTokenInfo.tokenInfo.token.tokenKeys);
        _setFungibleTokenInfo(tokenAddress, fungibleTokenInfo.tokenInfo);

        _fungibleTokenInfos[tokenAddress].decimals = fungibleTokenInfo.decimals;
    }

    // TODO: implement _post{Action} "internal" functions called inside and at the end of the pre{Action} functions is success == true
    // for getters implement _get{Data} "view internal" functions that have the exact same name as the HTS getter function name that is called after the precheck

    function _precheckCreateToken(
        address sender,
        HederaToken memory token,
        int64 initialTotalSupply,
        int32 decimals
    ) internal view returns (int64 responseCode) {
        bool validTreasurySig = sender == token.treasury;

        // if admin key is specified require admin sig
        KeyValue memory key = _getTokenKey(token.tokenKeys, _getKeyTypeValue(KeyHelper.KeyType.ADMIN));

        if (key.contractId != address(0)) {
            if (sender != key.contractId) {
                return HederaResponseCodes.INVALID_ADMIN_KEY;
            }
        }

        for (uint256 i = 0; i < token.tokenKeys.length; i++) {
            TokenKey memory tokenKey = token.tokenKeys[i];

            if (tokenKey.key.contractId != address(0)) {
                bool accountExists = _doesAccountExist(tokenKey.key.contractId);

                if (!accountExists) {

                    if (tokenKey.keyType == 1) { // KeyType.ADMIN
                        return HederaResponseCodes.INVALID_ADMIN_KEY;
                    }

                    if (tokenKey.keyType == 2) { // KeyType.KYC
                        return HederaResponseCodes.INVALID_KYC_KEY;
                    }

                    if (tokenKey.keyType == 4) { // KeyType.FREEZE
                        return HederaResponseCodes.INVALID_FREEZE_KEY;
                    }

                    if (tokenKey.keyType == 8) { // KeyType.WIPE
                        return HederaResponseCodes.INVALID_WIPE_KEY;
                    }

                    if (tokenKey.keyType == 16) { // KeyType.SUPPLY
                        return HederaResponseCodes.INVALID_SUPPLY_KEY;
                    }

                    if (tokenKey.keyType == 32) { // KeyType.FEE
                        return HederaResponseCodes.INVALID_CUSTOM_FEE_SCHEDULE_KEY;
                    }

                    if (tokenKey.keyType == 64) { // KeyType.PAUSE
                        return HederaResponseCodes.INVALID_PAUSE_KEY;
                    }
                }
            }
        }

        // TODO: add additional validation on token; validation most likely required on only tokenKeys(if an address(contract/EOA) has a zero-balance then consider the tokenKey invalid since active accounts on Hedera must have a positive HBAR balance)
        if (!validTreasurySig) {
            return HederaResponseCodes.AUTHORIZATION_FAILED;
        }

        if (decimals < 0 || decimals > 18) {
            return HederaResponseCodes.INVALID_TOKEN_DECIMALS;
        }

        if (initialTotalSupply < 0) {
            return HederaResponseCodes.INVALID_TOKEN_INITIAL_SUPPLY;
        }

        uint256 tokenNameLength = bytes(token.name).length;
        uint256 tokenSymbolLength = bytes(token.symbol).length;

        if (tokenNameLength == 0) {
            return HederaResponseCodes.MISSING_TOKEN_NAME;
        }

        // TODO: investigate correctness of max length conditionals
        // solidity strings use UTF-8 encoding, Hedera restricts the name and symbol to 100 bytes
        // in ASCII that is 100 characters
        // however in UTF-8 it is 100/4 = 25 UT-8 characters
        if (tokenNameLength > 100) {
            return HederaResponseCodes.TOKEN_NAME_TOO_LONG;
        }

        if (tokenSymbolLength == 0) {
            return HederaResponseCodes.MISSING_TOKEN_SYMBOL;
        }

        if (tokenSymbolLength > 100) {
            return HederaResponseCodes.TOKEN_SYMBOL_TOO_LONG;
        }

        return HederaResponseCodes.SUCCESS;
    }

    function _validateAdminKey(address token) internal view returns (bool success, int64 responseCode) {
        (bool validKey, bool noKey) = _hasAdminKeySig(token);
        (success, responseCode) = HederaTokenValidation._validateAdminKey(validKey, noKey);
    }

    function _validateKycKey(address token) internal view returns (bool success, int64 responseCode) {
        (bool validKey, bool noKey) = _hasKycKeySig(token);
        (success, responseCode) = HederaTokenValidation._validateKycKey(validKey, noKey);
    }

    function _validateSupplyKey(address token) internal view returns (bool success, int64 responseCode) {
        (bool validKey, bool noKey) = _hasSupplyKeySig(token);
        (success, responseCode) = HederaTokenValidation._validateSupplyKey(validKey, noKey);
    }

    function _validateFreezeKey(address token) internal view returns (bool success, int64 responseCode) {
        (bool validKey, bool noKey) = _hasFreezeKeySig(token);
        (success, responseCode) = HederaTokenValidation._validateFreezeKey(validKey, noKey);
    }

    function _validateTreasuryKey(address token) internal view returns (bool success, int64 responseCode) {
        (bool validKey, bool noKey) = _hasTreasurySig(token);
        (success, responseCode) = HederaTokenValidation._validateTreasuryKey(validKey, noKey);
    }

    function _validateWipeKey(address token) internal view returns (bool success, int64 responseCode) {
        (bool validKey, bool noKey) = _hasWipeKeySig(token);
        (success, responseCode) = HederaTokenValidation._validateWipeKey(validKey, noKey);
    }

    function _validateAccountKyc(address token, address account) internal view returns (bool success, int64 responseCode) {
        bool isKyced;
        (responseCode, isKyced) = isKyc(token, account);
        success = _doesAccountPassKyc(responseCode, isKyced);
        (success, responseCode) = HederaTokenValidation._validateAccountKyc(success);
    }

    function _validateAccountUnfrozen(address token, address account) internal view returns (bool success, int64 responseCode) {
        bool isAccountFrozen;
        (responseCode, isAccountFrozen) = isFrozen(token, account);
        success = _doesAccountPassUnfrozen(responseCode, isAccountFrozen);
        (success, responseCode) = success ? HederaTokenValidation._validateAccountFrozen(success) : (success, responseCode);
    }

    /// @dev the following internal _precheck functions are called in either of the following 2 scenarios:
    ///      1. before the HtsSystemContractMock calls any of the HederaFungibleToken or HederaNonFungibleToken functions that specify the onlyHtsPrecompile modifier
    ///      2. in any of HtsSystemContractMock functions that specifies the onlyHederaToken modifier which is only callable by a HederaFungibleToken or HederaNonFungibleToken contract

    /// @dev for Fungible
    function _precheckApprove(
        address token,
        address sender, // sender should be owner in order to approve
        address spender
    ) internal view returns (bool success, int64 responseCode) {

        success = true;

        /// @dev Hedera does not require an account to be associated with a token in be approved an allowance
        // if (!_association[token][owner] || !_association[token][spender]) {
        //     return HederaResponseCodes.TOKEN_NOT_ASSOCIATED_TO_ACCOUNT;
        // }

        (success, responseCode) = success ? _validateAccountKyc(token, sender) : (success, responseCode);
        (success, responseCode) = success ? _validateAccountKyc(token, spender) : (success, responseCode);

        (success, responseCode) = success ? _validateAccountUnfrozen(token, sender) : (success, responseCode);
        (success, responseCode) = success ? _validateAccountUnfrozen(token, spender) : (success, responseCode);

        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckMint(
        address token,
        int64,
        bytes[] memory
    ) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? _validateSupplyKey(token) : (success, responseCode);
    }

    // TODO: implement multiple NFTs being burnt instead of just index 0
    function _precheckBurn(
        address token,
        int64 amount,
        int64[] memory serialNumbers // since only 1 NFT can be burnt at a time; expect length to be 1
    ) internal view returns (bool success, int64 responseCode) {
        success = true;

        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? _validateTreasuryKey(token) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validateTokenSufficiency(token, _getTreasuryAccount(token), amount, serialNumbers[0], _isFungible) : (success, responseCode);
    }

    // TODO: implement multiple NFTs being wiped, instead of just index 0
    function _precheckWipe(
        address,
        address token,
        address account,
        int64 amount,
        int64[] memory serialNumbers // since only 1 NFT can be wiped at a time; expect length to be 1
    ) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validBurnInput(token, _isFungible, amount, serialNumbers) : (success, responseCode);
        (success, responseCode) = success ? _validateWipeKey(token) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validateTokenSufficiency(token, account, amount, serialNumbers[0], _isFungible) : (success, responseCode);
    }

    function _precheckGetFungibleTokenInfo(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validateIsFungible(token, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenCustomFees(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenDefaultFreezeStatus(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenDefaultKycStatus(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenExpiryInfo(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenInfo(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenKey(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckGetTokenType(address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckIsFrozen(address token, address) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? _validateFreezeKey(token) : (success, responseCode);
    }

    function _precheckIsKyc(address token, address) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? _validateKycKey(token) : (success, responseCode);
    }

    function _precheckAllowance(
        address token,
        address,
        address
    ) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
    }

    function _precheckAssociateToken(address account, address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);

        // TODO: consider extending HederaTokenValidation#_validateTokenAssociation with TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT
        if (success) {
            if (_association[token][account]) {
                return (false, HederaResponseCodes.TOKEN_ALREADY_ASSOCIATED_TO_ACCOUNT);
            }
        }

    }

    function _precheckDissociateToken(address account, address token) internal view returns (bool success, int64 responseCode) {
        success = true;
        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validateTokenAssociation(token, account, _association) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validateTokenDissociation(token, account, _association, _isFungible) : (success, responseCode);
    }

    /// @dev doesPassKyc if KYC is not enabled or if enabled then account is KYCed explicitly or by default
    function _doesAccountPassKyc(int64 responseCode, bool isKyced) internal pure returns (bool doesPassKyc) {
        doesPassKyc = responseCode == HederaResponseCodes.SUCCESS ? isKyced : true;
    }

    /// @dev doesPassUnfrozen if freeze is not enabled or if enabled then account is unfrozen explicitly or by default
    function _doesAccountPassUnfrozen(int64 responseCode, bool isAccountFrozen) internal pure returns (bool doesPassUnfrozen) {
        doesPassUnfrozen = responseCode == HederaResponseCodes.SUCCESS ? !isAccountFrozen : true;
    }

    function _precheckTransfer(
        address token,
        address spender,
        address from,
        address to,
        uint256 amountOrSerialNumber
    ) internal view returns (bool success, int64 responseCode, bool isRequestFromOwner) {

        success = true;

        (success, responseCode) = success ? HederaTokenValidation._validateToken(token, _tokenDeleted, _isFungible) : (success, responseCode);

        (success, responseCode) = success ? HederaTokenValidation._validateTokenAssociation(token, from, _association) : (success, responseCode);
        (success, responseCode) = success ? HederaTokenValidation._validateTokenAssociation(token, to, _association) : (success, responseCode);

        (success, responseCode) = success ? _validateAccountKyc(token, spender) : (success, responseCode);
        (success, responseCode) = success ? _validateAccountKyc(token, from) : (success, responseCode);
        (success, responseCode) = success ? _validateAccountKyc(token, to) : (success, responseCode);

        (success, responseCode) = success ? _validateAccountUnfrozen(token, spender) : (success, responseCode);
        (success, responseCode) = success ? _validateAccountUnfrozen(token, from) : (success, responseCode);
        (success, responseCode) = success ? _validateAccountUnfrozen(token, to) : (success, responseCode);

        // If transfer request is not from owner then check allowance of msg.sender
        bool shouldAssumeRequestFromOwner = spender == address(0);
        isRequestFromOwner = _isAccountSender(from) || shouldAssumeRequestFromOwner;

        (success, responseCode) = success ? HederaTokenValidation._validateTokenSufficiency(token, from, amountOrSerialNumber, amountOrSerialNumber, _isFungible) : (success, responseCode);

        if (isRequestFromOwner || !success) {
            return (success, responseCode, isRequestFromOwner);
        }

        (success, responseCode) = success ? HederaTokenValidation._validateApprovalSufficiency(token, spender, from, amountOrSerialNumber, _isFungible) : (success, responseCode);

        return (success, responseCode, isRequestFromOwner);
    }

    function _postAssociate(
        address token,
        address sender
    ) internal {
        _association[token][sender] = true;
    }

    function _postDissociate(
        address token,
        address sender
    ) internal {
        _association[token][sender] = false;
    }

    function _postIsAssociated(
        address token,
        address sender
    ) internal view returns (bool associated) {
        associated = _association[token][sender];
    }

    function preAssociate(
        address sender // msg.sender in the context of the Hedera{Non|}FungibleToken; it should be owner for SUCCESS
    ) external onlyHederaToken returns (int64 responseCode) {
        address token = msg.sender;
        bool success;
        (success, responseCode) = _precheckAssociateToken(sender, token);
        if (success) {
            _postAssociate(token, sender);
        }
    }

    function preIsAssociated(
        address sender // msg.sender in the context of the Hedera{Non|}FungibleToken; it should be owner for SUCCESS
    ) external view onlyHederaToken returns (bool associated) {
        address token = msg.sender;
        int64 responseCode;
        bool success;
        (success, responseCode) = _precheckAssociateToken(sender, token);
        if (success) {
            associated = _postIsAssociated(token, sender);
        }
    }

    function preDissociate(
        address sender // msg.sender in the context of the Hedera{Non|}FungibleToken; it should be owner for SUCCESS
    ) external onlyHederaToken returns (int64 responseCode) {
        address token = msg.sender;
        bool success;
        (success, responseCode) = _precheckDissociateToken(sender, token);
        if (success) {
            _postDissociate(token, sender);
        }
    }

    function preApprove(
        address sender, // msg.sender in the context of the Hedera{Non|}FungibleToken; it should be owner for SUCCESS
        address spender,
        uint256
    ) external view onlyHederaToken returns (int64 responseCode) {
        address token = msg.sender;
        bool success;
        (success, responseCode) = _precheckApprove(token, sender, spender);
    }

    function preTransfer(
        address spender, /// @dev if spender == address(0) then assume ERC20#transfer(i.e. msg.sender is attempting to spend their balance) otherwise ERC20#transferFrom(i.e. msg.sender is attempting to spend balance of "from" using allowance)
        address from,
        address to,
        uint256 amountOrSerialNumber
    ) external view onlyHederaToken returns (int64 responseCode) {
        address token = msg.sender;
        bool success;
        (success, responseCode, ) = _precheckTransfer(token, spender, from, to, amountOrSerialNumber);
    }

    /// @dev register HederaFungibleToken; msg.sender is the HederaFungibleToken
    ///      can be called by any contract; however assumes msg.sender is a HederaFungibleToken
    function registerHederaFungibleToken(address caller, FungibleTokenInfo memory fungibleTokenInfo) external {

        /// @dev if caller is this contract(i.e. the HtsSystemContractMock) then no need to call _precheckCreateToken since it was already called when the createFungibleToken or other relevant method was called
        bool doPrecheck = caller != address(this);

        int64 responseCode = doPrecheck ? _precheckCreateToken(caller, fungibleTokenInfo.tokenInfo.token, fungibleTokenInfo.tokenInfo.totalSupply, fungibleTokenInfo.decimals) : HederaResponseCodes.SUCCESS;

        if (responseCode != HederaResponseCodes.SUCCESS) {
            revert("PRECHECK_FAILED"); // TODO: revert with custom error that includes response code
        }

        address tokenAddress = msg.sender;
        _isFungible[tokenAddress] = true;
        address treasury = _setFungibleTokenInfo(fungibleTokenInfo);
        associateToken(treasury, tokenAddress);
    }

    function getFungibleTokenInfo(
        address token
    ) external view returns (int64 responseCode, FungibleTokenInfo memory fungibleTokenInfo) {

        bool success;
        (success, responseCode) = _precheckGetFungibleTokenInfo(token);

        if (!success) {
            return (responseCode, fungibleTokenInfo);
        }

        // TODO: abstract logic into _get{Data} function
        fungibleTokenInfo = _fungibleTokenInfos[token];
    }

    function getTokenInfo(address token) external view returns (int64 responseCode, TokenInfo memory tokenInfo) {

        bool success;
        (success, responseCode) = _precheckGetTokenInfo(token);

        if (!success) {
            return (responseCode, tokenInfo);
        }

        tokenInfo = _fungibleTokenInfos[token].tokenInfo;
    }

    function getTokenKey(address token, uint keyType) external view returns (int64 responseCode, KeyValue memory key) {

        bool success;
        (success, responseCode) = _precheckGetTokenKey(token);

        if (!success) {
            return (responseCode, key);
        }

        // TODO: abstract logic into _get{Data} function
        /// @dev the key can be retrieved using either of the following methods
        // method 1: gas inefficient
        // key = _getTokenKey(_fungibleTokenInfos[token].tokenInfo.token.tokenKeys, keyType);

        // method 2: more gas efficient and works for BOTH token types; however currently only considers contractId
        address keyValue = _tokenKeys[token][keyType];
        key.contractId = keyValue;
    }

    function _getTokenKey(IHederaTokenService.TokenKey[] memory tokenKeys, uint keyType) internal pure returns (KeyValue memory key) {
        uint256 length = tokenKeys.length;

        for (uint256 i = 0; i < length; i++) {
            IHederaTokenService.TokenKey memory tokenKey = tokenKeys[i];
            if (tokenKey.keyType == keyType) {
                key = tokenKey.key;
                break;
            }
        }
    }

    function isFrozen(address token, address account) public view returns (int64 responseCode, bool frozen) {

        bool success = true;
        (success, responseCode) = _precheckIsFrozen(token, account);

        if (!success) {
            return (responseCode, frozen);
        }

        bool isFungible = _isFungible[token];
        // TODO: abstract logic into _isFrozen function
        bool freezeDefault;
        if (isFungible) {
            FungibleTokenInfo memory fungibleTokenInfo = _fungibleTokenInfos[token];
            freezeDefault = fungibleTokenInfo.tokenInfo.token.freezeDefault;
        } else {
            revert NotImplemented();
        }

        TokenConfig memory unfrozenConfig = _unfrozen[token][account];

        /// @dev if unfrozenConfig.explicit is false && freezeDefault is true then an account must explicitly be unfrozen otherwise assume unfrozen
        frozen = unfrozenConfig.explicit ? !(unfrozenConfig.value) : (freezeDefault ? !(unfrozenConfig.value) : false);
    }

    function isKyc(address token, address account) public view returns (int64 responseCode, bool kycGranted) {

        bool success;
        (success, responseCode) = _precheckIsKyc(token, account);

        if (!success) {
            return (responseCode, kycGranted);
        }

        // TODO: abstract logic into _isKyc function
        bool isFungible = _isFungible[token];
        bool defaultKycStatus;
        if (isFungible) {
            FungibleTokenInfo memory fungibleTokenInfo = _fungibleTokenInfos[token];
            defaultKycStatus = fungibleTokenInfo.tokenInfo.defaultKycStatus;
        } else {
            revert NotImplemented();
        }

        TokenConfig memory kycConfig = _kyc[token][account];

        /// @dev if kycConfig.explicit is false && defaultKycStatus is true then an account must explicitly be KYCed otherwise assume KYCed
        kycGranted = kycConfig.explicit ? kycConfig.value : (defaultKycStatus ? kycConfig.value : true);
    }

    function isToken(address token) public view returns (int64 responseCode, bool itIs) {
        itIs = _isToken(token);
        responseCode = itIs ? HederaResponseCodes.SUCCESS : HederaResponseCodes.INVALID_TOKEN_ID;
    }

    function allowance(
        address token,
        address owner,
        address spender
    ) public view returns (int64 responseCode, uint256 amount) {

        bool success;
        (success, responseCode) = _precheckAllowance(token, owner, spender);

        if (!success) {
            return (responseCode, amount);
        }

        // TODO: abstract logic into _allowance function
        amount = HederaFungibleToken(token).allowance(owner, spender);
    }

    // Additional(not in IHederaTokenService) public/external view functions:
    /// @dev KeyHelper.KeyType is an enum; whereas KeyHelper.keyTypes is a mapping that maps the enum index to a uint256
    /// keyTypes[KeyType.ADMIN] = 1;
    /// keyTypes[KeyType.KYC] = 2;
    /// keyTypes[KeyType.FREEZE] = 4;
    /// keyTypes[KeyType.WIPE] = 8;
    /// keyTypes[KeyType.SUPPLY] = 16;
    /// keyTypes[KeyType.FEE] = 32;
    /// keyTypes[KeyType.PAUSE] = 64;
    /// i.e. the relation is 2^(uint(KeyHelper.KeyType)) = keyType
    function _getKey(address token, KeyHelper.KeyType keyType) internal view returns (address keyOwner) {
        /// @dev the following relation is used due to the below described issue with KeyHelper.getKeyType
        uint _keyType = _getKeyTypeValue(keyType);
        /// @dev the following does not work since the KeyHelper has all of its storage/state cleared/defaulted once vm.etch is used
        ///      to fix this KeyHelper should expose a function that does what it's constructor does i.e. initialise the keyTypes mapping
        // uint _keyType = getKeyType(keyType);
        keyOwner = _tokenKeys[token][_keyType];
    }

    // TODO: move into a common util contract as it's used elsewhere
    function _getKeyTypeValue(KeyHelper.KeyType keyType) internal pure returns (uint256 keyTypeValue) {
        keyTypeValue = 2 ** uint(keyType);
    }

    // TODO: validate account exists wherever applicable; transfers, mints, burns, etc
    // is account(either an EOA or contract) has a non-zero balance then assume it exists
    function _doesAccountExist(address account) internal view returns (bool exists) {
        exists = account.balance > 0;
    }

    // IHederaTokenService public/external state-changing functions:
    function createFungibleToken(
        HederaToken memory token,
        int64 initialTotalSupply,
        int32 decimals
    ) external payable noDelegateCall returns (int64 responseCode, address tokenAddress) {
        responseCode = _precheckCreateToken(msg.sender, token, initialTotalSupply, decimals);
        if (responseCode != HederaResponseCodes.SUCCESS) {
            return (responseCode, address(0));
        }

        FungibleTokenInfo memory fungibleTokenInfo;
        TokenInfo memory tokenInfo;

        tokenInfo.token = token;
        tokenInfo.totalSupply = initialTotalSupply;

        fungibleTokenInfo.decimals = decimals;
        fungibleTokenInfo.tokenInfo = tokenInfo;

        /// @dev no need to register newly created HederaFungibleToken in this context as the constructor will call HtsSystemContractMock#registerHederaFungibleToken
        HederaFungibleToken hederaFungibleToken = new HederaFungibleToken(fungibleTokenInfo);
        emit TokenCreated(address(hederaFungibleToken));
        return (HederaResponseCodes.SUCCESS, address(hederaFungibleToken));
    }

    function approve(
        address token,
        address spender,
        uint256 amount
    ) external noDelegateCall returns (int64 responseCode) {
        address owner = msg.sender;
        bool success;
        (success, responseCode) = _precheckApprove(token, owner, spender);

        if (!success) {
            return responseCode;
        }

        HederaFungibleToken(token).approveRequestFromHtsPrecompile(owner, spender, amount);
    }

    function associateToken(address account, address token) public noDelegateCall returns (int64 responseCode) {

        bool success;
        (success, responseCode) = _precheckAssociateToken(account, token);

        if (!success) {
            return responseCode;
        }

        // TODO: abstract logic into _post{Action} function
        _association[token][account] = true;
    }

    function associateTokens(
        address account,
        address[] memory tokens
    ) external noDelegateCall returns (int64 responseCode) {
        for (uint256 i = 0; i < tokens.length; i++) {
            responseCode = associateToken(account, tokens[i]);
            if (responseCode != HederaResponseCodes.SUCCESS) {
                return responseCode;
            }
        }
    }

    function dissociateTokens(
        address account,
        address[] memory tokens
    ) external noDelegateCall returns (int64 responseCode) {
        for (uint256 i = 0; i < tokens.length; i++) {
            responseCode = dissociateToken(account, tokens[i]);
            if (responseCode != HederaResponseCodes.SUCCESS) {
                return responseCode;
            }
        }
    }

    function dissociateToken(address account, address token) public noDelegateCall returns (int64 responseCode) {

        bool success;
        (success, responseCode) = _precheckDissociateToken(account, token);

        if (!success) {
            return responseCode;
        }

        // TODO: abstract logic into _post{Action} function
        _association[token][account] = false;
    }

    function mintToken(
        address token,
        int64 amount,
        bytes[] memory metadata
    ) external noDelegateCall returns (int64 responseCode, int64 newTotalSupply, int64[] memory serialNumbers) {
        bool success;
        (success, responseCode) = _precheckMint(token, amount, metadata);

        if (!success) {
            return (responseCode, 0, new int64[](0));
        }

        int64 amountOrSerialNumber;

        if (_isFungible[token]) {
            amountOrSerialNumber = amount;
            HederaFungibleToken hederaFungibleToken = HederaFungibleToken(token);
            hederaFungibleToken.mintRequestFromHtsPrecompile(amount);
            newTotalSupply = int64(int(hederaFungibleToken.totalSupply()));
        }
        return (responseCode, newTotalSupply, serialNumbers);
    }

    function burnToken(
        address token,
        int64 amount,
        int64[] memory serialNumbers
    ) external noDelegateCall returns (int64 responseCode, int64 newTotalSupply) {
        bool success;
        (success, responseCode) = _precheckBurn(token, amount, serialNumbers);

        if (!success) {
            return (responseCode, 0);
        }

        if (_isFungible[token]) {
            HederaFungibleToken hederaFungibleToken = HederaFungibleToken(token);
            hederaFungibleToken.burnRequestFromHtsPrecompile(amount);
            newTotalSupply = int64(int(hederaFungibleToken.totalSupply()));
        }
    }

    function transferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) external noDelegateCall returns (int64 responseCode) {
        /// @dev spender is set to non-zero address such that shouldAssumeRequestFromOwner always evaluates to false if HtsSystemContractMock#transferFrom is called
        address spender = msg.sender;
        bool isRequestFromOwner;

        bool success;
        (success, responseCode, isRequestFromOwner) = _precheckTransfer(token, spender, from, to, amount);

        if (!success) {
            return responseCode;
        }

        responseCode = HederaFungibleToken(token).transferRequestFromHtsPrecompile(
            isRequestFromOwner,
            spender,
            from,
            to,
            amount
        );
    }

    /// TODO implementation is currently identical to transferFrom; investigate the differences between the 2 functions
    function transferToken(
        address token,
        address sender,
        address recipient,
        int64 amount
    ) public noDelegateCall returns (int64 responseCode) {
        address spender = msg.sender;
        bool isRequestFromOwner;
        uint _amount = uint(int(amount));

        bool success;
        (success, responseCode, isRequestFromOwner) = _precheckTransfer(token, spender, sender, recipient, _amount);

        if (!success) {
            return responseCode;
        }

        responseCode = HederaFungibleToken(token).transferRequestFromHtsPrecompile(
            isRequestFromOwner,
            spender,
            sender,
            recipient,
            _amount
        );
    }

    function transferTokens(
        address token,
        address[] memory accountId,
        int64[] memory amount
    ) external noDelegateCall returns (int64 responseCode) {
        uint length = accountId.length;
        uint amountCount = amount.length;

        require(length == amountCount, 'UNEQUAL_ARRAYS');

        address spender = msg.sender;
        address receiver;
        int64 _amount;

        for (uint256 i = 0; i < length; i++) {
            receiver = accountId[i];
            _amount = amount[i];

            responseCode = transferToken(token, spender, receiver, _amount);

            // TODO: instead of reverting return responseCode; this will require prechecks on each individual transfer before enacting the transfer of all NFTs
            // alternatively consider reverting but catch error and extract responseCode from the error and return the responseCode
            if (responseCode != HederaResponseCodes.SUCCESS) {
                revert HtsPrecompileError(responseCode);
            }
        }
    }

    function wipeTokenAccount(
        address token,
        address account,
        int64 amount
    ) external noDelegateCall returns (int64 responseCode) {

        int64[] memory nullArray;

        bool success;
        (success, responseCode) = _precheckWipe(msg.sender, token, account, amount, nullArray);

        if (!success) {
            return responseCode;
        }

        // TODO: abstract logic into _post{Action} function
        HederaFungibleToken hederaFungibleToken = HederaFungibleToken(token);
        hederaFungibleToken.wipeRequestFromHtsPrecompile(account, amount);
    }

    // Additional(not in IHederaTokenService) public/external state-changing functions:
    function isAssociated(address account, address token) external view returns (bool associated) {
        associated = _association[token][account];
    }

    function getTreasuryAccount(address token) external view returns (address treasury) {
        return _getTreasuryAccount(token);
    }

    // Unimplemented
    function getTokenType(address) external pure returns (int64, int32) { revert NotImplemented(); }
    function grantTokenKyc(address, address) external pure returns (int64) { revert NotImplemented(); }
    function isApprovedForAll(address, address, address) external pure returns (int64, bool) { revert NotImplemented(); }
    function getNonFungibleTokenInfo(address, int64) external pure returns (int64, NonFungibleTokenInfo memory) { revert NotImplemented(); }
    function getTokenCustomFees(address) external pure returns (int64, FixedFee[] memory, FractionalFee[] memory, RoyaltyFee[] memory) { revert NotImplemented(); }
    function getTokenDefaultFreezeStatus(address) external pure returns (int64, bool) { revert NotImplemented(); }
    function getTokenDefaultKycStatus(address) external pure returns (int64, bool) { revert NotImplemented(); }
    function getTokenExpiryInfo(address) external pure returns (int64, Expiry memory) { revert NotImplemented(); }
    function preSetApprovalForAll(address, address, bool) external pure returns (int64) { revert NotImplemented(); }
    function preMint(address, int64, bytes[] memory) external pure returns (int64) { revert NotImplemented(); }
    function preBurn(int64, int64[] memory) external pure returns (int64) { revert NotImplemented(); }
    function registerHederaNonFungibleToken(address, TokenInfo memory) external pure { revert NotImplemented(); }
    function getApproved(address, uint256) external pure returns (int64, address) { revert NotImplemented(); }
    function createNonFungibleToken(HederaToken memory) external payable returns (int64, address) { revert NotImplemented(); }
    function createFungibleTokenWithCustomFees(HederaToken memory, int64, int32, FixedFee[] memory, FractionalFee[] memory) external payable returns (int64, address) { revert NotImplemented(); }
    function approveNFT(address, address, uint256) external pure returns (int64) { revert NotImplemented(); }
    function createNonFungibleTokenWithCustomFees(HederaToken memory, FixedFee[] memory, RoyaltyFee[] memory) external payable returns (int64, address) { revert NotImplemented(); }
    function cryptoTransfer(TransferList memory, TokenTransferList[] memory) external pure returns (int64) { revert NotImplemented(); }
    function deleteToken(address) external pure returns (int64) { revert NotImplemented(); }
    function freezeToken(address, address) external pure returns (int64) { revert NotImplemented(); }
    function pauseToken(address) external pure returns (int64) { revert NotImplemented(); }
    function revokeTokenKyc(address, address) external pure returns (int64) { revert NotImplemented(); }
    function setApprovalForAll(address, address, bool) external pure returns (int64) { revert NotImplemented(); }
    function transferFromNFT(address, address, address, uint256) external pure returns (int64) { revert NotImplemented(); }
    function transferNFT(address, address, address, int64) external pure returns (int64) { revert NotImplemented(); }
    function transferNFTs(address, address[] memory, address[] memory, int64[] memory) external pure returns (int64) { revert NotImplemented(); }
    function unfreezeToken(address, address) external pure returns (int64) { revert NotImplemented(); }
    function unpauseToken(address) external pure returns (int64) { revert NotImplemented(); }
    function updateTokenExpiryInfo(address, Expiry memory) external pure returns (int64) { revert NotImplemented(); }
    function updateTokenInfo(address, HederaToken memory) external pure returns (int64) { revert NotImplemented(); }
    function updateTokenKeys(address, TokenKey[] memory) external pure returns (int64) { revert NotImplemented(); }
    function airdropTokens(TokenTransferList[] memory) external pure returns (int64) { revert NotImplemented(); }
    function cancelAirdrops(PendingAirdrop[] memory) external pure returns (int64) { revert NotImplemented(); }
    function claimAirdrops(PendingAirdrop[] memory) external pure returns (int64) { revert NotImplemented(); }
    function rejectTokens(address, address[] memory, NftID[] memory) external pure returns (int64) { revert NotImplemented(); }
    function wipeTokenAccountNFT(address, address, int64[] memory) external pure returns (int64) { revert NotImplemented(); }
    function updateFungibleTokenCustomFees(address,  IHederaTokenService.FixedFee[] memory, IHederaTokenService.FractionalFee[] memory) external pure returns (int64) { revert NotImplemented(); }
    function updateNonFungibleTokenCustomFees(address, IHederaTokenService.FixedFee[] memory, IHederaTokenService.RoyaltyFee[] memory) external pure returns (int64){ revert NotImplemented(); }
    function redirectForToken(address, bytes memory) external pure override returns (int64, bytes memory) { revert NotImplemented(); }
}
