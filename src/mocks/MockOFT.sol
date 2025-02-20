// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IOFT, SendParam, MessagingFee, MessagingReceipt, OFTReceipt} from "../interfaces/IOFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockOFT {
    address public immutable token;

    constructor(address _token) {
        token = _token;
    }

    function quoteSend(
        SendParam calldata, //_sendParam,
        bool // _payInLzToken
    ) external pure returns (MessagingFee memory fee) {
        fee.nativeFee = 0.1 ether;
    }

    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata, // _fee,
        address // _refundAddress
    ) external payable returns (MessagingReceipt memory, OFTReceipt memory) {
        IERC20(token).transferFrom(
            msg.sender,
            address(this),
            _sendParam.amountLD
        );
    }

    function bridgeOut(address _to, uint256 _amount) external {
        IERC20(token).transfer(_to, _amount);
    }
}
