// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

import {AssetVault} from "../src/AssetVault.sol";
import {LPToken} from "../src/LPToken.sol";
import {IOFT, SendParam, MessagingFee} from "../src/interfaces/IOFT.sol";

import {MockToken} from "../src/mocks/MockToken.sol";
import {MockOFT} from "../src/mocks/MockOFT.sol";

contract Deploy is Script {
    address deployer;

    address token;
    address oft;

    function setUp() public {
        token = vm.envAddress("TOKEN_ADDR");
        console.log("token addr: ", token);
        oft = vm.envAddress("OFT_ADDR");
        console.log("OFT addr: ", oft);
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.createWallet(deployerPrivateKey).addr;
        console.log("Deployer address: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        deploy();
    }

    function deploy() public {
        uint256 amount = 5000000000000;
        IOFT oftContract = IOFT(oft);
        AssetVault vault = AssetVault(
            address(0x30cae239C3354909045eADd059A31b6693E45181)
        );
        SendParam memory sendParam = vault.generateSendParam(token, amount);
        MessagingFee memory fee = oftContract.quoteSend(sendParam, false);
        console.log(fee.nativeFee, deployer.balance / fee.nativeFee);
        vault.deposit{value: fee.nativeFee}(token, amount, fee);
    }
}
