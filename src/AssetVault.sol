// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {IToken} from "./interfaces/IToken.sol";
import {IOFT, SendParam, MessagingFee} from "./interfaces/IOFT.sol";
// import {console} from "forge-std/console.sol";

contract AssetVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    struct UnderlyingToken {
        uint8 decimals;
        address lpToken;
        address bridge;
        uint256 minDepositAmount;
        uint256 minWithdrawAmount;
    }
    struct WithdrawalRequest {
        bool isCompleted;
        address requester;
        address receiver;
        address requestToken;
        uint32 timestamp;
        uint256 lpAmount;
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
    event TokenAdded(address token, address lpToken, address bridge);
    event TokenRemoved(address token);
    event SetDepositPause(address token, bool paused);
    event SetWithdrawPause(address token, bool paused);
    event SetWhitelistMode(address token, bool whitelistMode);
    event SetWhitelist(address token, address user, bool allowed);
    event SetRedeemWaitPeriod(uint32 redeemWaitPeriod);
    event SetGoatSafeAddress(address newAddress);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE"); // TODO: more roles?
    uint32 public immutable eid; // Layer Zero destination endpoint id

    // bytes32 format of token receiving address on Goat network
    bytes32 public goatSafeAddress;

    address[] public underlyingTokenList;
    mapping(address => UnderlyingToken) public underlyingTokens;
    mapping(address lpToken => address underlyingToken)
        public lpToUnderlyingTokens;

    mapping(uint256 id => WithdrawalRequest) public withdrawalRequests;
    uint32 public redeemWaitPeriod; // wait time before the withdrawal can be processed
    uint64 public withdrawalCounter; // next id for withdrawal, start from 1
    uint64 public processedWithdrawalCounter; // the index of processed withdrawal requests

    mapping(address => bool) public depositPaused;
    mapping(address => bool) public withdrawPaused;

    mapping(address => bool) public whitelistMode;
    mapping(address => mapping(address => bool)) public depositWhitelist;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    function initialize(address _goatSafeAddress) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
        withdrawalCounter = 1;
    }

    // return all underlying tokens
    function getUnderlyings() external view returns (address[] memory) {
        return underlyingTokenList;
    }

    // generate the `SendParam` used for bridging
    function generateSendParam(
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

    // get required fee for deposit
    function getFee(
        address _token,
        uint256 _amount
    ) public view returns (MessagingFee memory) {
        UnderlyingToken memory tokenInfo = underlyingTokens[_token];
        return
            IOFT(tokenInfo.bridge).quoteSend(generateSendParam(_amount), false);
    }

    // deposit `_token` to Goat network
    // @NOTE: must provide bridging fee through msg.value
    function deposit(
        address _token,
        uint256 _amount, // @NOTE: has to take into account dust
        MessagingFee memory _fee
    ) external payable {
        UnderlyingToken memory tokenInfo = underlyingTokens[_token];
        require(tokenInfo.lpToken != address(0), "Invalid token");
        require(!depositPaused[_token], "Deposit paused");
        require(_amount >= tokenInfo.minDepositAmount, "Invalid amount");
        require(
            !whitelistMode[_token] || depositWhitelist[_token][msg.sender],
            "Not whitelisted"
        );

        IToken(_token).transferFrom(msg.sender, address(this), _amount);

        IOFT(tokenInfo.bridge).send{value: msg.value}(
            generateSendParam(_amount),
            _fee,
            msg.sender
        );

        uint256 mintAmount = _amount * 10 ** (18 - tokenInfo.decimals);
        IToken(tokenInfo.lpToken).mint(msg.sender, mintAmount);

        emit Deposit(msg.sender, _token, _amount, mintAmount);
    }

    // request a withdrawal
    function requestWithdraw(
        address _requestToken,
        address _receiver,
        uint256 _lpAmount
    ) external returns (uint256 id) {
        require(
            underlyingTokens[_requestToken].lpToken != address(0),
            "Invalid token"
        );
        require(_receiver != address(0), "Zero address");
        require(
            _lpAmount >= underlyingTokens[_requestToken].minWithdrawAmount,
            "Invalid amount"
        );
        require(!withdrawPaused[_requestToken], "Paused");

        IToken(underlyingTokens[_requestToken].lpToken).transferFrom(
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
            timestamp: uint32(block.timestamp),
            lpAmount: _lpAmount
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
    function cancelWithdrawal(uint64 _id) external {
        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[_id];
        require(!withdrawalRequest.isCompleted, "Already completed");
        address requester = withdrawalRequest.requester;
        require(msg.sender == requester, "Wrong requester");

        IToken(underlyingTokens[withdrawalRequest.requestToken].lpToken)
            .transfer(requester, withdrawalRequest.lpAmount);

        delete withdrawalRequests[_id];
        emit WithdrawalCancelled(
            requester,
            withdrawalRequest.requestToken, // TODO: check this value
            _id,
            withdrawalRequest.lpAmount
        );
    }

    // allow users to claim their requested withdrawals to `_id`th withdrawal
    function processUntil(uint64 _id) external onlyRole(ADMIN_ROLE) {
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
    function claim(uint64 _id) external nonReentrant {
        require(_id <= processedWithdrawalCounter, "Not processed");
        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[_id];
        require(!withdrawalRequest.isCompleted, "Already completed");

        address requester = withdrawalRequest.requester;
        require(msg.sender == requester, "Wrong requester");
        withdrawalRequests[_id].isCompleted = true;

        uint256 lpAmount = withdrawalRequest.lpAmount;
        address requestToken = withdrawalRequest.requestToken;
        require(
            lpAmount >= IToken(requestToken).balanceOf(address(this)),
            "Insufficient tokens"
        );
        address receiver = withdrawalRequest.receiver;

        IToken(underlyingTokens[requestToken].lpToken).burn(
            address(this),
            lpAmount
        );
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
        address _bridge,
        uint256 _minDepositAmount,
        uint256 _minWithdrawAmount
    ) external onlyRole(ADMIN_ROLE) {
        require(_token != address(0), "Invalid token");
        require(
            lpToUnderlyingTokens[_lpToken] == address(0),
            "Existing LP token"
        );
        require(underlyingTokens[_token].decimals == 0, "Token exists");

        uint8 decimals = IToken(_token).decimals();
        require(decimals <= 18, "Invalid decimals");

        // Set max allowance for Layer Zero bridge
        IToken(_token).approve(_bridge, type(uint256).max);

        // underlying token setup
        underlyingTokenList.push(_token);
        underlyingTokens[_token] = UnderlyingToken({
            decimals: decimals,
            lpToken: _lpToken,
            bridge: _bridge,
            minDepositAmount: _minDepositAmount,
            minWithdrawAmount: _minWithdrawAmount
        });
        lpToUnderlyingTokens[_lpToken] = _token;

        emit TokenAdded(_token, _lpToken, _bridge);
    }

    // remove an added underlying token
    function removeUnderlyingToken(
        address _token
    ) external onlyRole(ADMIN_ROLE) {
        address lpToken = underlyingTokens[_token].lpToken;
        require(lpToken != address(0), "Token does not exist");
        require(
            IToken(_token).balanceOf(address(this)) == 0,
            "Non-empty token"
        );
        require(
            IToken(lpToken).balanceOf(address(this)) == 0,
            "Non-empty LP token"
        );

        // remove underlying token from list
        address[] memory tokens = underlyingTokenList;
        uint256 length = tokens.length;
        for (uint8 i; i < length; i++) {
            if (tokens[i] == _token) {
                underlyingTokenList[i] = underlyingTokenList[length - 1];
                underlyingTokenList.pop();
                break;
            }
        }
        delete lpToUnderlyingTokens[lpToken];
        delete underlyingTokens[_token];

        emit TokenRemoved(_token);
    }

    // set deposit pause state
    function setDepositPause(
        address _token,
        bool _pause
    ) external onlyRole(ADMIN_ROLE) {
        depositPaused[_token] = _pause;
        emit SetDepositPause(_token, _pause);
    }

    // set withdraw pause state
    function setWithdrawPause(
        address _token,
        bool _pause
    ) external onlyRole(ADMIN_ROLE) {
        withdrawPaused[_token] = _pause;
        emit SetWithdrawPause(_token, _pause);
    }

    // set token whitelist mode
    function setWhitelistMode(
        address _token,
        bool _applyWhitelist
    ) external onlyRole(ADMIN_ROLE) {
        whitelistMode[_token] = _applyWhitelist;
        emit SetWhitelistMode(_token, _applyWhitelist);
    }

    // set address whitelist
    function setWhitelistAddress(
        address _token,
        address _user,
        bool _allowed
    ) external onlyRole(ADMIN_ROLE) {
        depositWhitelist[_token][_user] = _allowed;
        emit SetWhitelist(_token, _user, _allowed);
    }

    // set redeem wait period
    function setRedeemWaitPeriod(
        uint32 _redeemWaitPeriod
    ) external onlyRole(ADMIN_ROLE) {
        redeemWaitPeriod = _redeemWaitPeriod;
        emit SetRedeemWaitPeriod(_redeemWaitPeriod);
    }

    // set token receiving address on Goat
    function setGoatSafeAddress(
        address _goatSafeAddress
    ) external onlyRole(ADMIN_ROLE) {
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
        emit SetGoatSafeAddress(_goatSafeAddress);
    }
}
