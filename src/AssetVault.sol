// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IToken} from "./interfaces/IToken.sol";
import {IOFT, SendParam, MessagingFee} from "./interfaces/IOFT.sol";
// import {console} from "forge-std/console.sol";

contract AssetVault is AccessControl, ReentrancyGuard {
    struct WithdrawalRequest {
        bool isCompleted;
        address requester;
        address receiver;
        address requestToken;
        uint256 lpAmount;
        uint256 timestamp;
    }
    event Deposit(
        address indexed account,
        address indexed token,
        uint256 tokenAmount,
        uint256 lpAmount
    );
    event WithdrawalRequested(
        address indexed requester,
        address indexed receiver,
        address indexed requestToken,
        uint256 id,
        uint256 lpAmount
    );
    event WithdrawalCancelled(
        address indexed requester,
        address indexed requestToken,
        uint256 id,
        uint256 lpAmount
    );
    event WithdrawalProcessed(uint256 id);
    event Claim(
        uint256 id,
        address indexed requester,
        address indexed receiver,
        address indexed requestToken,
        uint256 lpAmount
    );
    event TokenAdded(address token);
    event TokenRemoved(address token);
    event SetDepositPause(address token, bool paused);
    event SetWithdrawPause(address token, bool paused);
    event SetWhitelistMode(address token, bool whitelistMode);
    event SetWhitelist(address token, address user, bool allowed);
    event SetRedeemWaitPeriod(uint256 redeemWaitPeriod);
    event SetGoatSafeAddress(address newAddress);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE"); // TODO: more roles?
    uint32 public immutable eid;

    bytes32 public goatSafeAddress;
    address[] public underlyingTokens;

    mapping(uint256 id => WithdrawalRequest) public withdrawalRequests;

    mapping(address => bool) public isUnderlyingToken;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => address lpToken) public lpTokens;
    mapping(address => address lzBridge) public tokenBridge;

    uint256 public redeemWaitPeriod;
    uint256 public withdrawalCounter;
    uint256 public processedWithdrawalCounter;

    mapping(address => bool) public depositPaused;
    mapping(address => bool) public withdrawPaused;

    mapping(address => bool) public whitelistMode;
    mapping(address => mapping(address => bool)) public depositWhitelist;

    constructor(uint32 _eid, address _goatSafeAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        eid = _eid;
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
        withdrawalCounter = 1;
    }

    function deposit(
        address _token,
        uint256 _amount, // NOTE: dust, has to take into account token decimals
        MessagingFee memory _fee
    ) external payable returns (uint256 mintAmount) {
        require(isUnderlyingToken[_token], "Invalid token");
        require(!depositPaused[_token], "Deposit paused");
        require(_amount > 0, "Zero amount");
        require(
            whitelistMode[_token] || depositWhitelist[_token][msg.sender],
            "Not whitelisted"
        );

        IToken(_token).transferFrom(msg.sender, address(this), _amount);

        IOFT(tokenBridge[_token]).send{value: msg.value}(
            generateSendParam(_token, _amount),
            _fee,
            msg.sender
        );

        mintAmount = _amount * 10 ** (18 - tokenDecimals[_token]);
        IToken(lpTokens[_token]).mint(msg.sender, mintAmount);

        emit Deposit(msg.sender, _token, _amount, mintAmount);
    }

    // request a withdrawal
    function requestWithdraw(
        address _requestToken,
        address _receiver,
        uint256 _lpAmount
    ) external returns (uint256 id) {
        require(_receiver != address(0), "Zero address");
        require(_lpAmount > 0, "Zero amount");
        require(isUnderlyingToken[_requestToken], "Invalid token");
        require(!withdrawPaused[_requestToken], "Paused");

        IToken(lpTokens[_requestToken]).transferFrom(
            msg.sender,
            address(this),
            _lpAmount
        );

        id = withdrawalCounter++;
        withdrawalRequests[id] = WithdrawalRequest({
            isCompleted: false,
            requester: msg.sender,
            receiver: _receiver,
            requestToken: _requestToken,
            lpAmount: _lpAmount,
            timestamp: block.timestamp
        });

        emit WithdrawalRequested(
            msg.sender,
            _receiver,
            _requestToken,
            id,
            _lpAmount
        );
    }

    // cancel the requested withdrawal
    function cancelWithdrawal(uint256 _id) external {
        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[_id];
        require(!withdrawalRequest.isCompleted, "Already completed");
        address requester = withdrawalRequest.requester;
        require(msg.sender == requester, "Wrong requester");

        uint256 lpAmount = withdrawalRequest.lpAmount;
        IToken(lpTokens[withdrawalRequest.requestToken]).transfer(
            requester,
            lpAmount
        );

        delete withdrawalRequests[_id];
        emit WithdrawalCancelled(
            requester,
            withdrawalRequest.requestToken, // TODO: check this value
            _id,
            lpAmount
        );
    }

    // allow users to claim their requested withdrawals to `_id`th withdrawal
    function processUntil(uint256 _id) external onlyRole(ADMIN_ROLE) {
        require(
            _id > processedWithdrawalCounter && _id < withdrawalCounter,
            "Invalid index"
        );
        require(
            withdrawalRequests[_id].timestamp + redeemWaitPeriod <=
                block.timestamp,
            "Time not reached"
        );
        processedWithdrawalCounter = _id;
        emit WithdrawalProcessed(_id);
    }

    // claim processed withdrawal request
    function claim(uint256 _id) external {
        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[_id];
        require(!withdrawalRequest.isCompleted, "Already completed");
        address requester = withdrawalRequest.requester;
        require(msg.sender == requester, "Wrong requester");
        withdrawalRequests[_id].isCompleted = true;

        address requestToken = withdrawalRequest.requestToken;
        address receiver = withdrawalRequest.receiver;
        uint256 lpAmount = withdrawalRequest.lpAmount;

        IToken(lpTokens[requestToken]).burn(address(this), lpAmount);
        IToken(requestToken).transfer(receiver, lpAmount);
        emit Claim(_id, requester, receiver, requestToken, lpAmount);
    }

    /**
     * @dev add an underlying token
     * @param _token The underlying token
     * @param _lpToken The matching LP token
     * @param _bridge The OFT/adapter for the underlying token
     */
    function addUnderlyingToken(
        address _token,
        address _lpToken,
        address _bridge
    ) external onlyRole(ADMIN_ROLE) {
        require(_token != address(0), "Invalid token");
        require(!isUnderlyingToken[_token], "Token already added");

        uint8 decimals = IToken(_token).decimals();
        require(decimals <= 18, "Invalid decimals");

        // Layer Zero bridge setup
        tokenBridge[_token] = _bridge;
        IToken(_token).approve(_bridge, type(uint256).max);

        // underlying token setup
        lpTokens[_token] = _lpToken;
        isUnderlyingToken[_token] = true;
        tokenDecimals[_token] = decimals;
        underlyingTokens.push(_token);

        emit TokenAdded(_token);
    }

    // remove an added underlying token
    function removeUnderlyingToken(
        address _token
    ) external onlyRole(ADMIN_ROLE) {
        require(isUnderlyingToken[_token], "Invalid token");
        require(
            IToken(_token).balanceOf(address(this)) == 0,
            "Non-empty token"
        );

        address[] memory tokens = underlyingTokens;

        uint256 length = tokens.length;
        uint256 i;
        for (i; i < length; i++) {
            if (tokens[i] == _token) {
                underlyingTokens[i] = underlyingTokens[length - 1];
                underlyingTokens.pop();
                break;
            }
        }
        isUnderlyingToken[_token] = false;

        emit TokenRemoved(_token);
    }

    function setDepositPause(
        address _token,
        bool _pause
    ) external onlyRole(ADMIN_ROLE) {
        depositPaused[_token] = _pause;
        emit SetDepositPause(_token, _pause);
    }

    function setWithdrawPause(
        address _token,
        bool _pause
    ) external onlyRole(ADMIN_ROLE) {
        withdrawPaused[_token] = _pause;
        emit SetWithdrawPause(_token, _pause);
    }

    function setWhitelistMode(
        address _token,
        bool _applyWhitelist
    ) external onlyRole(ADMIN_ROLE) {
        whitelistMode[_token] = _applyWhitelist;
        emit SetWhitelistMode(_token, _applyWhitelist);
    }

    function setWhitelistAddress(
        address _token,
        address _minter,
        bool _allowed
    ) external onlyRole(ADMIN_ROLE) {
        depositWhitelist[_token][_minter] = _allowed;
        emit SetWhitelist(_token, _minter, _allowed);
    }

    function setRedeemWaitPeriod(
        uint256 _redeemWaitPeriod
    ) external onlyRole(ADMIN_ROLE) {
        redeemWaitPeriod = _redeemWaitPeriod;
        emit SetRedeemWaitPeriod(_redeemWaitPeriod);
    }

    function setGoatSafeAddress(
        address _goatSafeAddress
    ) external onlyRole(ADMIN_ROLE) {
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
        emit SetGoatSafeAddress(_goatSafeAddress);
    }

    function getUnderlyings()
        external
        view
        returns (address[] memory underlyings)
    {
        return underlyingTokens;
    }

    // generate the `SendParam` used for bridging
    function generateSendParam(
        address _token,
        uint256 _amount
    ) public view returns (SendParam memory sendParam) {
        sendParam = SendParam({
            dstEid: eid,
            to: goatSafeAddress,
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }
}
