// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TransferHelper} from "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";

import {IToken} from "./interfaces/IToken.sol";
import {IOFT} from "./interfaces/IOFT.sol";

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

    address public immutable lpToken;
    address public immutable goatSafeAddress; // TODO: is this mutable?

    address[] public underlyingTokens;

    WithdrawalRequest[] public withdrawalRequests;

    mapping(address => bool) public isUnderlyingToken;
    mapping(address => uint8) public tokenDecimals;
    mapping(address => address) public tokenBridge;

    uint256 public depositFeeRate;
    uint256 public withdrawFeeRate;

    mapping(uint256 => uint256) public idToWithdrawalRequest;

    uint256 public withdrawalCounter;

    mapping(address => bool) public depositPaused;
    mapping(address => bool) public withdrawPaused;

    mapping(address => bool) public whitelistMode;
    mapping(address => mapping(address => bool)) public depositWhitelist;

    constructor(address _lpToken, address _goatSafeAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        lpToken = _lpToken;
        goatSafeAddress = _goatSafeAddress;
    }

    function deposit(
        address _token,
        uint256 _amount
    ) external returns (uint256 mintAmount) {
        require(isUnderlyingToken[_token], "Invalid token");
        require(!depositPaused[_token], "Deposit paused");
        require(_amount > 0, "Zero amount");
        require(
            whitelistMode[_token] || depositWhitelist[_token][msg.sender],
            "Not whitelisted"
        );

        TransferHelper.safeTransferFrom(
            _token,
            msg.sender,
            address(this),
            _amount
        );

        // TODO:
        // IOFT(tokenBridge[_token]).send(goatSafeAddress)

        mintAmount = _amount * 10 ** (18 - tokenDecimals[_token]);

        IToken(lpToken).mint(msg.sender, mintAmount);

        emit Deposit(msg.sender, _token, _amount, mintAmount);
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

        TransferHelper.safeTransferFrom(
            lpToken,
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

        TransferHelper.safeTransfer(lpToken, requester, lpAmount);

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
        returns (
            address requestToken,
            uint256 finalizedAmount,
            uint256 lpAmount
        )
    {
        uint256 index = idToWithdrawalRequest[_id];
        uint256 length = withdrawalRequests.length;
        require(
            index < length && _id < withdrawalCounter,
            "Array index out of bounds"
        );

        WithdrawalRequest memory withdrawalRequest = withdrawalRequests[index];

        require(_id == withdrawalRequest.id, "Invalid id");

        uint256 lpPrice = oracleConfigurator.getPrice(lpToken);

        (requestToken, finalizedAmount, lpAmount) = _finalizeWithdraw(
            withdrawalRequest,
            lpPrice
        );

        idToWithdrawalRequest[withdrawalRequests[length - 1].id] = index;
        idToWithdrawalRequest[_id] = type(uint256).max;

        withdrawalRequests[index] = withdrawalRequests[length - 1];
        withdrawalRequests.pop();
    }

    function processAllWithdrawal() external nonReentrant onlyRole(ADMIN_ROLE) {
        uint256 length = withdrawalRequests.length;
        require(length > 0, "Empty array");

        uint256 lpPrice = oracleConfigurator.getPrice(lpToken);

        uint256 i;
        for (i; i < length; i++) {
            WithdrawalRequest memory withdrawalRequest = withdrawalRequests[i];

            _finalizeWithdraw(withdrawalRequest, lpPrice);

            idToWithdrawalRequest[withdrawalRequest.id] = type(uint256).max;
        }

        delete withdrawalRequests;
    }

    function _finalizeWithdraw(
        WithdrawalRequest memory _withdrawalRequest,
        uint256 _lpPrice
    )
        internal
        returns (
            address requestToken,
            uint256 finalizedAmount,
            uint256 lpAmount
        )
    {
        uint256 minReceiveAmount = _withdrawalRequest.minReceiveAmount;
        requestToken = _withdrawalRequest.requestToken;

        lpAmount = _withdrawalRequest.lpAmount;

        address requester = _withdrawalRequest.requester;
        address receiver = _withdrawalRequest.receiver;

        IToken(lpToken).burn(address(this), lpAmount);

        TransferHelper.safeTransfer(address(requestToken), receiver, lpAmount);
        emit WithdrawalProcessed(requester, receiver, requestToken, lpAmount);
    }

    function withdrawFromVault(
        address[] memory _tokens,
        uint256[] memory _amounts
    ) external onlyRole(ADMIN_ROLE) {
        uint256 length = _tokens.length;
        if (length == 0 || length != _amounts.length)
            revert InvalidArrayLength();

        uint256 i;
        for (i; i < length; i++) {
            address token = _tokens[i];
            uint256 amount = _amounts[i];
            TransferHelper.safeTransfer(token, msg.sender, amount);

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
            TransferHelper.safeTransferFrom(
                token,
                msg.sender,
                address(this),
                amount
            );

            emit RepayToVault(msg.sender, token, amount);
        }
    }

    function addUnderlyingToken(
        address _token,
        address _bridge
    ) external onlyRole(ADMIN_ROLE) {
        if (_token == address(0) || _token == lpToken) revert InvalidToken();
        if (isUnderlyingToken[_token]) revert TokenAlreadyAdd();
        if (oracleConfigurator.oracles(_token) == address(0))
            revert InvalidOracle();

        uint8 decimals = ERC20(_token).decimals();
        if (decimals > 18) revert InvalidDecimals();

        tokenBridge[_token] = _bridge;
        ERC20(_token).approve(_bridge, type(uint256).max);
        isUnderlyingToken[_token] = true;
        tokenDecimals[_token] = decimals;
        underlyingTokens.push(_token);

        emit TokenAdded(_token);
    }

    function removeUnderlyingToken(
        address _token
    ) external onlyRole(SUPPORTED_TOKEN_OPERATION_ROLE) {
        require(isUnderlyingToken[_token], "Invalid token");
        require(ERC20(_token).balanceOf(address(this)) == 0, "Non-empty token");

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
