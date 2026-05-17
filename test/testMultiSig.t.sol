// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    MultiSigWallet,
    MultiSigWallet__AlreadyCancelled,
    MultiSigWallet__AlreadyConfirmed,
    MultiSigWallet__EmptySigners,
    MultiSigWallet__FailedToExecuteTx,
    MultiSigWallet__InsufficientTxConfirmations,
    MultiSigWallet__InvalidDeadline,
    MultiSigWallet__MoreConfirmationsThanSigners,
    MultiSigWallet__OnlyInitiatorCanCancel,
    MultiSigWallet__OnlySelfCallable,
    MultiSigWallet__OnlySignersAllowed,
    MultiSigWallet__ShouldBeAtLeastOneConfirmation,
    MultiSigWallet__SignerAlreadyExists,
    MultiSigWallet__SignerDoesNotExist,
    MultiSigWallet__StaleEpoch,
    MultiSigWallet__WouldBreakThresholdInvariant,
    MultiSigWallet_SignersShouldBeUnique,
    SignerAdded,
    SignerRemoved,
    RequiredConfirmationsChanged,
    Tx,
    TxMeta
} from "../src/MultiSigWallet.sol";

contract MultiSigWalletHarness is MultiSigWallet {
    constructor(address[] memory _signers, uint256 _requiredConfirmations)
        MultiSigWallet(_signers, _requiredConfirmations)
    {}

    function findDuplicateHarness(address[] memory _signers) public pure {
        findDuplicate(_signers);
    }
}

contract ReceiverTestContract {
    receive() external payable {}

    fallback() external {}
}

contract BadReceiverTestContract {
    fallback() external {}
}

