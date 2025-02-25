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
    uint256 public constant MIN_AMOUNT = 1;

    AssetVault public vault;
    LPToken public lpToken;
    MockToken public mockToken;
    MockOFT public oft;

    uint256 public depositAmount;
    uint256 public lpAmount;
    address public thisAddr;
    address public msgSender;

    function setUp() public virtual {
        msgSender = address(this);

        // deploy mock OFT
        uint32 testDestEid = 1;
        vault = new AssetVault(testDestEid);
        vault.initialize(msgSender, 0);
        vault.grantRole(vault.ADMIN_ROLE(), msgSender);
        mockToken = new MockToken();
        oft = new MockOFT(address(mockToken));

        vault.addUnderlyingToken(
            address(mockToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );
        (, address lpTokenAddr, , , ) = vault.underlyingTokens(
            address(mockToken)
        );
        lpToken = LPToken(lpTokenAddr);
        assertEq(vault.getUnderlyings().length, 1);
        vault.setRedeemWaitPeriod(1 days);

        // mock token setup
        depositAmount = 10 ** mockToken.decimals();
        lpAmount = depositAmount * 10 ** (18 - mockToken.decimals());
        mockToken.mint(msgSender, depositAmount);
        mockToken.approve(address(vault), type(uint256).max);
    }

    function test_StandardProcess() public {
        // deposit
        assertEq(lpToken.balanceOf(msgSender), 0);
        MessagingFee memory fee = vault.getFee(
            address(mockToken),
            depositAmount
        );
        vault.deposit{value: fee.nativeFee}(
            address(mockToken),
            depositAmount,
            fee
        );
        assertEq(lpToken.balanceOf(msgSender), lpAmount);
        assertEq(mockToken.balanceOf(msgSender), 0);
        assertEq(mockToken.balanceOf(address(oft)), depositAmount);

        // request redeem
        uint64 redeemId = vault.redeemCounter();
        lpToken.approve(address(vault), type(uint256).max);
        vault.requestRedeem(address(mockToken), msgSender, lpAmount);
        assertEq(redeemId + 1, vault.redeemCounter());
        (
            bool isCompleted,
            address requester,
            address receiver,
            address token,
            uint32 timestamp,
            uint256 amount
        ) = vault.redeemRequests(redeemId);
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
                lpAmount
            )
        );

        // cancel redeem
        vault.cancelRedeem(redeemId);

        // request a new redeem
        redeemId = vault.redeemCounter();
        vault.requestRedeem(address(mockToken), msgSender, lpAmount);

        // process redeem
        assertEq(vault.processedRedeemCounter(), 0);
        skip(1 days); // redeem wait period
        vault.processUntil(redeemId);
        assertEq(vault.processedRedeemCounter(), redeemId);

        // bridge back to Vault
        oft.bridgeOut(address(vault), depositAmount);

        // claim
        vault.claim(redeemId);
        assertEq(lpToken.balanceOf(msgSender), 0);
        assertEq(mockToken.balanceOf(msgSender), depositAmount);

        // remove underlying token
        vault.removeUnderlyingToken(address(mockToken));

        // set new Safe address
        vault.setGoatSafeAddress(address(1));
    }

    function test_Revert() public {
        MessagingFee memory fee = vault.getFee(
            address(mockToken),
            depositAmount
        );

        // fail deposit cases
        vm.expectRevert("Invalid token");
        vault.deposit(address(1), depositAmount, fee);

        vault.setDepositPause(address(mockToken), true);
        vm.expectRevert("Deposit paused");
        vault.deposit(address(mockToken), depositAmount, fee);
        vault.setDepositPause(address(mockToken), false);

        vm.expectRevert("Invalid amount");
        vault.deposit(address(mockToken), 0, fee);

        vault.setWhitelistMode(address(mockToken), true);
        vm.expectRevert("Not whitelisted");
        vault.deposit(address(mockToken), depositAmount, fee);

        // success deposit
        vault.setWhitelistAddress(address(mockToken), msgSender, true);
        vault.deposit{value: fee.nativeFee}(
            address(mockToken),
            depositAmount,
            fee
        );
        uint64 redeemId = vault.redeemCounter();

        // fail redeem cases
        vm.expectRevert("Invalid token");
        vault.requestRedeem(address(0), msgSender, lpAmount);

        vm.expectRevert("Zero address");
        vault.requestRedeem(address(mockToken), address(0), lpAmount);

        vm.expectRevert("Invalid amount");
        vault.requestRedeem(address(mockToken), msgSender, 0);

        vault.setRedeemPause(address(mockToken), true);
        vm.expectRevert("Paused");
        vault.requestRedeem(address(mockToken), msgSender, lpAmount);

        vault.setRedeemPause(address(mockToken), false);
        // success redeem
        lpToken.approve(address(vault), type(uint256).max);
        vault.requestRedeem(address(mockToken), msgSender, lpAmount);

        // fail to cancel redeem using different requester address
        vm.prank(address(1));
        vm.expectRevert("Wrong requester");
        vault.cancelRedeem(redeemId);

        // fail process cases
        vm.expectRevert("Invalid id");
        vault.processUntil(redeemId + 1);

        // success process redeem
        vault.processUntil(redeemId);

        // fail claim cases
        vm.expectRevert("Not processed");
        vault.claim(redeemId + 1);

        vm.expectRevert("Time not reached");
        vault.claim(redeemId);

        skip(1 days);
        vm.prank(address(1));
        vm.expectRevert("Wrong requester");
        vault.claim(redeemId);

        vm.expectRevert("Insufficient tokens");
        vault.claim(redeemId);

        // success claim
        oft.bridgeOut(address(vault), depositAmount);
        vault.claim(redeemId);

        // fail to operate on claimed redeem
        vm.expectRevert("Already processed");
        vault.cancelRedeem(redeemId);

        vm.expectRevert("Already completed");
        vault.claim(redeemId);

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
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );

        vm.expectRevert("Token exists");
        vault.addUnderlyingToken(
            address(mockToken),
            address(oft),
            MIN_AMOUNT,
            MIN_AMOUNT
        );

        MockInvalidToken invalidToken = new MockInvalidToken();
        vm.expectRevert("Invalid decimals");
        vault.addUnderlyingToken(
            address(invalidToken),
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

    function test_LPToken() public {
        address addr = address(1);
        uint256 transferAmount = 1 ether;
        lpToken.grantRole(lpToken.MINT_ROLE(), msgSender);

        // fail: transfer disabled
        vm.expectRevert("LPToken: transfer is paused");
        lpToken.transfer(addr, transferAmount);

        vm.expectRevert("LPToken: transfer is paused");
        lpToken.transferFrom(addr, msgSender, transferAmount);

        // success
        lpToken.setVaultAddress(msgSender);
        lpToken.mint(addr, transferAmount);
        vm.prank(addr);
        lpToken.approve(msgSender, transferAmount);
        lpToken.transferFrom(addr, msgSender, transferAmount);

        lpToken.setTransferSwitch(true);
        lpToken.transfer(addr, transferAmount);
    }
}
