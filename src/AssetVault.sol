// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

import {LPToken} from "./LPToken.sol";
import {IToken} from "./interfaces/IToken.sol";
import {IOFT, SendParam, MessagingFee} from "./interfaces/IOFT.sol";

/**
 * @title AssetVault
 * @dev A vault contract for bridging assets to the Goat network
 * @dev This contract is not compatible with rebasing tokens. Using rebasing tokens
 * will result in incorrect LP token ratios as the contract does not adjust LP token
 * balances when underlying token balances change due to rebasing events.
 */
contract AssetVault is AccessControlUpgradeable, ReentrancyGuardUpgradeable {
    // events
    event Deposit(
        address indexed account,
        address indexed token,
        uint256 tokenAmount,
        uint256 share
    );
    event RedeemRequested(
        address indexed requester,
        address indexed receiver,
        address indexed requestToken,
        uint256 id,
        uint256 share
    );
    event RedeemCancelled(
        address indexed requester,
        address indexed requestToken,
        uint256 id,
        uint256 share
    );
    event RedeemProcessed(uint256 id);
    event Claim(
        uint256 id,
        address indexed requester,
        address indexed receiver,
        address indexed requestToken,
        uint256 share,
        uint256 underlyingAmount
    );
    event TokenAdded(address token, address lpToken, address bridge);
    event TokenRemoved(address token);
    event SetDepositPause(address token, bool paused);
    event SetRedeemPause(address token, bool paused);
    event SetWhitelistMode(address token, bool whitelistMode);
    event SetWhitelist(address token, address user, bool allowed);
    event SetRedeemWaitPeriod(uint32 redeemWaitPeriod);
    event SetGoatSafeAddress(address newAddress);

    // structs
    struct UnderlyingToken {
        uint8 decimals;
        address lpToken;
        address bridge;
        uint256 minDepositAmount; // underlying token amount
        uint256 minRedeemAmount; // lp token amount
    }

    struct RedeemRequest {
        bool isCompleted;
        address requester;
        address receiver;
        address requestToken;
        uint32 timestamp;
        uint256 share;
    }

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint32 public immutable eid; // Layer Zero destination endpoint id

    // bytes32 format of token receiving address on Goat network
    bytes32 public goatSafeAddress;

    address[] public underlyingTokenList;
    mapping(address => UnderlyingToken) public underlyingTokens;
    mapping(address lpToken => address underlyingToken)
        public lpToUnderlyingTokens;

    mapping(uint256 id => RedeemRequest) public redeemRequests;
    uint32 public redeemWaitPeriod; // wait time before the redeem can be processed
    uint64 public redeemCounter; // next id for redeem, start from 1
    uint64 public processedRedeemCounter; // the index of processed redeem requests

    mapping(address => bool) public depositPaused;
    mapping(address => bool) public redeemPaused;

    mapping(address => bool) public whitelistMode;
    mapping(address => mapping(address => bool)) public depositWhitelist;

    constructor(uint32 _eid) {
        eid = _eid;
    }

    /**
     * @dev Initializes the contract with the given Goat safe address.
     * @param _goatSafeAddress The Goat safe address.
     */
    function initialize(address _goatSafeAddress) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
        redeemCounter = 1;
    }

    /**
     * @dev Returns all underlying tokens.
     * @return An array of underlying token addresses.
     */
    function getUnderlyings() external view returns (address[] memory) {
        return underlyingTokenList;
    }

    /**
     * @dev Generates the `SendParam` used for bridging.
     * @param _amount The amount to be bridged.
     * @return sendParam The generated `SendParam`.
     */
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

    /**
     * @dev Gets the required fee for deposit.
     * @param _token The token address.
     * @param _amount The amount to be deposited.
     * @return The required messaging fee.
     */
    function getFee(
        address _token,
        uint256 _amount
    ) public view returns (MessagingFee memory) {
        UnderlyingToken memory tokenInfo = underlyingTokens[_token];
        return
            IOFT(tokenInfo.bridge).quoteSend(generateSendParam(_amount), false);
    }

    /**
     * @dev Deposits `_token` to Goat network.
     * @param _token The token address.
     * @param _amount The amount to be deposited.
     * @param _fee The messaging fee.
     */
    function deposit(
        address _token,
        uint256 _amount,
        MessagingFee memory _fee
    ) external payable nonReentrant {
        UnderlyingToken memory tokenInfo = underlyingTokens[_token];
        require(tokenInfo.lpToken != address(0), "Invalid token");
        require(!depositPaused[_token], "Deposit paused");
        require(_amount >= tokenInfo.minDepositAmount, "Invalid amount");
        require(
            !whitelistMode[_token] || depositWhitelist[_token][msg.sender],
            "Not whitelisted"
        );
        require(_fee.lzTokenFee == 0, "LZ token fee not supported");
        require(_fee.nativeFee == msg.value, "Invalid native fee");

        IToken(_token).transferFrom(msg.sender, address(this), _amount);

        IOFT(tokenInfo.bridge).send{value: msg.value}(
            generateSendParam(_amount),
            _fee,
            msg.sender
        );

        uint256 share = _amount * 10 ** (18 - tokenInfo.decimals);
        IToken(tokenInfo.lpToken).mint(msg.sender, share);

        emit Deposit(msg.sender, _token, _amount, share);
    }

    /**
     * @dev Requests a redeem.
     * @param _requestToken The token to be redeemed.
     * @param _receiver The address to receive the redeemed tokens.
     * @param _share The amount of LP tokens to be burned for redeeming the token.
     * @return id The ID of the redeem request.
     */
    function requestRedeem(
        address _requestToken,
        address _receiver,
        uint256 _share
    ) external returns (uint256 id) {
        require(
            underlyingTokens[_requestToken].lpToken != address(0),
            "Invalid token"
        );
        require(_receiver != address(0), "Zero address");
        require(
            _share >= underlyingTokens[_requestToken].minRedeemAmount,
            "Invalid amount"
        );
        require(!redeemPaused[_requestToken], "Paused");

        IToken(underlyingTokens[_requestToken].lpToken).transferFrom(
            msg.sender,
            address(this),
            _share
        );

        id = redeemCounter++;
        redeemRequests[id] = RedeemRequest({
            isCompleted: false,
            requester: msg.sender,
            receiver: _receiver,
            requestToken: _requestToken,
            timestamp: uint32(block.timestamp),
            share: _share
        });

        emit RedeemRequested(msg.sender, _receiver, _requestToken, id, _share);
    }

    /**
     * @dev Cancels the requested redeem.
     * @param _id The ID of the redeem request to be cancelled.
     */
    function cancelRedeem(uint64 _id) external {
        require(_id > processedRedeemCounter, "Already processed");
        RedeemRequest memory redeemRequest = redeemRequests[_id];
        address requester = redeemRequest.requester;
        require(msg.sender == requester, "Wrong requester");

        IToken(underlyingTokens[redeemRequest.requestToken].lpToken).transfer(
            requester,
            redeemRequest.share
        );

        delete redeemRequests[_id];
        emit RedeemCancelled(
            requester,
            redeemRequest.requestToken,
            _id,
            redeemRequest.share
        );
    }

    /**
     * @dev Allows users to claim their requested redeems up to `_id`th redeem.
     * @param _id The ID up to which redeem request to be processed.
     */
    function processUntil(uint64 _id) external onlyRole(ADMIN_ROLE) {
        require(
            _id > processedRedeemCounter && _id < redeemCounter,
            "Invalid id"
        );
        processedRedeemCounter = _id;
        emit RedeemProcessed(_id);
    }

    /**
     * @dev Claims the processed redeem request.
     * @param _id The ID of the redeem request to be claimed.
     * @notice The requester can claim the redeem after the redeem wait period.
     */
    function claim(uint64 _id) external nonReentrant {
        require(_id <= processedRedeemCounter, "Not processed");
        RedeemRequest memory redeemRequest = redeemRequests[_id];
        require(!redeemRequest.isCompleted, "Already completed");
        require(
            redeemRequest.timestamp + redeemWaitPeriod <= block.timestamp,
            "Time not reached"
        );

        address requester = redeemRequest.requester;
        require(msg.sender == requester, "Wrong requester");
        redeemRequests[_id].isCompleted = true;

        uint256 share = redeemRequest.share;
        address requestToken = redeemRequest.requestToken;
        uint256 underlyingAmount = share /
            (10 ** (18 - underlyingTokens[requestToken].decimals));
        require(
            underlyingAmount <= IToken(requestToken).balanceOf(address(this)),
            "Insufficient tokens"
        );
        address receiver = redeemRequest.receiver;

        IToken(underlyingTokens[requestToken].lpToken).burn(
            address(this),
            share
        );
        IToken(requestToken).transfer(receiver, underlyingAmount);
        emit Claim(
            _id,
            requester,
            receiver,
            requestToken,
            share,
            underlyingAmount
        );
    }

    /**
     * @dev Adds an underlying token.
     * @param _token The underlying token address.
     * @param _bridge The OFT/adapter for the underlying token.
     * @param _minDepositAmount The minimum deposit amount, in underlying token.
     * @param _minRedeemAmount The minimum redeem amount, in LP token.
     */
    function addUnderlyingToken(
        address _token,
        address _bridge,
        uint256 _minDepositAmount,
        uint256 _minRedeemAmount
    ) external onlyRole(ADMIN_ROLE) {
        require(_token != address(0), "Invalid token");
        require(underlyingTokens[_token].lpToken == address(0), "Token exists");

        uint8 decimals = IToken(_token).decimals();
        require(decimals <= 18, "Invalid decimals");

        // Set max allowance for Layer Zero bridge
        IToken(_token).approve(_bridge, type(uint256).max);
        LPToken lpToken = new LPToken(
            msg.sender,
            string(abi.encodePacked("Goat ", IToken(_token).name())), // FIXME: temporary name
            string(abi.encodePacked("G", IToken(_token).symbol()))
        );

        // underlying token setup
        underlyingTokenList.push(_token);
        underlyingTokens[_token] = UnderlyingToken({
            decimals: decimals,
            lpToken: address(lpToken),
            bridge: _bridge,
            minDepositAmount: _minDepositAmount,
            minRedeemAmount: _minRedeemAmount
        });
        lpToUnderlyingTokens[address(lpToken)] = _token;

        emit TokenAdded(_token, address(lpToken), _bridge);
    }

    /**
     * @dev Removes an added underlying token.
     * @param _token The underlying token address to be removed.
     */
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

    /**
     * @dev Sets the deposit pause state.
     * @param _token The token address.
     * @param _pause The pause state.
     */
    function setDepositPause(
        address _token,
        bool _pause
    ) external onlyRole(ADMIN_ROLE) {
        depositPaused[_token] = _pause;
        emit SetDepositPause(_token, _pause);
    }

    /**
     * @dev Sets the redeem pause state.
     * @param _token The token address.
     * @param _pause The pause state.
     */
    function setRedeemPause(
        address _token,
        bool _pause
    ) external onlyRole(ADMIN_ROLE) {
        redeemPaused[_token] = _pause;
        emit SetRedeemPause(_token, _pause);
    }

    /**
     * @dev Sets the token whitelist mode.
     * @param _token The token address.
     * @param _applyWhitelist The whitelist mode state.
     */
    function setWhitelistMode(
        address _token,
        bool _applyWhitelist
    ) external onlyRole(ADMIN_ROLE) {
        whitelistMode[_token] = _applyWhitelist;
        emit SetWhitelistMode(_token, _applyWhitelist);
    }

    /**
     * @dev Sets the address whitelist.
     * @param _token The token address.
     * @param _user The user address.
     * @param _allowed The whitelist state.
     */
    function setWhitelistAddress(
        address _token,
        address _user,
        bool _allowed
    ) external onlyRole(ADMIN_ROLE) {
        depositWhitelist[_token][_user] = _allowed;
        emit SetWhitelist(_token, _user, _allowed);
    }

    /**
     * @dev Sets the wait period before the user can claim.
     * @param _redeemWaitPeriod The new wait period in seconds.
     */
    function setRedeemWaitPeriod(
        uint32 _redeemWaitPeriod
    ) external onlyRole(ADMIN_ROLE) {
        redeemWaitPeriod = _redeemWaitPeriod;
        emit SetRedeemWaitPeriod(_redeemWaitPeriod);
    }

    /**
     * @dev Sets the token receiving address on Goat.
     * @param _goatSafeAddress The new Goat safe address.
     */
    function setGoatSafeAddress(
        address _goatSafeAddress
    ) external onlyRole(ADMIN_ROLE) {
        require(_goatSafeAddress != address(0), "Zero address");
        goatSafeAddress = bytes32(uint256(uint160(_goatSafeAddress)));
        emit SetGoatSafeAddress(_goatSafeAddress);
    }
}
