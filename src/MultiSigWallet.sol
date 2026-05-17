// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

error MultiSigWallet__MoreConfirmationsThanSigners(uint256 _confirmations, uint256 _signers);
error MultiSigWallet__ShouldBeAtLeastOneConfirmation();
error MultiSigWallet__EmptySigners();
error MultiSigWallet_SignersShouldBeUnique(uint256 _firstOccurIdx, uint256 _secondOccurIdx);
error MultiSigWallet__OnlySignersAllowed(address _sender);
error MultiSigWallet__FailedToExecuteTx();
error MultiSigWallet__InvalidDeadline();
error MultiSigWallet__InvalidNonce();
error MultiSigWallet__AlreadyConfirmed();
error MultiSigWallet__Expired(uint256 deadline);
error MultiSigWallet__AlreadyExecuted();
error MultiSigWallet__InsufficientTxConfirmations();
error MultiSigWallet__CannotRevokeYet();
error MultiSigWallet__InvalidSigner();
error MultiSigWallet__OnlySelfCallable();
error MultiSigWallet__SignerAlreadyExists();
error MultiSigWallet__SignerDoesNotExist();
error MultiSigWallet__WouldBreakThresholdInvariant();
error MultiSigWallet__StaleEpoch();
error MultiSigWallet__OnlyInitiatorCanCancel();
error MultiSigWallet__AlreadyCancelled();

event Deposit(address indexed from, uint256 amount);
event SignerAdded(address indexed signer);
event SignerRemoved(address indexed signer);
event RequiredConfirmationsChanged(uint256 oldValue, uint256 newValue);

struct Tx {
    address initiator;
    uint64 deadline;
    bool executed;
    bool cancelled;
    uint64 confirmationsCount;
    address to;
    uint256 value;
    uint256 epoch;
    bytes data;
}

struct TxMeta {
    address initiator;
    address to;
    uint256 value;
    uint64 deadline;
    uint64 confirmationsCount;
    uint256 epoch;
    bool executed;
    bool cancelled;
}

/**
 * @title MultiSigWallet
 * @notice On-chain multi-signature wallet. Proposals are confirmed by a configurable
 *         set of signers and executed once a threshold is reached. Signer set and
 *         threshold are governed by the wallet itself via `onlySelf` admin entry points.
 * @dev Confirmations are stamped with a `signerEpoch`. Any admin change bumps the epoch
 *      and immediately invalidates every in-flight proposal — survivors must be
 *      re-proposed under the new policy.
 */
