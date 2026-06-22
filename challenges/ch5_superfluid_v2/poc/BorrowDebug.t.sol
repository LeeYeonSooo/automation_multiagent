// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface ICEther {
    function mint() external payable;
    function borrow(uint256) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function getCash() external view returns (uint256);
    function accrueInterest() external returns (uint256);
}

interface ICToken {
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function underlying() external view returns (address);
    function accrueInterest() external returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
    function oracle() external view returns (address);
    function checkMembership(address account, address cToken) external view returns (bool);
    function borrowAllowed(address cToken, address borrower, uint256 borrowAmount) external returns (uint256);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

contract BorrowDebugTest is Test {
    address constant HF_COMPTROLLER = 0xEdBA32185BAF7fEf9A26ca567bC4A6cbe426e499;
    address constant HF_MATIC = 0xEbd7f3349AbA8bB15b897e03D6c1a4Ba95B55e31;
    address constant HF_USDC = 0x607312a5C671D0C511998171e634DE32156e69d0;
    address constant HF_DAI = 0xE4e43864ea18d5E5211352a4B810383460aB7fcC;
    address constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
    address constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;

    function test_debugBorrow() public {
        address user = address(this);
        vm.deal(user, 100 ether);

        // Enter hMATIC market
        address[] memory markets = new address[](1);
        markets[0] = HF_MATIC;
        uint256[] memory results = IComptroller(HF_COMPTROLLER).enterMarkets(markets);
        console.log("enterMarkets result:", results[0]);

        // Mint hMATIC
        ICEther(HF_MATIC).mint{value: 100 ether}();
        console.log("hMATIC balance:", ICEther(HF_MATIC).balanceOf(user));

        // Check membership
        bool isMember = IComptroller(HF_COMPTROLLER).checkMembership(user, HF_MATIC);
        console.log("Is member of hMATIC:", isMember);

        // Check liquidity
        (uint256 err, uint256 liq, uint256 sf) = IComptroller(HF_COMPTROLLER).getAccountLiquidity(user);
        console.log("Error:", err);
        console.log("Liquidity:", liq);
        console.log("Shortfall:", sf);

        // Accrue interest first
        ICToken(HF_USDC).accrueInterest();
        ICEther(HF_MATIC).accrueInterest();

        // Try a tiny borrow
        uint256 borrowResult = ICToken(HF_USDC).borrow(1000000); // 1 USDC
        console.log("Borrow 1 USDC result:", borrowResult);
        console.log("USDC balance:", IERC20(USDC).balanceOf(user));

        // Try borrowing DAI
        borrowResult = ICToken(HF_DAI).borrow(1 ether); // 1 DAI
        console.log("Borrow 1 DAI result:", borrowResult);
        console.log("DAI balance:", IERC20(DAI).balanceOf(user));
    }

    receive() external payable {}
}
