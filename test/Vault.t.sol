pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {AssetVault} from "../src/AssetVault.sol";
import {LPToken} from "../src/LPToken.sol";
import {MessagingFee} from "../src/interfaces/IOFT.sol";

import {MockToken} from "../src/mocks/MockToken.sol";
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
        vault = new AssetVault(testDestEid, msgSender);
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
        vault.setWhitelistMode(address(mockToken), true);
        vault.setRedeemWaitPeriod(1 days);

        // mock token setup
        mockToken.mint(msgSender, DEFAULT_DEPOSIT_AMOUNT);
        mockToken.approve(address(vault), type(uint256).max);
    }

    function test_StandardProcess() public {
        // deposit
        assertEq(lpToken.balanceOf(msgSender), 0);
        MessagingFee memory fee = MessagingFee({
            nativeFee: 0.1 ether,
            lzTokenFee: 0
        });
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
    }

    function test_DepositRevert() public {
        MessagingFee memory fee = MessagingFee({
            nativeFee: 0.1 ether,
            lzTokenFee: 0
        });

        vm.expectRevert("Invalid token");
        vault.deposit(address(1), DEFAULT_DEPOSIT_AMOUNT, fee);

        vault.setDepositPause(address(mockToken), true);
        vm.expectRevert("Deposit paused");
        vault.deposit(address(mockToken), DEFAULT_DEPOSIT_AMOUNT, fee);
        vault.setDepositPause(address(mockToken), false);

        vm.expectRevert("Invalid amount");
        vault.deposit(address(mockToken), 0, fee);

        vault.setWhitelistMode(address(mockToken), false);
        vm.expectRevert("Not whitelisted");
        vault.deposit(address(mockToken), DEFAULT_DEPOSIT_AMOUNT, fee);
    }
}
