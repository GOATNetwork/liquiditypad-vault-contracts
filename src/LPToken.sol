// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract LPToken is AccessControl, ERC20 {
    bytes32 public constant MINT_ROLE = keccak256("MINT_ROLE");

    constructor(
        string calldata _name,
        string calldata _symbol
    ) ERC20(_name, _symbol) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address _to, uint256 _amount) external onlyRole(ADMIN_ROLE) {
        _mint(_to, _amount);
    }
}
