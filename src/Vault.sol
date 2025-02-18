// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IToken} from "./interfaces/IToken.sol";
import {IOFT, SendParam, MessagingFee} from "./interfaces/IOFT.sol";

contract AssetVault is AccessControl, ReentrancyGuard {
    struct WithdrawalRequest {
        address requester;
        address receiver;
        address requestToken;
        uint256 id;
        uint256 lpAmount;
        uint256 timestamp;
    }
    event Deposit(
        address indexed account,
        address indexed token,
        uint256 tokenAmount,
        uint256 lpAmount
    );
    event Deposit(
        address indexed account,
        address[] tokens,
        uint256[] tokenAmounts,
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
    event WithdrawalProcessed(
        address indexed requester,
        address indexed receiver,
        address indexed requestToken,
        uint256 lpAmount
    );
    event WithdrawFromVault(
        address indexed curator,
        address indexed token,
        uint256 amount
    );
    event RepayToVault(
        address indexed curator,
        address indexed token,
        uint256 amount
    );
    event TokenAdded(address token);
    event TokenRemoved(address token);
    event SetDepositPause(address token, bool paused);
    event SetWithdrawPause(address token, bool paused);
    event SetWhitelistMode(address token, bool whitelistMode);
    event SetWhitelist(address token, address user, bool allowed);

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE"); // TODO: more roles?

    bytes32 public immutable goatSafeAddress; // TODO: is this mutable?

    address[] public underlyingTokens;

    WithdrawalRequest[] public withdrawalRequests;

    mapping(address => bool) public isUnderlyingToken;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => address lpToken) public lpTokens;
    mapping(address => address lzBridge) public tokenBridge;
    mapping(address => uint32 destEid) public bridgeEid;

    uint256 public depositFeeRate;
    uint256 public withdrawFeeRate;

    mapping(uint256 => uint256) public idToWithdrawalRequest;

    uint256 public withdrawalCounter;

    mapping(address => bool) public depositPaused;
    mapping(address => bool) public withdrawPaused;

    mapping(address => bool) public whitelistMode;
    mapping(address => mapping(address => bool)) public depositWhitelist;

    constructor(address _goatSafeAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
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
            _generateSendParam(_token, _amount),
            _fee,
            msg.sender
        );

        mintAmount = _amount * 10 ** (18 - tokenDecimals[_token]);
        IToken(lpTokens[_token]).mint(msg.sender, mintAmount);

        emit Deposit(msg.sender, _token, _amount, mintAmount);
    }

    function _generateSendParam(
        address _token,
        uint256 _amount
    ) internal view returns (SendParam memory sendParam) {
        sendParam = SendParam({
            dstEid: bridgeEid[_token],
            to: goatSafeAddress,
            amountLD: _amount,
            minAmountLD: _amount,
            extraOptions: "",
            composeMsg: "",
            oftCmd: ""
        });
    }

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
        withdrawalRequests.push(
            WithdrawalRequest({
                requester: msg.sender,
                receiver: _receiver,
                requestToken: _requestToken,
                id: id,
                lpAmount: _lpAmount,
                timestamp: block.timestamp
            })
        );
        idToWithdrawalRequest[id] = withdrawalRequests.length - 1;

        emit WithdrawalRequested(
            msg.sender,
            _receiver,
            _requestToken,
            id,
            _lpAmount
        );
    }

    function cancelWithdrawal(uint256 _id) external {
        uint256 index = idToWithdrawalRequest[_id];
        uint256 length = withdrawalRequests.length;
        require(
            index < length && _id < withdrawalCounter,
            "Array index out of bounds"
        );

        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[index];
        address requester = withdrawalRequest.requester;
        require(msg.sender == requester, "Wrong requester");

        idToWithdrawalRequest[_id] = type(uint256).max;
        idToWithdrawalRequest[withdrawalRequests[length - 1].id] = index;
        withdrawalRequests[index] = withdrawalRequests[length - 1];
        withdrawalRequests.pop();

        uint256 lpAmount = withdrawalRequest.lpAmount;

        IToken(lpTokens[withdrawalRequest.requestToken]).transfer(
            requester,
            lpAmount
        );

        emit WithdrawalCancelled(
            requester,
            withdrawalRequest.requestToken,
            _id,
            lpAmount
        );
    }

    function processWithdrawal(
        uint256 _id
    )
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
        returns (address requestToken, uint256 lpAmount)
    {
        uint256 index = idToWithdrawalRequest[_id];
        uint256 length = withdrawalRequests.length;
        require(
            index < length && _id < withdrawalCounter,
            "Array index out of bounds"
        );

        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[index];

        require(_id == withdrawalRequest.id, "Invalid id");

        (requestToken, lpAmount) = _finalizeWithdraw(withdrawalRequest);

        idToWithdrawalRequest[withdrawalRequests[length - 1].id] = index;
        idToWithdrawalRequest[_id] = type(uint256).max;

        withdrawalRequests[index] = withdrawalRequests[length - 1];
        withdrawalRequests.pop();
    }

    function processAllWithdrawal() external nonReentrant onlyRole(ADMIN_ROLE) {
        uint256 length = withdrawalRequests.length;
        require(length > 0, "Empty array");

        uint256 i;
        for (i; i < length; i++) {
            WithdrawalRequest memory withdrawalRequest = withdrawalRequests[i];

            _finalizeWithdraw(withdrawalRequest);

            idToWithdrawalRequest[withdrawalRequest.id] = type(uint256).max;
        }

        delete withdrawalRequests;
    }

    function _finalizeWithdraw(
        WithdrawalRequest memory _withdrawalRequest
    ) internal returns (address requestToken, uint256 lpAmount) {
        requestToken = _withdrawalRequest.requestToken;

        lpAmount = _withdrawalRequest.lpAmount;

        address requester = _withdrawalRequest.requester;
        address receiver = _withdrawalRequest.receiver;

        IToken(lpTokens[requestToken]).burn(address(this), lpAmount);

        IToken(requestToken).transfer(receiver, lpAmount);
        emit WithdrawalProcessed(requester, receiver, requestToken, lpAmount);
    }

    function withdrawFromVault(
        address[] memory _tokens,
        uint256[] memory _amounts
    ) external onlyRole(ADMIN_ROLE) {
        uint256 length = _tokens.length;
        require(length > 0 && length == _amounts.length, "Invalid inputs");

        uint256 i;
        for (i; i < length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];
            IToken(token).transfer(msg.sender, amount);

            emit WithdrawFromVault(msg.sender, token, amount);
        }
    }

    function repayToVault(
        address[] memory _tokens,
        uint256[] memory _amounts
    ) external onlyRole(ADMIN_ROLE) {
        uint256 length = _tokens.length;

        require(length > 0 && length == _amounts.length, "Invalid inputs");

        for (uint8 i; i < length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];
            IToken(token).transferFrom(msg.sender, address(this), amount);

            emit RepayToVault(msg.sender, token, amount);
        }
    }

    function addUnderlyingToken(
        address _token,
        address _lpToken,
        address _bridge,
        uint32 _eid
    ) external onlyRole(ADMIN_ROLE) {
        require(_token != address(0), "Invalid token");
        require(!isUnderlyingToken[_token], "Token already added");

        uint8 decimals = IToken(_token).decimals();
        require(decimals <= 18, "Invalid decimals");

        // Layer Zero bridge setup
        tokenBridge[_token] = _bridge;
        bridgeEid[_token] = _eid;
        IToken(_token).approve(_bridge, type(uint256).max);

        // underlying token setup
        lpTokens[_token] = _lpToken;
        isUnderlyingToken[_token] = true;
        tokenDecimals[_token] = decimals;
        underlyingTokens.push(_token);

        emit TokenAdded(_token);
    }

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
        delete tokenDecimals[_token];

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

    function getUnderlyings()
        external
        view
        returns (address[] memory underlyings)
    {
        return underlyingTokens;
    }

    function getRequestsLength() external view returns (uint256 length) {
        length = withdrawalRequests.length;
    }

    function getRequestWithdrawals()
        external
        view
        returns (WithdrawalRequest[] memory allWithdrawalRequests)
    {
        return withdrawalRequests;
    }
}