contract MultiSigWalletTest is Test {
    MultiSigWalletHarness wallet;
    ReceiverTestContract receiver;

    address bobAddr = vm.addr(uint256(keccak256("bob")));
    address carolAddr = vm.addr(uint256(keccak256("carol")));
    address aliceAddr = vm.addr(uint256(keccak256("alice")));
    address daveAddr = vm.addr(uint256(keccak256("dave")));
    address eveAddr = vm.addr(uint256(keccak256("eve")));

    function proposeValidTx(bool autoApprove) internal returns (address proposer, uint256 nonceOut) {
        vm.prank(aliceAddr);
        wallet.proposeTx(address(receiver), 0, uint64(block.timestamp + 10000), bytes("Some extra text here!"));
        nonceOut = wallet.getNonce() - 1;
        if (autoApprove) {
            vm.prank(bobAddr);
            wallet.confirmTx(nonceOut);
            vm.prank(carolAddr);
            wallet.confirmTx(nonceOut);
        }
        return (aliceAddr, nonceOut);
    }

    function setUp() public {
        address[] memory signers = new address[](3);
        signers[0] = aliceAddr;
        signers[1] = bobAddr;
        signers[2] = carolAddr;

        wallet = new MultiSigWalletHarness(signers, 2);
        receiver = new ReceiverTestContract();
    }

    function testMultiSigWalletConstructor() public {
        address[] memory dupSigners = new address[](2);
        dupSigners[0] = aliceAddr;
        dupSigners[1] = aliceAddr;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet_SignersShouldBeUnique.selector, 0, 1));
        new MultiSigWallet(dupSigners, 1);

        address[] memory signers = new address[](2);
        signers[0] = aliceAddr;
        signers[1] = bobAddr;
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet__MoreConfirmationsThanSigners.selector, 3, 2));
        new MultiSigWallet(signers, 3);

        address[] memory emptySigners = new address[](0);
        vm.expectRevert(MultiSigWallet__EmptySigners.selector);
        new MultiSigWallet(emptySigners, 0);
    }

    function testFindDuplicateHarness() public {
        address[] memory diff = new address[](3);
        diff[0] = aliceAddr;
        diff[1] = bobAddr;
        diff[2] = carolAddr;
        wallet.findDuplicateHarness(diff); // no revert

        wallet.findDuplicateHarness(new address[](0)); // no revert

        address[] memory rep = new address[](2);
        rep[0] = vm.addr(uint256(keccak256("vadik")));
        rep[1] = vm.addr(uint256(keccak256("vadik")));
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet_SignersShouldBeUnique.selector, 0, 1));
        wallet.findDuplicateHarness(rep);
    }

    function testProposeTxWithWrongDeadline() public {
        vm.warp(1000);
        vm.expectRevert(MultiSigWallet__InvalidDeadline.selector);
        vm.prank(aliceAddr);
        wallet.proposeTx(address(0x1), 0, uint64(block.timestamp - 500), bytes("Hello world!"));
    }

    function testProposeRejectsNonSigner() public {
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet__OnlySignersAllowed.selector, daveAddr));
        vm.prank(daveAddr);
        wallet.proposeTx(address(receiver), 0, uint64(block.timestamp + 1000), "");
    }

    function testProposeCorrectTx() public {
        vm.prank(aliceAddr);
        wallet.proposeTx(address(receiver), 0, uint64(block.timestamp + 10000), bytes("Some extra text here!"));
        assertTrue(wallet.hasConfirmed(wallet.getNonce() - 1, aliceAddr));
        assertTrue(!wallet.hasConfirmed(wallet.getNonce() - 1, bobAddr));
    }

    function testTxApproving() external {
        (, uint256 n) = proposeValidTx(true);
        assertTrue(wallet.hasConfirmed(n, carolAddr));
        assertTrue(wallet.hasConfirmed(n, bobAddr));
        assertTrue(wallet.hasConfirmed(n, aliceAddr));

        Tx memory transaction = wallet.getTransaction(n);
        assertTrue(transaction.confirmationsCount == 3);
        assertTrue(!transaction.executed);
    }

    function testValidTxExecution() external {
        (, uint256 n) = proposeValidTx(true);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
        assertTrue(wallet.getTransaction(n).executed);
    }

    function testRevertedToExecuteTx() external {
        (bool ok,) = address(wallet).call{value: 1 ether}("");
        assertTrue(ok);
        BadReceiverTestContract bad = new BadReceiverTestContract();
        uint256 txValue = 0.9 ether;
        vm.prank(aliceAddr);
        wallet.proposeTx(address(bad), txValue, uint64(block.timestamp + 1000), bytes("Hello world!"));
        uint256 n = wallet.getNonce() - 1;

        vm.prank(bobAddr);
        wallet.confirmTx(n);
        vm.prank(carolAddr);
        wallet.confirmTx(n);

        vm.expectRevert(MultiSigWallet__FailedToExecuteTx.selector);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
    }

    function testInsufficientTxConfirmations() external {
        (, uint256 n) = proposeValidTx(false);
        vm.prank(aliceAddr);
        vm.expectRevert(MultiSigWallet__InsufficientTxConfirmations.selector);
        wallet.executeTx(n);
        assertTrue(!wallet.getTransaction(n).executed);
    }

    function testCancelByInitiator() external {
        (, uint256 n) = proposeValidTx(false);
        vm.prank(aliceAddr);
        wallet.cancelTx(n);
        assertTrue(wallet.getTransaction(n).cancelled);

        // further interactions revert
        vm.expectRevert(MultiSigWallet__AlreadyCancelled.selector);
        vm.prank(bobAddr);
        wallet.confirmTx(n);
    }

    function testCancelByNonInitiatorReverts() external {
        (, uint256 n) = proposeValidTx(false);
        vm.expectRevert(MultiSigWallet__OnlyInitiatorCanCancel.selector);
        vm.prank(bobAddr);
        wallet.cancelTx(n);
    }

    function testAlreadyConfirmed() external {
        (, uint256 n) = proposeValidTx(false);
        vm.expectRevert(MultiSigWallet__AlreadyConfirmed.selector);
        vm.prank(aliceAddr);
        wallet.confirmTx(n);
    }

    function testGetTransactionMeta() external {
        (, uint256 n) = proposeValidTx(false);
        TxMeta memory meta = wallet.getTransactionMeta(n);
        assertEq(meta.initiator, aliceAddr);
        assertEq(meta.to, address(receiver));
        assertEq(meta.confirmationsCount, 1);
        assertTrue(!meta.executed);
        assertTrue(!meta.cancelled);
    }

    // ---------- Admin flow (onlySelf via executeTx) ----------

    function _execSelf(bytes memory _data) internal returns (uint256 n) {
        vm.prank(aliceAddr);
        wallet.proposeTx(address(wallet), 0, uint64(block.timestamp + 1000), _data);
        n = wallet.getNonce() - 1;
        vm.prank(bobAddr);
        wallet.confirmTx(n);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
    }

    function testAddSignerViaSelfCall() external {
        uint256 epochBefore = wallet.getSignerEpoch();
        _execSelf(abi.encodeCall(MultiSigWallet.addSigner, (daveAddr)));
        assertTrue(wallet.isSigner(daveAddr));
        assertEq(wallet.getSignerCount(), 4);
        assertEq(wallet.getSignerEpoch(), epochBefore + 1);
    }

    function testRemoveSignerViaSelfCall() external {
        _execSelf(abi.encodeCall(MultiSigWallet.removeSigner, (carolAddr)));
        assertTrue(!wallet.isSigner(carolAddr));
        assertEq(wallet.getSignerCount(), 2);
    }

    function testRemoveSignerWouldBreakThresholdReverts() external {
        // signers=3, threshold=2 → removing one is OK; removing two would break.
        _execSelf(abi.encodeCall(MultiSigWallet.removeSigner, (carolAddr)));
        // now signers=2, threshold=2; another removal should revert inside executeTx
        vm.prank(aliceAddr);
        wallet.proposeTx(
            address(wallet), 0, uint64(block.timestamp + 1000), abi.encodeCall(MultiSigWallet.removeSigner, (bobAddr))
        );
        uint256 n = wallet.getNonce() - 1;
        vm.prank(bobAddr);
        wallet.confirmTx(n);
        vm.expectRevert(MultiSigWallet__FailedToExecuteTx.selector);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
    }

    function testReplaceSignerViaSelfCall() external {
        _execSelf(abi.encodeCall(MultiSigWallet.replaceSigner, (carolAddr, daveAddr)));
        assertTrue(!wallet.isSigner(carolAddr));
        assertTrue(wallet.isSigner(daveAddr));
        assertEq(wallet.getSignerCount(), 3);
    }

    function testSetRequiredConfirmationsViaSelfCall() external {
        _execSelf(abi.encodeCall(MultiSigWallet.setRequiredConfirmations, (3)));
        assertEq(wallet.getRequiredConfirmations(), 3);
    }

    function testSetRequiredConfirmationsAboveSignersReverts() external {
        vm.prank(aliceAddr);
        wallet.proposeTx(
            address(wallet),
            0,
            uint64(block.timestamp + 1000),
            abi.encodeCall(MultiSigWallet.setRequiredConfirmations, (4))
        );
        uint256 n = wallet.getNonce() - 1;
        vm.prank(bobAddr);
        wallet.confirmTx(n);
        vm.expectRevert(MultiSigWallet__FailedToExecuteTx.selector);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
    }

    function testDirectAdminCallRejected() external {
        vm.expectRevert(MultiSigWallet__OnlySelfCallable.selector);
        wallet.addSigner(daveAddr);

        vm.expectRevert(MultiSigWallet__OnlySelfCallable.selector);
        wallet.removeSigner(aliceAddr);

        vm.expectRevert(MultiSigWallet__OnlySelfCallable.selector);
        wallet.replaceSigner(aliceAddr, daveAddr);

        vm.expectRevert(MultiSigWallet__OnlySelfCallable.selector);
        wallet.setRequiredConfirmations(1);
    }

    function testAddExistingSignerReverts() external {
        vm.prank(aliceAddr);
        wallet.proposeTx(
            address(wallet), 0, uint64(block.timestamp + 1000), abi.encodeCall(MultiSigWallet.addSigner, (aliceAddr))
        );
        uint256 n = wallet.getNonce() - 1;
        vm.prank(bobAddr);
        wallet.confirmTx(n);
        vm.expectRevert(MultiSigWallet__FailedToExecuteTx.selector);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
    }

    function testRemoveUnknownSignerReverts() external {
        vm.prank(aliceAddr);
        wallet.proposeTx(
            address(wallet), 0, uint64(block.timestamp + 1000), abi.encodeCall(MultiSigWallet.removeSigner, (daveAddr))
        );
        uint256 n = wallet.getNonce() - 1;
        vm.prank(bobAddr);
        wallet.confirmTx(n);
        vm.expectRevert(MultiSigWallet__FailedToExecuteTx.selector);
        vm.prank(aliceAddr);
        wallet.executeTx(n);
    }

    function testPendingTxStaleAfterAdminChange() external {
        vm.prank(aliceAddr);
        wallet.proposeTx(address(receiver), 0, uint64(block.timestamp + 5000), bytes("pending"));
        uint256 pendingNonce = wallet.getNonce() - 1;

        // Run an admin self-call which bumps the epoch.
        _execSelf(abi.encodeCall(MultiSigWallet.addSigner, (daveAddr)));

        // confirm/execute/revoke/cancel on the stale tx should all revert with StaleEpoch
        vm.prank(bobAddr);
        vm.expectRevert(MultiSigWallet__StaleEpoch.selector);
        wallet.confirmTx(pendingNonce);

        vm.prank(aliceAddr);
        vm.expectRevert(MultiSigWallet__StaleEpoch.selector);
        wallet.executeTx(pendingNonce);

        vm.prank(aliceAddr);
        vm.expectRevert(MultiSigWallet__StaleEpoch.selector);
        wallet.revokeTx(pendingNonce);

        vm.prank(aliceAddr);
        vm.expectRevert(MultiSigWallet__StaleEpoch.selector);
        wallet.cancelTx(pendingNonce);
    }
}
