// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IToken {
    // standard ERC20 getter
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);

    // standard ERC20 methods
    function approve(address spender, uint256 value) external returns (bool);
    function transfer(address to, uint256 value) external returns (bool);
    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool);

    // custom methods
    function mint(address _to, uint256 _amount) external;
    function burn(address _to, uint256 _amount) external;
}
