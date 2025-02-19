// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.27;

import {Script, console} from "forge-std/Script.sol";

import {AssetVault} from "../src/AssetVault.sol";
import {LPToken} from "../src/LPToken.sol";
import {MessagingFee} from "../src/interfaces/IOFT.sol";

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
        AssetVault vault = new AssetVault(deployer);
        vault.grantRole(vault.ADMIN_ROLE(), deployer);

        LPToken lpToken = new LPToken("LP Token", "LPT");
        lpToken.setTransferWhitelist(address(vault), true);
        lpToken.grantRole(lpToken.MINT_ROLE(), address(vault));

        vault.addUnderlyingToken(token, address(lpToken), oft, 40356);
        vault.setWhitelistMode(token, true);

        console.log("Vault: ", address(vault));
        console.log("LP token: ", address(lpToken));
    }
}
