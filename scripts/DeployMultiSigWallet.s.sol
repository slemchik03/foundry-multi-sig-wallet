// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MultiSigWallet} from "../src/MultiSigWallet.sol";
import {Script, console} from "forge-std/Script.sol";

contract DeployMultiSigWallet is Script {
    function run() public {
        vm.startBroadcast();
        address[] memory signers = new address[](2);
        signers[0] = address(0x1234567890123456789012345678901234567890);
        signers[1] = address(0x0987654321098765432109876543210987654321);
        MultiSigWallet newMultiSigWallet = new MultiSigWallet(signers, 2);
        console.log("MultiSigWallet deployed at:", address(newMultiSigWallet));
        vm.stopBroadcast();
    }
}