contract MultiSigWallet is ReentrancyGuard {
    address[] signers;
    mapping(address => bool) public isSigner;
    mapping(uint256 => mapping(address => bool)) txConfirmers;
    mapping(uint256 => Tx) nonceToTx;
    uint256 internal nonce;
    uint256 internal requiredConfirmationCount;
    uint256 internal signerEpoch;

    event TransactionProposed(uint256 indexed txId, address indexed initiator);
    event TransactionConfirmed(uint256 indexed txId, address indexed signer);
    event TransactionRevoked(uint256 indexed txId, address indexed signer);
    event TransactionExecuted(uint256 indexed txId, bytes result);
    event TransactionCancelled(uint256 indexed txId, address indexed initiator);

    modifier onlySigners() {
        if (!isSigner[msg.sender]) {
            revert MultiSigWallet__OnlySignersAllowed(msg.sender);
        }
        _;
    }

    modifier validTx(uint256 _nonce) {
        checkTxValidation(_nonce);
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert MultiSigWallet__OnlySelfCallable();
        }
        _;
    }

    constructor(address[] memory _signers, uint256 _requiredConfirmationCount) {
        if (_signers.length == 0) {
            revert MultiSigWallet__EmptySigners();
        }
        if (_requiredConfirmationCount == 0) {
            revert MultiSigWallet__ShouldBeAtLeastOneConfirmation();
        }
        if (_requiredConfirmationCount > _signers.length) {
            revert MultiSigWallet__MoreConfirmationsThanSigners(_requiredConfirmationCount, _signers.length);
        }

        findDuplicate(_signers);

        signers = _signers;
        for (uint256 i = 0; i < _signers.length; i++) {
            isSigner[_signers[i]] = true;
        }
        requiredConfirmationCount = _requiredConfirmationCount;
    }

    /**
     * @notice Propose a new transaction for the signer set to confirm and execute.
     * @param _txAddress Target of the call.
     * @param _txValue Wei to forward with the call.
     * @param _txDeadline Latest timestamp (inclusive) at which this tx may execute.
     * @param _txData Calldata to forward.
     */
    function proposeTx(address _txAddress, uint256 _txValue, uint64 _txDeadline, bytes calldata _txData)
        external
        onlySigners
    {
        if (_txDeadline < block.timestamp) {
            revert MultiSigWallet__InvalidDeadline();
        }

        Tx memory transaction = Tx({
            initiator: msg.sender,
            deadline: _txDeadline,
            executed: false,
            cancelled: false,
            confirmationsCount: 1,
            to: _txAddress,
            value: _txValue,
            epoch: signerEpoch,
            data: _txData
        });

        txConfirmers[nonce][msg.sender] = true;
        nonceToTx[nonce] = transaction;
        emit TransactionProposed(nonce, msg.sender);
        nonce++;
    }

    /**
     * @notice Add the caller's confirmation to a pending transaction.
     */
    function confirmTx(uint256 _nonce) external nonReentrant onlySigners validTx(_nonce) {
        if (txConfirmers[_nonce][msg.sender]) {
            revert MultiSigWallet__AlreadyConfirmed();
        }
        txConfirmers[_nonce][msg.sender] = true;
        nonceToTx[_nonce].confirmationsCount++;
        emit TransactionConfirmed(_nonce, msg.sender);
    }

    /**
     * @notice Execute a transaction that has reached the confirmation threshold.
     * @dev `executed` is set before the external call (CEI). The single
     *      `nonReentrant` slot also blocks re-entry into confirm/revoke.
     */
    function executeTx(uint256 _nonce) external onlySigners validTx(_nonce) nonReentrant {
        Tx storage el = nonceToTx[_nonce];
        if (el.confirmationsCount < requiredConfirmationCount) {
            revert MultiSigWallet__InsufficientTxConfirmations();
        }

        el.executed = true;

        (bool success, bytes memory result) = el.to.call{value: el.value}(el.data);

        if (!success) {
            revert MultiSigWallet__FailedToExecuteTx();
        }

        emit TransactionExecuted(_nonce, result);
    }

    /**
     * @notice Withdraw the caller's prior confirmation from a pending transaction.
     */
    function revokeTx(uint256 _nonce) external nonReentrant onlySigners validTx(_nonce) {
        if (!txConfirmers[_nonce][msg.sender]) {
            revert MultiSigWallet__CannotRevokeYet();
        }
        txConfirmers[_nonce][msg.sender] = false;
        nonceToTx[_nonce].confirmationsCount--;
        emit TransactionRevoked(_nonce, msg.sender);
    }

    /**
     * @notice Permanently kill a pending transaction. Only callable by its initiator.
     */
    function cancelTx(uint256 _nonce) external onlySigners validTx(_nonce) {
        Tx storage el = nonceToTx[_nonce];
        if (msg.sender != el.initiator) {
            revert MultiSigWallet__OnlyInitiatorCanCancel();
        }
        el.cancelled = true;
        emit TransactionCancelled(_nonce, msg.sender);
    }

    /// @notice Add a new signer. Callable only via a confirmed self-call proposal.
    function addSigner(address _signer) external onlySelf {
        if (_signer == address(0)) revert MultiSigWallet__InvalidSigner();
        if (isSigner[_signer]) revert MultiSigWallet__SignerAlreadyExists();
        isSigner[_signer] = true;
        signers.push(_signer);
        signerEpoch++;
        emit SignerAdded(_signer);
    }

    /// @notice Remove a signer. Reverts if removal would leave the threshold unreachable.
    function removeSigner(address _signer) external onlySelf {
        if (!isSigner[_signer]) revert MultiSigWallet__SignerDoesNotExist();
        if (signers.length - 1 < requiredConfirmationCount) {
            revert MultiSigWallet__WouldBreakThresholdInvariant();
        }
        isSigner[_signer] = false;
        uint256 len = signers.length;
        for (uint256 i = 0; i < len; i++) {
            if (signers[i] == _signer) {
                signers[i] = signers[len - 1];
                signers.pop();
                break;
            }
        }
        signerEpoch++;
        emit SignerRemoved(_signer);
    }

    /// @notice Atomically swap a signer for a new address.
    function replaceSigner(address _old, address _new) external onlySelf {
        if (_new == address(0)) revert MultiSigWallet__InvalidSigner();
        if (!isSigner[_old]) revert MultiSigWallet__SignerDoesNotExist();
        if (isSigner[_new]) revert MultiSigWallet__SignerAlreadyExists();
        isSigner[_old] = false;
        isSigner[_new] = true;
        uint256 len = signers.length;
        for (uint256 i = 0; i < len; i++) {
            if (signers[i] == _old) {
                signers[i] = _new;
                break;
            }
        }
        signerEpoch++;
        emit SignerRemoved(_old);
        emit SignerAdded(_new);
    }

    /// @notice Change the confirmation threshold.
    function setRequiredConfirmations(uint256 _newCount) external onlySelf {
        if (_newCount == 0) revert MultiSigWallet__ShouldBeAtLeastOneConfirmation();
        if (_newCount > signers.length) {
            revert MultiSigWallet__MoreConfirmationsThanSigners(_newCount, signers.length);
        }
        uint256 oldCount = requiredConfirmationCount;
        requiredConfirmationCount = _newCount;
        signerEpoch++;
        emit RequiredConfirmationsChanged(oldCount, _newCount);
    }

    function findDuplicate(address[] memory _accounts) internal pure {
        for (uint256 i = 0; i < _accounts.length; i++) {
            if (_accounts[i] == address(0)) {
                revert MultiSigWallet__InvalidSigner();
            }
            for (uint256 j = i + 1; j < _accounts.length; j++) {
                if (_accounts[i] == _accounts[j]) {
                    revert MultiSigWallet_SignersShouldBeUnique(i, j);
                }
            }
        }
    }

    function checkTxValidation(uint256 _nonce) internal view {
        if (_nonce >= nonce) revert MultiSigWallet__InvalidNonce();
        Tx storage el = nonceToTx[_nonce];
        if (el.epoch != signerEpoch) revert MultiSigWallet__StaleEpoch();
        if (el.cancelled) revert MultiSigWallet__AlreadyCancelled();
        if (block.timestamp > el.deadline) revert MultiSigWallet__Expired(el.deadline);
        if (el.executed) revert MultiSigWallet__AlreadyExecuted();
    }

    /// @notice Full transaction record including calldata. Calldata is unbounded.
    function getTransaction(uint256 _nonce) external view returns (Tx memory) {
        return nonceToTx[_nonce];
    }

    /// @notice Lightweight transaction record without calldata.
    function getTransactionMeta(uint256 _nonce) external view returns (TxMeta memory) {
        Tx storage el = nonceToTx[_nonce];
        return TxMeta({
            initiator: el.initiator,
            to: el.to,
            value: el.value,
            deadline: el.deadline,
            confirmationsCount: el.confirmationsCount,
            epoch: el.epoch,
            executed: el.executed,
            cancelled: el.cancelled
        });
    }

    function getSigners() external view returns (address[] memory) {
        return signers;
    }

    function hasConfirmed(uint256 _nonce, address _signer) external view returns (bool) {
        return txConfirmers[_nonce][_signer];
    }

    function getRequiredConfirmations() external view returns (uint256) {
        return requiredConfirmationCount;
    }

    function getSignerCount() external view returns (uint256) {
        return signers.length;
    }

    function getNonce() external view returns (uint256) {
        return nonce;
    }

    function getSignerEpoch() external view returns (uint256) {
        return signerEpoch;
    }

    receive() external payable {
        emit Deposit(msg.sender, msg.value);
    }
}
