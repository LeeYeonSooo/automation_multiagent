// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Attempt46 {
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IComptrollerAttempt46 {
    function enterMarkets(address[] calldata cTokens) external returns (uint256[] memory);
    function exitMarket(address cToken) external returns (uint256);
}

interface ICEtherAttempt46 {
    function mint() external payable;
    function borrow(uint256 borrowAmount) external returns (uint256);
    function getCash() external view returns (uint256);
}

interface ICErc20Attempt46 {
    function mint(uint256 mintAmount) external returns (uint256);
    function borrow(uint256 borrowAmount) external returns (uint256);
    function borrowBalanceStored(address account) external view returns (uint256);
}

/// @notice Hypothesis: Pool 8's ETH borrow callback lets us borrow from CErc20 markets and still
/// call `exitMarket(fDAI)` before those CErc20 borrows become visible. If false, the callback-stable
/// borrow should be blocked outright or made visible before `exitMarket`, which kills the branch.
contract Attempt46 is Test {
    uint256 internal constant FORK_BLOCK = 14_684_704;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;

    uint256 internal constant COLLATERAL_DAI = 150_000_000e18;
    uint256 internal constant FETH_SEED = 2 ether;
    uint256 internal constant ETH_TRIGGER_BORROW = 1 ether + 1;
    uint256 internal constant FEI_BORROW = 1_000_000e18;

    IERC20Attempt46 internal constant DAI = IERC20Attempt46(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    IComptrollerAttempt46 internal constant COMPTROLLER =
        IComptrollerAttempt46(0xc54172e34046c1653d1920d40333Dd358c7a1aF4);
    ICEtherAttempt46 internal constant FETH = ICEtherAttempt46(0xbB025D470162CC5eA24daF7d4566064EE7f5F111);
    ICErc20Attempt46 internal constant FDAI = ICErc20Attempt46(0x7e9cE3CAa9910cc048590801e64174957Ed41d43);
    ICErc20Attempt46 internal constant FFEI = ICErc20Attempt46(0xd8553552f8868C1Ef160eEdf031cF0BCf9686945);

    bool internal reentered;
    bool internal feiBorrowCallOk;
    string internal feiBorrowRevertReason;
    uint256 internal feiDebtSeenInCallback;
    uint256 internal exitCodeAfterFailedFeiBorrow;

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(address(DAI), "DAI");
        vm.label(address(COMPTROLLER), "Pool8Comptroller");
        vm.label(address(FETH), "fETH-8");
        vm.label(address(FDAI), "fDAI-8");
        vm.label(address(FFEI), "fFEI-8");
    }

    function test_pool8_cross_asset_callback_borrow_is_blocked() public {
        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("FETH_CASH_BEFORE_SEED:", FETH.getCash());

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");

        deal(address(DAI), address(this), COLLATERAL_DAI);
        vm.deal(address(this), FETH_SEED);

        FETH.mint{value: FETH_SEED}();
        console.log("FETH_CASH_AFTER_SEED:", FETH.getCash());

        require(DAI.approve(address(FDAI), type(uint256).max), "approve fDAI failed");
        require(FDAI.mint(COLLATERAL_DAI) == 0, "fDAI mint failed");

        address[] memory markets = new address[](1);
        markets[0] = address(FDAI);
        uint256[] memory enterResults = COMPTROLLER.enterMarkets(markets);
        require(enterResults.length == 1 && enterResults[0] == 0, "enterMarkets failed");

        uint256 ethBorrowResult = FETH.borrow(ETH_TRIGGER_BORROW);

        console.log("ETH_BORROW_RESULT:", ethBorrowResult);
        console.log("REENTERED:", reentered);
        console.log("FEI_BORROW_CALL_OK:", feiBorrowCallOk);
        console.log("FEI_BORROW_REVERT_REASON:", feiBorrowRevertReason);
        console.log("FEI_DEBT_SEEN_IN_CALLBACK:", feiDebtSeenInCallback);
        console.log("EXIT_CODE_AFTER_FAILED_FEI_BORROW:", exitCodeAfterFailedFeiBorrow);

        assertEq(ethBorrowResult, 0, "fETH borrow failed");
        assertTrue(reentered, "callback not reached");
        assertFalse(feiBorrowCallOk, "cross-asset callback borrow unexpectedly succeeded");
        assertEq(feiBorrowRevertReason, "re-entered across assets", "unexpected callback borrow revert");
        assertEq(feiDebtSeenInCallback, 0, "fFEI debt should stay zero after blocked callback borrow");
        assertEq(exitCodeAfterFailedFeiBorrow, 0, "single-market exit should still work when cross-asset borrow is blocked");
    }

    receive() external payable {
        if (msg.sender != address(FETH) || reentered) {
            return;
        }

        reentered = true;
        console.log("REENTRANT_ETH_RECEIVED:", msg.value);

        bytes memory returnData;
        (feiBorrowCallOk, returnData) =
            address(FFEI).call(abi.encodeWithSelector(ICErc20Attempt46.borrow.selector, FEI_BORROW));
        if (!feiBorrowCallOk) {
            feiBorrowRevertReason = _decodeRevertReason(returnData);
        }
        feiDebtSeenInCallback = FFEI.borrowBalanceStored(address(this));

        console.log("CALLBACK_FEI_BORROW_CALL_OK:", feiBorrowCallOk);
        console.log("CALLBACK_FEI_BORROW_REVERT_REASON:", feiBorrowRevertReason);
        console.log("CALLBACK_FEI_DEBT:", feiDebtSeenInCallback);

        exitCodeAfterFailedFeiBorrow = COMPTROLLER.exitMarket(address(FDAI));
        console.log("CALLBACK_EXIT_CODE_AFTER_FAILED_FEI_BORROW:", exitCodeAfterFailedFeiBorrow);
    }

    function _decodeRevertReason(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length < 68) {
            return "raw revert";
        }

        assembly {
            revertData := add(revertData, 0x04)
        }

        return abi.decode(revertData, (string));
    }
}
