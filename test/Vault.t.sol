pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {AssetVault} from "../src/AssetVault.sol";
import {LPToken} from "../src/LPToken.sol";
import {MessagingFee} from "../src/interfaces/IOFT.sol";

import {MockToken} from "../src/mocks/MockToken.sol";
import {MockInvalidToken} from "../src/mocks/MockInvalidToken.sol";
import {MockOFT} from "../src/mocks/MockOFT.sol";

contract VaultTest is Test {
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant ENTRYPOINT_ROLE = keccak256("ENTRYPOINT_ROLE");
    uint256 public constant DEFAULT_DEPOSIT_AMOUNT = 1 ether;
    uint256 public constant MIN_AMOUNT = 0.1 ether;

    AssetVault public vault;
    LPToken public lpToken;
    MockToken public mockToken;
    MockOFT public oft;

    address public thisAddr;
    address public msgSender;

    function setUp() public virtual {
        msgSender = address(this);

        // deploy mock OFT
        uint32 testDestEid = 1;
        vault = new AssetVault(testDestEid);
        vault.initialize(msgSender);
        vault.grantRole(vault.ADMIN_ROLE(), msgSender);
        mockToken = new MockToken();
        lpToken = new LPToken("LP Token", "LPT");
        lpToken.setTransferWhitelist(address(vault), true);
        lpToken.grantRole(lpToken.MINT_ROLE(), address(vault));
        oft = new MockOFT(address(mockToken));

        vault.addUnderlyingToken(
            address(mockToken),
            address(lpToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );
        assertEq(vault.getUnderlyings().length, 1);
        vault.setRedeemWaitPeriod(1 days);

        // mock token setup
        mockToken.mint(msgSender, DEFAULT_DEPOSIT_AMOUNT);
        mockToken.approve(address(vault), type(uint256).max);
    }

    function test_StandardProcess() public {
        // deposit
        assertEq(lpToken.balanceOf(msgSender), 0);
        MessagingFee memory fee = vault.getFee(
            address(mockToken),
            DEFAULT_DEPOSIT_AMOUNT
        );
        vault.deposit{value: fee.nativeFee}(
            address(mockToken),
            DEFAULT_DEPOSIT_AMOUNT,
            fee
        );
        assertEq(lpToken.balanceOf(msgSender), DEFAULT_DEPOSIT_AMOUNT);
        assertEq(mockToken.balanceOf(msgSender), 0);
        assertEq(mockToken.balanceOf(address(oft)), DEFAULT_DEPOSIT_AMOUNT);

        // request withdraw
        uint64 withdrawId = vault.withdrawalCounter();
        lpToken.approve(address(vault), type(uint256).max);
        vault.requestWithdraw(
            address(mockToken),
            msgSender,
            DEFAULT_DEPOSIT_AMOUNT
        );
        assertEq(withdrawId + 1, vault.withdrawalCounter());
        (
            bool isCompleted,
            address requester,
            address receiver,
            address token,
            uint32 timestamp,
            uint256 amount
        ) = vault.withdrawalRequests(withdrawId);
        assertEq(
            abi.encodePacked(
                isCompleted,
                requester,
                receiver,
                token,
                timestamp,
                amount
            ),
            abi.encodePacked(
                false,
                msgSender,
                msgSender,
                address(mockToken),
                uint32(block.timestamp),
                DEFAULT_DEPOSIT_AMOUNT
            )
        );

        // cancel withdrawal
        vault.cancelWithdrawal(withdrawId);

        // request a new withdrawal
        withdrawId = vault.withdrawalCounter();
        vault.requestWithdraw(
            address(mockToken),
            msgSender,
            DEFAULT_DEPOSIT_AMOUNT
        );

        // process withdrawal
        assertEq(vault.processedWithdrawalCounter(), 0);
        skip(1 days); // redeem wait period
        vault.processUntil(withdrawId);
        assertEq(vault.processedWithdrawalCounter(), withdrawId);

        // bridge back to Vault
        oft.bridgeOut(address(vault), DEFAULT_DEPOSIT_AMOUNT);

        // claim
        vault.claim(withdrawId);
        assertEq(lpToken.balanceOf(msgSender), 0);
        assertEq(mockToken.balanceOf(msgSender), DEFAULT_DEPOSIT_AMOUNT);

        // remove underlying token
        vault.removeUnderlyingToken(address(mockToken));

        // set new Safe address
        vault.setGoatSafeAddress(address(1));
    }

    function test_Revert() public {
        MessagingFee memory fee = vault.getFee(
            address(mockToken),
            DEFAULT_DEPOSIT_AMOUNT
        );

        // fail deposit cases
        vm.expectRevert("Invalid token");
        vault.deposit(address(1), DEFAULT_DEPOSIT_AMOUNT, fee);

        vault.setDepositPause(address(mockToken), true);
        vm.expectRevert("Deposit paused");
        vault.deposit(address(mockToken), DEFAULT_DEPOSIT_AMOUNT, fee);
        vault.setDepositPause(address(mockToken), false);

        vm.expectRevert("Invalid amount");
        vault.deposit(address(mockToken), 0, fee);

        vault.setWhitelistMode(address(mockToken), true);
        vm.expectRevert("Not whitelisted");
        vault.deposit(address(mockToken), DEFAULT_DEPOSIT_AMOUNT, fee);

        // success deposit
        vault.setWhitelistAddress(address(mockToken), msgSender, true);
        vault.deposit{value: fee.nativeFee}(
            address(mockToken),
            DEFAULT_DEPOSIT_AMOUNT,
            fee
        );
        uint64 withdrawId = vault.withdrawalCounter();

        // fail withdraw cases
        vm.expectRevert("Invalid token");
        vault.requestWithdraw(address(0), msgSender, DEFAULT_DEPOSIT_AMOUNT);

        vm.expectRevert("Zero address");
        vault.requestWithdraw(
            address(mockToken),
            address(0),
            DEFAULT_DEPOSIT_AMOUNT
        );

        vm.expectRevert("Invalid amount");
        vault.requestWithdraw(address(mockToken), msgSender, 0);

        vault.setWithdrawPause(address(mockToken), true);
        vm.expectRevert("Paused");
        vault.requestWithdraw(
            address(mockToken),
            msgSender,
            DEFAULT_DEPOSIT_AMOUNT
        );

        vault.setWithdrawPause(address(mockToken), false);
        // success withdraw
        lpToken.approve(address(vault), type(uint256).max);
        vault.requestWithdraw(
            address(mockToken),
            msgSender,
            DEFAULT_DEPOSIT_AMOUNT
        );

        // fail to cancel withdraw using different requester address
        vm.prank(address(1));
        vm.expectRevert("Wrong requester");
        vault.cancelWithdrawal(withdrawId);

        // fail process cases
        vm.expectRevert("Invalid id");
        vault.processUntil(withdrawId + 1);

        vm.expectRevert("Time not reached");
        vault.processUntil(withdrawId);

        // success process withdrawal
        skip(1 days);
        vault.processUntil(withdrawId);

        // fail claim cases
        vm.expectRevert("Not processed");
        vault.claim(withdrawId + 1);

        vm.prank(address(1));
        vm.expectRevert("Wrong requester");
        vault.claim(withdrawId);

        vm.expectRevert("Insufficient tokens");
        vault.claim(withdrawId);

        // success claim
        oft.bridgeOut(address(vault), DEFAULT_DEPOSIT_AMOUNT);
        vault.claim(withdrawId);

        // fail to operate on claimed withdrawal
        vm.expectRevert("Already completed");
        vault.cancelWithdrawal(withdrawId);

        vm.expectRevert("Already completed");
        vault.claim(withdrawId);

        // fail due to setting zero address
        vm.expectRevert("Zero address");
        vault.setGoatSafeAddress(address(0));
    }

    function test_UnderlyingToken() public {
        MockToken tempToken = new MockToken();

        // add underlying token revert
        vm.expectRevert("Invalid token");
        vault.addUnderlyingToken(
            address(0),
            address(lpToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );

        vm.expectRevert("Existing LP token");
        vault.addUnderlyingToken(
            address(tempToken),
            address(lpToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );

        vm.expectRevert("Token exists");
        vault.addUnderlyingToken(
            address(mockToken),
            address(tempToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );

        MockInvalidToken invalidToken = new MockInvalidToken();
        vm.expectRevert("Invalid decimals");
        vault.addUnderlyingToken(
            address(invalidToken),
            address(tempToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );

        // remove underlying token revert
        vm.expectRevert("Token does not exist");
        vault.removeUnderlyingToken(address(tempToken));

        vm.prank(address(vault));
        lpToken.mint(address(vault), 1);
        vm.expectRevert("Non-empty LP token");
        vault.removeUnderlyingToken(address(mockToken));

        mockToken.mint(address(vault), 1);
        vm.expectRevert("Non-empty token");
        vault.removeUnderlyingToken(address(mockToken));
    }
}
