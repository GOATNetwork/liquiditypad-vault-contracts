// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

import {AssetVault} from "../src/AssetVault.sol";
import {LPToken} from "../src/LPToken.sol";
import {MessagingFee} from "../src/interfaces/IOFT.sol";

import {MockToken} from "../src/mocks/MockToken.sol";
import {MockOFT} from "../src/mocks/MockOFT.sol";

contract Deploy is Script {
    uint256 public constant MIN_AMOUNT = 1;

    address deployer;

    address token;
    address oft;
    uint32 eid;

    function setUp() public {
        token = vm.envAddress("TOKEN_ADDR");
        console.log("token addr: ", token);
        oft = vm.envAddress("OFT_ADDR");
        console.log("OFT addr: ", oft);
        eid = uint32(vm.envUint("ENDPOINT_ID"));
        console.log("Eid: ", eid);
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.createWallet(deployerPrivateKey).addr;
        console.log("Deployer address: ", deployer);

        vm.startBroadcast(deployerPrivateKey);

        deploy();
    }

    function deploy() public {
        AssetVault vault = new AssetVault(eid);
        vault.initialize(deployer, 0);
        vault.grantRole(vault.ADMIN_ROLE(), deployer);

        vault.addUnderlyingToken(token, oft, MIN_AMOUNT, MIN_AMOUNT);

        console.log("Vault: ", address(vault));
    }
}
