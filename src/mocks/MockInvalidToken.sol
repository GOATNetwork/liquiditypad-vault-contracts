// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockInvalidToken is ERC20 {
    constructor() ERC20("Mock Invalid Token", "MIT") {}

    function decimals() public pure override returns (uint8) {
        return 20;
    }
}
