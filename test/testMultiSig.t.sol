// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {
    MultiSigWallet,
    MultiSigWallet__FailedToExecuteTx,
    Tx,
    MultiSigWallet__EmptySigners,
    MultiSigWallet__AlreadyConfirmed,
    MultiSigWallet__MoreConfirmationsThanSigners,
    MultiSigWallet__ShouldBeAtLeastOneConfirmation,
    MultiSigWallet_SignersShouldBeUnique,
    MultiSigWallet__InsufficientBalance,
    MultiSigWallet__InvalidDeadline,
    MultiSigWallet__InsufficientTxConfirmations
} from "../src/MultiSigWallet.sol";
import "forge-std/console.sol";

contract MultiSigWalletHarness is MultiSigWallet {
    constructor(address[] memory _signers, uint256 _requiredConfirmations)
        MultiSigWallet(_signers, _requiredConfirmations)
    {}

    function isUniqueHarness(address[] memory _signers) public pure returns (int256, int256) {
        return isUnique(_signers);
    }
}

contract ReceiverTestContract {
    receive() external payable {}

    fallback() external {}
}

contract BadReceiverTestContract {
    // not payable so any tx execution on it will fail
    fallback() external {}
}

contract MultiSigWalletTest is Test {
    MultiSigWalletHarness wallet;
    ReceiverTestContract receiver;

    address bobAddr = vm.addr(uint256(keccak256("bob")));
    address carolAddr = vm.addr(uint256(keccak256("carol")));
    address aliceAddr = vm.addr(uint256(keccak256("alice")));

    function proposeValidTx(bool autoApprove) internal returns (address proposer, uint256 nonce) {
        vm.prank(aliceAddr);

        // vm.expectEmit();
        wallet.proposeTx(address(receiver), 0, uint64(block.timestamp + 10000), bytes("Some extra text here!"));
        uint256 nonce = wallet.getNonce() - 1;
        if (autoApprove) {
            vm.startPrank(bobAddr);
            wallet.confirmTx(nonce);
            vm.stopPrank();
            vm.startPrank(carolAddr);
            wallet.confirmTx(nonce);
            vm.stopPrank();
        }
        return (aliceAddr, nonce);
    }

    function setUp() public {
        address[] memory signers = new address[](3);
        signers[0] = vm.addr(uint256(keccak256("alice")));
        signers[1] = vm.addr(uint256(keccak256("bob")));
        signers[2] = vm.addr(uint256(keccak256("carol")));

        wallet = new MultiSigWalletHarness(signers, 2);
        receiver = new ReceiverTestContract();
    }

    function testMultiSigWalletConstructor() public {
        // testing contract creating with double occured singers
        address[] memory noneDistinctSignersAddresses = new address[](2);
        // Test that constructing with duplicate signers reverts with the correct error
        noneDistinctSignersAddresses[0] = vm.addr(uint256(keccak256("alice")));
        noneDistinctSignersAddresses[1] = vm.addr(uint256(keccak256("alice")));
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet_SignersShouldBeUnique.selector, 0, 1));
        new MultiSigWallet(noneDistinctSignersAddresses, 1);

        // Test that constructing with more confirmations than signers reverts
        address[] memory signers = new address[](2);
        signers[0] = vm.addr(uint256(keccak256("alice")));
        signers[1] = vm.addr(uint256(keccak256("bob")));
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet__MoreConfirmationsThanSigners.selector, 3, 2));
        new MultiSigWallet(signers, 3);

        // // Test that constructing with zero signers reverts
        address[] memory emptySigners = new address[](0);
        vm.expectRevert(MultiSigWallet__EmptySigners.selector);
        new MultiSigWallet(emptySigners, 0);
    }

    function testIsUniqueAccounts() public view {
        address[] memory diffrentAccounts = new address[](3);
        diffrentAccounts[0] = aliceAddr;
        diffrentAccounts[1] = bobAddr;
        diffrentAccounts[2] = carolAddr;

        (int256 n1Dif, int256 n2Dif) = wallet.isUniqueHarness(diffrentAccounts);

        assertTrue(n1Dif == -1 && n2Dif == -1, "Should be true when accounts are different");

        (int256 n1, int256 n2) = wallet.isUniqueHarness(new address[](0));

        assertTrue(
            n1 == n2, // both -1
            "Should be true when list is empty or there is only one element"
        );

        address[] memory repeatedAccounts = new address[](2);
        repeatedAccounts[0] = vm.addr(uint256(keccak256("vadik")));
        repeatedAccounts[1] = vm.addr(uint256(keccak256("vadik")));

        (int256 n1Repeated, int256 n2Repeated) = wallet.isUniqueHarness(repeatedAccounts);

        assertTrue(n1Repeated != n2Repeated, "Accounts should be different!");
    }

    function testProposeTxWithIsufficientBalance() public {
        // MultiSigWallet wallet = new MultiSigWallet{value: 1 ether}();
        uint64 txValue = 1 ether;
        vm.expectRevert(
            abi.encodeWithSelector(MultiSigWallet__InsufficientBalance.selector, txValue, address(wallet).balance)
        );
        vm.prank(vm.addr(uint256(keccak256("alice"))));
        wallet.proposeTx(
            address(0x1), txValue, uint64(block.timestamp + 1000 * 10 ** 10), bytes(string("Hello world!"))
        );
    }

    function testProposeTxWithWrongDeadline() public {
        vm.warp(1000); // Set block time using vm
        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet__InvalidDeadline.selector));
        vm.prank(vm.addr(uint256(keccak256("alice"))));
        wallet.proposeTx(address(0x1), 0, uint64(block.timestamp - 500), bytes("Hello world!"));
    }

    function testProposeCorrectTx() public {
        vm.prank(aliceAddr);
        wallet.proposeTx(address(receiver), 0, uint64(block.timestamp + 10000), bytes("Some extra text here!"));
        bool hasConfirmed = wallet.hasConfirmed(
            wallet.getNonce() - 1, // - 1 to get the previous nonce
            aliceAddr
        );
        assertTrue(hasConfirmed);
        bool hasFalsyConfirmedStatus = wallet.hasConfirmed(
            wallet.getNonce() - 1,
            bobAddr // bobs account
        );
        // because bob hasn't confirmed yet
        assertTrue(!hasFalsyConfirmedStatus);
    }

    function testTxApproving() external {
        (address proposer, uint256 nonce) = proposeValidTx(true);

        assertTrue(wallet.hasConfirmed(nonce, carolAddr));
        assertTrue(wallet.hasConfirmed(nonce, bobAddr));
        assertTrue(wallet.hasConfirmed(nonce, aliceAddr));

        Tx memory transaction = wallet.getTransaction(nonce);
        console.log(transaction.confirmationsCount);
        assertTrue(transaction.confirmationsCount == 3);
        assertTrue(!transaction.executed);
    }

    function testValidTxExecution() external {
        (address proposer, uint256 nonce) = proposeValidTx(true);
        vm.startPrank(aliceAddr);
        wallet.executeTx(nonce);
        Tx memory executedTransaction = wallet.getTransaction(nonce);
        assertTrue(executedTransaction.executed);
    }

    function testRevertedToExecuteTx() external {
        (, bytes memory result) = address(wallet).call{value: 1 ether}("");
        BadReceiverTestContract badContractAddr = new BadReceiverTestContract();
        uint64 txValue = 0.9 ether;
        vm.prank(aliceAddr);
        wallet.proposeTx(
            address(badContractAddr), txValue, uint64(block.timestamp + 1000 * 10 ** 10), bytes(string("Hello world!"))
        );
        uint256 nonce = wallet.getNonce() - 1;

        vm.startPrank(bobAddr);
        wallet.confirmTx(nonce);
        vm.stopPrank();
        vm.startPrank(carolAddr);
        wallet.confirmTx(nonce);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(MultiSigWallet__FailedToExecuteTx.selector));

        vm.prank(aliceAddr);
        wallet.executeTx(nonce);
    }

    function testInsufficientTxConfirmations() external {
        (, uint256 nonce) = proposeValidTx(false);
        vm.startPrank(aliceAddr);
        vm.expectRevert(MultiSigWallet__InsufficientTxConfirmations.selector);
        wallet.executeTx(nonce);
        Tx memory executedTransaction = wallet.getTransaction(nonce);
        assertTrue(!executedTransaction.executed);
    }
}
