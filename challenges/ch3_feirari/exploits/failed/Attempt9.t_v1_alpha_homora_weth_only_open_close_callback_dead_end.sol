// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "forge-std/Test.sol";

interface IERC20Attempt9 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IWETHAttempt9 is IERC20Attempt9 {
    function deposit() external payable;
}

interface IHomoraBankAttempt9 {
    function execute(uint256 positionId, address spell, bytes calldata data) external payable returns (uint256);
    function getPositionInfo(uint256 positionId)
        external
        view
        returns (address owner, address collToken, uint256 collId, uint256 collateralSize);
    function getPositionDebts(uint256 positionId)
        external
        view
        returns (address[] memory tokens, uint256[] memory debts);
    function getCollateralETHValue(uint256 positionId) external view returns (uint256);
    function getBorrowETHValue(uint256 positionId) external view returns (uint256);
}

interface ISushiswapSpellV1Attempt9 {
    struct Amounts {
        uint256 amtAUser;
        uint256 amtBUser;
        uint256 amtLPUser;
        uint256 amtABorrow;
        uint256 amtBBorrow;
        uint256 amtLPBorrow;
        uint256 amtAMin;
        uint256 amtBMin;
    }

    struct RepayAmounts {
        uint256 amtLPTake;
        uint256 amtLPWithdraw;
        uint256 amtARepay;
        uint256 amtBRepay;
        uint256 amtLPRepay;
        uint256 amtAMin;
        uint256 amtBMin;
    }

    struct WithdrawRepayAllAmounts {
        bool isRepayTokenA;
        uint256 amtLPTake;
        uint256 amtRepayMin;
    }

    function addLiquidityWMasterChef(address tokenA, address tokenB, Amounts calldata amt, uint256 pid) external payable;
    function removeLiquidityWMasterChef(address tokenA, address tokenB, RepayAmounts calldata amt) external;
    function WithdrawRepayAllAmountsWMasterChef(address tokenA, address tokenB, WithdrawRepayAllAmounts calldata amt)
        external;
    function harvestWMasterChef() external;
    function pairs(address tokenA, address tokenB) external view returns (address);
    function whitelistedLpTokens(address lpToken) external view returns (bool);
}

