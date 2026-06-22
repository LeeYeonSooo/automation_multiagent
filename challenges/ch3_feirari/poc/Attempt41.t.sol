// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IHomoraBankLike {
    function execute(uint256 positionId, address spell, bytes calldata data) external payable returns (uint256);
    function getBorrowETHValue(uint256 positionId) external view returns (uint256);
    function getCollateralETHValue(uint256 positionId) external view returns (uint256);
    function getPositionDebts(uint256 positionId) external view returns (address[] memory tokens, uint256[] memory debts);
}

/// @notice Hypothesis under test: Alpha Homora V2's Sushi spell can route borrowed WETH back to the executor
/// as native ETH, allowing a large Iron Bank extraction.
///
/// The verified HomoraBank implementation books debt before transferring borrowed tokens to the spell, then enforces
/// `collateralValue >= borrowValue` after the spell returns. This PoC verifies two concrete consequences on the live
/// challenge fork:
/// 1. A normal `addLiquidityWMasterChef` call can refund only the spell's tiny leftover WETH as ETH.
/// 2. Trying to amplify that refund by over-borrowing WETH just reverts with `insufficient collateral`.
contract Attempt41 is Test {
    struct LiquidityAmounts {
        uint256 amtAUser;
        uint256 amtBUser;
        uint256 amtLPUser;
        uint256 amtABorrow;
        uint256 amtBBorrow;
        uint256 amtLPBorrow;
        uint256 amtAMin;
        uint256 amtBMin;
    }

    uint256 internal constant FORK_BLOCK = 14_684_704;
    uint256 internal constant EXPECTED_CHAIN_ID = 2401;
    bytes4 internal constant ADD_LIQUIDITY_W_MASTER_CHEF_SELECTOR = 0xe07d904e;
    uint256 internal constant PID_WETH_USDC = 1;

    address internal constant ATTACKER = address(0xBEEF);
    address internal constant BANK = 0xba5eBAf3fc1Fcca67147050Bf80462393814E54B;
    address internal constant SPELL = 0xDc9c7A2Bae15dD89271ae5701a6f4DB147BAa44C;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    IHomoraBankLike internal constant HOMORA = IHomoraBankLike(BANK);
    IERC20Like internal constant USDC_TOKEN = IERC20Like(USDC);

    function setUp() public {
        vm.createSelectFork("ch3", FORK_BLOCK);

        vm.label(ATTACKER, "Attacker");
        vm.label(BANK, "HomoraBank");
        vm.label(SPELL, "SushiswapSpellV1");
        vm.label(USDC, "USDC");
        vm.label(WETH, "WETH");

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");
        assertEq(block.number, FORK_BLOCK, "unexpected challenge fork block");
    }

    function testSafeBorrowRefundsOnlyDustEth() public {
        LiquidityAmounts memory amounts = LiquidityAmounts({
            amtAUser: 100_000e6,
            amtBUser: 0,
            amtLPUser: 0,
            amtABorrow: 0,
            amtBBorrow: 10 ether,
            amtLPBorrow: 0,
            amtAMin: 0,
            amtBMin: 0
        });

        deal(USDC, ATTACKER, amounts.amtAUser);
        vm.deal(ATTACKER, 1 ether);

        bytes memory spellData = _encodeSpellData(amounts);

        vm.startPrank(ATTACKER, ATTACKER);
        require(USDC_TOKEN.approve(BANK, type(uint256).max), "approve failed");

        uint256 ethBefore = ATTACKER.balance;
        uint256 posId = HOMORA.execute(0, SPELL, spellData);
        uint256 ethAfter = ATTACKER.balance;
        vm.stopPrank();

        uint256 refundedEth = ethAfter - ethBefore;
        (address[] memory debtTokens, uint256[] memory debts) = HOMORA.getPositionDebts(posId);
        uint256 borrowValue = HOMORA.getBorrowETHValue(posId);
        uint256 collateralValue = HOMORA.getCollateralETHValue(posId);

        console.log("POSITION_ID:", posId);
        console.log("REFUNDED_ETH_WEI:", refundedEth);
        console.log("POSITION_BORROW_VALUE_WEI:", borrowValue);
        console.log("POSITION_COLLATERAL_VALUE_WEI:", collateralValue);
        console.log("USDC_BALANCE_AFTER:", USDC_TOKEN.balanceOf(ATTACKER));
        console.log("DEBT_TOKEN_COUNT:", debtTokens.length);
        for (uint256 i = 0; i < debtTokens.length; ++i) {
            console.log("DEBT_TOKEN:", debtTokens[i]);
            console.log("DEBT_AMOUNT:", debts[i]);
        }

        assertGt(posId, 0, "position not opened");
        assertLt(refundedEth, 0.01 ether, "refund path returned more than dust ETH");
        assertGt(borrowValue, 0, "position has no debt");
        assertGe(collateralValue, borrowValue, "position ended unsafe");
    }

    function testOverBorrowedWethRefundPathRevertsInsufficientCollateral() public {
        LiquidityAmounts memory amounts = LiquidityAmounts({
            amtAUser: 100_000e6,
            amtBUser: 0,
            amtLPUser: 0,
            amtABorrow: 0,
            amtBBorrow: 1_000 ether,
            amtLPBorrow: 0,
            amtAMin: 0,
            amtBMin: 0
        });

        deal(USDC, ATTACKER, amounts.amtAUser);
        vm.deal(ATTACKER, 1 ether);

        vm.startPrank(ATTACKER, ATTACKER);
        require(USDC_TOKEN.approve(BANK, type(uint256).max), "approve failed");
        vm.expectRevert(bytes("insufficient collateral"));
        HOMORA.execute(0, SPELL, _encodeSpellData(amounts));
        vm.stopPrank();
    }

    function _encodeSpellData(LiquidityAmounts memory amounts) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            ADD_LIQUIDITY_W_MASTER_CHEF_SELECTOR,
            USDC,
            WETH,
            amounts,
            PID_WETH_USDC
        );
    }
}
