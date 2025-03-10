// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// LPToken is a simple ERC20 token with additional features for the AssetVault
contract LPToken is AccessControl, ERC20 {
    event SetTransferSwitch(bool transferSwitch);
    event SetVaultAddress(address vaultAddress);

    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");

    address public vaultAddress;
    bool public transferSwitch;

    constructor(
        address _admin,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(MINT_ROLE, msg.sender);
        vaultAddress = msg.sender;
        transferSwitch = false;
    }

    // Set the transfer switch to pause or unpause all transfers
    function setTransferSwitch(
        bool _transferSwitch
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transferSwitch = _transferSwitch;
        emit SetTransferSwitch(_transferSwitch);
    }

    // Set the transfer whitelist for a specific address
    function setVaultAddress(
        address _address
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vaultAddress = _address;
        emit SetVaultAddress(_address);
    }

    // Mint and burn functions for the AssetVault
    function mint(address _to, uint256 _amount) external onlyRole(MINT_ROLE) {
        _mint(_to, _amount);
    }

    function burn(address _from, uint256 _amount) external onlyRole(MINT_ROLE) {
        _burn(_from, _amount);
    }

    // Override the transfer and transferFrom functions to check the transfer switch
    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        require(
            transferSwitch || msg.sender == vaultAddress,
            "LPToken: transfer is paused"
        );
        return super.transfer(to, value);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        require(
            transferSwitch || msg.sender == vaultAddress,
            "LPToken: transfer is paused"
        );
        return super.transferFrom(from, to, value);
    }
}
