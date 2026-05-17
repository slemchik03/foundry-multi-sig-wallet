// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiSigWallet} from "../src/MultiSigWallet.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployMultiSigWallet is Script {
    address internal constant i_firstSigner =
        0x1234567890123456789012345678901234567890;
    address internal constant i_secondSigner =
        0x0987654321098765432109876543210987654321;

    function run() public {
        vm.startBroadcast();
        address[] memory signers = new address[](2);
        signers[0] = i_firstSigner;
        signers[1] = i_secondSigner;
        MultiSigWallet newMultiSigWallet = new MultiSigWallet(signers, 2);
        console.log("MultiSigWallet deployed at:", address(newMultiSigWallet));
        vm.stopBroadcast();
    }
}