interface IUniswapV2FactoryAttempt9 {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2PairAttempt9 {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

contract ContractExecuteCallerAttempt9 {
    function forwardExecute(address bank, address spell, bytes calldata data)
        external
        payable
        returns (bool ok, bytes memory result)
    {
        return address(bank).call{value: msg.value}(
            abi.encodeWithSelector(IHomoraBankAttempt9.execute.selector, 0, spell, data)
        );
    }
}

contract CallbackTokenAttempt9 is IERC20Attempt9 {
    string public constant name = "Callback Token";
    string public constant symbol = "CBK";
    uint8 public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice Hypothesis under test: Alpha Homora's Sushi spell might expose a path to extract borrowed WETH
/// from the position lifecycle. This PoC checks the remaining live surfaces on the reset snapshot:
/// 1. WETH-only borrowing still gets routed into the LP via a Sushi swap instead of leaking to the executor.
/// 2. Closing/reducing the position sends the unwound assets back to the EOA only after debt repayment.
/// 3. Contract-based callback / fake-token entry points are blocked before they become a usable reentrancy surface.
contract Attempt9 is Test {
    struct OpenResult {
        uint256 positionId;
        uint256 collateralId;
        uint256 collateralSize;
        uint256 collateralValue;
        uint256 borrowValue;
        uint256 swapCount;
        uint256 usdcOutFromSwap;
        uint256 wethIntoSwap;
        address[] debtTokens;
        uint256[] debts;
        uint256 attackerEthAfterOpen;
        uint256 attackerWethAfterOpen;
        uint256 attackerUsdcAfterOpen;
    }

    struct CloseResult {
        bool usedFallbackRepayAll;
        string primaryRevert;
        uint256 borrowValueAfter;
        uint256 collateralValueAfter;
        uint256 collateralSizeAfter;
        uint256 attackerEthAfterClose;
        uint256 attackerWethAfterClose;
        uint256 attackerUsdcAfterClose;
        address[] debtTokensAfter;
        uint256[] debtsAfter;
    }

    uint256 internal constant EXPECTED_CHAIN_ID = 2401;
    uint256 internal constant PID_WETH_USDC = 1;
    uint256 internal constant USER_WETH_IN = 30 ether;
    uint256 internal constant BORROW_WETH_ONLY = 10 ether;
    bytes32 internal constant SWAP_TOPIC = keccak256("Swap(address,uint256,uint256,uint256,uint256,address)");

    address internal constant ATTACKER = address(0xBEEF);
    address internal constant BANK = 0xba5eBAf3fc1Fcca67147050Bf80462393814E54B;
    address internal constant SPELL = 0xDc9c7A2Bae15dD89271ae5701a6f4DB147BAa44C;
    address internal constant FACTORY = 0xC0AEe478e3658e2610c5F7A4A2E1777cE9e4f2Ac;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    IHomoraBankAttempt9 internal constant HOMORA = IHomoraBankAttempt9(BANK);
    ISushiswapSpellV1Attempt9 internal constant SUSHI_SPELL = ISushiswapSpellV1Attempt9(SPELL);
    IUniswapV2FactoryAttempt9 internal constant SUSHI_FACTORY = IUniswapV2FactoryAttempt9(FACTORY);
    IWETHAttempt9 internal constant WETH_TOKEN = IWETHAttempt9(WETH);
    IERC20Attempt9 internal constant USDC_TOKEN = IERC20Attempt9(USDC);

    uint256 internal forkBlock;
    address internal pair;

    function setUp() public {
        vm.createSelectFork("ch3");
        forkBlock = block.number;
        pair = SUSHI_SPELL.pairs(WETH, USDC);

        vm.label(ATTACKER, "Attempt9AttackerEOA");
        vm.label(BANK, "AlphaHomoraBank");
        vm.label(SPELL, "SushiswapSpellV1");
        vm.label(FACTORY, "SushiFactory");
        vm.label(WETH, "WETH");
        vm.label(USDC, "USDC");
        vm.label(pair, "SushiWETHUSDC");

        assertEq(block.chainid, EXPECTED_CHAIN_ID, "unexpected challenge chain id");
        assertTrue(pair != address(0), "missing canonical WETH/USDC pair");
    }

    function testBorrowedWethOnlyPathSwapsIntoLpAndCloseReturnsAssetsToEoa() public {
        OpenResult memory opened = _openWethOnlyPosition();

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", forkBlock);
        console.log("POSITION_ID:", opened.positionId);
        console.log("COLLATERAL_ID:", opened.collateralId);
        console.log("COLLATERAL_SIZE_AFTER_OPEN:", opened.collateralSize);
        console.log("COLLATERAL_ETH_VALUE_AFTER_OPEN:", opened.collateralValue);
        console.log("BORROW_ETH_VALUE_AFTER_OPEN:", opened.borrowValue);
        console.log("PAIR_SWAP_COUNT_DURING_OPEN:", opened.swapCount);
        console.log("USDC_OUT_FROM_SWAP_DURING_OPEN:", opened.usdcOutFromSwap);
        console.log("WETH_INTO_SWAP_DURING_OPEN:", opened.wethIntoSwap);
        console.log("ATTACKER_ETH_AFTER_OPEN:", opened.attackerEthAfterOpen);
        console.log("ATTACKER_WETH_AFTER_OPEN:", opened.attackerWethAfterOpen);
        console.log("ATTACKER_USDC_AFTER_OPEN:", opened.attackerUsdcAfterOpen);
        console.log("OPEN_DEBT_TOKEN_COUNT:", opened.debtTokens.length);
        for (uint256 i = 0; i < opened.debtTokens.length; ++i) {
            console.log("OPEN_DEBT_TOKEN:", opened.debtTokens[i]);
            console.log("OPEN_DEBT_AMOUNT:", opened.debts[i]);
        }

        assertGt(opened.positionId, 0, "position not opened");
        assertGt(opened.swapCount, 0, "WETH-only borrow path did not perform a Sushi swap");
        assertGt(opened.usdcOutFromSwap, 0, "borrowed WETH was not converted into USDC for LP");
        assertEq(opened.debtTokens.length, 1, "unexpected debt token count after WETH-only borrow");
        assertEq(opened.debtTokens[0], WETH, "WETH-only path created non-WETH debt");
        assertLt(opened.attackerWethAfterOpen, 1e15, "open path leaked significant WETH back to executor");
        assertLt(opened.attackerUsdcAfterOpen, 1e6, "open path leaked significant USDC back to executor");

        vm.roll(block.number + 20);
        CloseResult memory closed = _closePosition(opened.positionId, opened.collateralSize);

        console.log("USED_WITHDRAW_REPAY_ALL_FALLBACK:", closed.usedFallbackRepayAll);
        if (bytes(closed.primaryRevert).length != 0) {
            console.log("PRIMARY_REMOVE_REVERT:", closed.primaryRevert);
        }
        console.log("BORROW_ETH_VALUE_AFTER_CLOSE:", closed.borrowValueAfter);
        console.log("COLLATERAL_ETH_VALUE_AFTER_CLOSE:", closed.collateralValueAfter);
        console.log("COLLATERAL_SIZE_AFTER_CLOSE:", closed.collateralSizeAfter);
        console.log("ATTACKER_ETH_AFTER_CLOSE:", closed.attackerEthAfterClose);
        console.log("ATTACKER_ETH_DELTA_FROM_OPEN:", closed.attackerEthAfterClose - opened.attackerEthAfterOpen);
        console.log("ATTACKER_WETH_AFTER_CLOSE:", closed.attackerWethAfterClose);
        console.log("ATTACKER_USDC_AFTER_CLOSE:", closed.attackerUsdcAfterClose);
        console.log("CLOSE_DEBT_TOKEN_COUNT:", closed.debtTokensAfter.length);
        for (uint256 i = 0; i < closed.debtTokensAfter.length; ++i) {
            console.log("CLOSE_DEBT_TOKEN:", closed.debtTokensAfter[i]);
            console.log("CLOSE_DEBT_AMOUNT:", closed.debtsAfter[i]);
        }

        assertEq(closed.debtTokensAfter.length, 0, "close path left live debt");
        assertEq(closed.borrowValueAfter, 0, "borrow value survived full close");
        assertEq(closed.collateralSizeAfter, 0, "collateral remained trapped after close");
        assertGt(
            closed.attackerEthAfterClose, opened.attackerEthAfterOpen, "close path did not return native ETH to the EOA"
        );
        assertGt(closed.attackerUsdcAfterClose, 0, "close path did not return leftover USDC to the EOA");
    }

    function testContractExecutorCannotReachSpellCallbackSurface() public {
        ContractExecuteCallerAttempt9 caller = new ContractExecuteCallerAttempt9();

        (bool ok, bytes memory result) = _callThroughContract(caller, bytes(""));

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", forkBlock);
        console.log("CONTRACT_EXECUTOR_CALL_OK:", ok);
        console.log("CONTRACT_EXECUTOR_REVERT:", _decodeRevert(result));

        assertFalse(ok, "contract caller unexpectedly passed onlyEOA");
        assertEq(_decodeRevert(result), "not eoa", "unexpected contract-caller revert");
    }

    function testFakeCallbackTokenPairCannotEnterWhitelistedSpellPath() public {
        CallbackTokenAttempt9 fake = new CallbackTokenAttempt9();
        vm.label(address(fake), "CallbackToken");

        address fakePair = SUSHI_FACTORY.createPair(address(fake), WETH);
        vm.label(fakePair, "SushiFakeWethPair");

        bool whitelisted = SUSHI_SPELL.whitelistedLpTokens(fakePair);
        address cachedPair = SUSHI_SPELL.pairs(address(fake), WETH);

        console.log("CHAIN_ID:", block.chainid);
        console.log("FORK_BLOCK:", forkBlock);
        console.log("FAKE_PAIR:", fakePair);
        console.log("SPELL_PAIR_CACHE_FOR_FAKE:", cachedPair);
        console.log("FAKE_PAIR_WHITELISTED:", whitelisted);

        assertEq(cachedPair, address(0), "spell unexpectedly cached the fake pair");
        assertFalse(whitelisted, "fresh fake pair unexpectedly whitelisted");
    }

    function _openWethOnlyPosition() internal returns (OpenResult memory result) {
        vm.deal(ATTACKER, USER_WETH_IN + 5 ether);

        vm.startPrank(ATTACKER, ATTACKER);
        WETH_TOKEN.deposit{value: USER_WETH_IN}();
        require(WETH_TOKEN.approve(BANK, type(uint256).max), "WETH approve failed");
        require(USDC_TOKEN.approve(BANK, type(uint256).max), "USDC approve failed");

        vm.recordLogs();
        result.positionId = HOMORA.execute(
            0,
            SPELL,
            abi.encodeWithSelector(
                ISushiswapSpellV1Attempt9.addLiquidityWMasterChef.selector,
                WETH,
                USDC,
                ISushiswapSpellV1Attempt9.Amounts({
                    amtAUser: USER_WETH_IN,
                    amtBUser: 0,
                    amtLPUser: 0,
                    amtABorrow: BORROW_WETH_ONLY,
                    amtBBorrow: 0,
                    amtLPBorrow: 0,
                    amtAMin: 0,
                    amtBMin: 0
                }),
                PID_WETH_USDC
            )
        );
        Vm.Log[] memory entries = vm.getRecordedLogs();
        vm.stopPrank();

        (result.swapCount, result.usdcOutFromSwap, result.wethIntoSwap) = _summarizeSwap(entries);

        (,, result.collateralId, result.collateralSize) = HOMORA.getPositionInfo(result.positionId);
        result.collateralValue = HOMORA.getCollateralETHValue(result.positionId);
        result.borrowValue = HOMORA.getBorrowETHValue(result.positionId);
        (result.debtTokens, result.debts) = HOMORA.getPositionDebts(result.positionId);
        result.attackerEthAfterOpen = ATTACKER.balance;
        result.attackerWethAfterOpen = WETH_TOKEN.balanceOf(ATTACKER);
        result.attackerUsdcAfterOpen = USDC_TOKEN.balanceOf(ATTACKER);
    }

    function _closePosition(uint256 positionId, uint256 collateralSize) internal returns (CloseResult memory result) {
        bytes memory removeData = abi.encodeWithSelector(
            ISushiswapSpellV1Attempt9.removeLiquidityWMasterChef.selector,
            WETH,
            USDC,
            ISushiswapSpellV1Attempt9.RepayAmounts({
                amtLPTake: collateralSize,
                amtLPWithdraw: 0,
                amtARepay: type(uint256).max,
                amtBRepay: type(uint256).max,
                amtLPRepay: 0,
                amtAMin: 0,
                amtBMin: 0
            })
        );

        (bool ok, bytes memory ret) = _callExecute(positionId, removeData);
        if (!ok) {
            result.usedFallbackRepayAll = true;
            result.primaryRevert = _decodeRevert(ret);

            bytes memory repayAllData = abi.encodeWithSelector(
                ISushiswapSpellV1Attempt9.WithdrawRepayAllAmountsWMasterChef.selector,
                WETH,
                USDC,
                ISushiswapSpellV1Attempt9.WithdrawRepayAllAmounts({
                    isRepayTokenA: true, amtLPTake: collateralSize, amtRepayMin: 0
                })
            );

            (ok, ret) = _callExecute(positionId, repayAllData);
            assertTrue(ok, _decodeRevert(ret));
        }

        (,,, result.collateralSizeAfter) = HOMORA.getPositionInfo(positionId);
        result.borrowValueAfter = HOMORA.getBorrowETHValue(positionId);
        result.collateralValueAfter = HOMORA.getCollateralETHValue(positionId);
        (result.debtTokensAfter, result.debtsAfter) = HOMORA.getPositionDebts(positionId);
        result.attackerEthAfterClose = ATTACKER.balance;
        result.attackerWethAfterClose = WETH_TOKEN.balanceOf(ATTACKER);
        result.attackerUsdcAfterClose = USDC_TOKEN.balanceOf(ATTACKER);
    }

    function _callExecute(uint256 positionId, bytes memory spellData) internal returns (bool ok, bytes memory result) {
        vm.prank(ATTACKER, ATTACKER);
        return address(HOMORA)
            .call(abi.encodeWithSelector(IHomoraBankAttempt9.execute.selector, positionId, SPELL, spellData));
    }

    function _callThroughContract(ContractExecuteCallerAttempt9 caller, bytes memory bankCall)
        internal
        returns (bool ok, bytes memory result)
    {
        vm.prank(ATTACKER, ATTACKER);
        return caller.forwardExecute(BANK, SPELL, bankCall);
    }

    function _summarizeSwap(Vm.Log[] memory entries)
        internal
        view
        returns (uint256 swapCount, uint256 usdcOutFromSwap, uint256 wethIntoSwap)
    {
        address token0 = IUniswapV2PairAttempt9(pair).token0();
        bool usdcIsToken0 = token0 == USDC;

        for (uint256 i = 0; i < entries.length; ++i) {
            if (entries[i].emitter != pair || entries[i].topics.length == 0 || entries[i].topics[0] != SWAP_TOPIC) {
                continue;
            }

            swapCount += 1;
            (uint256 amount0In, uint256 amount1In, uint256 amount0Out, uint256 amount1Out) =
                abi.decode(entries[i].data, (uint256, uint256, uint256, uint256));

            if (usdcIsToken0) {
                wethIntoSwap += amount1In;
                usdcOutFromSwap += amount0Out;
            } else {
                wethIntoSwap += amount0In;
                usdcOutFromSwap += amount1Out;
            }
        }
    }

    function _decodeRevert(bytes memory revertData) internal pure returns (string memory) {
        if (revertData.length >= 68) {
            bytes4 selector;
            assembly {
                selector := mload(add(revertData, 0x20))
            }
            if (selector == 0x08c379a0) {
                bytes memory reasonData = new bytes(revertData.length - 4);
                for (uint256 i = 0; i < reasonData.length; ++i) {
                    reasonData[i] = revertData[i + 4];
                }
                return abi.decode(reasonData, (string));
            }
        }
        if (revertData.length == 0) {
            return "empty revert";
        }
        return "non-string revert";
    }
}
