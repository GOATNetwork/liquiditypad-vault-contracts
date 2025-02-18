// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LPToken is AccessControl, ERC20 {
    event SetTransferSwitch(bool _transferSwitch);

    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");

    bool public transferSwitch;

    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function setTransferSwitch(
        bool _transferSwitch
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        transferSwitch = _transferSwitch;
        emit SetTransferSwitch(_transferSwitch);
    }

    function mint(address _to, uint256 _amount) external onlyRole(MINT_ROLE) {
        _mint(_to, _amount);
    }

    function burn(address _to, uint256 _amount) external onlyRole(MINT_ROLE) {
        _burn(_to, _amount);
    }

    function transfer(
        address to,
        uint256 value
    ) public override returns (bool) {
        require(transferSwitch, "LPToken: transfer is paused");
        return super.transfer(to, value);
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) public override returns (bool) {
        require(transferSwitch, "LPToken: transfer is paused");
        return super.transferFrom(from, to, value);
    }
}
