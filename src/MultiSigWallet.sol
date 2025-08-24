// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// @note Confirmation count should always be LESS than signers count
// because when signer initiates a voting for tx execution it automatically
// confirms that proposal from contract perspective
error MultiSigWallet__MoreConfirmationsThanSigners(
    uint _confirmations,
    uint _signers
);
error MultiSigWallet__ShouldBeAtLeastOneConfirmation();
error MultiSigWallet__EmptySigners();
error MultiSigWallet_SignersShouldBeUnique(
    uint _firstOccurIdx,
    uint _secondOccurIdx
);
error MultiSigWallet__OnlySignersAllowed(address _sender);
error MultiSigWallet__InvalidDeadline();
error MultiSigWallet__InsufficientBalance(uint256 _asked, uint256 _got);
error MultiSigWallet__InvalidNonce();
error MultiSigWallet__AlreadyConfirmed();
error MultiSigWallet__Expired(uint256 deadline);
error MultiSigWallet__AlreadyExecuted();
error MultiSigWallet__OnlyOwnerCanExecute();
error MultiSigWallet__InsufficientTxConfirmations();
error MultiSigWallet__CannotRevokeYet();
error MultiSigWallet__InvalidSigner();

struct Tx {
    address initiator;
    uint256 value;
    address to;
    bytes data;
    uint256 deadline;
    uint256 confirmationsCount;
    bool executed;
}

contract MultiSigWallet {
    address[] signers;
    mapping(uint256 => mapping(address => bool)) txConfirmers;
    mapping(uint256 => Tx) nonceToTx;
    // @note points to the next nonce value (tx id)
    uint256 internal nonce;
    uint256 immutable i_maxSignersCount;
    uint256 immutable i_requiredConfirmationCount;

    event TxExecuted(uint256 _txId, bytes _txResult);
    event TransactionProposed(uint256 indexed txId, address indexed initiator);
    event TransactionConfirmed(uint256 indexed txId, address indexed signer);
    event TransactionRevoked(uint256 indexed txId, address indexed signer);

    modifier onlySigners() {
        if (!isSigner()) {
            revert MultiSigWallet__OnlySignersAllowed(msg.sender);
        }
        _;
    }
    modifier validTx(uint256 _nonce) {
        checkTxValidation(_nonce);
        _;
    }
    modifier onlyTxOwner(uint256 _nonce) {
        require(
            msg.sender == nonceToTx[_nonce].initiator,
            "Error you should be a tx owner!"
        );
        _;
    }

    constructor(address[] memory _signers, uint256 _requiredConfirmationCount) {
        if (_signers.length == 0) {
            revert MultiSigWallet__EmptySigners();
        }
        if (_requiredConfirmationCount == 0) {
            revert MultiSigWallet__ShouldBeAtLeastOneConfirmation();
        }
        // It should be >, not >=, to allow the case where required confirmations equals the number of signers.
        if (_requiredConfirmationCount > _signers.length) {
            revert MultiSigWallet__MoreConfirmationsThanSigners(
                _requiredConfirmationCount,
                _signers.length
            );
        }

        (int n1, int n2) = isUnique(_signers);
        if (n1 != -1 && n2 != -1) {
            revert MultiSigWallet_SignersShouldBeUnique(uint(n1), uint(n2));
        }

        signers = _signers;
        i_requiredConfirmationCount = _requiredConfirmationCount;
        i_maxSignersCount = _signers.length;
        nonce = 0;
    }

    function proposeTx(
        address _txAddress,
        uint256 _txValue,
        uint256 _txDeadline,
        bytes calldata _txData
    ) external onlySigners {
        if (_txDeadline <= block.timestamp) {
            revert MultiSigWallet__InvalidDeadline();
        }
        if (_txValue > address(this).balance) {
            revert MultiSigWallet__InsufficientBalance(
                _txValue,
                address(this).balance
            );
        }

        Tx memory transaction = Tx(
            msg.sender,
            _txValue,
            _txAddress,
            _txData,
            _txDeadline,
            1, // Start with 1 confirmation (initiator's)
            false
        );
        txConfirmers[nonce][msg.sender] = true;
        nonceToTx[nonce] = transaction;

        emit TransactionProposed(nonce, msg.sender);
        nonce++;
    }

    function confirmTx(uint256 _nonce) external onlySigners validTx(_nonce) {
        if (txConfirmers[_nonce][msg.sender]) {
            revert MultiSigWallet__AlreadyConfirmed();
        }

        txConfirmers[_nonce][msg.sender] = true;
        nonceToTx[_nonce].confirmationsCount++;

        emit TransactionConfirmed(_nonce, msg.sender);
    }

    function executeTx(uint256 _nonce) external onlySigners validTx(_nonce) {
        Tx storage el = nonceToTx[_nonce];
        if (el.confirmationsCount < i_requiredConfirmationCount) {
            revert MultiSigWallet__InsufficientTxConfirmations();
        }

        el.executed = true;

        (, bytes memory result) = address(el.to).call{value: el.value}(el.data);

        emit TxExecuted(_nonce, result);
    }

    function revokeTx(uint256 _nonce) external onlySigners validTx(_nonce) {
        if (!txConfirmers[_nonce][msg.sender]) {
            revert MultiSigWallet__CannotRevokeYet();
        }
        txConfirmers[_nonce][msg.sender] = false;
        nonceToTx[_nonce].confirmationsCount--;

        emit TransactionRevoked(_nonce, msg.sender);
    }

    function isUnique(
        address[] memory _accounts
    ) internal pure returns (int, int) {
        if (_accounts.length <= 1) {
            return (-1, -1);
        }
        for (uint i = 0; i < _accounts.length; i++) {
            if (_accounts[i] == address(0)) {
                revert MultiSigWallet__InvalidSigner();
            }
            for (uint j = _accounts.length - 1; j > i; j--) {
                if (_accounts[i] == _accounts[j]) {
                    return (int(i), int(j));
                }
            }
        }
        return (-1, -1);
    }

    function isSigner() internal view returns (bool) {
        address[] memory signersCopy = signers;
        for (uint256 i = 0; i < signersCopy.length; i++) {
            if (signersCopy[i] == msg.sender) {
                return true;
            }
        }
        return false;
    }

    function checkTxValidation(uint256 _nonce) internal view {
        if (block.timestamp > nonceToTx[_nonce].deadline) {
            revert MultiSigWallet__Expired(nonceToTx[_nonce].deadline);
        }
        if (nonceToTx[_nonce].executed) {
            revert MultiSigWallet__AlreadyExecuted();
        }
    }

    // Getter functions
    function getTransaction(uint256 _nonce) external view returns (Tx memory) {
        return nonceToTx[_nonce];
    }

    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    function hasConfirmed(
        uint256 _nonce,
        address _signer
    ) external view returns (bool) {
        return txConfirmers[_nonce][_signer];
    }

    function getRequiredConfirmations() external view returns (uint256) {
        return i_requiredConfirmationCount;
    }

    function getMaxSignersCount() external view returns (uint256) {
        return i_maxSignersCount;
    }

    function getNonce() external view returns (uint256) {
        return nonce;
    }

    // Allow contract to receive ETH
    receive() external payable {}
}
